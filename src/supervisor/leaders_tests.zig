//! Tests for `leaders.zig` with real child process groups.
const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const c = std.c;
const leaders_mod = @import("leaders.zig");
const Leaders = leaders_mod.Leaders;
const Leader = leaders_mod.Leader;
const Event = leaders_mod.Event;
const SIG = leaders_mod.SIG;
const monotonicMs = leaders_mod.monotonicMs;

extern "c" fn fork() c.pid_t;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn getpgid(pid: c.pid_t) c.pid_t;
extern "c" fn sigprocmask(how: c_int, set: ?*const c.sigset_t, old: ?*c.sigset_t) c_int;

/// Forks `/bin/sh -c script` as the leader of a new session and group, as
/// forkpty does, and waits until the group exists.
fn spawnLeader(script: [*:0]const u8) !c.pid_t {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        const empty = std.mem.zeroes(c.sigset_t);
        _ = sigprocmask(c.SIG.SETMASK, &empty, null);
        _ = execv("/bin/sh", &argv);
        c._exit(127);
    }
    const deadline = monotonicMs() + 2_000;
    while (getpgid(pid) != pid) {
        if (monotonicMs() > deadline) return error.Timeout;
        sleepMs(1);
    }
    return pid;
}

fn sleepMs(ms: u32) void {
    var req: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
    while (c.nanosleep(&req, &req) != 0 and c.errno(@as(c_int, -1)) == .INTR) {}
}

/// Collects events from ticks until `n` events have arrived.
const Log = struct {
    events: [16]Event = undefined,
    len: usize = 0,

    fn drive(log: *Log, set: *Leaders, n: usize, timeout_ms: u32) !void {
        const deadline = monotonicMs() + timeout_ms;
        while (log.len < n) {
            if (monotonicMs() > deadline) return error.Timeout;
            try set.tick();
            log.drain(set);
            if (log.len < n) sleepMs(1);
        }
    }
    fn drain(log: *Log, set: *Leaders) void {
        while (set.nextEvent()) |e| {
            log.events[log.len] = e;
            log.len += 1;
        }
    }
};

fn sigNumber(sig: SIG) u32 {
    return @intCast(@backingInt(sig));
}

/// A recording sender. `drop_kill` swallows SIGKILL, which stands in for a
/// leader that cannot die (uninterruptible sleep) so timeouts are testable.
var sent: [64]struct { pid: c.pid_t, sig: SIG } = undefined;
var sent_len: usize = 0;
var drop_kill = false;

fn record(pid: c.pid_t, sig: SIG) c_int {
    sent[sent_len] = .{ .pid = pid, .sig = sig };
    sent_len += 1;
    if (drop_kill and sig == .KILL) return 0;
    if (c.kill(pid, sig) == 0) return 0;
    return @intCast(@backingInt(c.errno(@as(c_int, -1))));
}

fn resetRecord() void {
    sent_len = 0;
    drop_kill = false;
}

fn countSent(sig: SIG) usize {
    var n: usize = 0;
    for (sent[0..sent_len]) |s| if (s.sig == sig) {
        n += 1;
    };
    return n;
}

var fake_now: i64 = 0;
fn fakeClock() i64 {
    return fake_now;
}

const ignore_term = "trap '' TERM; while :; do sleep 0.01; done";

test "leaders: cooperative leader exits on the requested signal without escalation" {
    resetRecord();
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader("exec sleep 30"));
    const started = monotonicMs();
    const r = try set.terminate(l, .{ .signal = .TERM, .deadline = set.now() + 5_000 });
    try testing.expect(monotonicMs() - started < 100); // returns without waiting
    try testing.expect(r == .started);
    try testing.expectEqual(leaders_mod.Phase.terminating, l.phase);
    try testing.expectEqual(SIG.TERM, l.requested_signal.?);
    // Requested signal, then SIGCONT, both to the group.
    try testing.expectEqual(SIG.TERM, sent[0].sig);
    try testing.expectEqual(-l.pid, sent[0].pid);
    try testing.expectEqual(SIG.CONT, sent[1].sig);
    var log: Log = .{};
    try log.drive(&set, 2, 5_000);
    try testing.expect(log.events[0] == .exited and log.events[0].exited == l);
    try testing.expectEqual(r.started, log.events[1].done.request);
    try testing.expectEqual(leaders_mod.Outcome.exited, log.events[1].done.outcome);
    try testing.expect(!l.escalated);
    try testing.expectEqual(leaders_mod.Phase.exited, l.phase);
    try testing.expectEqual(sigNumber(.TERM), l.status.?.signal.number);
    try testing.expectEqual(@as(u32, sigNumber(.TERM)), l.status.?.waitStatus());
    // The pinned sweep happened before the reap.
    try testing.expectEqual(@as(usize, 1), countSent(.KILL));
    try testing.expectEqual(SIG.KILL, sent[sent_len - 1].sig);
    try set.release(l);
}

