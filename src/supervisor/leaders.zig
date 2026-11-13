//! Nonblocking termination of daemon-created process-group leaders
//! Linux and macOS.
//!
//! A product that forks PTY leaders (one process group each, created by
//! `setsid` in `forkpty`) adopts every leader right after the fork and then
//! lets `Leaders` be the only code that waits on it:
//!
//! ```zig
//! var leaders = supervisor.Leaders.init(gpa, .{});
//! defer leaders.deinit();
//! const leader = try leaders.adopt(pty.pid);
//! // In a request handler:
//! switch (try leaders.terminate(leader, .{ .signal = .TERM, .deadline = leaders.now() + grace_ms })) {
//!     .already_exited => {}, // nothing was sent
//!     .started => |id| {}, // emit pane.terminating; remember id
//!     .joined => |id| {}, // remember id
//! }
//! // Every reactor turn (poll on `leader.pollFd()` and `leaders.timeoutMs(..)`):
//! try leaders.tick();
//! while (leaders.nextEvent()) |event| switch (event) {
//!     .exited => |l| {}, // l.status is final; commit pane.exited
//!     .done => |d| {}, // respond to request d.request: d.outcome, d.leader.escalated
//! };
//! ```
//!
//! Guarantees:
//!
//! * **Pinned.** A leader's exit is observed with `waitid(WNOWAIT)`. A
//!   terminating leader's group then gets one `SIGKILL` sweep for members
//!   left behind, and only then is the leader reaped, all inside one call.
//!   While the leader is an unreaped zombie its group ID cannot be reused, so
//!   every signal hits the group this daemon created.
//! * **Never after reap.** Every signal goes through one function that
//!   refuses a reaped leader. `terminate` on an exited leader sends nothing.
//! * **Safe targets.** Only adopted children of this process are signalled,
//!   never a group ID ≤ 1 or this process's own group.
//! * **Escalation.** `terminate` sends the requested signal and `SIGCONT` to
//!   the group. At the deadline (monotonic clock) the group gets `SIGKILL`
//!   and the request a fixed `kill_wait_ms` kill-wait, after which it
//!   completes with `.timeout` while the leader stays `terminating` and is
//!   still supervised. A deadline at or before now escalates at once.
//! * **Joining.** A leader has at most one termination. Later requests join
//!   it: no second requested signal; an earlier deadline shortens the
//!   current one, a later one never extends it; a request joining after
//!   escalation sends `SIGKILL` again and gets its own kill-wait. All joined
//!   requests complete from the same exit.
//! * **Cancellation** (`cancel`) drops a request without an event. The
//!   termination itself continues to its deadline and the exit is reaped.
//! * **Nonblocking.** No call sleeps or blocks on a wait.
//!
//! On macOS there is no pidfd: `Leader.pollFd` is null and the reactor ticks
//! on `timeoutMs`, which polls every `fallback_ms` while a leader lives. The
//! pin is the same `waitid(WNOWAIT)`.
//!
//! Not covered: processes that left the group.
//! A daemon that is a subreaper collects those with `Supervisor`'s
//! `reap_orphans`, which leaves adopted leaders alone. Never wait on an adopted
//! leader elsewhere.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const c = std.c;

comptime {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) @compileError("supervisor.Leaders needs Linux or macOS (waitid WNOWAIT)");
}

pub const SIG = std.posix.SIG;

/// Fixed wait after `SIGKILL` before a request times out.
pub const kill_wait_ms: i64 = 1000;

/// How a reaped leader ended.
pub const Status = union(enum) {
    code: u8,
    signal: struct { number: u32, core: bool = false },

    /// The same value in `waitpid` encoding.
    pub fn waitStatus(s: Status) u32 {
        return switch (s) {
            .code => |code| @as(u32, code) << 8,
            .signal => |sig| (sig.number & 0x7f) | (if (sig.core) @as(u32, 0x80) else 0),
        };
    }
};

