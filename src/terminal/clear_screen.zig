//! The "clear screen" action (Cmd+K) expressed as the escape sequences that
//! perform it. Fork-owned; not part of upstream Ghostty.
//!
//! Upstream's `Termio.clearScreen` edits the terminal directly. A host that
//! keeps a replayable transcript of the bytes the terminal consumed (Spaces
//! persists them in `output.log`) cannot observe such an edit, so the live
//! screen and the replay of that transcript drift apart. This module builds the
//! same clear as ordinary escape bytes instead: the host feeds them through its
//! normal output path, so the parser, the transcript and the byte count all see
//! one stream, and any libghostty-vt build replays them.
//!
//! The rule is Ghostty's:
//!
//!   * Alternate screen: nothing. The running program owns that screen.
//!   * At a prompt (`Terminal.cursorIsAtPrompt`): erase the whole screen and the
//!     scrollback, leaving no history (ghostty-org/ghostty#970). The caller
//!     then writes a form feed (0x0C) to the shell so it repaints its prompt.
//!   * Otherwise: erase the scrollback, delete the rows above the cursor so the
//!     cursor row becomes the top row (blank rows grow at the bottom), and
//!     delete all Kitty images.
//!
//! The rows-above-the-cursor deletion is a scroll up by the cursor's row
//! followed by a scrollback erase: a full-screen scroll moves the rows through
//! the scrollback and keeps their soft-wrap and prompt marks, and the erase then
//! drops them. The scroll only reaches the whole screen with default margins,
//! no origin mode and no background color, so those are switched off for the
//! duration and put back afterwards.
//!
//! Where bytes cannot reproduce a direct edit exactly:
//!
//!   * A wrap-pending cursor (last column just written) loses its pending wrap
//!     when the cursor row moves, because every cursor movement clears it.
//!     Re-creating it would mean re-printing the cell under the cursor.
//!   * With origin mode on and a top margin below row 0, the cursor lands on the
//!     top margin row. Origin-mode addressing cannot reach the rows above it.
//!   * With origin mode on and the cursor left of the left margin, the cursor
//!     lands on the left margin column, for the same reason.
const std = @import("std");
const Terminal = @import("Terminal.zig");

/// Upper bound on the bytes `write` produces, so callers can use a fixed buffer.
pub const max_len = 256;

/// APC `a=d,d=A`: delete every Kitty image placement and its image data.
const kitty_delete_all = "\x1b_Ga=d,d=A\x1b\\";

pub const Outcome = enum {
    /// Nothing is cleared (alternate screen) and no bytes were written.
    skipped,
    /// The bytes clear the screen.
    cleared,
    /// The bytes clear the screen and the cursor sits at a shell prompt. The
    /// caller must also write a form feed (0x0C) to the shell so it repaints.
    cleared_at_prompt,
};

/// Writes the escape bytes that clear the terminal's active screen and
/// scrollback into `writer` (at most `max_len` bytes) and reports which case
/// applied. Reads the terminal only: the caller applies the bytes by feeding
/// them to the terminal's parser, and must do so before any other output so the
/// state they were built from still holds.
pub fn write(t: *Terminal, writer: *std.Io.Writer) std.Io.Writer.Error!Outcome {
    if (t.screens.active_key == .alternate) return .skipped;

    if (t.cursorIsAtPrompt()) {
        // Screen first: at a marked prompt the screen erase scrolls the screen
        // into the scrollback before clearing it, so the scrollback erase has
        // to come after it.
        try writer.writeAll("\x1b[2J\x1b[3J");
        return .cleared_at_prompt;
    }

    try writer.writeAll(kitty_delete_all);

    const cursor = &t.screens.active.cursor;
    const y = cursor.y;
    if (y == 0) {
        // Nothing sits above the cursor row.
        try writer.writeAll("\x1b[3J");
        return .cleared;
    }

    const region = t.scrolling_region;
    const origin = t.modes.get(.origin);
    const left_right = t.modes.get(.enable_left_and_right_margin);
    const top_bottom = region.top != 0 or region.bottom != t.rows - 1;
    const bg = cursor.style.bg_color;

    // Each of these resets homes the cursor, which is fine: the cursor is put
    // back below.
    if (origin) try writer.writeAll("\x1b[?6l");
    if (left_right) try writer.writeAll("\x1b[?69l");
    if (top_bottom) try writer.writeAll("\x1b[r");
    // Rows scrolled in at the bottom take the current background color, which a
    // direct deletion would not give them.
    if (bg != .none) try writer.writeAll("\x1b[49m");

    try writer.print("\x1b[{d}S\x1b[3J", .{y});

    switch (bg) {
        .none => {},
        .palette => |index| try writer.print("\x1b[48;5;{d}m", .{index}),
        .rgb => |rgb| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
    }
    if (top_bottom) try writer.print("\x1b[{d};{d}r", .{ region.top + 1, region.bottom + 1 });
    if (left_right) try writer.print("\x1b[?69h\x1b[{d};{d}s", .{ region.left + 1, region.right + 1 });
    if (origin) try writer.writeAll("\x1b[?6h");

    if (origin or left_right or top_bottom) {
        // The restores above homed the cursor, so address the target absolutely.
        // In origin mode the column is relative to the left margin.
        const column = if (origin) (if (cursor.x > region.left) cursor.x - region.left else 0) else cursor.x;
        try writer.print("\x1b[1;{d}H", .{column + 1});
    } else {
        // The scroll left the cursor on its row; move it up to the top.
        try writer.print("\x1b[{d}A", .{y});
    }
    return .cleared;
}

