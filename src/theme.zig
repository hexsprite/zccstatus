const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn hex(v: u24) Rgb {
        return .{
            .r = @truncate(v >> 16),
            .g = @truncate(v >> 8),
            .b = @truncate(v),
        };
    }
};

/// Foreground and background for one segment.
pub const Pair = struct { fg: Rgb, bg: Rgb };

pub const Theme = struct {
    name: []const u8,

    model: Pair,
    ctx: Pair,
    cwd: Pair,
    git: Pair,
    lines: Pair,
    cost: Pair,
    cache: Pair,

    /// Severity ramp. The context gauge and the cache countdown both use it.
    ok: Rgb,
    warn: Rgb,
    crit: Rgb,

    /// Unfilled gauge cells.
    bar_dim: Rgb,

    /// Ink for text on an alert block. Which one applies is decided by the
    /// background's luminance, not by the theme: a pink that looks bright can
    /// still be dark enough to swallow black text.
    ink_dark: Rgb,
    ink_light: Rgb,

    add: Rgb,
    del: Rgb,
};

/// Hot magenta, electric cyan, deep indigo. Synthwave.
pub const neon: Theme = .{
    .name = "neon",
    .model = .{ .fg = Rgb.hex(0x14001f), .bg = Rgb.hex(0xff2a6d) },
    .ctx = .{ .fg = Rgb.hex(0xd1f7ff), .bg = Rgb.hex(0x1a1040) },
    .cwd = .{ .fg = Rgb.hex(0xa8f0ff), .bg = Rgb.hex(0x005678) },
    .git = .{ .fg = Rgb.hex(0x01212b), .bg = Rgb.hex(0x05d9e8) },
    .lines = .{ .fg = Rgb.hex(0x9aa8c7), .bg = Rgb.hex(0x14213d) },
    .cost = .{ .fg = Rgb.hex(0xc9a6ff), .bg = Rgb.hex(0x2d1b4e) },
    .cache = .{ .fg = Rgb.hex(0xf0e6ff), .bg = Rgb.hex(0x7b2cbf) },
    .ok = Rgb.hex(0x39ff14),
    .warn = Rgb.hex(0xffd700),
    .crit = Rgb.hex(0xff2a6d),
    .bar_dim = Rgb.hex(0x55407f),
    .ink_dark = Rgb.hex(0x14001f),
    .ink_light = Rgb.hex(0xfff0ff),
    .add = Rgb.hex(0x39ff14),
    .del = Rgb.hex(0xff2a6d),
};

/// Amber, teal, charcoal. Warmer and grittier.
pub const blade: Theme = .{
    .name = "blade",
    .model = .{ .fg = Rgb.hex(0x1a1200), .bg = Rgb.hex(0xff9f1c) },
    .ctx = .{ .fg = Rgb.hex(0xd8e2dc), .bg = Rgb.hex(0x1c2321) },
    .cwd = .{ .fg = Rgb.hex(0x8fd6d6), .bg = Rgb.hex(0x0b3a3a) },
    .git = .{ .fg = Rgb.hex(0x042d2a), .bg = Rgb.hex(0x2ec4b6) },
    .lines = .{ .fg = Rgb.hex(0xb0a48f), .bg = Rgb.hex(0x1f1b16) },
    .cost = .{ .fg = Rgb.hex(0xe0b080), .bg = Rgb.hex(0x3d2b1f) },
    .cache = .{ .fg = Rgb.hex(0xffe8d6), .bg = Rgb.hex(0xc1440e) },
    .ok = Rgb.hex(0x2ec4b6),
    .warn = Rgb.hex(0xff9f1c),
    .crit = Rgb.hex(0xff3b52),
    .bar_dim = Rgb.hex(0x6b6152),
    .ink_dark = Rgb.hex(0x1a1200),
    .ink_light = Rgb.hex(0xfff8f0),
    .add = Rgb.hex(0x2ec4b6),
    .del = Rgb.hex(0xff3b52),
};

/// Terminal green on black with hot pink. Most terminal-native of the three.
pub const acid: Theme = .{
    .name = "acid",
    .model = .{ .fg = Rgb.hex(0xfff0f7), .bg = Rgb.hex(0xff006e) },
    .ctx = .{ .fg = Rgb.hex(0xb6ffb6), .bg = Rgb.hex(0x0a0f0a) },
    .cwd = .{ .fg = Rgb.hex(0x7fff7f), .bg = Rgb.hex(0x123312) },
    .git = .{ .fg = Rgb.hex(0x041004), .bg = Rgb.hex(0x39ff14) },
    .lines = .{ .fg = Rgb.hex(0x8f8f8f), .bg = Rgb.hex(0x0f0f0f) },
    .cost = .{ .fg = Rgb.hex(0xff6ba8), .bg = Rgb.hex(0x1a0f14) },
    .cache = .{ .fg = Rgb.hex(0xff9ecb), .bg = Rgb.hex(0x2a0a1a) },
    .ok = Rgb.hex(0x39ff14),
    .warn = Rgb.hex(0xccff00),
    .crit = Rgb.hex(0xff2d86),
    .bar_dim = Rgb.hex(0x354a35),
    .ink_dark = Rgb.hex(0x0a0a0a),
    .ink_light = Rgb.hex(0xf0fff0),
    .add = Rgb.hex(0x39ff14),
    .del = Rgb.hex(0xff2d86),
};

pub const all = [_]Theme{ neon, blade, acid };
pub const default = neon;

pub fn byName(name: []const u8) ?Theme {
    for (all) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

test "byName" {
    try std.testing.expectEqualStrings("blade", byName("blade").?.name);
    try std.testing.expect(byName("nope") == null);
}

test "hex splits channels" {
    const c = Rgb.hex(0xff2a6d);
    try std.testing.expectEqual(@as(u8, 0xff), c.r);
    try std.testing.expectEqual(@as(u8, 0x2a), c.g);
    try std.testing.expectEqual(@as(u8, 0x6d), c.b);
}
