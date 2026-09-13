const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = BlockingQueue(termio.Message, 64);

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
        active: std.atomic.Value(bool) = .init(false),
        closed: bool = false,
        cond_active: std.Io.Condition = .init,
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup } };
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                while (v.queue.pop(global.io())) |msg| msg.deinit();
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where queues are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
    ) void {
        _ = self.sendTracked(msg, mutex);
    }

    /// Sends the given message without notifying there are messages. Returns
    /// false if the message was not queued and will never be processed.
    pub fn sendTracked(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
    ) bool {
        switch (self.*) {
            .spsc => |*mb| send: {
                // Try to write to the queue with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.queue.push(global.io(), msg, .{ .instant = {} }) > 0) break :send;

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    msg.deinit();
                    return false;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock(global.io());
                defer if (mutex) |m| m.lockUncancelable(global.io());
                if (mb.queue.push(global.io(), msg, .{ .forever = {} }) == 0) {
                    msg.deinit();
                    return false;
                }
            },
        }

        return true;
    }

    /// Sends the given message and wakes the mailbox consumer. Returns false
    /// if the message was not queued or the wakeup could not be guaranteed.
    pub fn sendAndNotifyTracked(
        self: *Mailbox,
        msg: termio.Message,
    ) bool {
        switch (self.*) {
            .spsc => |*mb| {
                const io = global.io();
                const queue = mb.queue;
                queue.mutex.lockUncancelable(io);
                defer queue.mutex.unlock(io);

                if (!mb.active.load(.acquire)) return false;
                if (queue.len == queue.data.len) return false;

                const old_write = queue.write;
                const bounds: Queue.Size = @intCast(queue.data.len);
                queue.data[queue.write] = msg;
                queue.write += 1;
                if (queue.write >= bounds) queue.write -= bounds;
                queue.len += 1;

                mb.wakeup.notify() catch |err| {
                    queue.write = old_write;
                    queue.len -= 1;
                    if (queue.not_full_waiters > 0) queue.cond_not_full.signal(io);

                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    return false;
                };
            },
        }

        return true;
    }

    /// Sends the given message and wakes the mailbox consumer. This blocks
    /// through transient startup and full-queue states so callers that cannot
    /// report retryable errors don't silently lose their message.
    pub fn sendAndNotifyBlocking(
        self: *Mailbox,
        msg: termio.Message,
    ) bool {
        switch (self.*) {
            .spsc => |*mb| {
                const io = global.io();
                const queue = mb.queue;
                queue.mutex.lockUncancelable(io);
                defer queue.mutex.unlock(io);

                while (!mb.active.load(.acquire) and !mb.closed) {
                    mb.cond_active.waitUncancelable(io, &queue.mutex);
                }
                if (mb.closed) return false;

                while (queue.len == queue.data.len) {
                    mb.wakeup.notify() catch |err| {
                        log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                        return false;
                    };

                    queue.not_full_waiters += 1;
                    queue.cond_not_full.waitUncancelable(io, &queue.mutex);
                    queue.not_full_waiters -= 1;

                    if (mb.closed) return false;
                }

                const old_write = queue.write;
                const bounds: Queue.Size = @intCast(queue.data.len);
                queue.data[queue.write] = msg;
                queue.write += 1;
                if (queue.write >= bounds) queue.write -= bounds;
                queue.len += 1;

                mb.wakeup.notify() catch |err| {
                    queue.write = old_write;
                    queue.len -= 1;
                    if (queue.not_full_waiters > 0) queue.cond_not_full.signal(io);

                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    return false;
                };
            },
        }

        return true;
    }

    /// Mark the mailbox as accepting messages that require a guaranteed
    /// consumer wakeup.
    pub fn activate(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*mb| {
                const io = global.io();
                mb.queue.mutex.lockUncancelable(io);
                defer mb.queue.mutex.unlock(io);
                mb.active.store(true, .release);
                mb.cond_active.broadcast(io);
            },
        }
    }

    /// Stop accepting guaranteed-wakeup messages and release queued messages.
    pub fn deactivateAndDrain(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*mb| {
                const io = global.io();
                mb.queue.mutex.lockUncancelable(io);
                mb.closed = true;
                mb.active.store(false, .release);
                mb.cond_active.broadcast(io);
                mb.queue.cond_not_full.broadcast(io);
                mb.queue.mutex.unlock(io);

                while (mb.queue.pop(io)) |msg| msg.deinit();
            },
        }
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};
