const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const MessageData = @import("../datastruct/main.zig").MessageData;
const global = @import("../global.zig");

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~40 bytes at the time of writing this comment).
/// At the current size we can queue 26,000 messages before consuming a MB of
/// RAM, which matters for host-managed output traffic.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the largest
    /// other union value. It can be upped if we add a larger union member
    /// in the future.
    pub const WriteReq = MessageData(u8, 38);

    pub const ProcessExit = struct {
        exit_code: u32,
        runtime_ms: u64,
    };

    pub const BlockingOutput = struct {
        data: []const u8,
        notify_screen_change: bool,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        done: bool = false,
        err: ?anyerror = null,

        pub fn complete(self: *BlockingOutput, err: ?anyerror) void {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.err = err;
            self.done = true;
            self.cond.signal(io);
        }

        pub fn wait(self: *BlockingOutput) !void {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            while (!self.done) self.cond.waitUncancelable(io, &self.mutex);
            if (self.err) |err| return err;
        }

        pub fn isDone(self: *BlockingOutput) bool {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            return self.done;
        }
    };

    /// A message that carries nothing and does nothing, used purely to learn when this terminal's IO
    /// thread has reached it. Because the mailbox is FIFO, its completion proves every message queued
    /// before it was already handled — including a host-managed write, whose handling is what invokes
    /// the embedder's receive-buffer callback. Nothing here touches the stream parser or the terminal,
    /// so a host can order against its own input without injecting bytes that a parser mid-sequence
    /// (a DCS passthrough, a partial UTF-8 codepoint) would fold into the stream.
    pub const BlockingSync = struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        done: bool = false,
        err: ?anyerror = null,

        pub fn complete(self: *BlockingSync, err: ?anyerror) void {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.err = err;
            self.done = true;
            self.cond.signal(io);
        }

        pub fn wait(self: *BlockingSync) !void {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            while (!self.done) self.cond.waitUncancelable(io, &self.mutex);
            if (self.err) |err| return err;
        }
    };

    pub const BlockingProcessExit = struct {
        data: ProcessExit,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        done: bool = false,
        err: ?anyerror = null,

        pub fn complete(self: *BlockingProcessExit, err: ?anyerror) void {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.err = err;
            self.done = true;
            self.cond.signal(io);
        }

        pub fn wait(self: *BlockingProcessExit) !void {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            while (!self.done) self.cond.waitUncancelable(io, &self.mutex);
            if (self.err) |err| return err;
        }

        pub fn isDone(self: *BlockingProcessExit) bool {
            const io = global.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            return self.done;
        }
    };

    /// Request a color scheme report is sent to the PTY.
    color_scheme_report: struct {
        /// Force write the current color scheme
        force: bool,
    },

    /// Request a visibility report is sent to the PTY.
    visibility_report: struct {
        /// The visibility state to report.
        visible: bool,

        /// Send the report even when mode 2033 is disabled.
        force: bool,
    },

    /// Purposely crash the renderer. This is used for testing and debugging.
    /// See the "crash" binding action.
    crash: void,

    /// The derived configuration to update the implementation with. This
    /// is allocated via the allocator and is expected to be freed when done.
    change_config: struct {
        alloc: Allocator,
        ptr: *termio.Termio.DerivedConfig,
    },

    /// Activate or deactivate the inspector.
    inspector: bool,

    /// Resize the window.
    resize: renderer.Size,

    /// Request a size report is sent to the PTY ([in-band
    /// size report, mode 2048](https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83) and
    /// [XTWINOPS](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Functions-using-CSI-_-ordered-by-the-final-character-lparen-s-rparen:CSI-Ps;Ps;Ps-t.1EB0)).
    size_report: SizeReport,

    /// Clear the screen.
    clear_screen: struct {
        /// Include clearing the history
        history: bool,
    },

    /// Scroll the viewport
    scroll_viewport: terminal.Terminal.ScrollViewport,

    /// Selection scrolling. If this is set to true then the termio
    /// thread starts a timer that will trigger a `selection_scroll_tick`
    /// message back to the surface. This ping/pong is because the
    /// surface thread doesn't have access to an event loop from libghostty.
    selection_scroll: bool,

    /// Jump forward/backward n prompts.
    jump_to_prompt: isize,

    /// Send this when a synchronized output mode is started. This will
    /// start the timer so that the output mode is disabled after a
    /// period of time so that a bad actor can't hang the terminal.
    start_synchronized_output: void,

    /// Enable or disable linefeed mode (mode 20).
    linefeed_mode: bool,

    /// The surface gained or lost focus.
    focused: bool,

    /// The host-managed child process has exited.
    process_exit: ProcessExit,

    process_exit_blocking: *BlockingProcessExit,

    /// PTY output supplied by a host-managed embedder that must be processed
    /// before the caller returns.
    pty_output_blocking: *BlockingOutput,

    /// A no-op message whose only purpose is to be completed in mailbox order,
    /// so a host-managed embedder can wait for everything queued before it.
    sync_blocking: *BlockingSync,

    /// Record a Kitty clipboard protocol session grant for a password
    /// so future requests carrying it skip the permission prompt, for
    /// reads and writes respectively.
    kitty_clipboard_grant_read: KittyClipboardGrant,
    kitty_clipboard_grant_write: KittyClipboardGrant,

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: WriteReq.Stable,

    /// Write where the data is allocated and must be freed.
    write_alloc: WriteReq.Alloc,

    /// Raw write where the data fits in the union. This bypasses terminal
    /// linefeed mode.
    write_raw_small: WriteReq.Small,

    /// Raw write where the data pointer is stable. This bypasses terminal
    /// linefeed mode.
    write_raw_stable: WriteReq.Stable,

    /// Raw write where the data is allocated and must be freed. This bypasses
    /// terminal linefeed mode.
    write_raw_alloc: WriteReq.Alloc,

    /// PTY output supplied by a host-managed embedder where the data fits in
    /// the union.
    pty_output_small: WriteReq.Small,

    /// PTY output supplied by a host-managed embedder where the data pointer
    /// is stable.
    pty_output_stable: WriteReq.Stable,

    /// PTY output supplied by a host-managed embedder where the data is
    /// allocated and must be freed.
    pty_output_alloc: WriteReq.Alloc,

    /// The payload of the kitty_clipboard_grant_* messages. The
    /// password is allocated and must be freed.
    pub const KittyClipboardGrant = struct {
        alloc: Allocator,
        pw: []const u8,
    };

    /// Return a write request for the given data. This will use
    /// write_small if it fits or write_alloc otherwise. This should NOT
    /// be used for stable pointers which can be manually set to write_stable.
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_small = v },
            .alloc => |v| Message{ .write_alloc = v },
        };
    }

    /// Return a raw write request for the given data. This bypasses terminal
    /// linefeed mode and otherwise follows writeReq allocation behavior.
    pub fn writeReqRaw(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_raw_small = v },
            .alloc => |v| Message{ .write_raw_alloc = v },
        };
    }

    /// Return a PTY output request for host-managed output bytes.
    pub fn outputReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .pty_output_small = v },
            .alloc => |v| Message{ .pty_output_alloc = v },
        };
    }

    /// Free resources owned by a message that will not be processed.
    /// The message is invalid after this call.
    pub fn deinit(self: *const Message) void {
        switch (self.*) {
            .change_config => |v| {
                v.ptr.deinit();
                v.alloc.destroy(v.ptr);
            },
            .process_exit_blocking => |v| v.complete(error.TermioDraining),
            .pty_output_blocking => |v| v.complete(error.TermioDraining),
            .sync_blocking => |v| v.complete(error.TermioDraining),
            .write_alloc,
            .write_raw_alloc,
            .pty_output_alloc,
            => |v| v.alloc.free(v.data),
            .kitty_clipboard_grant_read,
            .kitty_clipboard_grant_write,
            => |v| v.alloc.free(v.pw),
            else => {},
        }
    }

    /// The types of size reports that we support.
    pub const SizeReport = terminal.size_report.Style;
};

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}