test "leaders: signal-ignoring leader escalates to SIGKILL at the deadline" {
    resetRecord();
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader(ignore_term));
    sleepMs(50); // let sh install its trap
    const started = monotonicMs();
    const r = try set.terminate(l, .{ .deadline = set.now() + 200 });
    try testing.expect(set.timeoutMs(1_000) <= 200);
    var log: Log = .{};
    try log.drive(&set, 2, 5_000);
    const took = monotonicMs() - started;
    try testing.expect(took >= 200 and took < 200 + leaders_mod.kill_wait_ms + 500);
    try testing.expect(l.escalated);
    try testing.expectEqual(sigNumber(.KILL), l.status.?.signal.number);
    try testing.expectEqual(r.started, log.events[1].done.request);
    try testing.expectEqual(leaders_mod.Outcome.exited, log.events[1].done.outcome);
    try testing.expectEqual(@as(usize, 1), countSent(.TERM));
}

test "leaders: grace 0 sends signal, SIGCONT and SIGKILL in the first call" {
    resetRecord();
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader(ignore_term));
    _ = try set.terminate(l, .{ .signal = .HUP, .deadline = set.now() });
    try testing.expectEqual(@as(usize, 3), sent_len);
    try testing.expectEqual(SIG.HUP, sent[0].sig);
    try testing.expectEqual(SIG.CONT, sent[1].sig);
    try testing.expectEqual(SIG.KILL, sent[2].sig);
    try testing.expect(l.escalated);
    var log: Log = .{};
    try log.drive(&set, 2, 5_000);
}

test "leaders: a stopped leader is continued so it can act on the signal" {
    resetRecord();
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader("exec sleep 30"));
    try testing.expectEqual(@as(c_int, 0), c.kill(-l.pid, .STOP));
    sleepMs(20);
    _ = try set.terminate(l, .{ .signal = .TERM, .deadline = set.now() + 5_000 });
    var log: Log = .{};
    try log.drive(&set, 2, 3_000);
    try testing.expect(!l.escalated);
    try testing.expectEqual(sigNumber(.TERM), l.status.?.signal.number);
}

test "leaders: the pinned sweep kills group members the leader left behind" {
    resetRecord();
    // Become a subreaper so the stray member is reparented to us and the test
    // can reap it.
    _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
    defer _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 0, 0, 0, 0);
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    // A background member ignores TERM; the leader exits on TERM.
    const l = try set.adopt(try spawnLeader("(trap '' TERM; exec sleep 30) & trap 'exit 0' TERM; while :; do sleep 0.01; done"));
    sleepMs(50);
    const pgid = l.pid;
    _ = try set.terminate(l, .{ .signal = .TERM, .deadline = set.now() + 5_000 });
    var log: Log = .{};
    try log.drive(&set, 2, 3_000);
    try testing.expect(!l.escalated);
    try testing.expectEqual(@as(u8, 0), l.status.?.code);
    // Only the sweep ends the member, which ignores TERM and sleeps for 30s.
    // P_PGID reaps this group alone. ECHILD means none of it is left.
    var reaped: usize = 0;
    const deadline = monotonicMs() + 2_000;
    while (true) {
        var info: linux.siginfo_t = undefined;
        info.fields.common.first.piduid.pid = 0;
        const e = linux.errno(linux.waitid(.PGID, pgid, &info, linux.W.EXITED | linux.W.NOHANG, null));
        if (e == .CHILD) break;
        try testing.expectEqual(linux.E.SUCCESS, e);
        if (info.fields.common.first.piduid.pid != 0) {
            reaped += 1;
        } else {
            if (monotonicMs() > deadline) return error.GroupSurvived;
            sleepMs(1);
        }
    }
    try testing.expect(reaped >= 1);
    try testing.expectEqual(@as(c_int, -1), c.kill(-pgid, @fromBackingInt(0)));
}

