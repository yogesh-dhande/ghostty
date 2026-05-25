//! HostManaged implements a terminal IO backend where the embedding host owns
//! the actual process/PTY. Ghostty keeps terminal parsing and rendering state,
//! while input bytes and resize events are handed back to the host.
const HostManaged = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

pub const ReceiveBufferCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
pub const ReceiveResizeCallback = *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void;

userdata: ?*anyopaque = null,
receive_buffer: ?ReceiveBufferCallback = null,
receive_resize: ?ReceiveResizeCallback = null,

pub const Config = struct {
    userdata: ?*anyopaque = null,
    receive_buffer: ?ReceiveBufferCallback = null,
    receive_resize: ?ReceiveResizeCallback = null,
};

pub fn init(config: Config) HostManaged {
    return .{
        .userdata = config.userdata,
        .receive_buffer = config.receive_buffer,
        .receive_resize = config.receive_resize,
    };
}

pub fn deinit(self: *HostManaged) void {
    self.* = undefined;
}

pub fn initTerminal(self: *HostManaged, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *HostManaged,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .host_managed = .{} };
}

pub fn threadExit(self: *HostManaged, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *HostManaged,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *HostManaged,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    const callback = self.receive_resize orelse return;
    callback(
        self.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

pub fn queueWrite(
    self: *HostManaged,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    const callback = self.receive_buffer orelse return;

    if (!linefeed) {
        callback(self.userdata, data.ptr, data.len);
        return;
    }

    var extra: usize = 0;
    for (data) |byte| {
        if (byte == '\r') extra += 1;
    }
    const out = try alloc.alloc(u8, data.len + extra);
    defer alloc.free(out);

    var out_i: usize = 0;
    for (data) |byte| {
        out[out_i] = byte;
        out_i += 1;
        if (byte == '\r') {
            out[out_i] = '\n';
            out_i += 1;
        }
    }

    callback(self.userdata, out.ptr, out.len);
}

pub fn childExitedAbnormally(
    self: *HostManaged,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *HostManaged, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

test {
    std.testing.refAllDecls(@This());
}
