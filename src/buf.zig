const std = @import("std");

/// Fixed-capacity output buffer.
///
/// The status line has a bounded width, so rendering never allocates. Writes
/// past the end are dropped: a clipped bar is better than a crashed one.
pub const Buf = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    pub fn append(self: *Buf, s: []const u8) void {
        const n = @min(s.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    pub fn print(self: *Buf, comptime f: []const u8, args: anytype) void {
        const w = std.fmt.bufPrint(self.bytes[self.len..], f, args) catch return;
        self.len += w.len;
    }

    pub fn slice(self: *const Buf) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Token count in the shortest readable form.
/// 950 -> "950", 9500 -> "9.5k", 112000 -> "112k", 1000000 -> "1M"
pub fn tokens(out: []u8, n: u64) []const u8 {
    if (n < 1_000) return std.fmt.bufPrint(out, "{d}", .{n}) catch "?";
    if (n < 10_000) return std.fmt.bufPrint(out, "{d}.{d}k", .{ n / 1000, (n % 1000) / 100 }) catch "?";
    if (n < 1_000_000) return std.fmt.bufPrint(out, "{d}k", .{n / 1000}) catch "?";
    const whole = n / 1_000_000;
    const tenth = (n % 1_000_000) / 100_000;
    if (tenth == 0) return std.fmt.bufPrint(out, "{d}M", .{whole}) catch "?";
    return std.fmt.bufPrint(out, "{d}.{d}M", .{ whole, tenth }) catch "?";
}

/// Duration for the cache countdown. The caller handles the expired case.
/// 42 -> "42s", 252 -> "4m12s", 3480 -> "58m", 3599 -> "1h00m"
///
/// Minutes round up, the way a countdown timer does. Truncating made a cache
/// written one second ago read "59m", which looks broken right after a refresh.
pub fn duration(out: []u8, secs: u64) []const u8 {
    if (secs < 60) return std.fmt.bufPrint(out, "{d}s", .{secs}) catch "?";
    if (secs < 600) return std.fmt.bufPrint(out, "{d}m{d:0>2}s", .{ secs / 60, secs % 60 }) catch "?";

    const mins = (secs + 59) / 60;
    if (mins < 60) return std.fmt.bufPrint(out, "{d}m", .{mins}) catch "?";
    return std.fmt.bufPrint(out, "{d}h{d:0>2}m", .{ mins / 60, mins % 60 }) catch "?";
}

/// Last component of a path. Trailing slashes are ignored.
/// "/Users/you/co/zccstatus" -> "zccstatus", "/" -> "/"
pub fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return if (path.len > 0) "/" else "";
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    return path[start..end];
}

/// Drop a trailing parenthetical from a model name.
/// "Opus 5 (1M context)" -> "Opus 5". "Opus 5" is returned unchanged.
///
/// Claude Code already spells the window out in `display_name`. The bar
/// re-adds it in a shorter form, so keeping the original would double it.
pub fn stripParenthetical(name: []const u8) []const u8 {
    const open = std.mem.lastIndexOfScalar(u8, name, '(') orelse return name;
    if (open == 0 or name[name.len - 1] != ')') return name;
    return std.mem.trimEnd(u8, name[0..open], " ");
}

/// Clip to at most `max` bytes and append an ellipsis.
///
/// The cut backs off to a UTF-8 codepoint boundary. A cut in the middle of a
/// codepoint prints a replacement blob, which looks like corruption.
pub fn clip(out: []u8, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (max < 2 or out.len < max + 3) return s[0..@min(s.len, max)];
    var cut = max - 1;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    @memcpy(out[0..cut], s[0..cut]);
    @memcpy(out[cut..][0..3], "\u{2026}");
    return out[0 .. cut + 3];
}

test "tokens" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("950", tokens(&b, 950));
    try std.testing.expectEqualStrings("9.5k", tokens(&b, 9500));
    try std.testing.expectEqualStrings("112k", tokens(&b, 112_000));
    try std.testing.expectEqualStrings("1M", tokens(&b, 1_000_000));
    try std.testing.expectEqualStrings("1.2M", tokens(&b, 1_250_000));
}

test "duration" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("42s", duration(&b, 42));
    try std.testing.expectEqualStrings("4m12s", duration(&b, 252));
    try std.testing.expectEqualStrings("58m", duration(&b, 3480));
    try std.testing.expectEqualStrings("1h02m", duration(&b, 3720));
    // A cache written moments ago must read as a full hour, not 59m.
    try std.testing.expectEqualStrings("1h00m", duration(&b, 3599));
    try std.testing.expectEqualStrings("1h00m", duration(&b, 3600));
    try std.testing.expectEqualStrings("59m", duration(&b, 3540));
}

test "basename" {
    try std.testing.expectEqualStrings("zccstatus", basename("/Users/you/co/zccstatus"));
    try std.testing.expectEqualStrings("zccstatus", basename("/Users/you/co/zccstatus/"));
    try std.testing.expectEqualStrings("/", basename("/"));
    try std.testing.expectEqualStrings("solo", basename("solo"));
}

test "stripParenthetical" {
    try std.testing.expectEqualStrings("Opus 5", stripParenthetical("Opus 5 (1M context)"));
    try std.testing.expectEqualStrings("Opus 5", stripParenthetical("Opus 5"));
    try std.testing.expectEqualStrings("Sonnet 5", stripParenthetical("Sonnet 5"));
    // Not a trailing parenthetical, so it stays put.
    try std.testing.expectEqualStrings("a (b) c", stripParenthetical("a (b) c"));
    try std.testing.expectEqualStrings("(all)", stripParenthetical("(all)"));
}

test "clip keeps codepoints whole" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("short", clip(&b, "short", 20));
    try std.testing.expectEqualStrings("abcdefghi\u{2026}", clip(&b, "abcdefghijklmno", 10));
    // The 'e' with an accent is two bytes; the cut must not land inside it.
    const out = clip(&b, "caf\u{e9}xxxxxxxxxx", 5);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "buf drops overflow instead of crashing" {
    var b: Buf = .{};
    for (0..300) |_| b.append("0123456789abcdef");
    try std.testing.expectEqual(@as(usize, 4096), b.len);
}
