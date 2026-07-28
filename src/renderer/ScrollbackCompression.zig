//! Schedules incremental scrollback compression after terminal activity stops.
//!
//! The terminal decides when compression-relevant activity changes and performs
//! the actual work; this only provides idle scheduling on a host event loop and
//! never waits for the terminal lock.
//!
//! The host is generic because which thread owns this scheduling depends on the
//! session. Rendered sessions schedule it on the renderer thread, which already
//! wakes on every terminal mutation. Headless sessions have no renderer thread
//! at all, so their IO thread owns it instead. Both hosts drive the same
//! cadence off the same signal (PageList activity), so scrollback in a daemon
//! session compresses exactly as it does in a rendered one.

const std = @import("std");
const global = @import("../global.zig");
const xev = global.xev;
const State = @import("State.zig");
const terminalpkg = @import("../terminal/main.zig");

const log = std.log.scoped(.scrollback_compression);

/// `Host` must provide:
///
///   fn compressionScheduler(*Host) *ScrollbackCompression(Host)
///   fn compressionLoop(*Host) *xev.Loop
///   fn compressionState(*Host) *State
///   fn compressionEnabled(*Host) bool
///
/// The host pointer is passed in on every call rather than stored so that a
/// scheduler can be created before its host reaches its final address.
pub fn ScrollbackCompression(comptime Host: type) type {
    return struct {
        const Self = @This();

        const idle_interval = 250;
        const step_interval = 1;

        timer: xev.Timer,
        completion: xev.Completion = .{},
        reset_completion: xev.Completion = .{},
        activity: ?u64 = null,

        pub fn init() !Self {
            return .{ .timer = try xev.Timer.init() };
        }

        pub fn deinit(self: *Self) void {
            self.timer.deinit();
        }

        /// Reconsider existing history on the next wake even when no terminal
        /// activity occurred since the last check. Used when compression is
        /// enabled by a config reload.
        pub fn resetActivity(self: *Self) void {
            self.activity = null;
        }

        /// Start or postpone compression after terminal activity.
        pub fn wake(self: *Self, host: *Host) void {
            // If we have no compression then don't do anything.
            if (comptime !terminalpkg.compression_enabled) return;
            if (!host.compressionEnabled()) return;

            const state = host.compressionState();

            // PageList activity, rather than a generic wake, restarts the idle
            // interval. In particular, the inspector wakes the renderer every
            // frame without changing terminal contents and must not starve this
            // timer indefinitely.
            if (state.mutex.tryLock()) {
                defer state.mutex.unlock(global.io());
                const activity = state.terminal.compressionActivity();
                if (self.activity == activity) return;
                self.activity = activity;
            } else if (self.completion.state() == .active) {
                // Contention doesn't prove that compression-relevant activity
                // changed. Keep an existing deadline so frequent wakes cannot
                // postpone compression forever. The timer rechecks both the
                // activity token and lock availability before doing any work.
                return;
            }

            // Contention may mean parsing is active. Scheduling is a harmless
            // false positive when no compression work is actually pending, but
            // is necessary when no timer is already active.
            self.schedule(host, idle_interval);
        }

        /// Start the one-shot timer, or move its deadline if it is already active.
        fn schedule(self: *Self, host: *Host, delay_ms: u64) void {
            self.timer.reset(
                host.compressionLoop(),
                &self.completion,
                &self.reset_completion,
                delay_ms,
                Host,
                host,
                timerCallback,
            );
        }

        fn timerCallback(
            host_: ?*Host,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch |err| switch (err) {
                error.Canceled => return .disarm,
                else => {
                    log.warn("error in compression timer err={}", .{err});
                    return .disarm;
                },
            };

            const host = host_ orelse return .disarm;
            const self = host.compressionScheduler();

            if (self.step(host)) |delay| self.schedule(host, delay);
            return .disarm;
        }

        /// Try one bounded step without waiting for the terminal lock. The return
        /// value is the delay before another attempt, or null when work is done.
        fn step(self: *Self, host: *Host) ?u64 {
            if (!host.compressionEnabled()) return null;

            const state = host.compressionState();
            if (!state.mutex.tryLock()) return idle_interval;
            defer state.mutex.unlock(global.io());

            const activity = state.terminal.compressionActivity();
            if (self.activity != activity) {
                self.activity = activity;
                return idle_interval;
            }

            return switch (state.terminal.compress(.incremental)) {
                .pending => step_interval,
                .unsupported,
                .complete,
                => null,
            };
        }
    };
}

test "ScrollbackCompression: an idle host loop compresses cold scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = global.io();

    // A minimal host: an event loop plus the terminal state the scheduler
    // compresses. This is the same contract the IO thread satisfies for a
    // headless session.
    const Host = struct {
        const Self = @This();
        loop: xev.Loop,
        state: State,
        compression: ScrollbackCompression(Self) = undefined,

        pub fn compressionScheduler(self: *Self) *ScrollbackCompression(Self) {
            return &self.compression;
        }
        pub fn compressionLoop(self: *Self) *xev.Loop {
            return &self.loop;
        }
        pub fn compressionState(self: *Self) *State {
            return &self.state;
        }
        pub fn compressionEnabled(self: *Self) bool {
            _ = self;
            return true;
        }
    };

    var term = try terminalpkg.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10 * 1024 * 1024,
    });
    defer term.deinit(alloc);

    // Fill enough scrollback that there is cold history to compress.
    for (0..2000) |i| {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "scrollback line {d}\r\n", .{i}) catch unreachable;
        try term.printString(line);
    }

    var mutex: std.Io.Mutex = .init;
    var host: Host = .{
        .loop = try xev.Loop.init(.{}),
        .state = .{ .mutex = &mutex, .terminal = &term },
    };
    defer host.loop.deinit();
    host.compression = try .init();
    defer host.compression.deinit();

    // The first wake records activity and arms the idle timer; running the loop
    // to completion drives every scheduled step through to `.complete`. If the
    // scheduler ever failed to terminate, this would hang instead of returning.
    const started = std.Io.Timestamp.now(io, .awake);
    host.compression.wake(&host);
    try testing.expect(host.compression.completion.state() == .active);
    try host.loop.run(.until_done);
    try testing.expect(host.compression.completion.state() == .dead);

    // The idle interval elapsed, so the timer really fired rather than the loop
    // finding nothing to run.
    try testing.expect(started.durationTo(
        std.Io.Timestamp.now(io, .awake),
    ).toMilliseconds() >= 250);

    // Compression is transparent: the scrollback still reads back intact.
    const text = try term.plainString(alloc);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "scrollback line 1999") != null);
}
