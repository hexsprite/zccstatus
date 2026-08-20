const std = @import("std");
const Io = std.Io;

const th = @import("theme.zig");
const jsonu = @import("json_util.zig");
const transcript = @import("transcript.zig");
const gitinfo = @import("gitinfo.zig");
const render = @import("render.zig");
const Buf = @import("buf.zig").Buf;

/// Context window sizes. Claude Code does not send the window size, so it has
/// to be inferred from the model id.
const window_1m: u64 = 1_000_000;
const window_default: u64 = 200_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = init.minimal.args.toSlice(arena) catch &.{};

    var stdout_buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &writer.interface;

    if (hasFlag(args, "--demo")) {
        demo(w, usableColumns(init, args));
    } else {
        const theme = pickTheme(init, args);
        var out: Buf = .{};
        const usable = usableColumns(init, args);
        render.renderFit(&out, theme, gather(io, arena, readStdin(io, arena)), usable);
        out.append("\n");
        w.writeAll(out.slice()) catch return;
    }
    w.flush() catch return;
}

/// Sample data for `--demo`. It touches no clock and no filesystem, so the
/// three themes render identically every time and can be compared by eye.
const demo_input: render.Input = .{
    .model_name = "Opus 5",
    .cwd = "/Users/you/co/zccstatus",
    .cost_usd = 0.42,
    .lines_added = 156,
    .lines_removed = 23,
    .ctx_used = 112_000,
    .ctx_max = 1_000_000,
    .cache_left = 3480,
    .branch = "main",
    .detached = false,
};

/// Columns the bar may actually use.
///
/// Claude Code shares the status line's row with system notifications, which
/// sit on the right and truncate the bar when they collide with it. COLUMNS is
/// the whole terminal, so the notification zone has to be reserved by hand.
fn usableColumns(init: std.process.Init, args: []const [:0]const u8) usize {
    return applyMargin(columnsOf(init), marginOf(init, args));
}

/// Subtract the reserved zone, but never shrink below the point where the bar
/// has nothing left to shed. A cramped bar beats no bar.
pub fn applyMargin(cols: usize, margin: usize) usize {
    return if (cols > margin + render.min_columns) cols - margin else cols;
}

/// Width kept clear on the right. Tunable, because what lands there varies:
/// a slash-command hint is short, an auto-update notice is not.
fn marginOf(init: std.process.Init, args: []const [:0]const u8) usize {
    var margin = default_margin;
    if (init.environ_map.get("ZCC_MARGIN")) |v| {
        margin = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch margin;
    }
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--margin") and i + 1 < args.len) {
            i += 1;
            margin = std.fmt.parseInt(usize, args[i], 10) catch margin;
        } else if (std.mem.startsWith(u8, args[i], "--margin=")) {
            margin = std.fmt.parseInt(usize, args[i]["--margin=".len..], 10) catch margin;
        }
    }
    return margin;
}

const default_margin: usize = 8;

/// Terminal width, as Claude Code reports it.
///
/// Claude Code pipes the status line's output, so neither an ioctl nor
/// `tput cols` can see the terminal. Claude Code sets COLUMNS for exactly this
/// reason (v2.1.153 and later). Anything older falls back to a common width.
fn columnsOf(init: std.process.Init) usize {
    const raw = init.environ_map.get("COLUMNS") orelse return default_columns;
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return default_columns;
    return if (n == 0) default_columns else n;
}

const default_columns: usize = 100;

fn demo(w: *Io.Writer, columns: usize) void {
    const fills = [_]u64{ 112_000, 640_000, 930_000 };
    for (th.all) |t| {
        w.print("\n  {s}\n", .{t.name}) catch return;
        for (fills) |used| {
            var in = demo_input;
            in.ctx_used = used;
            // Shrink the countdown alongside the window so the demo also shows
            // the warn and critical colors.
            in.cache_left = if (used > 900_000) 40 else if (used > 600_000) 200 else 3480;

            var out: Buf = .{};
            render.renderFit(&out, t, in, if (columns > 2) columns - 2 else columns);
            w.writeAll("  ") catch return;
            w.writeAll(out.slice()) catch return;
            w.writeAll("\n") catch return;
        }
    }
    w.writeAll("\n") catch return;
}

