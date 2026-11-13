//! supervisor: run threads or child processes, restart them with exponential
//! backoff, publish a status file, and shut down gracefully on SIGTERM.
//!
//! This is the nullclaw pattern; `venom-os up` builds on it.
//!
//! ```zig
//! const stop = supervisor.installSignalHandlers(); // SIGTERM and SIGINT
//! var sup = supervisor.Supervisor.init(gpa, .{ .status_path = status, .logger = &logger });
//! defer sup.deinit();
//! try sup.addThread("serve", supervisor.Task.init(&server_loop), .{});
//! try sup.addProcess("helper", &.{ "venom-helper", "serve" }, .{ .restart = .always });
//! sup.run(stop, .{}); // returns after a graceful shutdown
//! ```
//!
//! * A **thread** worker is a `Task`. It must return promptly once its `Stop`
//!   is requested. Returning an error is a failure and is restarted; a clean
//!   return is final under the default `.on_failure` policy. A panic still
//!   aborts the whole process, as everywhere in Zig.
//! * A **process** worker runs `argv` (looked up in `PATH`) in its own
//!   process group. A non-zero exit or a signal is a failure. On shutdown the
//!   group receives SIGTERM, then SIGKILL once the grace period runs out.
//! * Consecutive failures wait `initial_ms * 2^(n-1)`, capped at `max_ms`. A
//!   worker that stayed up for `reset_after_ms` counts as healthy again.
//! * The status file (JSON, mode 0600) is rewritten atomically on every state
//!   change, so other tools (`doctor`, `venom-os status`) can read it at any time.
//!
//! * `Leaders` terminates adopted process-group leaders (PTY panes) without
//!   blocking: pinned exit observation, group sweep, escalation, joining.
//! * With `reap_orphans`, `run` also reaps the escaped descendants a subreaper
//!   collects, and only those. A blanket
//!   `waitpid(-1)` would take the status of a child some thread is waiting
//!   for. The kernel gives a reparented process to the first live thread of
//!   the subreaper, which is the main thread, and `__WNOTHREAD` limits a wait
//!   to the calling thread's children. So on the main thread it sees orphans
//!   and never a child that a reactor or worker thread forked: `Leaders`, and
//!   `std.process.run` on any thread, keep their statuses without registering
//!   anything. If the kernel ever reparented elsewhere, the failure would be a
//!   zombie, not a stolen status. The rules that follow:
//!     - Call `run` on the main thread. Elsewhere reaping does nothing.
//!     - Fork other children from other threads while `run` is running. One
//!       the main thread forks and waits for before returning to `run` is also
//!       fine; one it leaves for later is taken for an orphan.
//!     - A thread's children that outlive it move to the main thread, where
//!       they look like orphans but may still be someone's: `Leaders` keeps
//!       waiting for them. So once any thread worker has ended, on its own or
//!       to be restarted, reaping stays off for good: orphans stay zombies from
//!       then on, and every status stays with its owner.
//!     - Reaping stops once `shutdown` starts, since joined threads' children
//!       move to the main thread then. A late orphan goes to init with the daemon.
//!
//! The supervisor itself is driven from one thread (`run` or `tick`); only the
//! workers' `Stop` flags are shared with other threads.
const std = @import("std");
const builtin = @import("builtin");
const iface = @import("iface");

/// Nonblocking, pinned process-group termination of daemon-created leaders
/// Linux and macOS; see `leaders.zig`.
pub const leaders = @import("leaders.zig");
pub const Leaders = leaders.Leaders;
pub const Leader = leaders.Leader;
const log = @import("log");
const c = std.c;

pub const Restart = enum {
    /// Restart after any exit, clean or not.
    always,
    /// Restart after an error, a non-zero exit code or a signal.
    on_failure,
    /// Run once.
    never,
};

pub const Policy = struct {
    restart: Restart = .on_failure,
    initial_ms: u32 = 100,
    max_ms: u32 = 30_000,
    /// A worker that ran this long before exiting resets its failure count.
    reset_after_ms: u32 = 10_000,
    /// Give up after this many consecutive failures; null retries forever.
    max_failures: ?u32 = null,

    /// Delay before restart number `failures` (1-based).
    pub fn delay(policy: Policy, failures: u32) u32 {
        if (failures == 0) return 0;
        const shift: u6 = @intCast(@min(failures - 1, 32));
        const wide = @as(u64, policy.initial_ms) << shift;
        return @intCast(@min(wide, policy.max_ms));
    }
};

/// Cooperative stop request for a thread worker.
pub const Stop = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn requested(self: *const Stop) bool {
        return self.flag.load(.acquire);
    }
    pub fn request(self: *Stop) void {
        self.flag.store(true, .release);
    }
};

/// A thread worker: `pub fn run(self: *T, stop: *const Stop) anyerror!void`.
pub const Task = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, stop: *const Stop) anyerror!void,
    };

    pub fn init(impl: anytype) Task {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .run = runThunk };
            fn runThunk(ptr: *anyopaque, stop: *const Stop) anyerror!void {
                return iface.cast(T, ptr).run(stop);
            }
        }.vt };
    }

    pub fn run(self: Task, stop: *const Stop) anyerror!void {
        return self.vtable.run(self.ptr, stop);
    }
};

pub const State = enum {
    /// Added, not started yet.
    pending,
    running,
    /// Waiting for its next restart.
    backoff,
    /// Ended and will not be restarted (clean exit, or policy `.never`).
    exited,
    /// Gave up after `max_failures`, or could not be started at all.
    failed,
    /// Ended by `shutdown`.
    stopped,

    fn terminal(state: State) bool {
        return state == .exited or state == .failed or state == .stopped;
    }
};

pub const Exit = union(enum) {
    /// Thread returned or process exited with status 0.
    ok,
    /// Thread returned this error.
    @"error": anyerror,
    /// Process exited with this non-zero status.
    code: u8,
    /// Process was killed by this signal.
    signal: u32,

    pub fn failed(exit: Exit) bool {
        return exit != .ok;
    }
};