pub const Phase = enum {
    running,
    /// A termination is in progress. Only left for `exited`.
    terminating,
    /// Reaped. Never signalled again.
    exited,
};

pub const Leader = struct {
    /// Also the process-group ID, recorded at adoption.
    pid: c.pid_t,
    pidfd: c.fd_t = -1,
    phase: Phase = .running,
    /// Set once reaped; stays null if other code reaped the leader.
    status: ?Status = null,
    /// The termination reached its deadline and sent `SIGKILL`.
    escalated: bool = false,
    /// The signal the termination started with.
    requested_signal: ?SIG = null,
    /// Grace deadline while terminating and not yet escalated.
    deadline: i64 = 0,

    /// Readable once the leader has exited; poll it in the reactor and call
    /// `tick`. Null without pidfd support (then tick on `timeoutMs`).
    pub fn pollFd(self: *const Leader) ?c.fd_t {
        return if (self.pidfd >= 0) self.pidfd else null;
    }
};

pub const RequestId = enum(u64) { _ };

pub const Outcome = enum {
    /// The leader exited and was reaped after the group sweep.
    exited,
    /// The kill-wait passed with the leader still alive. It stays
    /// `terminating` and supervised; its late exit still yields `.exited`.
    timeout,
};

pub const Event = union(enum) {
    /// A leader was reaped; once per leader, before any `done` for it.
    exited: *Leader,
    /// A termination request completed.
    done: struct { request: RequestId, leader: *Leader, outcome: Outcome },
};

pub const Terminate = union(enum) {
    /// The leader had already exited (now or earlier); nothing was sent.
    already_exited,
    /// This request started the termination.
    started: RequestId,
    /// This request joined a termination already in progress.
    joined: RequestId,
};

pub const TerminateOptions = struct {
    signal: SIG = .TERM,
    /// Grace deadline on `Leaders.now()`'s clock; at or before now escalates
    /// immediately (`grace_ms=0`).
    deadline: i64,
};

/// Sends `sig` following kill(2): negative `pid` is a process group.
/// Returns 0 or an errno value.
pub const Sender = *const fn (pid: c.pid_t, sig: SIG) c_int;

pub const Options = struct {
    /// Monotonic milliseconds (`CLOCK_MONOTONIC`). Tests may pin it.
    clock: *const fn () i64 = monotonicMs,
    /// Signal delivery. Tests may intercept it; everything else uses kill(2).
    send: Sender = sendKill,
};

const Request = struct {
    id: RequestId,
    leader: *Leader,
    /// Set once the leader has escalated for this request.
    kill_deadline: ?i64 = null,
};

