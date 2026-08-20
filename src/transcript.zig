const std = @import("std");
const Io = std.Io;
const jsonu = @import("json_util.zig");

/// What the transcript tells us that the status payload does not.
pub const Snapshot = struct {
    /// input + cache read + cache creation from the newest main-thread turn.
    used: u64,
    /// Prompt cache lifetime in seconds: 300 or 3600.
    ttl_secs: u64,
    /// Epoch milliseconds of that turn.
    ts_ms: i64,
};

/// Bytes read from the end of the transcript on the first attempt.
const first_window: u64 = 256 * 1024;
/// Widened window, used once when the first holds no usable turn.
const second_window: u64 = 1024 * 1024;

/// How many assistant turns to examine while hunting for the cache flavor.
/// A session that never created cache would otherwise walk the whole window.
const max_records = 40;

/// Read the newest usage snapshot, or null if the transcript has none.
pub fn read(io: Io, gpa: std.mem.Allocator, path: []const u8) ?Snapshot {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    const len = file.length(io) catch return null;
    if (len == 0) return null;

    var window = first_window;
    while (true) {
        const size: usize = @intCast(@min(len, window));
        const buf = gpa.alloc(u8, size) catch return null;
        defer gpa.free(buf);

        const off = len - @as(u64, size);
        const n = file.readPositionalAll(io, buf, off) catch return null;
        const tail = trimPartialLine(buf[0..n], off > 0);

        if (scanTail(gpa, tail)) |s| return s;
        if (size >= len or window >= second_window) return null;
        window = second_window;
    }
}

/// Drop a leading fragment when the read started in the middle of a line.
fn trimPartialLine(tail: []const u8, started_mid_file: bool) []const u8 {
    if (!started_mid_file) return tail;
    const nl = std.mem.indexOfScalar(u8, tail, '\n') orelse return tail[0..0];
    return tail[nl + 1 ..];
}

/// Walk the lines backward and take the first usable assistant turn.
pub fn scanTail(gpa: std.mem.Allocator, tail: []const u8) ?Snapshot {
    var used: ?u64 = null;
    var ts_ms: i64 = 0;
    var ttl: ?u64 = null;
    var examined: usize = 0;

    var end = tail.len;
    while (end > 0 and examined < max_records) {
        var start = end;
        while (start > 0 and tail[start - 1] != '\n') start -= 1;
        const line = std.mem.trim(u8, tail[start..end], " \t\r\n");
        end = if (start == 0) 0 else start - 1;

        if (line.len == 0 or line[0] != '{') continue;

        var parsed = std.json.parseFromSlice(jsonu.Value, gpa, line, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;

        const kind = jsonu.str(jsonu.get(root, &.{"type"})) orelse continue;
        if (!std.mem.eql(u8, kind, "assistant")) continue;

        // Subagent turns are written to the same file. Their counts belong to
        // the subagent's context, not to ours. Counting them makes the bar lie
        // whenever a subagent runs.
        if (jsonu.boolean(jsonu.get(root, &.{"isSidechain"})) orelse false) continue;

        const usage = jsonu.get(root, &.{ "message", "usage" }) orelse continue;
        examined += 1;

        if (used == null) {
            used = sumTokens(usage);
            ts_ms = parseIso8601Ms(jsonu.str(jsonu.get(root, &.{"timestamp"})) orelse "") orelse 0;
        }
        if (ttl == null) ttl = ttlFrom(usage);
        if (used != null and ttl != null) break;
    }

    return .{
        .used = used orelse return null,
        // A tail with no cache creation at all is almost certainly a short
        // 5 minute session, so that is the safer default.
        .ttl_secs = ttl orelse 300,
        .ts_ms = ts_ms,
    };
}

fn sumTokens(usage: jsonu.Value) u64 {
    const keys = [_][]const u8{
        "input_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    };
    var total: i64 = 0;
    for (keys) |k| total += jsonu.int(jsonu.get(usage, &.{k})) orelse 0;
    return if (total < 0) 0 else @intCast(total);
}

/// Which prompt cache lifetime this turn wrote, if it wrote one at all.
fn ttlFrom(usage: jsonu.Value) ?u64 {
    const cc = jsonu.get(usage, &.{"cache_creation"}) orelse return null;
    if ((jsonu.int(jsonu.get(cc, &.{"ephemeral_1h_input_tokens"})) orelse 0) > 0) return 3600;
    if ((jsonu.int(jsonu.get(cc, &.{"ephemeral_5m_input_tokens"})) orelse 0) > 0) return 300;
    return null;
}

/// Parse "2026-08-19T21:50:12.345Z" to epoch milliseconds.
/// Claude Code writes UTC, so no zone handling is needed.
pub fn parseIso8601Ms(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T') return null;
    const y = parseU(s[0..4]) orelse return null;
    const mo = parseU(s[5..7]) orelse return null;
    const d = parseU(s[8..10]) orelse return null;
    const h = parseU(s[11..13]) orelse return null;
    const mi = parseU(s[14..16]) orelse return null;
    const sec = parseU(s[17..19]) orelse return null;

    const ms: i64 = if (s.len >= 23 and s[19] == '.') parseU(s[20..23]) orelse 0 else 0;
    const days = daysFromCivil(y, mo, d);
    return ((days * 86400) + h * 3600 + mi * 60 + sec) * 1000 + ms;
}

fn parseU(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// Days since the Unix epoch, by Howard Hinnant's civil calendar algorithm.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @as(i64, @intFromBool(m <= 2));
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const shift: i64 = if (m > 2) -3 else 9;
    const doy = @divFloor(153 * (m + shift) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parseIso8601Ms" {
    try std.testing.expectEqual(@as(i64, 0), parseIso8601Ms("1970-01-01T00:00:00.000Z").?);
    try std.testing.expectEqual(@as(i64, 1_000), parseIso8601Ms("1970-01-01T00:00:01Z").?);
    try std.testing.expectEqual(@as(i64, 1_787_176_212_000), parseIso8601Ms("2026-08-19T21:50:12.000Z").?);
    try std.testing.expectEqual(@as(i64, 1_787_176_212_345), parseIso8601Ms("2026-08-19T21:50:12.345Z").?);
    // A leap day, and a date before 2000, exercise the civil calendar maths.
    try std.testing.expectEqual(@as(i64, 1_709_208_000_000), parseIso8601Ms("2024-02-29T12:00:00.000Z").?);
    try std.testing.expectEqual(@as(i64, 946_684_799_000), parseIso8601Ms("1999-12-31T23:59:59.000Z").?);
    try std.testing.expect(parseIso8601Ms("not a date") == null);
    try std.testing.expect(parseIso8601Ms("") == null);
}

test "scanTail takes the newest main-thread turn" {
    const tail =
        \\{"type":"user","message":{"content":"hi"}}
        \\{"type":"assistant","timestamp":"2026-08-19T21:00:00.000Z","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":0}}}}
        \\{"type":"assistant","timestamp":"2026-08-19T21:10:00.000Z","message":{"usage":{"input_tokens":2,"cache_read_input_tokens":2000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}}}
    ;
    const s = scanTail(std.testing.allocator, tail).?;
    try std.testing.expectEqual(@as(u64, 2202), s.used);
    try std.testing.expectEqual(@as(u64, 3600), s.ttl_secs);
    try std.testing.expectEqual(parseIso8601Ms("2026-08-19T21:10:00.000Z").?, s.ts_ms);
}