pub const Kind = enum { thread, process };

pub const Worker = struct {
    name: []const u8,
    kind: Kind,
    policy: Policy,
    state: State = .pending,
    /// Total restarts since the supervisor started.
    restarts: u32 = 0,
    /// Consecutive failures; drives the backoff.
    failures: u32 = 0,
    last_exit: ?Exit = null,
    started_ms: i64 = 0,
    /// When a worker in `.backoff` starts again.
    next_ms: i64 = 0,

    // Thread workers.
    task: Task = undefined,
    stop: Stop = .{},
    done: std.atomic.Value(bool) = .init(false),
    result: ?anyerror = null,
    thread: ?std.Thread = null,

    // Process workers.
    argv: [:null]?[*:0]const u8 = undefined,
    pid: c.pid_t = 0,

    fn threadMain(self: *Worker) void {
        if (self.task.run(&self.stop)) |_| {
            self.result = null;
        } else |err| {
            self.result = err;
        }
        self.done.store(true, .release);
    }
};

pub const Options = struct {
    /// Where to publish status JSON; null disables the file.
    status_path: ?[]const u8 = null,
    logger: ?*log.Logger = null,
    /// Monotonic milliseconds. Tests may pin it.
    clock: *const fn () i64 = monotonicMs,
    /// For a daemon with the subreaper: reap orphans each turn (module doc).
    reap_orphans: bool = false,
};

pub const RunOptions = struct {
    /// How often `run` checks workers and the stop flag.
    poll_ms: u32 = 50,
    /// Grace period between SIGTERM (or a thread's Stop) and SIGKILL.
    grace_ms: u32 = 5_000,
};