fn hasFlag(args: []const [:0]const u8, name: []const u8) bool {
    for (args[@min(1, args.len)..]) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// Turn the status payload into the values the bar draws.
/// Every lookup falls back, so a payload from a newer or older Claude Code
/// still produces a bar instead of an error.
fn gather(io: Io, arena: std.mem.Allocator, payload: []const u8) render.Input {
    var in: render.Input = .{
        .model_name = "claude",
        .cwd = "",
        .cost_usd = 0,
        .lines_added = 0,
        .lines_removed = 0,
        .ctx_used = null,
        .ctx_max = window_default,
        .cache_left = null,
        .branch = null,
        .detached = false,
    };

    const parsed = std.json.parseFromSlice(jsonu.Value, arena, payload, .{}) catch return in;
    const root = parsed.value;

    if (jsonu.str(jsonu.get(root, &.{ "model", "display_name" }))) |v| in.model_name = v;

    // Claude Code sends the window and the usage directly. Prefer them: they
    // are authoritative, and they cost no file read.
    if (jsonu.int(jsonu.get(root, &.{ "context_window", "context_window_size" }))) |v| {
        if (v > 0) in.ctx_max = @intCast(v);
    } else {
        const model_id = jsonu.str(jsonu.get(root, &.{ "model", "id" })) orelse "";
        in.ctx_max = windowFor(model_id, jsonu.boolean(jsonu.get(root, &.{"exceeds_200k_tokens"})) orelse false);
    }
    if (jsonu.int(jsonu.get(root, &.{ "context_window", "total_input_tokens" }))) |v| {
        if (v >= 0) in.ctx_used = @intCast(v);
    }

    in.cwd = jsonu.str(jsonu.get(root, &.{ "workspace", "current_dir" })) orelse
        jsonu.str(jsonu.get(root, &.{"cwd"})) orelse "";

    if (jsonu.float(jsonu.get(root, &.{ "cost", "total_cost_usd" }))) |v| in.cost_usd = v;
    if (jsonu.int(jsonu.get(root, &.{ "cost", "total_lines_added" }))) |v| in.lines_added = v;
    if (jsonu.int(jsonu.get(root, &.{ "cost", "total_lines_removed" }))) |v| in.lines_removed = v;

    if (jsonu.str(jsonu.get(root, &.{"transcript_path"}))) |path| {
        if (transcript.read(io, arena, path)) |snap| {
            // Only fall back to the transcript when the payload lacked usage.
            if (in.ctx_used == null) in.ctx_used = snap.used;
            const now_ms = Io.Clock.now(.real, io).toMilliseconds();
            in.cache_left = cacheLeft(now_ms, snap.ts_ms, snap.ttl_secs);
        }
    }

    if (in.cwd.len > 0) {
        const buf = arena.alloc(u8, 128) catch return in;
        if (gitinfo.find(io, in.cwd, buf)) |head| {
            in.branch = head.name;
            in.detached = head.detached;
        }
    }

    return in;
}

/// Seconds of prompt cache left. A turn with no timestamp yields null rather
/// than a countdown measured from 1970.
pub fn cacheLeft(now_ms: i64, turn_ms: i64, ttl_secs: u64) ?i64 {
    if (turn_ms <= 0) return null;
    const elapsed = @divFloor(now_ms - turn_ms, 1000);
    return @as(i64, @intCast(ttl_secs)) - elapsed;
}

/// A `[1m]` model id means the million-token window. Anything unrecognised
/// falls back to 200k, so the bar errs pessimistic instead of flattering.
pub fn windowFor(model_id: []const u8, exceeds_200k: bool) u64 {
    if (std.mem.indexOf(u8, model_id, "[1m]") != null) return window_1m;
    if (exceeds_200k) return window_1m;
    return window_default;
}

fn pickTheme(init: std.process.Init, args: []const [:0]const u8) th.Theme {
    var theme = th.default;

    if (init.environ_map.get("ZCC_THEME")) |name| {
        if (th.byName(name)) |t| theme = t;
    }

    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--theme") and i + 1 < args.len) {
            i += 1;
            if (th.byName(args[i])) |t| theme = t;
        } else if (std.mem.startsWith(u8, a, "--theme=")) {
            if (th.byName(a["--theme=".len..])) |t| theme = t;
        }
    }
    return theme;
}

fn readStdin(io: Io, arena: std.mem.Allocator) []const u8 {
    var buf: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buf);
    return reader.interface.allocRemaining(arena, .limited(1 << 20)) catch "";
}

test "windowFor" {
    try std.testing.expectEqual(window_1m, windowFor("claude-opus-5[1m]", false));
    try std.testing.expectEqual(window_default, windowFor("claude-opus-5", false));
    try std.testing.expectEqual(window_1m, windowFor("something-unknown", true));
    try std.testing.expectEqual(window_default, windowFor("", false));
}

test "applyMargin" {
    try std.testing.expectEqual(@as(usize, 174), applyMargin(182, 8));
    try std.testing.expectEqual(@as(usize, 92), applyMargin(100, 8));
    // Too narrow to give anything back: keep every column.
    try std.testing.expectEqual(@as(usize, 34), applyMargin(34, 8));
    try std.testing.expectEqual(@as(usize, 40), applyMargin(40, 0));
}

test "cacheLeft" {
    const t0: i64 = 1_787_527_812_000;
    try std.testing.expectEqual(@as(i64, 3600), cacheLeft(t0, t0, 3600).?);
    try std.testing.expectEqual(@as(i64, 3480), cacheLeft(t0 + 120_000, t0, 3600).?);
    try std.testing.expectEqual(@as(i64, -60), cacheLeft(t0 + 360_000, t0, 300).?);
    try std.testing.expect(cacheLeft(t0, 0, 300) == null);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("buf.zig");
    _ = @import("theme.zig");
    _ = @import("json_util.zig");
    _ = @import("transcript.zig");
    _ = @import("gitinfo.zig");
    _ = @import("render.zig");
}