const testing = std.testing;

/// Parses `bytes` into `t` the way a host's output path does.
fn feed(t: *Terminal, bytes: []const u8) void {
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(bytes);
}

/// The clear as a direct edit, which the tests compare the bytes against. Away
/// from a prompt it is the edit `Termio.clearScreen` performs. At a prompt it is
/// the full clear Ghostty intends (ghostty-org/ghostty#970): `Termio.clearScreen`
/// erases the scrollback before the screen, and at a marked prompt the screen
/// erase first scrolls the screen into the scrollback, where it stays (the
/// `TODO: fix this` there).
fn clearDirectly(t: *Terminal) void {
    if (t.screens.active_key == .alternate) return;
    t.screens.active.clearSelection();
    if (t.cursorIsAtPrompt()) {
        t.eraseDisplay(.complete, false);
        t.eraseDisplay(.scrollback, false);
        return;
    }
    t.eraseDisplay(.scrollback, false);
    if (t.screens.active.cursor.y > 0) t.screens.active.eraseActive(t.screens.active.cursor.y - 1);
}

/// Applies the clear as bytes and returns the outcome.
fn clearWithBytes(t: *Terminal) !Outcome {
    var buf: [max_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const outcome = try write(t, &writer);
    feed(t, writer.buffered());
    return outcome;
}

/// Every row of the active screen plus any scrollback, as text.
fn screenText(t: *Terminal) ![]const u8 {
    return try t.screens.active.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
}

/// Two identical terminals: one is cleared with the direct edit, the other
/// through the bytes. Feed them with `setup` once they are in place.
const Pair = struct {
    direct: Terminal,
    bytes: Terminal,

    fn init(cols: u16, rows: u16) !Pair {
        var direct = try Terminal.init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows });
        errdefer direct.deinit(testing.allocator);
        const bytes = try Terminal.init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows });
        return .{ .direct = direct, .bytes = bytes };
    }

    fn deinit(self: *Pair) void {
        self.direct.deinit(testing.allocator);
        self.bytes.deinit(testing.allocator);
    }

    fn setup(self: *Pair, text: []const u8) void {
        feed(&self.direct, text);
        feed(&self.bytes, text);
    }

    /// Clears both and asserts the screens, scrollback and the cursor column and row agree.
    fn expectSameClear(self: *Pair) !Outcome {
        clearDirectly(&self.direct);
        const outcome = try clearWithBytes(&self.bytes);
        const direct_text = try screenText(&self.direct);
        defer testing.allocator.free(direct_text);
        const bytes_text = try screenText(&self.bytes);
        defer testing.allocator.free(bytes_text);
        try testing.expectEqualStrings(direct_text, bytes_text);
        try testing.expectEqual(self.direct.screens.active.cursor.x, self.bytes.screens.active.cursor.x);
        try testing.expectEqual(self.direct.screens.active.cursor.y, self.bytes.screens.active.cursor.y);
        try testing.expectEqual(self.direct.screens.active.pages.total_rows, self.bytes.screens.active.pages.total_rows);
        return outcome;
    }
};

