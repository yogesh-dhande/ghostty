//! Represents the "writer" thread for terminal IO. The reader side is
//! handled by the Termio struct itself and dependent on the underlying
//! implementation (i.e. if its a pty, manual, etc.).
//!
//! The writer thread does handle writing bytes to the pty but also handles
//! different events such as starting synchronized output, changing some
//! modes (like linefeed), etc. The goal is to offload as much from the
//! reader thread as possible since it is the hot path in parsing VT
//! sequences and updating terminal state.
//!
//! This thread state can only be used by one thread at a time.
pub const Thread = @This();

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");
const terminalpkg = @import("../terminal/main.zig");
const ScrollbackCompression = @import("../renderer/ScrollbackCompression.zig").ScrollbackCompression;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

threadlocal var current_callback: ?*CallbackData = null;

/// This stores the information that is coalesced.
const Coalesce = struct {
    /// The number of milliseconds to coalesce certain messages like resize for.
    /// Not all message types are coalesced.
    const min_ms = 25;

    resize: ?renderer.Size = null,
};

/// The number of milliseconds before we reset the synchronized output flag
/// if the running program hasn't already.
const sync_reset_ms = 1000;

/// The number of milliseconds between each movement during selection scrolling.
const selection_scroll_ms = 15;

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// The completion to use for the wakeup async handle that is present
/// on the termio.Writer.
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// This is used for timer-based selection scrolling.
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,

/// This is used to coalesce resize events.
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},

/// This timer is used to reset synchronized output modes so that
/// the terminal doesn't freeze with a bad actor.
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},