pub const Supervisor = struct {
    gpa: std.mem.Allocator,
    options: Options,
    workers: std.ArrayList(*Worker) = .empty,
    stopping: bool = false,
    dirty: bool = true,
    /// A thread worker has ended, so `reapOrphans` stays off (module doc).
    thread_ended: bool = false,
    /// Orphans reaped with `reap_orphans`. Any thread may read it.
    orphans_reaped: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, options: Options) Supervisor {
        return .{ .gpa = gpa, .options = options };
    }

    /// Call `shutdown` (or let `run` return) first; live workers are stopped here
    /// with the default grace period as a last resort.
    pub fn deinit(self: *Supervisor) void {
        if (!self.allSettled()) self.shutdown(5_000);
        for (self.workers.items) |w| {
            self.gpa.free(w.name);
            if (w.kind == .process) {
                for (w.argv) |arg| self.gpa.free(std.mem.span(arg.?));
                self.gpa.free(w.argv);
            }
            self.gpa.destroy(w);
        }
        self.workers.deinit(self.gpa);
        if (self.options.status_path) |p| self.removeStatus(p);
    }

    pub fn addThread(self: *Supervisor, name: []const u8, task: Task, policy: Policy) !void {
        const w = try self.add(name, .thread, policy);
        w.task = task;
    }

    pub fn addProcess(self: *Supervisor, name: []const u8, argv: []const []const u8, policy: Policy) !void {
        if (argv.len == 0) return error.EmptyArgv;
        const list = try self.gpa.allocSentinel(?[*:0]const u8, argv.len, null);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |arg| self.gpa.free(std.mem.span(arg.?));
            self.gpa.free(list);
        }
        for (argv, 0..) |arg, i| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgv;
            list[i] = try self.gpa.dupeSentinel(u8, arg, 0);
            filled += 1;
        }
        const w = try self.add(name, .process, policy);
        w.argv = list;
    }

    fn add(self: *Supervisor, name: []const u8, kind: Kind, policy: Policy) !*Worker {
        if (self.stopping) return error.ShuttingDown;
        for (self.workers.items) |w| if (std.mem.eql(u8, w.name, name)) return error.DuplicateWorker;
        try self.workers.ensureUnusedCapacity(self.gpa, 1);
        const w = try self.gpa.create(Worker);
        errdefer self.gpa.destroy(w);
        w.* = .{ .name = try self.gpa.dupe(u8, name), .kind = kind, .policy = policy };
        self.workers.appendAssumeCapacity(w);
        self.dirty = true;
        return w;
    }

    pub fn find(self: *Supervisor, name: []const u8) ?*Worker {
        for (self.workers.items) |w| if (std.mem.eql(u8, w.name, name)) return w;
        return null;
    }

    /// Reaps exited workers, starts pending or due ones and publishes status.
    pub fn tick(self: *Supervisor) void {
        const now = self.options.clock();
        for (self.workers.items) |w| {
            if (w.state == .running) if (self.reap(w, false)) |exit| self.exited(w, exit, now);
            if (self.stopping) continue;
            if (w.state == .pending or (w.state == .backoff and now >= w.next_ms)) self.start(w, now);
        }
        if (self.options.reap_orphans and !self.stopping) self.reapOrphans();
        if (self.dirty) self.publish();
    }

    /// See the module doc for why this only ever finds orphans.
    fn reapOrphans(self: *Supervisor) void {
        if (builtin.os.tag != .linux) return;
        const linux = std.os.linux;
        if (self.thread_ended or linux.gettid() != linux.getpid()) return;
        const flags = linux.W.EXITED | linux.W.NOHANG | wnothread;
        while (true) {
            var peek: linux.siginfo_t = undefined;
            peek.fields.common.first.piduid.pid = 0;
            if (linux.errno(linux.waitid(.ALL, 0, &peek, flags | linux.W.NOWAIT, null)) != .SUCCESS) return;
            const pid = peek.fields.common.first.piduid.pid;
            if (pid == 0) return;
            // A process worker that just exited: `tick` reaps it next turn,
            // first, so it can't hide an orphan for long.
            for (self.workers.items) |w| if (w.kind == .process and w.pid == pid) return;
            // `tick` may have read `done` just before a thread ended. Its
            // children only move here after `done` is set, so this load, after
            // the peek, can't miss the thread that left this one behind.
            for (self.workers.items) |w| if (w.kind == .thread and w.done.load(.acquire)) {
                self.thread_ended = true;
                return;
            };
            var done: linux.siginfo_t = undefined;
            done.fields.common.first.piduid.pid = 0;
            if (linux.errno(linux.waitid(.PID, pid, &done, flags, null)) != .SUCCESS) return;
            _ = self.orphans_reaped.fetchAdd(1, .monotonic);
        }
    }

    /// True when no worker is running or waiting to restart.
    pub fn allSettled(self: *const Supervisor) bool {
        for (self.workers.items) |w| if (!w.state.terminal()) return false;
        return true;
    }

    /// Ticks until `stop` is set (normally by `installSignalHandlers`) or every
    /// worker has settled, then shuts down gracefully.
    pub fn run(self: *Supervisor, stop: *const std.atomic.Value(bool), options: RunOptions) void {
        while (!stop.load(.acquire)) {
            self.tick();
            if (self.workers.items.len > 0 and self.allSettled()) break;
            sleepMs(options.poll_ms);
        }
        self.shutdown(options.grace_ms);
    }

    /// Stops every worker: Stop for threads, SIGTERM to process groups, then
    /// SIGKILL after `grace_ms`. Threads are always joined, so a task that
    /// ignores its Stop delays shutdown (a warning is logged).
    pub fn shutdown(self: *Supervisor, grace_ms: u32) void {
        self.stopping = true;
        self.info("shutting down", .{ .workers = self.workers.items.len });
        for (self.workers.items) |w| switch (w.state) {
            .running => switch (w.kind) {
                .thread => w.stop.request(),
                .process => _ = c.kill(-w.pid, .TERM),
            },
            .pending, .backoff => w.state = .stopped,
            else => {},
        };
        self.dirty = true;
        self.publish();
        const deadline = monotonicMs() + grace_ms;
        while (true) {
            var live: usize = 0;
            for (self.workers.items) |w| if (w.state == .running) {
                if (self.reap(w, false)) |exit| self.settle(w, exit) else live += 1;
            };
            if (live == 0) break;
            if (monotonicMs() >= deadline) break;
            sleepMs(10);
        }
        for (self.workers.items) |w| if (w.state == .running) {
            switch (w.kind) {
                .thread => self.warn("worker ignores stop; waiting", .{ .worker = w.name }),
                .process => {
                    self.warn("worker did not stop in time; killing", .{ .worker = w.name, .pid = w.pid });
                    _ = c.kill(-w.pid, .KILL);
                },
            }
            self.settle(w, self.reap(w, true).?);
        };
        self.publish();
        self.info("stopped", .{});
    }

    fn settle(self: *Supervisor, w: *Worker, exit: Exit) void {
        w.last_exit = exit;
        w.state = .stopped;
        w.pid = 0;
        self.dirty = true;
    }

    fn start(self: *Supervisor, w: *Worker, now: i64) void {
        if (w.state == .backoff) w.restarts += 1;
        w.started_ms = now;
        switch (w.kind) {
            .thread => {
                w.stop = .{};
                w.done.store(false, .release);
                w.result = null;
                w.thread = std.Thread.spawn(.{}, Worker.threadMain, .{w}) catch |err| {
                    self.exited(w, .{ .@"error" = err }, now);
                    return;
                };
                self.info("worker started", .{ .worker = w.name, .kind = w.kind, .restarts = w.restarts });
            },
            .process => {
                w.pid = spawn(w.argv) catch |err| {
                    self.exited(w, .{ .@"error" = err }, now);
                    return;
                };
                self.info("worker started", .{ .worker = w.name, .kind = w.kind, .pid = w.pid, .restarts = w.restarts });
            },
        }
        w.state = .running;
        self.dirty = true;
    }

    /// Non-blocking unless `block`. Returns the exit once the worker is gone.
    fn reap(_: *Supervisor, w: *Worker, block: bool) ?Exit {
        switch (w.kind) {
            .thread => {
                if (!block and !w.done.load(.acquire)) return null;
                w.thread.?.join();
                w.thread = null;
                return if (w.result) |err| .{ .@"error" = err } else .ok;
            },
            .process => {
                var raw: c_int = 0;
                while (true) {
                    const rc = c.waitpid(w.pid, &raw, if (block) 0 else c.W.NOHANG);
                    if (rc == 0) return null;
                    if (rc < 0) {
                        if (c.errno(rc) == .INTR) continue;
                        return .{ .@"error" = error.WaitFailed };
                    }
                    break;
                }
                const s: u32 = @bitCast(raw);
                if (c.W.IFEXITED(s)) {
                    const code = c.W.EXITSTATUS(s);
                    return if (code == 0) .ok else .{ .code = code };
                }
                return .{ .signal = @backingInt(c.W.TERMSIG(s)) };
            },
        }
    }

    fn exited(self: *Supervisor, w: *Worker, exit: Exit, now: i64) void {
        if (w.kind == .thread) {
            self.thread_ended = true;
            // A clean return is how a daemon ends: only a failure is worth a warning.
            if (self.options.reap_orphans and exit.failed()) self.warn("thread worker failed; orphans are no longer reaped and stay zombies until restart", .{ .worker = w.name });
        }
        w.last_exit = exit;
        w.pid = 0;
        self.dirty = true;
        if (now - w.started_ms >= w.policy.reset_after_ms) w.failures = 0;
        const restart = switch (w.policy.restart) {
            .always => true,
            .on_failure => exit.failed(),
            .never => false,
        };
        if (exit.failed()) w.failures += 1;
        if (!restart) {
            w.state = if (exit.failed()) .failed else .exited;
            self.logExit(w, exit, "worker ended");
            return;
        }
        if (w.policy.max_failures) |max| if (w.failures > max) {
            w.state = .failed;
            self.logExit(w, exit, "worker failed too often; giving up");
            return;
        };
        const delay = w.policy.delay(@max(w.failures, 1));
        w.state = .backoff;
        w.next_ms = now + delay;
        self.logExit(w, exit, "worker exited; restarting");
    }

    fn logExit(self: *Supervisor, w: *Worker, exit: Exit, msg: []const u8) void {
        const l = self.options.logger orelse return;
        const level: log.Level = if (exit.failed()) .warn else .info;
        const delay: ?u32 = if (w.state == .backoff) w.policy.delay(@max(w.failures, 1)) else null;
        switch (exit) {
            .ok => l.log(level, msg, .{ .worker = w.name, .exit = "ok", .failures = w.failures, .delay_ms = delay }),
            .@"error" => |e| l.log(level, msg, .{ .worker = w.name, .@"error" = e, .failures = w.failures, .delay_ms = delay }),
            .code => |code| l.log(level, msg, .{ .worker = w.name, .code = code, .failures = w.failures, .delay_ms = delay }),
            .signal => |sig| l.log(level, msg, .{ .worker = w.name, .signal = sig, .failures = w.failures, .delay_ms = delay }),
        }
    }

    fn info(self: *Supervisor, msg: []const u8, fields: anytype) void {
        if (self.options.logger) |l| l.info(msg, fields);
    }
    fn warn(self: *Supervisor, msg: []const u8, fields: anytype) void {
        if (self.options.logger) |l| l.warn(msg, fields);
    }

    fn publish(self: *Supervisor) void {
        self.dirty = false;
        const p = self.options.status_path orelse return;
        self.writeStatus(p) catch |err| self.warn("cannot write status file", .{ .path = p, .@"error" = err });
    }

    /// Renders the status document into `w`.
    pub fn status(self: *const Supervisor, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("pid");
        try s.write(c.getpid());
        try s.objectField("updated_ms");
        try s.write(log.realtimeMs());
        try s.objectField("stopping");
        try s.write(self.stopping);
        try s.objectField("workers");
        try s.beginArray();
        for (self.workers.items) |wk| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(wk.name);
            try s.objectField("kind");
            try s.write(@tagName(wk.kind));
            try s.objectField("state");
            try s.write(@tagName(wk.state));
            try s.objectField("pid");
            try s.write(if (wk.pid != 0) @as(?c.pid_t, wk.pid) else null);
            try s.objectField("restarts");
            try s.write(wk.restarts);
            try s.objectField("failures");
            try s.write(wk.failures);
            try s.objectField("last_exit");
            if (wk.last_exit) |exit| {
                try s.beginObject();
                switch (exit) {
                    .ok => {
                        try s.objectField("ok");
                        try s.write(true);
                    },
                    .@"error" => |e| {
                        try s.objectField("error");
                        try s.write(@errorName(e));
                    },
                    .code => |code| {
                        try s.objectField("code");
                        try s.write(code);
                    },
                    .signal => |sig| {
                        try s.objectField("signal");
                        try s.write(sig);
                    },
                }
                try s.endObject();
            } else try s.write(null);
            try s.objectField("restart_in_ms");
            try s.write(if (wk.state == .backoff) @as(?i64, @max(0, wk.next_ms - self.options.clock())) else null);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }

    fn writeStatus(self: *const Supervisor, p: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer buf.deinit();
        try self.status(&buf.writer);
        try buf.writer.writeByte('\n');
        const final = try self.gpa.dupeSentinel(u8, p, 0);
        defer self.gpa.free(final);
        const tmp = try std.fmt.allocPrintSentinel(self.gpa, "{s}.tmp", .{p}, 0);
        defer self.gpa.free(tmp);
        const fd = c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        var rest = buf.written();
        while (rest.len > 0) {
            const n = c.write(fd, rest.ptr, rest.len);
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) {
                _ = c.close(fd);
                _ = c.unlink(tmp);
                return error.WriteFailed;
            }
            rest = rest[@intCast(n)..];
        }
        _ = c.close(fd);
        if (c.rename(tmp, final) != 0) {
            _ = c.unlink(tmp);
            return error.RenameFailed;
        }
    }

    fn removeStatus(self: *Supervisor, p: []const u8) void {
        const z = self.gpa.dupeSentinel(u8, p, 0) catch return;
        defer self.gpa.free(z);
        _ = c.unlink(z);
    }
};