test "leaders: timeout leaves the leader terminating and supervised until its late exit" {
    resetRecord();
    drop_kill = true;
    fake_now = 1_000;
    var set = Leaders.init(testing.allocator, .{ .send = record, .clock = fakeClock });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader(ignore_term));
    sleepMs(50);
    const r = try set.terminate(l, .{ .deadline = fake_now + 100 });
    try set.tick();
    try testing.expect(set.nextEvent() == null);
    fake_now += 100;
    try set.tick();
    try testing.expect(l.escalated);
    try testing.expectEqual(@as(?i64, fake_now + leaders_mod.kill_wait_ms), set.nextDeadline());
    fake_now += leaders_mod.kill_wait_ms - 1;
    try set.tick();
    try testing.expect(set.nextEvent() == null);
    fake_now += 1;
    try set.tick();
    const e = set.nextEvent().?;
    try testing.expectEqual(r.started, e.done.request);
    try testing.expectEqual(leaders_mod.Outcome.timeout, e.done.outcome);
    try testing.expect(set.nextEvent() == null);
    try testing.expectEqual(leaders_mod.Phase.terminating, l.phase);
    try testing.expectError(error.NotExited, set.release(l));
    try testing.expectEqual(@as(?i64, null), set.nextDeadline());
    // The leader finally dies: it is swept and reaped, with no second `done`.
    drop_kill = false;
    try testing.expectEqual(@as(c_int, 0), c.kill(-l.pid, .KILL));
    var log: Log = .{};
    try log.drive(&set, 1, 3_000);
    try testing.expect(log.events[0] == .exited);
    try set.tick();
    try testing.expect(set.nextEvent() == null);
    try testing.expectEqual(leaders_mod.Phase.exited, l.phase);
}

test "leaders: joining shares one termination, shortens but never extends the deadline" {
    resetRecord();
    drop_kill = true;
    fake_now = 1_000;
    var set = Leaders.init(testing.allocator, .{ .send = record, .clock = fakeClock });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader(ignore_term));
    sleepMs(50);
    const first = try set.terminate(l, .{ .deadline = fake_now + 5_000 });
    const later = try set.terminate(l, .{ .signal = .INT, .deadline = fake_now + 9_000 });
    try testing.expect(later == .joined);
    try testing.expectEqual(fake_now + 5_000, l.deadline);
    const sooner = try set.terminate(l, .{ .deadline = fake_now + 300 });
    try testing.expectEqual(fake_now + 300, l.deadline);
    try testing.expectEqual(@as(usize, 1), countSent(.TERM)); // no second requested signal
    try testing.expectEqual(@as(usize, 0), countSent(.INT));
    try testing.expectEqual(SIG.TERM, l.requested_signal.?);
    fake_now += 300;
    try set.tick();
    try testing.expect(l.escalated);
    try testing.expectEqual(@as(usize, 1), countSent(.KILL));
    // Joining after escalation sends SIGKILL again and gets its own kill-wait.
    fake_now += 600;
    const late = try set.terminate(l, .{ .deadline = fake_now + 5_000 });
    try testing.expectEqual(@as(usize, 2), countSent(.KILL));
    fake_now += 400; // the first three reach their kill-wait; `late` does not
    try set.tick();
    var timed_out: usize = 0;
    while (set.nextEvent()) |e| {
        try testing.expectEqual(leaders_mod.Outcome.timeout, e.done.outcome);
        try testing.expect(e.done.request != late.joined);
        timed_out += 1;
    }
    try testing.expectEqual(@as(usize, 3), timed_out);
    _ = first;
    _ = sooner;
    // The real exit completes the remaining joined request.
    drop_kill = false;
    try testing.expectEqual(@as(c_int, 0), c.kill(-l.pid, .KILL));
    var log: Log = .{};
    try log.drive(&set, 2, 3_000);
    try testing.expect(log.events[0] == .exited);
    try testing.expectEqual(late.joined, log.events[1].done.request);
    try testing.expectEqual(leaders_mod.Outcome.exited, log.events[1].done.outcome);
    try testing.expect(l.escalated);
}