test "scanTail ignores sidechain turns" {
    // The subagent turn is newest and huge. Counting it would triple the bar.
    const tail =
        \\{"type":"assistant","timestamp":"2026-08-19T21:00:00.000Z","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":0}}}}
        \\{"type":"assistant","isSidechain":true,"timestamp":"2026-08-19T21:05:00.000Z","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":999999,"cache_creation_input_tokens":0}}}
    ;
    const s = scanTail(std.testing.allocator, tail).?;
    try std.testing.expectEqual(@as(u64, 1000), s.used);
    try std.testing.expectEqual(@as(u64, 300), s.ttl_secs);
}

test "scanTail inherits cache flavor from an older turn" {
    // The newest turn only read cache, so it carries no flavor of its own.
    const tail =
        \\{"type":"assistant","timestamp":"2026-08-19T20:00:00.000Z","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":10,"cache_creation_input_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":10,"ephemeral_5m_input_tokens":0}}}}
        \\{"type":"assistant","timestamp":"2026-08-19T20:30:00.000Z","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}
    ;
    const s = scanTail(std.testing.allocator, tail).?;
    try std.testing.expectEqual(@as(u64, 501), s.used);
    try std.testing.expectEqual(@as(u64, 3600), s.ttl_secs);
}

test "scanTail survives junk and empty input" {
    try std.testing.expect(scanTail(std.testing.allocator, "") == null);
    try std.testing.expect(scanTail(std.testing.allocator, "not json\n{broken\n") == null);
    try std.testing.expect(scanTail(std.testing.allocator, "{\"type\":\"user\"}\n") == null);
}

test "trimPartialLine" {
    try std.testing.expectEqualStrings("b\nc", trimPartialLine("garbage\nb\nc", true));
    try std.testing.expectEqualStrings("a\nb", trimPartialLine("a\nb", false));
    try std.testing.expectEqualStrings("", trimPartialLine("no newline here", true));
}