extern "c" fn fork() c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn sigprocmask(how: c_int, set: ?*const c.sigset_t, old: ?*c.sigset_t) c_int;

/// fork + execvp in a new process group. The child only makes
/// async-signal-safe calls before exec; exit status 127 means exec failed.
fn spawn(argv: [:null]?[*:0]const u8) !c.pid_t {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        // Handlers are reset by exec; restore default dispositions for the
        // signals a supervisor typically catches, and unblock everything.
        const dfl: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
        _ = c.sigaction(.TERM, &dfl, null);
        _ = c.sigaction(.INT, &dfl, null);
        _ = c.sigaction(.HUP, &dfl, null);
        const empty = std.mem.zeroes(c.sigset_t);
        _ = sigprocmask(c.SIG.SETMASK, &empty, null);
        _ = execvp(argv[0].?, argv.ptr);
        c._exit(127);
    }
    // Also set it here, so a SIGTERM to the group cannot race the child's setpgid.
    _ = c.setpgid(pid, pid);
    return pid;
}

var signaled: std.atomic.Value(bool) = .init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    signaled.store(true, .release);
}

/// Routes SIGTERM and SIGINT to a process-wide flag and returns it; pass it to
/// `Supervisor.run`. SIGHUP keeps its disposition: a supervisor must not stop
/// its daemons because its terminal closed. A client that
/// must clean up its terminal opts in with `routeHangup`.
pub fn installSignalHandlers() *std.atomic.Value(bool) {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.INT, &action, null);
    return &signaled;
}