test "leaders: joined requests complete together from the same exit" {
    resetRecord();
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader("exec sleep 30"));
    const a = try set.terminate(l, .{ .deadline = set.now() + 5_000 });
    const b = try set.terminate(l, .{ .deadline = set.now() + 5_000 });
    var log: Log = .{};
    try log.drive(&set, 3, 3_000);
    try testing.expect(log.events[0] == .exited);
    try testing.expectEqual(a.started, log.events[1].done.request);
    try testing.expectEqual(b.joined, log.events[2].done.request);
}

test "leaders: cancellation drops the request but supervision continues" {
    resetRecord();
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    const l = try set.adopt(try spawnLeader(ignore_term));
    sleepMs(50);
    const r = try set.terminate(l, .{ .deadline = set.now() + 100 });
    try testing.expect(set.cancel(r.started));
    try testing.expect(!set.cancel(r.started));
    var log: Log = .{};
    try log.drive(&set, 1, 3_000);
    try testing.expect(log.events[0] == .exited);
    try testing.expect(l.escalated); // escalation continued to its deadline
    try set.tick();
    try testing.expect(set.nextEvent() == null); // no done for the cancelled request
}

test "leaders: never signals a reaped leader" {
    resetRecord();
    var set = Leaders.init(testing.allocator, .{ .send = record });
    defer set.deinit();
    // Exited and observed by tick: an ordinary exit, no sweep.
    const a = try set.adopt(try spawnLeader("exit 4"));
    var log: Log = .{};
    try log.drive(&set, 1, 3_000);
    try testing.expectEqual(@as(u8, 4), a.status.?.code);
    try testing.expectEqual(@as(u32, 4 << 8), a.status.?.waitStatus());
    try testing.expect(try set.terminate(a, .{ .deadline = 0 }) == .already_exited);
    // Exited but not observed yet: terminate reaps it and sends nothing.
    const b = try set.adopt(try spawnLeader("exit 5"));
    const deadline = monotonicMs() + 2_000;
    while (true) { // until it is a zombie, peeking without reaping
        var info: linux.siginfo_t = undefined;
        info.fields.common.first.piduid.pid = 0;
        _ = linux.waitid(.PID, b.pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
        if (info.fields.common.first.piduid.pid != 0) break;
        if (monotonicMs() > deadline) return error.Timeout;
        sleepMs(1);
    }
    try testing.expect(try set.terminate(b, .{ .deadline = 0 }) == .already_exited);
    try testing.expectEqual(@as(u8, 5), b.status.?.code);
    log.drain(&set);
    try testing.expect(log.events[log.len - 1] == .exited and log.events[log.len - 1].exited == b);
    try testing.expectEqual(@as(usize, 0), sent_len);
    set.deinit();
    try testing.expectEqual(@as(usize, 0), sent_len); // deinit does not signal reaped leaders
    set = Leaders.init(testing.allocator, .{ .send = record });
}

test "leaders: adopt rejects unsafe or foreign groups" {
    var set = Leaders.init(testing.allocator, .{});
    defer set.deinit();
    try testing.expectError(error.UnsafeGroup, set.adopt(0));
    try testing.expectError(error.UnsafeGroup, set.adopt(1));
    try testing.expectError(error.UnsafeGroup, set.adopt(c.getpid()));
    try testing.expectError(error.UnsafeGroup, set.adopt(getpgid(0)));
    try testing.expectError(error.NotChild, set.adopt(c.getppid()));
    const pid = try spawnLeader("exec sleep 30");
    const l = try set.adopt(pid);
    try testing.expectError(error.AlreadyAdopted, set.adopt(pid));
    try testing.expect(l.pollFd() != null);
    // deinit kills and reaps what it can without waiting.
}

test "leaders: allocation failures leave no effects" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var set = Leaders.init(failing.allocator(), .{});
    defer set.deinit();
    const pid = try spawnLeader("exec sleep 30");
    defer {
        _ = c.kill(-pid, .KILL);
        _ = c.waitpid(pid, null, 0);
    }
    try testing.expectError(error.OutOfMemory, set.adopt(pid));
    try testing.expectEqual(@as(usize, 0), set.live());
}