pub const Leaders = struct {
    gpa: std.mem.Allocator,
    options: Options,
    own_pgrp: c.pid_t,
    leaders: std.ArrayList(*Leader) = .empty,
    requests: std.ArrayList(Request) = .empty,
    events: std.ArrayList(Event) = .empty,
    /// Index of the next event `nextEvent` returns.
    event_head: usize = 0,
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, options: Options) Leaders {
        return .{ .gpa = gpa, .options = options, .own_pgrp = getpgrp() };
    }

    /// Kills the group of every leader not yet reaped (safe: still pinned)
    /// and reaps those already gone, without waiting. A leader that is not
    /// gone yet is left to the subreaper or init.
    pub fn deinit(self: *Leaders) void {
        for (self.leaders.items) |l| {
            if (l.phase != .exited) {
                self.signalGroup(l, .KILL);
                if (self.exitedNow(l)) self.reap(l);
            }
            closePidfd(l);
            self.gpa.destroy(l);
        }
        self.leaders.deinit(self.gpa);
        self.requests.deinit(self.gpa);
        self.events.deinit(self.gpa);
    }

    pub fn now(self: *const Leaders) i64 {
        return self.options.clock();
    }

    /// Takes over a leader this process just forked as the leader of a new
    /// process group. Fails for pid ≤ 1, this process or its group, a
    /// process that is not a child, or one already adopted.
    pub fn adopt(self: *Leaders, pid: c.pid_t) !*Leader {
        if (pid <= 1 or pid == self.own_pgrp or pid == c.getpid()) return error.UnsafeGroup;
        for (self.leaders.items) |l| if (l.pid == pid) return error.AlreadyAdopted;
        if (sys.wait(pid, -1, true) == .not_child) return error.NotChild;
        try self.leaders.ensureUnusedCapacity(self.gpa, 1);
        const l = try self.gpa.create(Leader);
        l.* = .{ .pid = pid, .pidfd = sys.pidfdOpen(pid) };
        self.leaders.appendAssumeCapacity(l);
        return l;
    }

    /// Forgets an exited leader, with any of its events not yet returned.
    pub fn release(self: *Leaders, l: *Leader) error{NotExited}!void {
        if (l.phase != .exited) return error.NotExited;
        var i: usize = self.event_head;
        while (i < self.events.items.len) {
            const for_l = switch (self.events.items[i]) {
                .exited => |e| e == l,
                .done => |d| d.leader == l,
            };
            if (for_l) _ = self.events.orderedRemove(i) else i += 1;
        }
        for (self.leaders.items, 0..) |item, idx| if (item == l) {
            _ = self.leaders.swapRemove(idx);
            break;
        };
        closePidfd(l);
        self.gpa.destroy(l);
    }

    /// Starts or joins the termination of `l` (see the module doc).
    pub fn terminate(self: *Leaders, l: *Leader, options: TerminateOptions) !Terminate {
        if (l.phase == .exited) return .already_exited;
        try self.requests.ensureUnusedCapacity(self.gpa, 1);
        try self.events.ensureUnusedCapacity(self.gpa, 1 + self.pendingFor(l));
        const t = self.now();
        if (l.phase == .running and self.exitedNow(l)) {
            // Exited but not observed yet: an ordinary exit, nothing to sweep.
            self.finish(l);
            return .already_exited;
        }
        const id: RequestId = @fromBackingInt(@intCast(self.next_id));
        self.next_id += 1;
        var request: Request = .{ .id = id, .leader = l };
        const result: Terminate = switch (l.phase) {
            .running => blk: {
                l.phase = .terminating;
                l.requested_signal = options.signal;
                l.deadline = options.deadline;
                self.signalGroup(l, options.signal);
                self.signalGroup(l, .CONT);
                break :blk .{ .started = id };
            },
            .terminating => blk: {
                if (l.escalated) {
                    self.signalGroup(l, .KILL);
                    request.kill_deadline = t + kill_wait_ms;
                } else if (options.deadline < l.deadline) {
                    l.deadline = options.deadline;
                }
                break :blk .{ .joined = id };
            },
            .exited => unreachable,
        };
        self.requests.appendAssumeCapacity(request);
        if (!l.escalated and l.deadline <= t) self.escalate(l, t);
        return result;
    }

    /// Drops a request without an event; returns false if it already
    /// completed. Termination of its leader continues.
    pub fn cancel(self: *Leaders, id: RequestId) bool {
        for (self.requests.items, 0..) |r, i| if (r.id == id) {
            _ = self.requests.orderedRemove(i);
            return true;
        };
        return false;
    }

    /// One reactor turn: observes exits (sweep, then reap), escalates at
    /// grace deadlines and times out requests at their kill-wait deadlines.
    /// Never blocks. Fails only before any effect, when event space cannot
    /// be reserved.
    pub fn tick(self: *Leaders) error{OutOfMemory}!void {
        try self.events.ensureUnusedCapacity(self.gpa, self.live() + self.requests.items.len);
        const t = self.now();
        for (self.leaders.items) |l| {
            if (l.phase == .exited) continue;
            if (self.exitedNow(l)) {
                self.finish(l);
            } else if (l.phase == .terminating and !l.escalated and t >= l.deadline) {
                self.escalate(l, t);
            }
        }
        var i: usize = 0;
        while (i < self.requests.items.len) {
            const r = self.requests.items[i];
            if (r.kill_deadline) |d| if (t >= d) {
                _ = self.requests.orderedRemove(i);
                self.push(.{ .done = .{ .request = r.id, .leader = r.leader, .outcome = .timeout } });
                continue;
            };
            i += 1;
        }
    }

    /// The next event, in order; null when drained.
    pub fn nextEvent(self: *Leaders) ?Event {
        if (self.event_head == self.events.items.len) {
            self.events.clearRetainingCapacity();
            self.event_head = 0;
            return null;
        }
        defer self.event_head += 1;
        return self.events.items[self.event_head];
    }

    /// The earliest grace or kill-wait deadline, if any.
    pub fn nextDeadline(self: *const Leaders) ?i64 {
        var best: ?i64 = null;
        for (self.leaders.items) |l| if (l.phase == .terminating and !l.escalated) {
            best = if (best) |b| @min(b, l.deadline) else l.deadline;
        };
        for (self.requests.items) |r| if (r.kill_deadline) |d| {
            best = if (best) |b| @min(b, d) else d;
        };
        return best;
    }

    /// A poll timeout of at most `max_ms` that wakes for the next deadline.
    /// Without a pidfd, a terminating leader also caps it at `fallback_ms`.
    pub fn timeoutMs(self: *const Leaders, max_ms: i32) i32 {
        var out: i64 = max_ms;
        if (self.nextDeadline()) |d| out = @min(out, @max(0, d - self.now()));
        for (self.leaders.items) |l| if (l.phase != .exited and l.pidfd < 0) {
            out = @min(out, fallback_ms);
        };
        return @intCast(@max(0, out));
    }

    pub const fallback_ms: i64 = 10;

    /// Leaders adopted and not reaped yet.
    pub fn live(self: *const Leaders) usize {
        var n: usize = 0;
        for (self.leaders.items) |l| if (l.phase != .exited) {
            n += 1;
        };
        return n;
    }

    fn pendingFor(self: *const Leaders, l: *const Leader) usize {
        var n: usize = 0;
        for (self.requests.items) |r| if (r.leader == l) {
            n += 1;
        };
        return n;
    }

    fn escalate(self: *Leaders, l: *Leader, t: i64) void {
        l.escalated = true;
        self.signalGroup(l, .KILL);
        for (self.requests.items) |*r| if (r.leader == l and r.kill_deadline == null) {
            r.kill_deadline = t + kill_wait_ms;
        };
    }

    /// The leader has exited and is still pinned: sweep, reap, report.
    fn finish(self: *Leaders, l: *Leader) void {
        if (l.phase == .terminating) self.signalGroup(l, .KILL);
        self.reap(l);
        self.push(.{ .exited = l });
        var i: usize = 0;
        while (i < self.requests.items.len) {
            const r = self.requests.items[i];
            if (r.leader != l) {
                i += 1;
                continue;
            }
            _ = self.requests.orderedRemove(i);
            self.push(.{ .done = .{ .request = r.id, .leader = l, .outcome = .exited } });
        }
    }

    /// Capacity is reserved by `terminate` and `tick` before any effect.
    fn push(self: *Leaders, event: Event) void {
        self.events.appendAssumeCapacity(event);
    }

    /// The only path that signals. Refuses reaped leaders. Falls back to the
    /// pinned leader alone when its group does not exist yet (the child has
    /// not reached `setsid`).
    fn signalGroup(self: *Leaders, l: *const Leader, sig: SIG) void {
        if (l.phase == .exited or l.pid <= 1 or l.pid == self.own_pgrp) return;
        const rc = self.options.send(-l.pid, sig);
        if (rc == @backingInt(c.E.SRCH)) _ = self.options.send(l.pid, sig);
    }

    fn exitedNow(_: *Leaders, l: *const Leader) bool {
        // not_child: someone else reaped it. Treat as gone so it is never signalled.
        return switch (sys.wait(l.pid, l.pidfd, true)) {
            .not_child, .exited => true,
            .running, .failed => false,
        };
    }

    fn reap(_: *Leaders, l: *Leader) void {
        const w = sys.wait(l.pid, l.pidfd, false);
        l.phase = .exited;
        closePidfd(l);
        // Null when something else reaped it (a contract violation by the caller).
        l.status = switch (w) {
            .exited => |st| st,
            else => null,
        };
    }
};