/// Incremental scrollback compression scheduling for headless sessions.
///
/// A rendered surface schedules this on its renderer thread, which wakes on
/// every terminal mutation. A headless session has no renderer thread, so the
/// IO thread — the only thread that mutates the terminal for such a session —
/// owns the same scheduler instead. Null for rendered surfaces.
compression: ?Compression = null,

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,

    /// True if linefeed mode is enabled. This is duplicated here so that the
    /// write thread doesn't need to grab a lock to check this on every write.
    linefeed_mode: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // This timer is used for selection scrolling.
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();

    // This timer is used to coalesce resize events.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // This timer is used to reset synchronized output modes.
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    if (self.compression) |*v| v.deinit();
    self.stop.deinit();
    self.loop.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    // Call child function so we can use errors...
    self.threadMain_(io) catch |err| {
        io.mailbox.deactivateAndDrain();
        log.warn("error in io thread err={}", .{err});

        // Use an arena to simplify memory management below
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // If there is an error, we replace our terminal screen with
        // the error message. It might be better in the future to send
        // the error to the surface thread and let the apprt deal with it
        // in some way but this works for now. Without this, the user would
        // just see a blank terminal window.
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        const t = io.renderer_state.terminal;

        // Hide the cursor
        t.modes.set(.cursor_visible, false);

        // This is weird but just ensures that no matter what our underlying
        // implementation we have the errors below. For example, Windows doesn't
        // have "OpenptyFailed".
        const Err = @TypeOf(err) || error{
            OpenptyFailed,
            InputNotFound,
            InputFailed,
        };

        switch (@as(Err, @errorCast(err))) {
            error.OpenptyFailed => {
                const str =
                    \\Your system cannot allocate any more pty devices.
                    \\
                    \\Ghostty requires a pty device to launch a new terminal.
                    \\This error is usually due to having too many terminal
                    \\windows open or having another program that is using too
                    \\many pty devices.
                    \\
                    \\Please free up some pty devices and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            error.InputNotFound,
            error.InputFailed,
            => {
                const str =
                    \\A configured `input` path was not found, was not readable,
                    \\was too large, or the underlying pty failed to accept
                    \\the write.
                    \\
                    \\Ghostty can't continue since it can't guarantee that
                    \\initial terminal state will be as desired. Please review
                    \\the value of `input` in your configuration file and
                    \\ensure that all the path values exist and are readable.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            else => {
                const str = std.fmt.allocPrint(
                    alloc,
                    \\error starting IO thread: {}
                    \\
                    \\The underlying shell or command was unable to be started.
                    \\This error is usually due to exhausting a system resource.
                    \\If this looks like a bug, please report it.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{err},
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
        }
    };

    // If our loop is not stopped, then we need to keep running so that
    // messages are drained and we can wait for the surface to send a stop
    // message.
    if (!self.loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

fn threadMain_(self: *Thread, io: *termio.Termio) !void {
    defer log.debug("IO thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"io".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Get the mailbox. This must be an SPSC mailbox for threading.
    const mailbox = switch (io.mailbox) {
        .spsc => |*v| v,
        // else => return error.TermioUnsupportedMailbox,
    };

    // This is the data sent to xev callbacks. We want a pointer to both
    // ourselves and the thread data so we can thread that through (pun intended).
    var cb: CallbackData = .{ .self = self, .io = io };

    // A headless session has no renderer thread to schedule scrollback
    // compression, so this thread does it. The flag is immutable, so this
    // read cannot race a rendered session's endpoint rebinding.
    if (comptime terminalpkg.compression_enabled) {
        if (io.headless) self.compression = try .init();
    }

    // Host-managed callbacks may synchronously feed output back into Ghostty
    // during threadEnter initial input, before the mailbox is activated.
    std.debug.assert(current_callback == null);
    current_callback = &cb;
    defer current_callback = null;

    // Run our thread start/end callbacks. This allows the implementation
    // to hook into the event loop as needed. The thread data is created
    // on the stack here so that it has a stable pointer throughout the
    // lifetime of the thread.
    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);

    // Start the async handlers.
    mailbox.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);
    io.mailbox.activate();
    defer io.mailbox.deactivateAndDrain();

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}

/// This is the data passed to xev callbacks on the thread.
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,

    /// Accessors required by `ScrollbackCompression`.
    pub fn compressionScheduler(self: *CallbackData) *Compression {
        return &self.self.compression.?;
    }

    pub fn compressionLoop(self: *CallbackData) *xev.Loop {
        return &self.self.loop;
    }

    pub fn compressionState(self: *CallbackData) *renderer.State {
        return self.io.renderer_state;
    }

    pub fn compressionEnabled(self: *CallbackData) bool {
        return self.io.config.scrollback_compression;
    }
};

/// Process host-managed output from this terminal's IO thread by queueing it
/// behind pending mailbox messages and draining until it completes. Returns
/// false when the caller is not on the IO thread for the provided termio.
pub fn processOutputOnCurrentThread(
    io: *termio.Termio,
    data: []const u8,
    notify_screen_change: bool,
) anyerror!bool {
    const cb = current_callback orelse return false;
    if (cb.io != io) return false;

    var output: termio.Message.BlockingOutput = .{
        .data = data,
        .notify_screen_change = notify_screen_change,
    };
    try cb.self.queueBlockingOutputOnCurrentThread(cb, &output);
    return true;
}

/// Whether the caller is running on the IO thread that serves `io`. Used to refuse a synchronous
/// wait that would otherwise deadlock on the very thread it waits for.
pub fn isCurrentThread(io: *termio.Termio) bool {
    const cb = current_callback orelse return false;
    return cb.io == io;
}

/// Queue a host-managed process exit from this terminal's IO thread by placing
/// it behind pending mailbox messages and draining until it is delivered.
/// Returns false when the caller is not on the IO thread for the provided
/// termio.
pub fn queueProcessExitOnCurrentThread(
    io: *termio.Termio,
    exit_code: u32,
    runtime_ms: u64,
) anyerror!bool {
    const cb = current_callback orelse return false;
    if (cb.io != io) return false;

    var process_exit: termio.Message.BlockingProcessExit = .{
        .data = .{
            .exit_code = exit_code,
            .runtime_ms = runtime_ms,
        },
    };
    try cb.self.queueBlockingProcessExitOnCurrentThread(cb, &process_exit);
    return true;
}

fn queueBlockingOutputOnCurrentThread(
    self: *Thread,
    cb: *CallbackData,
    output: *termio.Message.BlockingOutput,
) anyerror!void {
    if (self.flags.drain) return error.TermioDraining;

    const queue = cb.io.mailbox.spsc.queue;
    var redraw = false;
    var first_err: ?anyerror = null;

    while (queue.push(global.io(), .{
        .pty_output_blocking = output,
    }, .{ .instant = {} }) == 0) {
        const message = queue.pop(global.io()) orelse return error.TermioMailboxUnavailable;
        redraw = true;
        self.handleMessage(cb, message) catch |err| {
            if (first_err == null) first_err = err;
        };
    }

    while (!output.isDone()) {
        const message = queue.pop(global.io()) orelse return error.TermioMailboxUnavailable;
        redraw = true;
        self.handleMessage(cb, message) catch |err| {
            if (first_err == null) first_err = err;
        };
    }

    output.wait() catch |err| {
        if (first_err == null) first_err = err;
    };
    if (redraw) {
        self.wakeCompression(cb);
        try cb.io.notifyRenderer();
    }
    if (first_err) |err| return err;
}

fn queueBlockingProcessExitOnCurrentThread(
    self: *Thread,
    cb: *CallbackData,
    process_exit: *termio.Message.BlockingProcessExit,
) anyerror!void {
    if (self.flags.drain) return error.TermioDraining;

    const queue = cb.io.mailbox.spsc.queue;
    var redraw = false;
    var first_err: ?anyerror = null;

    while (queue.push(global.io(), .{
        .process_exit_blocking = process_exit,
    }, .{ .instant = {} }) == 0) {
        const message = queue.pop(global.io()) orelse return error.TermioMailboxUnavailable;
        redraw = true;
        self.handleMessage(cb, message) catch |err| {
            if (first_err == null) first_err = err;
        };
    }

    while (!process_exit.isDone()) {
        const message = queue.pop(global.io()) orelse return error.TermioMailboxUnavailable;
        redraw = true;
        self.handleMessage(cb, message) catch |err| {
            if (first_err == null) first_err = err;
        };
    }

    process_exit.wait() catch |err| {
        if (first_err == null) first_err = err;
    };
    if (redraw) {
        self.wakeCompression(cb);
        cb.io.notifyRenderer() catch |err| {
            if (first_err == null) first_err = err;
        };
    }
    if (first_err) |err| return err;
}

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    // We assert when starting the thread that this is the state
    const mailbox = cb.io.mailbox.spsc.queue;

    // If we're draining, we just drain the mailbox and return.
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| msg.deinit();
        return;
    }

    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.
    var redraw: bool = false;
    var first_err: ?anyerror = null;
    while (mailbox.pop(global.io())) |message| {
        // If we have a message we always redraw
        redraw = true;

        log.debug("mailbox message={s}", .{@tagName(message)});
        self.handleMessage(cb, message) catch |err| {
            if (first_err == null) first_err = err;
        };
    }

    // Trigger a redraw after we've drained so we don't waste cyces
    // messaging a redraw.
    if (redraw) {
        cb.io.notifyRenderer() catch |err| {
            if (first_err == null) first_err = err;
        };
    }

    if (first_err) |err| return err;
}

fn handleMessage(
    self: *Thread,
    cb: *CallbackData,
    message: termio.Message,
) anyerror!void {
    const io = cb.io;
    const data = &cb.data;

    switch (message) {
        .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
        .visibility_report => |v| try io.visibilityReport(
            data,
            v.visible,
            v.force,
        ),
        .crash => @panic("crash request, crashing intentionally"),
        .change_config => |config| {
            defer config.alloc.destroy(config.ptr);
            const compression_was_enabled = io.config.scrollback_compression;
            try io.changeConfig(data, config.ptr);

            // A newly enabled scheduler holds a stale activity token, so its
            // next wake would decide nothing changed and never compress the
            // history that accumulated while compression was off.
            if (!compression_was_enabled and io.config.scrollback_compression) {
                if (self.compression) |*compression| compression.resetActivity();
            }
        },
        .inspector => |v| self.flags.has_inspector = v,
        .resize => |v| self.handleResize(cb, v),
        .size_report => |v| try io.sizeReport(data, v),
        .clear_screen => |v| try io.clearScreen(data, v.history),
        .scroll_viewport => |v| io.scrollViewport(v),
        .selection_scroll => |v| {
            if (v) {
                self.startScrollTimer(cb);
            } else {
                self.stopScrollTimer();
            }
        },
        .jump_to_prompt => |v| try io.jumpToPrompt(v),
        .kitty_clipboard_grant_read => |v| {
            defer v.alloc.free(v.pw);
            try io.kittyClipboardGrant(v.pw, .read);
        },
        .kitty_clipboard_grant_write => |v| {
            defer v.alloc.free(v.pw);
            try io.kittyClipboardGrant(v.pw, .write);
        },
        .start_synchronized_output => self.startSynchronizedOutput(cb),
        .linefeed_mode => |v| self.flags.linefeed_mode = v,
        .focused => |v| try io.focusGained(data, v),
        .process_exit => |v| self.handleProcessExit(cb, v),
        .process_exit_blocking => |v| {
            self.handleProcessExit(cb, v.data);
            v.complete(null);
        },
        .pty_output_blocking => |v| {
            self.processHostOutput(
                cb,
                v.data,
                v.notify_screen_change,
            ) catch |err| {
                v.complete(err);
                return err;
            };
            v.complete(null);
        },
        // Nothing to do but report having got here: this message exists so a host can order
        // against messages queued before it (see Message.BlockingSync).
        .sync_blocking => |v| v.complete(null),
        .pty_output_small => |v| try self.processHostOutput(cb, v.data[0..v.len], true),
        .pty_output_stable => |v| try self.processHostOutput(cb, v, true),
        .pty_output_alloc => |v| {
            defer v.alloc.free(v.data);
            try self.processHostOutput(cb, v.data, true);
        },
        .write_small => |v| try io.queueWrite(
            data,
            v.data[0..v.len],
            self.flags.linefeed_mode,
        ),
        .write_stable => |v| try io.queueWrite(
            data,
            v,
            self.flags.linefeed_mode,
        ),
        .write_alloc => |v| {
            defer v.alloc.free(v.data);
            try io.queueWrite(
                data,
                v.data,
                self.flags.linefeed_mode,
            );
        },
        .write_raw_small => |v| try io.queueWrite(
            data,
            v.data[0..v.len],
            false,
        ),
        .write_raw_stable => |v| try io.queueWrite(
            data,
            v,
            false,
        ),
        .write_raw_alloc => |v| {
            defer v.alloc.free(v.data);
            try io.queueWrite(
                data,
                v.data,
                false,
            );
        },
    }
}

fn handleProcessExit(
    self: *Thread,
    cb: *CallbackData,
    process_exit: termio.Message.ProcessExit,
) void {
    self.flushCoalescedResize(cb);
    _ = cb.io.surface_mailbox.push(.{
        .child_exited = .{
            .exit_code = process_exit.exit_code,
            .runtime_ms = process_exit.runtime_ms,
        },
    }, .{ .forever = {} });
}

fn processHostOutput(
    self: *Thread,
    cb: *CallbackData,
    data: []const u8,
    notify_screen_change: bool,
) anyerror!void {
    self.flushCoalescedResize(cb);

    const messages_alloc = cb.io.terminal_stream.handler.alloc;
    var messages: std.ArrayListUnmanaged(termio.Message) = .empty;
    defer messages.deinit(messages_alloc);

    cb.io.processOutputCaptureMessages(data, notify_screen_change, &messages);

    var next: usize = 0;
    errdefer {
        while (next < messages.items.len) : (next += 1) {
            messages.items[next].deinit();
        }
    }
    while (next < messages.items.len) {
        const message = messages.items[next];
        next += 1;
        try self.handleMessage(cb, message);
    }
}

fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    self.sync_reset.reset(
        &self.loop,
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        sync_reset_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}

fn handleResize(self: *Thread, cb: *CallbackData, resize: renderer.Size) void {
    self.coalesce_data.resize = resize;

    // If the timer is already active we just return. In the future we want
    // to reset the timer up to a maximum wait time but for now this ensures
    // relatively smooth resizing.
    if (self.coalesce_c.state() == .active) return;

    self.coalesce.reset(
        &self.loop,
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.min_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}

fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}

fn flushCoalescedResize(self: *Thread, cb: *CallbackData) void {
    if (self.coalesce_data.resize) |v| {
        self.coalesce_data.resize = null;
        cb.io.resize(&cb.data, v) catch |err| {
            log.warn("error during resize err={}", .{err});
        };

        // A resize reflows the PageList, which is compression-relevant work
        // that may not be followed by any further output.
        self.wakeCompression(cb);
    }
}

fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.self.flushCoalescedResize(cb);

    return .disarm;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});

    // Unconditional because a backend reader thread signals compression by
    // notifying this async without publishing a message.
    cb.self.wakeCompression(cb);

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.stop();
    return .disarm;
}

fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;

    switch (self.scroll_c.state()) {
        // If it is already active, e.g. startScrollTimer is called multiple
        // times, then we just return. We can't simply check `scroll_active`
        // because its possible that `stopScrollTimer` was called but there
        // was no loop tick between then and now to halt out completion.
        .active => return,

        // If the completion is not active then we need to start it.
        .dead => self.scroll.run(
            &self.loop,
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}

fn stopScrollTimer(self: *Thread) void {
    // This will stop the scrolling on the next iteration.
    self.scroll_active = false;
}

fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    const self = cb.self;

    // Send the tick to the main surface
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );

    if (self.scroll_active) self.scroll.run(
        &self.loop,
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );

    return .disarm;
}

/// Wake the scrollback compression scheduler, if this thread owns one.
fn wakeCompression(self: *Thread, cb: *CallbackData) void {
    if (self.compression) |*compression| compression.wake(cb);
}

/// Wake a termio's scrollback compression scheduler from the shared terminal
/// parse path, which runs on a different thread depending on the backend: a
/// host-managed backend parses on this IO thread, while `Exec` parses on its
/// own reader thread.
///
/// The scheduler's timer belongs to the IO thread's event loop, so a foreign
/// thread must not touch it. It hands off through the mailbox wakeup async,
/// which is threadsafe, and `wakeupCallback` performs the wake.
pub fn wakeCompressionForTermio(io: *termio.Termio) void {
    if (current_callback) |cb| {
        if (cb.io == io) {
            cb.self.wakeCompression(cb);
            return;
        }
    }

    io.mailbox.notify();
}

/// The compression scheduler is hosted on `CallbackData` because it needs both
/// this thread's event loop and the termio's renderer state, and `CallbackData`
/// is the only stable pointer that has both.
const Compression = ScrollbackCompression(CallbackData);
