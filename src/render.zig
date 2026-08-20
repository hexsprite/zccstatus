const std = @import("std");
const th = @import("theme.zig");
const bufmod = @import("buf.zig");

const Buf = bufmod.Buf;
const Rgb = th.Rgb;
const Pair = th.Pair;
const Theme = th.Theme;

/// Powerline separators. U+E0B0 points right, U+E0B2 points left. Both are in
/// every Powerline and Nerd Font.
const sep_r = "\u{e0b0}";
const sep_l = "\u{e0b2}";
const reset = "\x1b[0m";

/// Segment icons. All are Font Awesome codepoints that every Nerd Font carries.
const icon_model = "\u{f0e7}"; // bolt
const icon_ctx = "\u{f2db}"; // microchip
const icon_cwd = "\u{f07b}"; // folder
const icon_git = "\u{e0a0}"; // powerline branch
const icon_cache = "\u{f017}"; // clock

const cell_full = "\u{2593}";
const cell_empty = "\u{2591}";

/// The window every model has unless told otherwise.
pub const standard_window: u64 = 200_000;

const branch_max = 20;
const model_max = 18;
const dir_max = 28;

const gauge_min = 8;
const gauge_max = 16;

/// Below this much free space, splitting into two groups looks like a mistake
/// rather than a layout.
const min_split_gap = 6;

/// Everything the bar needs, already gathered. Nothing here reads the clock or
/// the filesystem, which is what makes the render testable.
pub const Input = struct {
    model_name: []const u8,
    cwd: []const u8,
    cost_usd: f64,
    lines_added: i64,
    lines_removed: i64,
    /// null when neither the payload nor the transcript had a usage figure.
    ctx_used: ?u64,
    ctx_max: u64,
    /// Seconds of prompt cache left. Negative means expired, null means unknown.
    cache_left: ?i64,
    branch: ?[]const u8,
    detached: bool,
};

/// Layout knobs. The fitter searches over these; the renderer just obeys them.
pub const Opts = struct {
    /// Spaces either side of a segment's content.
    pad: usize = 1,
    gauge: usize = gauge_min,
    /// Blank columns between the left and right groups. Zero means one chain.
    filler: usize = 0,
    split: bool = false,
    drop_lines: bool = false,
    drop_cost: bool = false,
    drop_git: bool = false,
    drop_cwd: bool = false,
    /// Last resort: shortest possible model label and a bare percentage.
    compact: bool = false,
};

/// Below this the bar has nothing useful left to shed, so it emits its
/// smallest form and may overflow. No real terminal is this narrow.
pub const min_columns = 30;

const Kind = enum { model, ctx, cwd, git, lines, cost, cache };
const Group = enum { left, right };
const Slot = struct { kind: Kind, pair: Pair, group: Group };

/// Fixed layout, used by tests and as the fallback when the width is unknown.
pub fn render(out: *Buf, t: Theme, in: Input) void {
    renderWith(out, t, in, .{});
}

/// Lay the bar out for a terminal `columns` wide.
///
/// Claude Code pipes the output, so the width cannot be read from the terminal
/// itself. It arrives in the COLUMNS environment variable instead.
pub fn renderFit(out: *Buf, t: Theme, in: Input, columns: usize) void {
    if (columns < min_columns) {
        return renderWith(out, t, in, .{ .compact = true, .drop_lines = true, .drop_cost = true, .drop_git = true, .drop_cwd = true, .gauge = 0 });
    }

    // One column stays free: a bar that exactly fills the row can wrap.
    const avail = columns - 1;
    var o: Opts = .{};

    // Shrink until the essentials fit, giving up the least useful things first.
    // The model and the countdown are the last two standing.
    while (measure(t, in, o) > avail) {
        if (!o.drop_lines) {
            o.drop_lines = true;
        } else if (!o.drop_cost) {
            o.drop_cost = true;
        } else if (!o.drop_git) {
            o.drop_git = true;
        } else if (o.gauge > gauge_min / 2) {
            o.gauge -= 1;
        } else if (!o.drop_cwd) {
            o.drop_cwd = true;
        } else if (o.gauge > 0) {
            o.gauge -= 1;
        } else if (!o.compact) {
            o.compact = true;
        } else break;
    }

    // Then spend whatever is left over, widest-value-first.
    var wider = o;
    wider.pad = 2;
    if (measure(t, in, wider) <= avail) o = wider;

    while (o.gauge < gauge_max) {
        var g = o;
        g.gauge += 1;
        if (measure(t, in, g) > avail) break;
        o = g;
    }

    // Push the tail to the right edge if the gap is big enough to read as one.
    var s = o;
    s.split = true;
    s.filler = 0;
    const base = measure(t, in, s);
    if (avail > base + min_split_gap) {
        s.filler = avail - base;
        o = s;
    }

    renderWith(out, t, in, o);
}