/// Also routes SIGHUP to the flag `installSignalHandlers` returns. For a
/// full-screen client, called once it owns the terminal, so that closing the
/// host terminal restores it instead of leaving it raw. Not for daemons or
/// their supervisors. A SIGHUP that was already ignored stays ignored, so
/// `nohup` keeps working.
pub fn routeHangup() void {
    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.HUP, null, &current);
    if (current.handler.handler == std.posix.SIG.IGN) return;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.HUP, &action, null);
}

pub fn monotonicMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// wait(2)'s `__WNOTHREAD`: only the calling thread's children.
const wnothread: u32 = 0x20000000;

fn sleepMs(ms: u32) void {
    var req: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
    while (c.nanosleep(&req, &req) != 0 and c.errno(@as(c_int, -1)) == .INTR) {}
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test {
    if (builtin.os.tag == .linux) _ = @import("leaders_tests.zig");
}

fn settle(sup: *Supervisor, timeout_ms: u32, comptime done: fn (*Supervisor) bool) !void {
    const deadline = monotonicMs() + timeout_ms;
    while (!done(sup)) {
        if (monotonicMs() > deadline) return error.Timeout;
        sup.tick();
        sleepMs(1);
    }
}

test "supervisor: backoff doubles from initial and caps at max" {
    const p: Policy = .{ .initial_ms = 100, .max_ms = 1_000 };
    try testing.expectEqual(@as(u32, 0), p.delay(0));
    try testing.expectEqual(@as(u32, 100), p.delay(1));
    try testing.expectEqual(@as(u32, 200), p.delay(2));
    try testing.expectEqual(@as(u32, 800), p.delay(4));
    try testing.expectEqual(@as(u32, 1_000), p.delay(5));
    try testing.expectEqual(@as(u32, 1_000), p.delay(1_000));
}

const Flaky = struct {
    calls: std.atomic.Value(u32) = .init(0),
    fail_first: u32,
    pub fn run(self: *Flaky, _: *const Stop) anyerror!void {
        if (self.calls.fetchAdd(1, .acq_rel) < self.fail_first) return error.Boom;
    }
};

test "supervisor: failing thread restarts with backoff until it succeeds" {
    var task: Flaky = .{ .fail_first = 2 };
    var sup = Supervisor.init(testing.allocator, .{});
    defer sup.deinit();
    try sup.addThread("flaky", Task.init(&task), .{ .initial_ms = 1, .max_ms = 4 });
    try testing.expectError(error.DuplicateWorker, sup.addThread("flaky", Task.init(&task), .{}));
    try settle(&sup, 5_000, Supervisor.allSettled);
    const w = sup.find("flaky").?;
    try testing.expectEqual(State.exited, w.state);
    try testing.expectEqual(@as(u32, 3), task.calls.load(.acquire));
    try testing.expectEqual(@as(u32, 2), w.restarts);
    try testing.expectEqual(Exit.ok, w.last_exit.?);
}

test "supervisor: max_failures gives up" {
    var task: Flaky = .{ .fail_first = 100 };
    var sup = Supervisor.init(testing.allocator, .{});
    defer sup.deinit();
    try sup.addThread("doomed", Task.init(&task), .{ .initial_ms = 1, .max_failures = 2 });
    try settle(&sup, 5_000, Supervisor.allSettled);
    const w = sup.find("doomed").?;
    try testing.expectEqual(State.failed, w.state);
    try testing.expectEqual(@as(u32, 3), task.calls.load(.acquire));
    try testing.expectEqual(error.Boom, w.last_exit.?.@"error");
}

const Loop = struct {
    ticks: std.atomic.Value(u32) = .init(0),
    pub fn run(self: *Loop, stop: *const Stop) anyerror!void {
        while (!stop.requested()) {
            _ = self.ticks.fetchAdd(1, .monotonic);
            sleepMs(1);
        }
    }
};

test "supervisor: run stops thread workers when the stop flag is set" {
    var task: Loop = .{};
    var sup = Supervisor.init(testing.allocator, .{});
    defer sup.deinit();
    try sup.addThread("loop", Task.init(&task), .{ .restart = .always });
    var stop: std.atomic.Value(bool) = .init(false);
    const Stopper = struct {
        fn go(flag: *std.atomic.Value(bool), t: *Loop) void {
            while (t.ticks.load(.monotonic) < 5) sleepMs(1);
            flag.store(true, .release);
        }
    };
    const stopper = try std.Thread.spawn(.{}, Stopper.go, .{ &stop, &task });
    sup.run(&stop, .{ .poll_ms = 1, .grace_ms = 1_000 });
    stopper.join();
    const w = sup.find("loop").?;
    try testing.expectEqual(State.stopped, w.state);
    try testing.expectEqual(Exit.ok, w.last_exit.?);
    try testing.expectError(error.ShuttingDown, sup.addThread("late", Task.init(&task), .{}));
}

test "supervisor: child process exit codes, restarts and missing binaries" {
    var sup = Supervisor.init(testing.allocator, .{});
    defer sup.deinit();
    try sup.addProcess("sh", &.{ "sh", "-c", "exit 3" }, .{ .initial_ms = 1, .max_failures = 1 });
    try sup.addProcess("missing", &.{"venom-supervisor-test-no-such-binary"}, .{ .restart = .never });
    try sup.addProcess("ok", &.{ "sh", "-c", "exit 0" }, .{});
    try settle(&sup, 5_000, Supervisor.allSettled);
    const sh = sup.find("sh").?;
    try testing.expectEqual(State.failed, sh.state);
    try testing.expectEqual(@as(u32, 1), sh.restarts);
    try testing.expectEqual(@as(u8, 3), sh.last_exit.?.code);
    try testing.expectEqual(@as(u8, 127), sup.find("missing").?.last_exit.?.code);
    try testing.expectEqual(State.exited, sup.find("ok").?.state);
    try testing.expectError(error.EmptyArgv, sup.addProcess("empty", &.{}, .{}));
}

/// On a thread of its own, like a reactor: forks children, waits for their
/// exact statuses, and leaves orphans behind for the main thread.
const OwnChildren = struct {
    rounds: u32 = 0,

    pub fn run(self: *OwnChildren, _: *const Stop) anyerror!void {
        for (0..5) |i| {
            const code: u8 = @intCast(10 + i);
            const child = c.fork();
            if (child == 0) c._exit(code);
            if (child < 0) return error.ForkFailed;

            var pipe: [2]c.fd_t = undefined;
            if (c.pipe(&pipe) != 0) return error.PipeFailed;
            const parent = c.fork();
            if (parent == 0) {
                const orphan = c.fork();
                if (orphan == 0) {
                    sleepMs(5);
                    c._exit(0);
                }
                _ = c.write(pipe[1], std.mem.asBytes(&orphan), @sizeOf(c.pid_t));
                c._exit(0);
            }
            if (parent < 0) return error.ForkFailed;
            _ = c.close(pipe[1]);
            var orphan: c.pid_t = 0;
            const n = c.read(pipe[0], std.mem.asBytes(&orphan), @sizeOf(c.pid_t));
            _ = c.close(pipe[0]);
            if (n != @sizeOf(c.pid_t)) return error.NoOrphan;
            try expectExit(parent, 0);

            // kill(2) still finds a zombie: this ends only once it was reaped.
            const deadline = monotonicMs() + 5_000;
            while (c.kill(orphan, @fromBackingInt(0)) == 0) {
                if (monotonicMs() > deadline) return error.OrphanStayedZombie;
                sleepMs(1);
            }
            // A zombie for many of the main thread's turns, and still ours.
            sleepMs(20);
            try expectExit(child, code);
            self.rounds += 1;
        }
    }

    fn expectExit(pid: c.pid_t, code: u8) !void {
        var raw: c_int = 0;
        if (c.waitpid(pid, &raw, 0) != pid) return error.StatusStolen;
        const s: u32 = @bitCast(raw);
        if (!c.W.IFEXITED(s) or c.W.EXITSTATUS(s) != code) return error.WrongStatus;
    }
};

test "supervisor: reap_orphans takes orphans, not other threads' children or its workers" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    if (linux.gettid() != linux.getpid()) return error.SkipZigTest;
    _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
    defer _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 0, 0, 0, 0);
    var sup = Supervisor.init(testing.allocator, .{ .reap_orphans = true });
    defer sup.deinit();
    var own: OwnChildren = .{};
    try sup.addThread("own", Task.init(&own), .{ .restart = .never });
    try sup.addProcess("worker", &.{ "sh", "-c", "sleep 0.05; exit 3" }, .{ .restart = .never });
    var stop: std.atomic.Value(bool) = .init(false);
    // Ends by itself once both workers settled.
    sup.run(&stop, .{ .poll_ms = 1, .grace_ms = 1_000 });
    const w = sup.find("own").?;
    if (w.last_exit.? != .ok) {
        std.debug.print("own children: {any}\n", .{w.last_exit.?});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u32, 5), own.rounds);
    try testing.expect(sup.orphans_reaped.load(.monotonic) >= 5);
    try testing.expectEqual(@as(u8, 3), sup.find("worker").?.last_exit.?.code);
}

