const std = @import("std");
const Io = std.Io;

pub const Head = struct {
    /// Branch name, or a short object id when detached. Slices into the
    /// caller's buffer.
    name: []const u8,
    detached: bool,
};

const max_path = 1024;

/// Find the branch for `start` by walking up to the nearest repository.
///
/// No subprocess: git spawn costs more than every other segment combined.
pub fn find(io: Io, start: []const u8, out: []u8) ?Head {
    var dir_buf: [max_path]u8 = undefined;
    if (start.len == 0 or start.len >= dir_buf.len) return null;

    var dir_len = start.len;
    @memcpy(dir_buf[0..dir_len], start);
    while (dir_len > 1 and dir_buf[dir_len - 1] == '/') dir_len -= 1;

    while (true) {
        if (readHeadIn(io, dir_buf[0..dir_len], out)) |h| return h;
        if (dir_len <= 1) return null;

        var i = dir_len;
        while (i > 0 and dir_buf[i - 1] != '/') i -= 1;
        dir_len = if (i <= 1) 1 else i - 1;
    }
}

fn readHeadIn(io: Io, dir: []const u8, out: []u8) ?Head {
    var path_buf: [max_path]u8 = undefined;
    var head_buf: [512]u8 = undefined;

    // The ordinary case: .git is a directory.
    if (std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{dir})) |p| {
        if (readSmall(io, p, &head_buf)) |content| return parseHead(content, out);
    } else |_| {}

    // A worktree: .git is a file naming the real git directory.
    var link_buf: [max_path]u8 = undefined;
    const dot = std.fmt.bufPrint(&path_buf, "{s}/.git", .{dir}) catch return null;
    const link = readSmall(io, dot, &link_buf) orelse return null;
    const gitdir = parseGitdir(link) orelse return null;

    var wt_buf: [max_path]u8 = undefined;
    const wt_head = if (gitdir[0] == '/')
        std.fmt.bufPrint(&wt_buf, "{s}/HEAD", .{gitdir}) catch return null
    else
        std.fmt.bufPrint(&wt_buf, "{s}/{s}/HEAD", .{ dir, gitdir }) catch return null;

    const content = readSmall(io, wt_head, &head_buf) orelse return null;
    return parseHead(content, out);
}

/// Pull the path out of a worktree's `.git` file: "gitdir: /path/to/wt".
pub fn parseGitdir(content: []const u8) ?[]const u8 {
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, content, prefix)) return null;
    const path = std.mem.trim(u8, content[prefix.len..], " \t\r\n");
    return if (path.len == 0) null else path;
}

/// Read the branch out of a HEAD file's contents.
pub fn parseHead(content: []const u8, out: []u8) ?Head {
    const line = std.mem.trim(u8, content, " \t\r\n");
    if (line.len == 0) return null;

    const ref = "ref: refs/heads/";
    if (std.mem.startsWith(u8, line, ref)) {
        const name = line[ref.len..];
        if (name.len == 0) return null;
        const n = @min(name.len, out.len);
        @memcpy(out[0..n], name[0..n]);
        return .{ .name = out[0..n], .detached = false };
    }

    // Detached HEAD holds a raw object id. Seven characters is what git shows.
    const n = @min(@min(line.len, 7), out.len);
    @memcpy(out[0..n], line[0..n]);
    return .{ .name = out[0..n], .detached = true };
}

/// Read a small file whole. Opening a directory succeeds on POSIX, so the
/// read is what actually rejects `.git` when it is a directory.
fn readSmall(io: Io, path: []const u8, buf: []u8) ?[]const u8 {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

test "parseHead reads a branch" {
    var out: [64]u8 = undefined;
    const h = parseHead("ref: refs/heads/feat/cyberpunk-bar\n", &out).?;
    try std.testing.expectEqualStrings("feat/cyberpunk-bar", h.name);
    try std.testing.expectEqual(false, h.detached);
}

test "parseHead shortens a detached id" {
    var out: [64]u8 = undefined;
    const h = parseHead("9f8e7d6c5b4a39281706abcdef0123456789abcd\n", &out).?;
    try std.testing.expectEqualStrings("9f8e7d6", h.name);
    try std.testing.expectEqual(true, h.detached);
}

test "parseHead rejects empty content" {
    var out: [64]u8 = undefined;
    try std.testing.expect(parseHead("", &out) == null);
    try std.testing.expect(parseHead("   \n", &out) == null);
    try std.testing.expect(parseHead("ref: refs/heads/", &out) == null);
}

test "parseGitdir" {
    try std.testing.expectEqualStrings("/a/b/.git/worktrees/x", parseGitdir("gitdir: /a/b/.git/worktrees/x\n").?);
    try std.testing.expectEqualStrings("../.git/worktrees/x", parseGitdir("gitdir: ../.git/worktrees/x").?);
    try std.testing.expect(parseGitdir("ref: refs/heads/main") == null);
    try std.testing.expect(parseGitdir("gitdir:   \n") == null);
}