fn measure(t: Theme, in: Input, o: Opts) usize {
    var probe: Buf = .{};
    renderWith(&probe, t, in, o);
    return displayWidth(probe.slice());
}

/// Columns a rendered bar occupies. Escape sequences take none, and every
/// glyph the bar uses is one column wide.
pub fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        w += 1;
    }
    return w;
}

fn buildSlots(t: Theme, in: Input, o: Opts, slots: *[7]Slot) usize {
    var n: usize = 0;
    slots[n] = .{ .kind = .model, .pair = t.model, .group = .left };
    n += 1;
    slots[n] = .{ .kind = .ctx, .pair = t.ctx, .group = .left };
    n += 1;
    if (in.cwd.len > 0 and !o.drop_cwd) {
        slots[n] = .{ .kind = .cwd, .pair = t.cwd, .group = .left };
        n += 1;
    }
    if (in.branch != null and !o.drop_git) {
        slots[n] = .{ .kind = .git, .pair = t.git, .group = .left };
        n += 1;
    }
    // When the bar splits, the tail carries the numbers you glance at, which
    // also keeps both ends weighted instead of leaving a hole in the middle.
    if (!o.drop_lines) {
        slots[n] = .{ .kind = .lines, .pair = t.lines, .group = if (o.split) .right else .left };
        n += 1;
    }
    // The tail carries what you glance at, so it gets the right edge.
    if (!o.drop_cost and in.cost_usd > 0) {
        slots[n] = .{ .kind = .cost, .pair = t.cost, .group = if (o.split) .right else .left };
        n += 1;
    }
    slots[n] = .{ .kind = .cache, .pair = cachePair(t, in.cache_left), .group = if (o.split) .right else .left };
    n += 1;
    return n;
}

pub fn renderWith(out: *Buf, t: Theme, in: Input, o: Opts) void {
    var slots: [7]Slot = undefined;
    const n = buildSlots(t, in, o, &slots);

    var first_right: usize = n;
    for (slots[0..n], 0..) |s, i| {
        if (s.group == .right) {
            first_right = i;
            break;
        }
    }

    // Left group: separators point right, each wearing the ending segment's
    // background as its foreground.
    for (slots[0..first_right], 0..) |s, i| {
        setFg(out, s.pair.fg);
        setBg(out, s.pair.bg);
        pad(out, o.pad);
        emit(out, t, s, in, o);
        pad(out, o.pad);

        if (i + 1 < first_right) {
            setFg(out, s.pair.bg);
            setBg(out, slots[i + 1].pair.bg);
        } else {
            out.append(reset);
            setFg(out, s.pair.bg);
        }
        out.append(sep_r);
    }
    out.append(reset);

    if (first_right >= n) return;

    pad(out, o.filler);

    // Right group: separators point left and sit before the segment they open.
    var prev_bg: ?Rgb = null;
    for (slots[first_right..n]) |s| {
        setFg(out, s.pair.bg);
        if (prev_bg) |b| setBg(out, b) else out.append(reset);
        out.append(sep_l);

        setFg(out, s.pair.fg);
        setBg(out, s.pair.bg);
        pad(out, o.pad);
        emit(out, t, s, in, o);
        pad(out, o.pad);
        prev_bg = s.pair.bg;
    }
    out.append(reset);
}