/// Blocks until `pid` has exited, leaving it a zombie.
fn awaitZombie(pid: c.pid_t) !void {
    const linux = std.os.linux;
    var info: linux.siginfo_t = undefined;
    if (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOWAIT, null)) != .SUCCESS) return error.WaitFailed;
}

fn expectExitCode(pid: c.pid_t, code: u8) !void {
    var raw: c_int = 0;
    try testing.expectEqual(pid, c.waitpid(pid, &raw, c.W.NOHANG));
    const s: u32 = @bitCast(raw);
    try testing.expect(c.W.IFEXITED(s));
    try testing.expectEqual(code, c.W.EXITSTATUS(s));
}

fn onMainLinux() bool {
    if (builtin.os.tag != .linux) return false;
    return std.os.linux.gettid() == std.os.linux.getpid();
}

test "supervisor: reap_orphans is off during shutdown" {
    if (!onMainLinux()) return error.SkipZigTest;
    var sup = Supervisor.init(testing.allocator, .{ .reap_orphans = true });
    defer sup.deinit();
    const child = c.fork();
    if (child == 0) c._exit(4);
    try testing.expect(child > 0);
    // Exited, and a child of this (main) thread: only `stopping` protects it.
    try awaitZombie(child);
    sup.stopping = true;
    sup.tick();
    sup.stopping = false;
    try testing.expectEqual(@as(u64, 0), sup.orphans_reaped.load(.monotonic));
    // On the main thread and not stopping, it does count as an orphan.
    sup.tick();
    try testing.expectEqual(@as(u64, 1), sup.orphans_reaped.load(.monotonic));
    try testing.expectEqual(@as(c_int, -1), c.waitpid(child, null, c.W.NOHANG));
}

test "supervisor: reap_orphans does nothing off the main thread" {
    if (!onMainLinux()) return error.SkipZigTest;
    var sup = Supervisor.init(testing.allocator, .{ .reap_orphans = true });
    defer sup.deinit();
    const OffMain = struct {
        code: ?u8 = null,
        // The child is this thread's, so `__WNOTHREAD` alone would find it.
        fn run(self: *@This(), s: *Supervisor) void {
            const child = c.fork();
            if (child == 0) c._exit(5);
            if (child < 0) return;
            awaitZombie(child) catch return;
            s.tick();
            var raw: c_int = 0;
            if (c.waitpid(child, &raw, c.W.NOHANG) != child) return;
            self.code = c.W.EXITSTATUS(@bitCast(raw));
        }
    };
    var off: OffMain = .{};
    const thread = try std.Thread.spawn(.{}, OffMain.run, .{ &off, &sup });
    thread.join();
    try testing.expectEqual(@as(?u8, 5), off.code);
    try testing.expectEqual(@as(u64, 0), sup.orphans_reaped.load(.monotonic));
}