test "clear screen: cursor mid-screen keeps its row and column and drops the rows above" {
    var pair = try Pair.init(20, 6);
    defer pair.deinit();
    pair.setup("one\r\ntwo\r\nthree\r\nfour\x1b[3;3H");
    try testing.expectEqual(Outcome.cleared, try pair.expectSameClear());
    const text = try screenText(&pair.bytes);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("three\nfour", text);
    try testing.expectEqual(@as(u16, 2), pair.bytes.screens.active.cursor.x);
    try testing.expectEqual(@as(u16, 0), pair.bytes.screens.active.cursor.y);
}

test "clear screen: scrollback is erased" {
    var pair = try Pair.init(10, 4);
    defer pair.deinit();
    pair.setup("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng");
    try testing.expect(pair.bytes.screens.active.pages.total_rows > 4);
    _ = try pair.expectSameClear();
    try testing.expectEqual(@as(usize, 4), pair.bytes.screens.active.pages.total_rows);
}

test "clear screen: cursor on the top row only erases scrollback" {
    var pair = try Pair.init(10, 4);
    defer pair.deinit();
    pair.setup("a\r\nb\r\nc\r\nd\r\ne\x1b[H");
    try testing.expectEqual(Outcome.cleared, try pair.expectSameClear());
    const text = try screenText(&pair.bytes);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("b\nc\nd\ne", text);
}

test "clear screen: cursor on the top row keeps a pending wrap" {
    var pair = try Pair.init(5, 3);
    defer pair.deinit();
    pair.setup("x\r\n12345\x1b[H12345");
    try testing.expect(pair.bytes.screens.active.cursor.pending_wrap);
    _ = try pair.expectSameClear();
    try testing.expectEqual(pair.direct.screens.active.cursor.pending_wrap, pair.bytes.screens.active.cursor.pending_wrap);
    try testing.expect(pair.bytes.screens.active.cursor.pending_wrap);
}

test "clear screen: cursor on the bottom row of a full screen" {
    var pair = try Pair.init(10, 4);
    defer pair.deinit();
    pair.setup("r1\r\nr2\r\nr3\r\nr4");
    _ = try pair.expectSameClear();
    const text = try screenText(&pair.bytes);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("r4", text);
    try testing.expectEqual(@as(u16, 0), pair.bytes.screens.active.cursor.y);
}

test "clear screen: a pending wrap is cleared when the cursor row moves" {
    // Documented deviation: every cursor movement clears pending wrap.
    var pair = try Pair.init(5, 3);
    defer pair.deinit();
    pair.setup("top\r\n12345");
    try testing.expect(pair.bytes.screens.active.cursor.pending_wrap);
    _ = try pair.expectSameClear();
    try testing.expect(pair.direct.screens.active.cursor.pending_wrap);
    try testing.expect(!pair.bytes.screens.active.cursor.pending_wrap);
    try testing.expectEqual(@as(u16, 4), pair.bytes.screens.active.cursor.x);
}

test "clear screen: soft-wrapped rows keep their wrap state" {
    var pair = try Pair.init(5, 4);
    defer pair.deinit();
    pair.setup("a\r\nbbbbbcc\x1b[2;1H");
    _ = try pair.expectSameClear();
    for (0..2) |y| {
        const direct = pair.direct.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = @intCast(y) } }).?;
        const bytes = pair.bytes.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = @intCast(y) } }).?;
        try testing.expectEqual(direct.row.wrap, bytes.row.wrap);
        try testing.expectEqual(direct.row.wrap_continuation, bytes.row.wrap_continuation);
    }
}