/// One nonblocking `waitid(WEXITED|WNOHANG)` on a leader, `WNOWAIT` if `peek`.
const Wait = union(enum) {
    /// ECHILD: not our child, or already reaped by someone else.
    not_child,
    /// Still alive.
    running,
    exited: Status,
    /// Any other error.
    failed,
};

const sys = if (builtin.os.tag == .linux) struct {
    fn pidfdOpen(pid: c.pid_t) c.fd_t {
        const fd = linux.pidfd_open(pid, 0);
        return if (linux.errno(fd) == .SUCCESS) @intCast(fd) else -1;
    }

    fn wait(pid: c.pid_t, pidfd: c.fd_t, peek: bool) Wait {
        var info: linux.siginfo_t = undefined;
        info.fields.common.first.piduid.pid = 0;
        const flags: u32 = linux.W.EXITED | linux.W.NOHANG | (if (peek) @as(u32, linux.W.NOWAIT) else 0);
        var e: linux.E = .INVAL;
        if (pidfd >= 0) e = waitid(.PIDFD, pidfd, &info, flags);
        if (e == .INVAL) e = waitid(.PID, pid, &info, flags);
        return switch (e) {
            .SUCCESS => if (info.fields.common.first.piduid.pid == 0) .running else .{ .exited = statusOf(info.code, info.fields.common.second.sigchld.status) },
            .CHILD => .not_child,
            else => .failed,
        };
    }

    fn waitid(id_type: linux.P, id: c.pid_t, info: *linux.siginfo_t, flags: u32) linux.E {
        while (true) {
            const e = linux.errno(linux.waitid(id_type, id, info, flags, null));
            if (e != .INTR) return e;
        }
    }
} else struct {
    // <sys/wait.h> on Darwin; std.c.W lacks these two.
    const P_PID: c_int = 1;
    const WEXITED: c_int = 0x04;
    const WNOWAIT: c_int = 0x20;
    extern "c" fn waitid(idtype: c_int, id: c_uint, info: *c.siginfo_t, options: c_int) c_int;

    fn pidfdOpen(_: c.pid_t) c.fd_t {
        return -1;
    }

    fn wait(pid: c.pid_t, _: c.fd_t, peek: bool) Wait {
        var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
        const flags = WEXITED | c.W.NOHANG | (if (peek) WNOWAIT else 0);
        while (true) {
            if (waitid(P_PID, @intCast(pid), &info, flags) == 0) {
                return if (info.pid == 0) .running else .{ .exited = statusOf(info.code, info.status) };
            }
            switch (c.errno(@as(c_int, -1))) {
                .INTR => continue,
                .CHILD => return .not_child,
                else => return .failed,
            }
        }
    }
};

/// CLD_EXITED, CLD_KILLED, CLD_DUMPED: the same codes on Linux and macOS.
fn statusOf(code: c_int, raw: c_int) Status {
    return switch (code) {
        1 => .{ .code = @truncate(@as(u32, @bitCast(raw))) },
        3 => .{ .signal = .{ .number = @bitCast(raw), .core = true } },
        else => .{ .signal = .{ .number = @bitCast(raw) } },
    };
}

fn closePidfd(l: *Leader) void {
    if (l.pidfd >= 0) _ = c.close(l.pidfd);
    l.pidfd = -1;
}

fn sendKill(pid: c.pid_t, sig: SIG) c_int {
    if (c.kill(pid, sig) == 0) return 0;
    return @backingInt(c.errno(@as(c_int, -1)));
}

extern "c" fn getpgrp() c.pid_t;

pub fn monotonicMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}