fn pad(out: *Buf, n: usize) void {
    for (0..n) |_| out.append(" ");
}

fn emit(out: *Buf, t: Theme, s: Slot, in: Input, o: Opts) void {
    var scratch: [64]u8 = undefined;
    switch (s.kind) {
        .model => {
            out.append(icon_model);
            out.append(" ");
            const limit: usize = if (o.compact) 8 else model_max;
            out.append(bufmod.clip(&scratch, bufmod.stripParenthetical(in.model_name), limit));
            // Only an unusual window is worth the width. The standard one is
            // the default everywhere and says nothing.
            if (!o.compact and in.ctx_max != standard_window) {
                var w: [16]u8 = undefined;
                out.print(" ({s})", .{bufmod.tokens(&w, in.ctx_max)});
            }
        },
        .ctx => emitCtx(out, t, s.pair, in, o),
        .cwd => {
            out.append(icon_cwd);
            out.append(" ");
            out.append(bufmod.clip(&scratch, bufmod.basename(in.cwd), dir_max));
        },
        .git => {
            out.append(icon_git);
            out.append(" ");
            if (in.detached) out.append("@");
            out.append(bufmod.clip(&scratch, in.branch.?, branch_max));
        },
        .lines => {
            setFg(out, t.add);
            out.print("+{d}", .{in.lines_added});
            setFg(out, s.pair.fg);
            out.append("/");
            setFg(out, t.del);
            out.print("-{d}", .{in.lines_removed});
            setFg(out, s.pair.fg);
        },
        .cost => out.print("${d:.2}", .{in.cost_usd}),
        .cache => emitCache(out, in),
    }
}

fn emitCtx(out: *Buf, t: Theme, pair: Pair, in: Input, o: Opts) void {
    out.append(icon_ctx);
    out.append(" ");

    const used = in.ctx_used orelse {
        out.append("--");
        return;
    };

    const pct = percent(used, in.ctx_max);
    if (!o.compact) {
        var a: [16]u8 = undefined;
        out.append(bufmod.tokens(&a, used));
        out.append(" ");
    }

    const hot = severity(t, pct);
    const filled = (pct * o.gauge + 50) / 100;

    setFg(out, hot);
    for (0..o.gauge) |i| out.append(if (i < filled) cell_full else cell_empty);

    setFg(out, pair.fg);
    out.print(" {d}%", .{pct});
}

/// The countdown carries its severity in the whole segment, not just the text.
///
/// Tinting only the text is what broke here once: a theme whose cache
/// background equals its critical color rendered the number invisible.
/// Swapping the pair keeps foreground and background chosen together.
pub fn cachePair(t: Theme, left: ?i64) Pair {
    const secs = left orelse return t.cache;
    if (secs < 60) return alert(t, t.crit);
    if (secs < 300) return alert(t, t.warn);
    return t.cache;
}

/// An alert block, with ink chosen by how bright the block actually is.
fn alert(t: Theme, bg: Rgb) Pair {
    return .{ .fg = if (luma(bg) >= 128) t.ink_dark else t.ink_light, .bg = bg };
}

fn emitCache(out: *Buf, in: Input) void {
    out.append(icon_cache);
    out.append(" ");

    const left = in.cache_left orelse {
        out.append("--");
        return;
    };
    if (left <= 0) {
        out.append("cold");
        return;
    }

    var a: [16]u8 = undefined;
    out.append(bufmod.duration(&a, @intCast(left)));
}

/// Percent of the window in use, capped at 100.
pub fn percent(used: u64, max: u64) u64 {
    if (max == 0) return 0;
    return @min(used * 100 / max, 100);
}

fn severity(t: Theme, pct: u64) Rgb {
    if (pct < 60) return t.ok;
    if (pct < 85) return t.warn;
    return t.crit;
}

