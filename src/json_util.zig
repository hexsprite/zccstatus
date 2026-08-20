const std = @import("std");

pub const Value = std.json.Value;

/// Follow a chain of object keys. A missing or wrong-typed link yields null,
/// so callers never have to guard each hop.
pub fn get(v: ?Value, keys: []const []const u8) ?Value {
    var cur = v orelse return null;
    for (keys) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

pub fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

pub fn int(v: ?Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| n,
        .float => |f| @as(i64, @intFromFloat(f)),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn float(v: ?Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |n| @as(f64, @floatFromInt(n)),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn boolean(v: ?Value) ?bool {
    const x = v orelse return null;
    return switch (x) {
        .bool => |b| b,
        else => null,
    };
}

test "get walks nested objects and fails soft" {
    const src =
        \\{"a":{"b":{"c":7,"s":"hi","f":1.5,"t":true}}}
    ;
    var p = try std.json.parseFromSlice(Value, std.testing.allocator, src, .{});
    defer p.deinit();

    try std.testing.expectEqual(@as(i64, 7), int(get(p.value, &.{ "a", "b", "c" })).?);
    try std.testing.expectEqualStrings("hi", str(get(p.value, &.{ "a", "b", "s" })).?);
    try std.testing.expectEqual(@as(f64, 1.5), float(get(p.value, &.{ "a", "b", "f" })).?);
    try std.testing.expectEqual(true, boolean(get(p.value, &.{ "a", "b", "t" })).?);

    try std.testing.expect(get(p.value, &.{ "a", "nope" }) == null);
    try std.testing.expect(get(p.value, &.{ "a", "b", "c", "deeper" }) == null);
    try std.testing.expect(str(get(p.value, &.{ "a", "b", "c" })) == null);
}