test "supervisor: reap_orphans leaves a process worker's exit to tick" {
    if (!onMainLinux()) return error.SkipZigTest;
    var sup = Supervisor.init(testing.allocator, .{ .reap_orphans = true });
    defer sup.deinit();
    try sup.addProcess("worker", &.{ "sh", "-c", "exit 3" }, .{ .restart = .never });
    sup.tick();
    const w = sup.find("worker").?;
    try awaitZombie(w.pid);
    sup.reapOrphans();
    try testing.expectEqual(@as(u64, 0), sup.orphans_reaped.load(.monotonic));
    sup.tick();
    try testing.expectEqual(@as(u8, 3), w.last_exit.?.code);
}

/// A reactor that returns while a child it forked is a zombie.
const LeavesZombie = struct {
    child: c.pid_t = 0,
    fail: bool,

    pub fn run(self: *LeavesZombie, _: *const Stop) anyerror!void {
        const child = c.fork();
        if (child == 0) c._exit(7);
        if (child < 0) return error.ForkFailed;
        self.child = child;
        try awaitZombie(child);
        if (self.fail) return error.Boom;
    }
};

test "supervisor: a thread worker's zombie keeps its status after the thread ended" {
    if (!onMainLinux()) return error.SkipZigTest;
    for ([_]bool{ false, true }) |fail| {
        for (0..20) |_| {
            var sup = Supervisor.init(testing.allocator, .{ .reap_orphans = true });
            defer sup.deinit();
            var t: LeavesZombie = .{ .fail = fail };
            try sup.addThread("reactor", Task.init(&t), .{ .restart = .never });
            var stop: std.atomic.Value(bool) = .init(false);
            sup.run(&stop, .{ .poll_ms = 1, .grace_ms = 100 });
            try expectExitCode(t.child, 7);
            try testing.expectEqual(@as(u64, 0), sup.orphans_reaped.load(.monotonic));
        }
    }
}

test "supervisor: reap_orphans checks done after the peek, and stays off" {
    if (!onMainLinux()) return error.SkipZigTest;
    var sup = Supervisor.init(testing.allocator, .{ .reap_orphans = true });
    defer sup.deinit();
    var t: Flaky = .{ .fail_first = 0 };
    try sup.addThread("reactor", Task.init(&t), .{ .restart = .never });
    const w = sup.find("reactor").?;
    const child = c.fork();
    if (child == 0) c._exit(8);
    try testing.expect(child > 0);
    try awaitZombie(child);
    // What `tick` can't see yet: the thread has just set `done`.
    w.done.store(true, .release);
    sup.reapOrphans();
    w.done.store(false, .release);
    // A restarted thread's `done` is false again: still off.
    sup.reapOrphans();
    try testing.expectEqual(@as(u64, 0), sup.orphans_reaped.load(.monotonic));
    try expectExitCode(child, 8);
}

test "supervisor: exited() turns reap_orphans off for a thread worker" {
    if (!onMainLinux()) return error.SkipZigTest;
    var sup = Supervisor.init(testing.allocator, .{ .reap_orphans = true });
    defer sup.deinit();
    var t: Flaky = .{ .fail_first = 0 };
    try sup.addThread("reactor", Task.init(&t), .{ .restart = .never });
    const child = c.fork();
    if (child == 0) c._exit(9);
    try testing.expect(child > 0);
    try awaitZombie(child);
    sup.exited(sup.find("reactor").?, .ok, 0);
    sup.reapOrphans();
    try testing.expectEqual(@as(u64, 0), sup.orphans_reaped.load(.monotonic));
    try expectExitCode(child, 9);
}

test "supervisor: a failed thread worker warns that reaping is off, only with the option" {
    for ([_]bool{ true, false }) |on| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var logger = log.Logger.init(.{ .source = "t", .stderr = &out.writer });
        defer logger.deinit();
        var sup = Supervisor.init(testing.allocator, .{ .logger = &logger, .reap_orphans = on });
        defer sup.deinit();
        var t: Flaky = .{ .fail_first = 0 };
        try sup.addThread("reactor", Task.init(&t), .{ .restart = .never });
        sup.exited(sup.find("reactor").?, .{ .@"error" = error.Boom }, 0);
        try testing.expectEqual(on, std.mem.indexOf(u8, out.written(), "no longer reaped") != null);
    }
}

fn allRunning(sup: *Supervisor) bool {
    for (sup.workers.items) |w| if (w.state != .running) return false;
    return true;
}

test "supervisor: shutdown sends SIGTERM, then SIGKILL after the grace period" {
    var sup = Supervisor.init(testing.allocator, .{});
    defer sup.deinit();
    try sup.addProcess("polite", &.{ "sleep", "30" }, .{});
    // Ignores SIGTERM (its short sleeps die, the loop continues) until SIGKILL.
    try sup.addProcess("stubborn", &.{ "sh", "-c", "trap '' TERM; while :; do sleep 0.01; done" }, .{});
    try settle(&sup, 5_000, allRunning);
    sleepMs(50); // let sh install its trap
    const started = monotonicMs();
    sup.shutdown(300);
    const took = monotonicMs() - started;
    try testing.expect(took >= 300 and took < 5_000);
    try testing.expectEqual(@as(u32, @backingInt(std.posix.SIG.TERM)), sup.find("polite").?.last_exit.?.signal);
    try testing.expectEqual(@as(u32, @backingInt(std.posix.SIG.KILL)), sup.find("stubborn").?.last_exit.?.signal);
    try testing.expect(sup.allSettled());
}