fn setFg(out: *Buf, c: Rgb) void {
    out.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

fn setBg(out: *Buf, c: Rgb) void {
    out.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// Approximate relative luminance, 0 to 255. Enough to catch a foreground that
/// disappears into its own background.
fn luma(c: Rgb) u32 {
    return (2126 * @as(u32, c.r) + 7152 * @as(u32, c.g) + 722 * @as(u32, c.b)) / 10000;
}

fn contrast(p: Pair) u32 {
    const a = luma(p.fg);
    const b = luma(p.bg);
    return if (a > b) a - b else b - a;
}

/// Strip escapes so tests can assert on the text the user actually sees.
fn plain(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        try list.append(alloc, s[i]);
        i += 1;
    }
    return list.toOwnedSlice(alloc);
}

const test_input: Input = .{
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

fn plainRender(alloc: std.mem.Allocator, t: Theme, in: Input) ![]u8 {
    var out: Buf = .{};
    render(&out, t, in);
    return plain(alloc, out.slice());
}

test "percent caps at 100" {
    try std.testing.expectEqual(@as(u64, 11), percent(112_000, 1_000_000));
    try std.testing.expectEqual(@as(u64, 100), percent(300_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), percent(5, 0));
}

test "full bar text" {
    const text = try plainRender(std.testing.allocator, th.neon, test_input);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        " \u{f0e7} Opus 5 (1M) \u{e0b0} \u{f2db} 112k \u{2593}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591} 11% \u{e0b0}" ++
            " \u{f07b} zccstatus \u{e0b0} \u{e0a0} main \u{e0b0} +156/-23 \u{e0b0} $0.42 \u{e0b0} \u{f017} 58m \u{e0b0}",
        text,
    );
}

test "separator chains previous background into next" {
    var out: Buf = .{};
    render(&out, th.neon, test_input);
    const s = out.slice();
    const want = "\x1b[38;2;255;42;109m\x1b[48;2;26;16;64m" ++ sep_r;
    try std.testing.expect(std.mem.indexOf(u8, s, want) != null);
    try std.testing.expect(std.mem.endsWith(u8, s, reset));
}

test "lines are always shown, even at zero" {
    var in = test_input;
    in.lines_added = 0;
    in.lines_removed = 0;
    const text = try plainRender(std.testing.allocator, th.neon, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "+0/-0") != null);
}

test "optional segments drop out" {
    var in = test_input;
    in.branch = null;
    in.cost_usd = 0;
    const text = try plainRender(std.testing.allocator, th.blade, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "main") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zccstatus") != null);
}

test "unknown context and cold cache degrade to placeholders" {
    var in = test_input;
    in.ctx_used = null;
    in.cache_left = -5;
    const text = try plainRender(std.testing.allocator, th.acid, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{f2db} --") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cold") != null);
}

test "gauge fills with the window" {
    var in = test_input;
    in.ctx_used = 1_000_000;
    const text = try plainRender(std.testing.allocator, th.neon, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, cell_full ** gauge_min ++ " 100%") != null);
}

test "long branch clips with an ellipsis" {
    var in = test_input;
    in.branch = "feat/a-very-long-branch-name-indeed";
    const text = try plainRender(std.testing.allocator, th.neon, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2026}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "indeed") == null);
}

test "an empty directory leaves no hollow segment" {
    var in = test_input;
    in.cwd = "";
    const text = try plainRender(std.testing.allocator, th.neon, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, icon_cwd) == null);
}

test "model label shortens Claude Code's own name" {
    // The real payload sends "Opus 5 (1M context)". Appending the window to
    // that produced "Opus 5 (1M cont...", clipped mid-word.
    var in = test_input;
    in.model_name = "Opus 5 (1M context)";
    const text = try plainRender(std.testing.allocator, th.neon, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Opus 5 (1M) ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "context") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2026}") == null);
}

test "a standard window is not spelled out" {
    var in = test_input;
    in.model_name = "Sonnet 5";
    in.ctx_max = standard_window;
    const text = try plainRender(std.testing.allocator, th.neon, in);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Sonnet 5 \u{e0b0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "200k)") == null);
}

