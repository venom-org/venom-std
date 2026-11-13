//! The shared `skill` and
//! `skill.install` verbs. `skill` returns the generated SKILL.md;
//! `skill.install` writes exactly those bytes to
//! `<root>/<tool>/SKILL.md` on the daemon's host, enforcing the `files`
//! grant on the destination and refusing symlinks below the resolved root.
const std = @import("std");
const proto = @import("proto");
const docs = @import("docs.zig");
const c = std.c;
const Allocator = std.mem.Allocator;

/// Default user skill roots, relative to the daemon user's `$HOME`.
pub const default_roots = [_]struct { []const u8, []const u8 }{
    .{ "claude-code", ".claude/skills" },
    .{ "codex", ".agents/skills" },
    .{ "opencode", ".config/opencode/skills" },
};

pub fn render(comptime G: type, a: Allocator, notes: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try docs.writeSkill(G, &out.writer, notes);
    return out.toOwnedSlice();
}

/// `skill` handler.
pub fn Show(comptime G: type) type {
    return struct {
        /// Hand-written Markdown appended under "Notes". No credentials.
        notes: []const u8 = "",
        pub fn call(self: *@This(), call_: *proto.Call) anyerror!void {
            try call_.ok(.{ .content = try render(G, call_.arena(), self.notes) });
        }
    };
}

/// `skill.install` handler.
pub fn Install(comptime G: type) type {
    return struct {
        notes: []const u8 = "",
        /// The daemon user's absolute home directory, if known.
        home: ?[]const u8 = null,

        pub fn call(self: *@This(), call_: *proto.Call) anyerror!void {
            const a = call_.arena();
            const params = call_.params.object;
            const target = params.get("target").?.string;
            const replace = params.get("replace").?.bool;
            const root: []const u8 = if (params.get("directory")) |d| d.string else blk: {
                const home = self.home orelse return badRoot(call_, "HOME is unavailable; pass --directory");
                if (!std.fs.path.isAbsolute(home)) return badRoot(call_, "HOME is not absolute; pass --directory");
                const rel = for (default_roots) |r| {
                    if (std.mem.eql(u8, r[0], target)) break r[1];
                } else unreachable; // target is a validated enum
                break :blk try std.fs.path.join(a, &.{ home, rel });
            };
            if (!std.fs.path.isAbsolute(root)) return badRoot(call_, "directory must be an absolute path");
            const resolved = proto.canonicalPath(a, root) catch |err| {
                if (err == error.OutOfMemory) return err;
                return badRoot(call_, "directory cannot be resolved");
            };
            const dir_path = try std.fs.path.join(a, &.{ resolved, G.schema.tool });
            const file_path = try std.fs.path.join(a, &.{ dir_path, "SKILL.md" });
            if (!try call_.authorize(.files, .{ .kind = "path", .id = file_path })) return;
            const content = try render(G, a, self.notes);
            const changed = install(a, dir_path, content, replace) catch |err| return switch (err) {
                error.OutOfMemory => err,
                error.Exists => call_.fail("conflict.skill_exists", "a different SKILL.md exists; pass --replace=true to replace it", .{ .path = file_path }),
                error.Symlink => badRoot(call_, "the destination traverses a symlink"),
                error.AccessDenied => call_.fail("denied.files", "permission denied writing the skill", .{ .path = file_path }),
                else => call_.fail("failed.skill_write", "could not write the skill", .{ .path = file_path, .reason = @errorName(err) }),
            };
            try call_.ok(.{ .target = target, .path = file_path, .changed = changed });
        }
    };
}

fn badRoot(call_: *proto.Call, message: []const u8) !void {
    return call_.fail("invalid_params.skill_directory", message, null);
}

fn fsError(rc: anytype) anyerror {
    return switch (c.errno(rc)) {
        .LOOP, .NOTDIR => error.Symlink,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOENT => error.FileNotFound,
        else => error.Unexpected,
    };
}

/// Open (creating if missing) each component of the absolute, already
/// canonical `path` without following symlinks. Caller closes the result.
fn openDirs(a: Allocator, path: []const u8) !c.fd_t {
    var fd = c.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return fsError(fd);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        errdefer _ = c.close(fd);
        const z = try a.dupeSentinel(u8, component, 0);
        const flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
        var next = c.openat(fd, z, flags);
        if (next < 0 and c.errno(next) == .NOENT) {
            if (c.mkdirat(fd, z, 0o755) < 0 and c.errno(@as(c_int, -1)) != .EXIST) return fsError(@as(c_int, -1));
            next = c.openat(fd, z, flags);
        }
        if (next < 0) return fsError(next);
        _ = c.close(fd);
        fd = next;
    }
    return fd;
}

/// Write `content` to `<dir>/SKILL.md`. Returns whether the file changed.
pub fn install(a: Allocator, dir: []const u8, content: []const u8, replace: bool) !bool {
    const dfd = try openDirs(a, dir);
    defer _ = c.close(dfd);
    const existing = c.openat(dfd, "SKILL.md", .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
    if (existing >= 0) {
        defer _ = c.close(existing);
        // Read one byte past `content` so a longer file never compares equal.
        const buf = try a.alloc(u8, content.len + 1);
        var n: usize = 0;
        while (n < buf.len) {
            const got = c.read(existing, buf[n..].ptr, buf.len - n);
            if (got < 0) return fsError(got);
            if (got == 0) break;
            n += @intCast(got);
        }
        if (std.mem.eql(u8, buf[0..n], content)) return false;
        if (!replace) return error.Exists;
    } else switch (c.errno(existing)) {
        .NOENT => {},
        else => return fsError(existing),
    }
    var name_buf: [48]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&name_buf, ".SKILL.md.{d}.tmp", .{c.getpid()}, 0);
    const fd = c.openat(dfd, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return fsError(fd);
    var keep = false;
    defer if (!keep) {
        _ = c.unlinkat(dfd, tmp, 0);
    };
    {
        defer _ = c.close(fd);
        var off: usize = 0;
        while (off < content.len) {
            const put = c.write(fd, content[off..].ptr, content.len - off);
            if (put < 0) return fsError(put);
            off += @intCast(put);
        }
        if (c.fsync(fd) < 0) return fsError(@as(c_int, -1));
    }
    // rename(2) replaces the destination atomically, even a symlink itself.
    if (c.renameat(dfd, tmp, dfd, "SKILL.md") < 0) return fsError(@as(c_int, -1));
    keep = true;
    return true;
}