test "clear screen: scroll margins and origin mode survive and the screen matches" {
    var pair = try Pair.init(10, 8);
    defer pair.deinit();
    pair.setup("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\x1b[3;7r\x1b[?6h\x1b[3;4H");
    const before = pair.bytes.scrolling_region;
    // Origin mode and the margins cannot change what the screen shows.
    clearDirectly(&pair.direct);
    _ = try clearWithBytes(&pair.bytes);
    const direct_text = try screenText(&pair.direct);
    defer testing.allocator.free(direct_text);
    const bytes_text = try screenText(&pair.bytes);
    defer testing.allocator.free(bytes_text);
    try testing.expectEqualStrings(direct_text, bytes_text);
    try testing.expectEqual(before.top, pair.bytes.scrolling_region.top);
    try testing.expectEqual(before.bottom, pair.bytes.scrolling_region.bottom);
    try testing.expect(pair.bytes.modes.get(.origin));
    // Documented deviation: the cursor lands on the top margin row rather than
    // the unreachable row 0 above it.
    try testing.expectEqual(pair.bytes.scrolling_region.top, pair.bytes.screens.active.cursor.y);
    try testing.expectEqual(@as(u16, 3), pair.bytes.screens.active.cursor.x);
}

test "clear screen: scroll margins without origin mode match the direct edit" {
    var pair = try Pair.init(10, 8);
    defer pair.deinit();
    pair.setup("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\x1b[3;7r\x1b[5;4H");
    const before = pair.bytes.scrolling_region;
    _ = try pair.expectSameClear();
    try testing.expectEqual(before.top, pair.bytes.scrolling_region.top);
    try testing.expectEqual(before.bottom, pair.bytes.scrolling_region.bottom);
    try testing.expect(!pair.bytes.modes.get(.origin));
}

test "clear screen: left and right margins survive and the screen matches" {
    var pair = try Pair.init(10, 5);
    defer pair.deinit();
    pair.setup("a\r\nb\r\nc\r\nd\r\ne\x1b[?69h\x1b[3;8s\x1b[3;5H");
    const before = pair.bytes.scrolling_region;
    _ = try pair.expectSameClear();
    try testing.expect(pair.bytes.modes.get(.enable_left_and_right_margin));
    try testing.expectEqual(before.left, pair.bytes.scrolling_region.left);
    try testing.expectEqual(before.right, pair.bytes.scrolling_region.right);
}

test "clear screen: a background color keeps applying and does not color the new rows" {
    var pair = try Pair.init(10, 4);
    defer pair.deinit();
    pair.setup("a\r\nb\r\nc\x1b[44m\x1b[3;1H");
    _ = try pair.expectSameClear();
    try testing.expect(pair.bytes.screens.active.cursor.style.bg_color != .none);
    try testing.expectEqual(pair.direct.screens.active.cursor.style.bg_color, pair.bytes.screens.active.cursor.style.bg_color);
    // The bottom row is the one scrolled in; a direct deletion leaves it uncolored.
    const bottom_direct = pair.direct.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 3 } }).?;
    const bottom_bytes = pair.bytes.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 3 } }).?;
    try testing.expectEqual(bottom_direct.cell.content_tag, bottom_bytes.cell.content_tag);
}

test "clear screen: at a marked prompt the screen and scrollback are erased and a form feed is requested" {
    var pair = try Pair.init(20, 4);
    defer pair.deinit();
    pair.setup("out1\r\nout2\r\nout3\r\nout4\r\n\x1b]133;A\x07$ \x1b]133;B\x07");
    try testing.expect(pair.bytes.screens.active.pages.total_rows > 4);
    try testing.expectEqual(Outcome.cleared_at_prompt, try pair.expectSameClear());
    // Nothing survives, the scrollback included.
    try testing.expectEqual(@as(usize, 4), pair.bytes.screens.active.pages.total_rows);
    const text = try screenText(&pair.bytes);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);
}

test "clear screen: the alternate screen is left alone" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit(testing.allocator);
    feed(&t, "main\x1b[?1049halt");
    var buf: [max_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expectEqual(Outcome.skipped, try write(&t, &writer));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "clear screen: every case fits the buffer bound" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 200, .rows = 100 });
    defer t.deinit(testing.allocator);
    // The longest sequence: every restore plus an RGB background and 3-digit coordinates.
    feed(&t, "\x1b[2;99r\x1b[?69h\x1b[10;190s\x1b[?6h\x1b[48;2;255;255;255m\x1b[50;100H");
    var buf: [max_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expectEqual(Outcome.cleared, try write(&t, &writer));
    try testing.expect(writer.buffered().len <= max_len);
}
