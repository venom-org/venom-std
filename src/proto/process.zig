//! Process identity is a (PID,starttime) pair. All failures close the floor.
const std = @import("std");
const os = @import("os.zig");
const c = os.c;
pub const Ref = struct {
    pid: c.pid_t,
    start: u64,
    pub fn eql(a: Ref, b: Ref) bool {
        return a.pid == b.pid and a.start == b.start;
    }
};
pub const Stat = struct { ref: Ref, parent: c.pid_t };
pub const Chain = struct {
    refs: [66]Ref = undefined,
    len: usize = 0,
    orphan: bool = false,
    failed: bool = false,
    pub fn contains(self: Chain, r: Ref) bool {
        for (self.refs[0..self.len]) |p| if (p.eql(r)) return true;
        return false;
    }
};
pub fn parseStat(pid: c.pid_t, bytes: []const u8) !Stat {
    // comm may contain spaces, parentheses and newlines; the last ')' ends it.
    const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.InvalidStat;
    var fields = std.mem.tokenizeAny(u8, bytes[end + 1 ..], " \t\n");
    const state = fields.next() orelse return error.InvalidStat; // field 3
    if (std.mem.eql(u8, state, "Z") or std.mem.eql(u8, state, "X")) return error.ProcessGone;
    const parent = std.fmt.parseInt(c.pid_t, fields.next() orelse return error.InvalidStat, 10) catch return error.InvalidStat;
    for (5..22) |_| _ = fields.next() orelse return error.InvalidStat;
    const start = std.fmt.parseInt(u64, fields.next() orelse return error.InvalidStat, 10) catch return error.InvalidStat;
    return .{ .ref = .{ .pid = pid, .start = start }, .parent = parent };
}
pub fn stat(pid: c.pid_t) !Stat {
    if (!os.is_linux) return darwinStat(pid);
    var path: [64:0]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&path, "/proc/{d}/stat", .{pid}, 0);
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return error.ProcessGone;
    defer os.close(fd);
    var bytes: [4096]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    if (n <= 0 or n == bytes.len) return error.ProcessGone;
    return parseStat(pid, bytes[0..@intCast(n)]);
}
pub fn alive(ref: Ref) bool {
    return ref.eql((stat(ref.pid) catch return false).ref);
}
pub fn walk(peer: c.pid_t, daemon: c.pid_t) Chain {
    var result: Chain = .{};
    if (peer == 0) return result;
    var pid = peer;
    while (result.len < result.refs.len) {
        const s = stat(pid) catch {
            result.orphan = true;
            result.failed = true;
            return result;
        };
        result.refs[result.len] = s.ref;
        result.len += 1;
        if (pid == daemon) {
            result.orphan = true;
            break;
        }
        if (pid <= 1) break;
        if (result.len > 64) {
            result.orphan = true;
            result.failed = true;
            break;
        }
        pid = s.parent;
    }
    // Detect a vanished/recycled peer even on kernels without SO_PEERPIDFD.
    if (result.len > 0 and !alive(result.refs[0])) {
        result.orphan = true;
        result.failed = true;
    }
    return result;
}
pub fn peerPid(fd: c.fd_t) c.pid_t {
    if (os.is_linux) {
        var cred: extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t } = undefined;
        var len: c.socklen_t = @sizeOf(@TypeOf(cred));
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) != 0 or len != @sizeOf(@TypeOf(cred))) return 0;
        return cred.pid;
    }
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    // Darwin SOL_LOCAL=0, LOCAL_PEERPID=2.
    if (c.getsockopt(fd, 0, 2, &pid, &len) != 0) return 0;
    return pid;
}
pub fn peerPidfd(fd: c.fd_t) ?c.fd_t {
    if (!os.is_linux) return null;
    var pidfd: c.fd_t = -1;
    var len: c.socklen_t = @sizeOf(c.fd_t);
    // Linux UAPI SO_PEERPIDFD (since 6.5).
    if (c.getsockopt(fd, c.SOL.SOCKET, 77, &pidfd, &len) != 0) return null;
    if (c.fcntl(pidfd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) {
        os.close(pidfd);
        return null;
    }
    return pidfd;
}
pub fn exited(pidfd: c.fd_t) bool {
    var fds = [_]c.pollfd{.{ .fd = pidfd, .events = c.POLL.IN, .revents = 0 }};
    os.poll(&fds, 0) catch return true;
    return fds[0].revents != 0;
}
pub fn subreaper() !void {
    if (os.is_linux and prctl(36, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.SubreaperFailed;
}
extern "c" fn prctl(c_int, ...) c_int;
// Darwin's proc_bsdinfo ABI (libproc.h).
const BsdInfo = extern struct {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu: u32,
    comm: [16]u8,
    name: [32]u8,
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    nice: i32,
    start_sec: u64,
    start_usec: u64,
};
extern "c" fn proc_pidinfo(c_int, c_int, u64, *anyopaque, c_int) c_int;
fn darwinStat(pid: c.pid_t) !Stat {
    var info: BsdInfo = undefined;
    if (proc_pidinfo(pid, 3, 0, &info, @sizeOf(BsdInfo)) != @sizeOf(BsdInfo)) return error.ProcessGone;
    return .{ .ref = .{ .pid = pid, .start = info.start_sec * 1_000_000 + info.start_usec }, .parent = @intCast(info.ppid) };
}