test "supervisor: status file is valid JSON and removed on deinit" {
    var template = "/tmp/venom-sup-test-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    defer _ = c.rmdir(dir);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/t.status.json", .{dir}, 0);
    defer testing.allocator.free(path);
    {
        var task: Flaky = .{ .fail_first = 1 };
        var sup = Supervisor.init(testing.allocator, .{ .status_path = path });
        defer sup.deinit();
        try sup.addThread("flaky", Task.init(&task), .{ .initial_ms = 60_000 });
        try settle(&sup, 5_000, struct {
            fn f(s: *Supervisor) bool {
                return s.find("flaky").?.state == .backoff;
            }
        }.f);
        const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        try testing.expect(fd >= 0);
        defer _ = c.close(fd);
        var bytes: [4096]u8 = undefined;
        const n = c.read(fd, &bytes, bytes.len);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes[0..@intCast(n)], .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try testing.expectEqual(@as(i64, c.getpid()), root.get("pid").?.integer);
        const w = root.get("workers").?.array.items[0].object;
        try testing.expectEqualStrings("flaky", w.get("name").?.string);
        try testing.expectEqualStrings("thread", w.get("kind").?.string);
        try testing.expectEqualStrings("backoff", w.get("state").?.string);
        try testing.expectEqualStrings("Boom", w.get("last_exit").?.object.get("error").?.string);
        try testing.expectEqual(@as(i64, 1), w.get("failures").?.integer);
        try testing.expect(w.get("restart_in_ms").?.integer > 0);
        sup.shutdown(1_000);
    }
    try testing.expect(c.access(path, 0) != 0);
}

test "supervisor: logs lifecycle through the log module" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var logger = log.Logger.init(.{ .source = "t", .stderr = &out.writer, .config = .{ .level = .debug, .stderr_level = .debug, .stderr_format = .json } });
    var task: Flaky = .{ .fail_first = 1 };
    var sup = Supervisor.init(testing.allocator, .{ .logger = &logger });
    defer sup.deinit();
    try sup.addThread("flaky", Task.init(&task), .{ .initial_ms = 1 });
    try settle(&sup, 5_000, Supervisor.allSettled);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "\"msg\":\"worker exited; restarting\",\"worker\":\"flaky\",\"error\":\"Boom\",\"failures\":1,\"delay_ms\":1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"msg\":\"worker ended\",\"worker\":\"flaky\",\"exit\":\"ok\"") != null);
}

test "supervisor: SIGTERM sets the stop flag" {
    const flag = installSignalHandlers();
    defer {
        flag.store(false, .release);
        const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.TERM, &dfl, null);
        std.posix.sigaction(.INT, &dfl, null);
    }
    try testing.expect(!flag.load(.acquire));
    _ = c.kill(c.getpid(), .TERM);
    const deadline = monotonicMs() + 1_000;
    while (!flag.load(.acquire) and monotonicMs() < deadline) sleepMs(1);
    try testing.expect(flag.load(.acquire));
}

/// Runs `body` with SIGHUP set to `disposition`, then restores what was there,
/// so the result doesn't depend on how the test runner was started.
fn withHup(disposition: ?std.posix.Sigaction.handler_fn, body: *const fn () anyerror!void) !void {
    const empty = std.posix.sigemptyset();
    var saved: [3]std.posix.Sigaction = undefined;
    const set: std.posix.Sigaction = .{ .handler = .{ .handler = disposition }, .mask = empty, .flags = 0 };
    std.posix.sigaction(.HUP, &set, &saved[0]);
    std.posix.sigaction(.TERM, null, &saved[1]);
    std.posix.sigaction(.INT, null, &saved[2]);
    defer {
        std.posix.sigaction(.HUP, &saved[0], null);
        std.posix.sigaction(.TERM, &saved[1], null);
        std.posix.sigaction(.INT, &saved[2], null);
        signaled.store(false, .release);
    }
    return body();
}

test "supervisor: installSignalHandlers leaves SIGHUP alone" {
    try withHup(std.posix.SIG.IGN, struct {
        fn run() !void {
            const flag = installSignalHandlers();
            var current: std.posix.Sigaction = undefined;
            std.posix.sigaction(.HUP, null, &current);
            try testing.expect(current.handler.handler == std.posix.SIG.IGN);
            try testing.expect(!flag.load(.acquire));
        }
    }.run);
}

test "supervisor: routeHangup sets the stop flag on SIGHUP" {
    try withHup(std.posix.SIG.DFL, struct {
        fn run() !void {
            const flag = installSignalHandlers();
            routeHangup();
            try testing.expect(!flag.load(.acquire));
            try testing.expectEqual(@as(c_int, 0), c.raise(.HUP));
            try testing.expect(flag.load(.acquire));
        }
    }.run);
}

test "supervisor: routeHangup keeps a SIGHUP that was ignored (nohup)" {
    try withHup(std.posix.SIG.IGN, struct {
        fn run() !void {
            const flag = installSignalHandlers();
            routeHangup();
            try testing.expectEqual(@as(c_int, 0), c.raise(.HUP));
            try testing.expect(!flag.load(.acquire));
        }
    }.run);
}

test "supervisor: a spawned child starts with the default SIGHUP" {
    try withHup(std.posix.SIG.IGN, struct {
        fn run() !void {
            // A shell can't undo an inherited ignore, so this dies only if spawn reset it.
            const argv = [_:null]?[*:0]const u8{ "sh", "-c", "kill -HUP $$; exit 0" };
            var args = argv;
            const pid = try spawn(&args);
            var status: c_int = 0;
            try testing.expectEqual(pid, c.waitpid(pid, &status, 0));
            try testing.expectEqual(@as(c_int, @backingInt(std.posix.SIG.HUP)), status & 0x7f);
        }
    }.run);
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