test "cachePair swaps the block instead of tinting the text" {
    // acid's cache background and critical color were the same pink. Tinting
    // only the text made the countdown invisible below 60 seconds.
    try std.testing.expect(contrast(cachePair(th.acid, 40)) > 60);
    try std.testing.expect(contrast(cachePair(th.acid, 200)) > 60);
    try std.testing.expect(contrast(cachePair(th.acid, -5)) > 60);
    try std.testing.expect(contrast(cachePair(th.acid, null)) > 60);
}

test "every theme keeps every segment legible" {
    const min_gap: u32 = 60;
    for (th.all) |t| {
        const pairs = [_]struct { name: []const u8, p: Pair }{
            .{ .name = "model", .p = t.model },
            .{ .name = "ctx", .p = t.ctx },
            .{ .name = "cwd", .p = t.cwd },
            .{ .name = "git", .p = t.git },
            .{ .name = "lines", .p = t.lines },
            .{ .name = "cost", .p = t.cost },
            .{ .name = "cache", .p = t.cache },
            .{ .name = "cache warn", .p = cachePair(t, 200) },
            .{ .name = "cache crit", .p = cachePair(t, 30) },
            .{ .name = "cache cold", .p = cachePair(t, -1) },
            .{ .name = "ctx ok", .p = .{ .fg = t.ok, .bg = t.ctx.bg } },
            .{ .name = "ctx warn", .p = .{ .fg = t.warn, .bg = t.ctx.bg } },
            .{ .name = "ctx crit", .p = .{ .fg = t.crit, .bg = t.ctx.bg } },
            .{ .name = "lines add", .p = .{ .fg = t.add, .bg = t.lines.bg } },
            .{ .name = "lines del", .p = .{ .fg = t.del, .bg = t.lines.bg } },
        };
        for (pairs) |x| {
            if (contrast(x.p) < min_gap) {
                std.debug.print("theme {s}: {s} contrast {d}\n", .{ t.name, x.name, contrast(x.p) });
                return error.LowContrast;
            }
        }

        // Empty gauge cells are meant to recede, so they get a lower floor.
        // They still have to be visible, or the gauge loses its scale.
        const dim: Pair = .{ .fg = t.bar_dim, .bg = t.ctx.bg };
        if (contrast(dim) < 40) {
            std.debug.print("theme {s}: bar_dim contrast {d}\n", .{ t.name, contrast(dim) });
            return error.LowContrast;
        }
    }
}

test "displayWidth ignores escapes" {
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("\x1b[0mabc"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\x1b[38;2;1;2;3m\u{e0b0}\u{2593}"));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "renderFit never exceeds the terminal width" {
    // Every width from cramped to enormous, across all themes.
    for (th.all) |t| {
        var cols: usize = min_columns;
        while (cols <= 300) : (cols += 1) {
            var out: Buf = .{};
            renderFit(&out, t, test_input, cols);
            const w = displayWidth(out.slice());
            if (w > cols) {
                std.debug.print("theme {s}: {d} cols produced {d}\n", .{ t.name, cols, w });
                return error.Overflow;
            }
        }
    }
}

test "renderFit spends a wide terminal" {
    var narrow: Buf = .{};
    renderFit(&narrow, th.neon, test_input, 70);
    var wide: Buf = .{};
    renderFit(&wide, th.neon, test_input, 182);

    const nw = displayWidth(narrow.slice());
    const ww = displayWidth(wide.slice());
    try std.testing.expect(ww > nw);
    // A wide terminal should end up close to full, not stuck at natural width.
    try std.testing.expect(ww >= 175);
    // And it should have reached for the right edge with a reverse separator.
    try std.testing.expect(std.mem.indexOf(u8, wide.slice(), sep_l) != null);
}

test "renderFit sheds segments when cramped" {
    var out: Buf = .{};
    renderFit(&out, th.neon, test_input, 42);
    const text = try plain(std.testing.allocator, out.slice());
    defer std.testing.allocator.free(text);
    // The model and the countdown are the two that must survive.
    try std.testing.expect(std.mem.indexOf(u8, text, "Opus 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "58m") != null);
    try std.testing.expect(displayWidth(out.slice()) <= 42);
}
