//! Small POSIX backend. Socket descriptors are always non-blocking and CLOEXEC.
//! libc is linked by the proto build module; Linux and macOS are supported.
const std = @import("std");
const builtin = @import("builtin");
pub const c = std.c;
pub const is_linux = builtin.os.tag == .linux;
extern "c" fn getpeereid(c_int, *c.uid_t, *c.gid_t) c_int;

pub fn close(fd: c.fd_t) void {
    _ = c.close(fd);
}
pub fn address(path: []const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}
pub fn nonblocking(fd: c.fd_t) !void {
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SystemResources;
    const flags = c.fcntl(fd, c.F.GETFL);
    const nonblock: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
    if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
    if (!is_linux) {
        const one: c_int = 1;
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int)) < 0) return error.SystemResources;
    }
}
pub fn socket() !c.fd_t {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | (if (is_linux) c.SOCK.CLOEXEC | c.SOCK.NONBLOCK else 0), 0);
    if (fd < 0) return error.SystemResources;
    errdefer close(fd);
    try nonblocking(fd);
    return fd;
}
pub fn sameUser(fd: c.fd_t) bool {
    if (is_linux) {
        var cred: extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t } = undefined;
        var len: c.socklen_t = @sizeOf(@TypeOf(cred));
        return c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) == 0 and len == @sizeOf(@TypeOf(cred)) and cred.uid == c.getuid();
    } else {
        var uid: c.uid_t = undefined;
        var gid: c.gid_t = undefined;
        return getpeereid(fd, &uid, &gid) == 0 and uid == c.getuid();
    }
}
pub const SocketOptions = struct {
    socket: ?[]const u8 = null,
    environ: ?std.process.Environ = null,
};
pub fn socketPath(gpa: std.mem.Allocator, tool: []const u8, options: SocketOptions) ![:0]u8 {
    return @import("xdg").socketPath(gpa, tool, .{ .socket = options.socket, .environ = options.environ, .uid = c.getuid() });
}
pub const Stat = struct { mode: u32, uid: u32, nlink: u64 };
pub fn statAt(dir: c.fd_t, path: [:0]const u8, flags: u32) !Stat {
    if (is_linux) {
        var st: std.os.linux.Statx = undefined;
        if (c.statx(dir, path, flags, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true }, &st) < 0) return switch (c.errno(-1)) {
            .NOENT => error.FileNotFound,
            else => error.InsecurePath,
        };
        return .{ .mode = st.mode, .uid = st.uid, .nlink = st.nlink };
    } else {
        var st: c.Stat = undefined;
        if (c.fstatat(dir, path, &st, @intCast(flags)) < 0) return switch (c.errno(-1)) {
            .NOENT => error.FileNotFound,
            else => error.InsecurePath,
        };
        return .{ .mode = st.mode, .uid = st.uid, .nlink = st.nlink };
    }
}
/// Open the immediate parent with NOFOLLOW, verify it, and keep the directory
/// descriptor for lock and unlink operations. The bind uses the checked path.
pub fn runtimeDir(gpa: std.mem.Allocator, path: []const u8, create: bool) !c.fd_t {
    const raw_parent = std.fs.path.dirname(path) orelse ".";
    const trimmed = std.mem.trimEnd(u8, raw_parent, "/");
    const parent = if (trimmed.len == 0) "/" else trimmed;
    const z = try gpa.dupeSentinel(u8, parent, 0);
    defer gpa.free(z);
    if (create and c.mkdir(z, 0o700) < 0 and c.errno(-1) != .EXIST) return error.InsecurePath;
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return if (!create and c.errno(fd) == .NOENT) error.NotRunning else error.InsecurePath;
    errdefer close(fd);
    const st = try statAt(fd, ".", c.AT.SYMLINK_NOFOLLOW);
    if ((st.mode & c.S.IFMT) != c.S.IFDIR or st.uid != c.getuid() or (st.mode & 0o077) != 0) return error.InsecurePath;
    return fd;
}
pub fn nowMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
pub fn recv(fd: c.fd_t, buf: []u8) !?usize {
    while (true) {
        const n = c.recv(fd, buf.ptr, buf.len, 0);
        if (n >= 0) return @intCast(n);
        switch (c.errno(n)) {
            .INTR => continue,
            .AGAIN => return null,
            else => return error.Disconnected,
        }
    }
}
pub fn send(fd: c.fd_t, buf: []const u8) !?usize {
    while (true) {
        const n = c.send(fd, buf.ptr, buf.len, if (is_linux) c.MSG.NOSIGNAL else 0);
        if (n >= 0) return @intCast(n);
        switch (c.errno(n)) {
            .INTR => continue,
            .AGAIN => return null,
            else => return error.Disconnected,
        }
    }
}
pub fn poll(fds: []c.pollfd, timeout_ms: i32) !void {
    const rc = c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
    if (rc < 0 and c.errno(rc) != .INTR) return error.SystemResources;
}
