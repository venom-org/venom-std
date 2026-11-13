//! A process that starts processes for others leaves an
//! empty marker next to its socket, named by its (pid, starttime). A daemon
//! with a socket in that directory refuses its owner token to anything below a
//! marked process. A marker only ever denies, so forging one costs nothing, and
//! one left by a crash matches no live process.
const std = @import("std");
const os = @import("os.zig");
const proc = @import("process.zig");
const c = os.c;

const Name = [64:0]u8;

fn nameOf(buf: *Name, ref: proc.Ref) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "manager-{d}-{d}", .{ ref.pid, ref.start }, 0);
}

fn selfRef() !proc.Ref {
    return (try proc.stat(c.getpid())).ref;
}

/// Marks this process in the checked directory `dir`.
pub fn mark(dir: c.fd_t) !void {
    var buf: Name = undefined;
    const name = try nameOf(&buf, try selfRef());
    const fd = c.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.InsecurePath;
    os.close(fd);
}

pub fn unmark(dir: c.fd_t) void {
    var buf: Name = undefined;
    const name = nameOf(&buf, selfRef() catch return) catch return;
    _ = c.unlinkat(dir, name, 0);
}

/// Whether this process is marked in `dir`. Like `below`, one that can't be
/// checked counts.
pub fn marked(dir: c.fd_t, ref: proc.Ref) bool {
    var buf: Name = undefined;
    const name = nameOf(&buf, ref) catch return true;
    _ = os.statAt(dir, name, c.AT.SYMLINK_NOFOLLOW) catch |err| return err != error.FileNotFound;
    return true;
}

/// Whether a process above the peer is marked in `dir`. The peer itself is not
/// counted: `venom serve` is a manager, and presents venomx's owner token only
/// from outside every tree. A marker that can't be checked counts.
pub fn below(dir: c.fd_t, chain: proc.Chain) bool {
    if (chain.len < 2) return false;
    for (chain.refs[1..chain.len]) |ref| {
        var buf: Name = undefined;
        const name = nameOf(&buf, ref) catch return true;
        _ = os.statAt(dir, name, c.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return true,
        };
        return true;
    }
    return false;
}

/// A marker for a process with no server, such as a TUI that starts shells and
/// harnesses as its own children, next to the socket it talks to.
pub const Held = struct {
    dir: c.fd_t,

    pub fn acquire(gpa: std.mem.Allocator, socket: []const u8) !Held {
        const dir = try os.runtimeDir(gpa, socket, false);
        errdefer os.close(dir);
        try mark(dir);
        return .{ .dir = dir };
    }

    pub fn release(self: Held) void {
        unmark(self.dir);
        os.close(self.dir);
    }
};

const t = std.testing;

fn tmpFd(tmp: *std.testing.TmpDir) c.fd_t {
    return tmp.dir.handle;
}

test "below: a marked ancestor counts, the marked peer itself does not" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmpFd(&tmp);
    const me = try selfRef();
    const other: proc.Ref = .{ .pid = 1, .start = 1 };
    try mark(dir);
    var chain: proc.Chain = .{};
    chain.refs[0] = me;
    chain.len = 1;
    try t.expect(!below(dir, chain));
    chain.refs[0] = other;
    chain.refs[1] = me;
    chain.len = 2;
    try t.expect(below(dir, chain));
    unmark(dir);
    try t.expect(!below(dir, chain));
}

test "below: a marker for another start of the same pid does not match" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmpFd(&tmp);
    const me = try selfRef();
    try mark(dir);
    defer unmark(dir);
    var chain: proc.Chain = .{};
    chain.refs[0] = .{ .pid = 1, .start = 1 };
    chain.refs[1] = .{ .pid = me.pid, .start = me.start + 1 };
    chain.len = 2;
    try t.expect(!below(dir, chain));
}

test "below: an empty chain, as for a peer with no visible pid" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try t.expect(!below(tmpFd(&tmp), .{}));
}
