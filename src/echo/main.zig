const std = @import("std");
const cli = @import("cli");
const proto = @import("proto");
const cfg = @import("cfg");
const log = @import("log");
const supervisor = @import("supervisor");
const xdg = @import("xdg");
const Config = struct {
    appearance: struct { prefix: []const u8 = "" } = .{},
    /// Log levels and formats; applied live on `config set` and reloads.
    log: log.Config = .{},
    suffix: []const u8 = "",
    count: u32 = 4,
    api_token: []const u8 = "",
};
const ConfigStore = cfg.Store(Config, &.{ .{ .key = "suffix", .restart = true }, .{ .key = "api_token", .secret = true } });
fn validateConfig(value: Config) ?cfg.Validation {
    return if (value.count == 0) .{ .key = "count" } else null;
}
const input = @import("verbs.zon");
const manifest = .{ .format = input.format, .tool = input.tool, .summary = input.summary, .verbs = input.verbs ++ .{proto.events.manifest} };
const App = cli.FromModel(cfg.merge(cli.manifest.normalize(manifest)), cli.manifest.examples(manifest));

const Echo = struct {
    config: *ConfigStore,
    pub fn call(self: *Echo, c: *proto.Call) anyerror!void {
        const text = c.params.object.get("text").?.string;
        const style = c.params.object.get("style").?.string;
        const output = try c.arena().dupe(u8, text);
        if (std.mem.eql(u8, style, "upper")) for (output) |*ch| {
            ch.* = std.ascii.toUpper(ch.*);
        };
        try c.ok(.{ .text = try std.fmt.allocPrint(c.arena(), "{s}{s}{s}", .{ self.config.current().appearance.prefix, output, self.config.current().suffix }) });
    }
};
/// `counter.inc` (write) and `counter.get` (read): an in-memory counter that
/// lets conformance tests observe whether a denied mutation ran its handler.
const Counter = struct {
    value: u64 = 0,
    pub const IncParams = struct { by: i64 };
    pub fn inc(self: *Counter) Inc {
        return .{ .counter = self };
    }
    pub fn call(self: *Counter, c: *proto.Call) anyerror!void {
        try c.ok(.{ .value = self.value });
    }
    const Inc = struct {
        counter: *Counter,
        pub fn call(self: *Inc, c: *proto.Call, params: IncParams) anyerror!void {
            const by: u64 = @intCast(params.by); // the schema bounds it to 1..1_000_000
            const max: u64 = @intCast(proto.schema.max_safe_integer);
            if (self.counter.value > max - by)
                return c.fail("conflict.counter_overflow", "the increment would exceed the largest exact JSON integer", .{ .value = self.counter.value, .by = by });
            self.counter.value += by;
            try c.ok(.{ .value = self.counter.value });
        }
    };
};
/// `sleep` (streaming): one `{"tick":n}` item every `ms`, then `{"ticks":n}`.
/// Calls are answered on later reactor turns by ticket, so a cancelled call
/// or a closed connection is simply dropped (`Dispatcher.get` returns null).
const Sleep = struct {
    gpa: std.mem.Allocator,
    dispatcher: ?*proto.Dispatcher = null,
    pending: std.ArrayList(Pending) = .empty,
    /// Milliseconds on the daemon's monotonic clock, used for new calls.
    now_ms: i64 = 0,
    const Pending = struct { ticket: proto.Ticket, interval: i64, due: i64, tick: u32 = 0, ticks: u32, fail_at: u32 };
    pub const Params = struct { ms: i64, ticks: i64, fail_at: i64 };
    pub fn deinit(self: *Sleep) void {
        self.pending.deinit(self.gpa);
    }
    pub fn call(self: *Sleep, c: *proto.Call, params: Params) anyerror!void {
        // Bounds come from the schema: ms 0..60000, ticks 1..1000, fail_at 0..1000.
        try self.pending.append(self.gpa, .{ .ticket = c.ticket, .interval = params.ms, .due = self.now_ms + params.ms, .ticks = @intCast(params.ticks), .fail_at = @intCast(params.fail_at) });
    }
    /// Advance every pending call to `now_ms`, emitting due ticks.
    pub fn tick(self: *Sleep, now_ms: i64) !void {
        self.now_ms = now_ms;
        const d = self.dispatcher orelse return;
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = &self.pending.items[i];
            if (try advance(d, p, now_ms)) i += 1 else _ = self.pending.swapRemove(i);
        }
    }
    /// false once the call has ended.
    fn advance(d: *proto.Dispatcher, p: *Pending, now_ms: i64) !bool {
        while (p.due <= now_ms) {
            const c = d.get(p.ticket) orelse return false;
            p.tick += 1;
            if (p.tick == p.fail_at) {
                try c.fail("failed.sleep_aborted", "sleep was told to fail at this tick", .{ .tick = p.tick });
                return false;
            }
            c.item(.{ .tick = p.tick }) catch |err| {
                if (err == error.OutOfMemory) return err;
                return false; // the call has ended
            };
            if (p.tick == p.ticks) {
                try c.ok(.{ .ticks = p.ticks });
                return false;
            }
            p.due += p.interval;
        }
        return d.get(p.ticket) != null;
    }
};
/// Product doctor check: persisted configuration validity.
const ConfigCheck = struct {
    config: *ConfigStore,
    pub fn run(self: *ConfigCheck, r: *cli.doctor.Report) anyerror!void {
        const fix = try r.command("{s} config check --json", r.tool);
        self.config.check() catch |err| {
            if (err == error.OutOfMemory) return err;
            const code = if (err == error.InvalidConfig) self.config.failure.code else @errorName(err);
            return r.add("config.valid", .fail, try r.print("configuration is invalid: {s} (key '{s}')", .{ code, self.config.failure.key() }), fix);
        };
        try r.add("config.valid", .ok, "configuration is valid", fix);
    }
};
/// Product doctor check: event log retention and watermarks.
const EventsCheck = struct {
    events: *proto.events.Log,
    pub fn run(self: *EventsCheck, r: *cli.doctor.Report) anyerror!void {
        const st = self.events.status();
        try r.add("events.log", .ok, try r.print("event log {s} retains seq {d}..{d} ({d} of {d} bytes)", .{ st.source, st.low, st.high, st.bytes, st.limits.bytes }), try r.command("{s} events --follow=false --json", r.tool));
    }
};
const skill_notes =
    \\venom-echo is a toy daemon for agent-contract conformance tests. Start it
    \\with `venom-echo serve`. Its only side effects are its socket, status file,
    \\audit and daemon logs, ZON configuration (change it with
    \\`venom-echo config set`) and installed skills. `counter.inc` and
    \\`counter.get` keep an in-memory counter that resets on restart, and
    \\`sleep` streams one tick per interval.
;
/// The serving loop, run as a supervised thread: a failed poll or tick is
/// restarted with backoff instead of taking the daemon down.
const ServeLoop = struct {
    io: std.Io,
    server: *proto.Server,
    events: *proto.events.Log,
    config: *ConfigStore,
    logger: *log.Logger,
    sleep: *Sleep,
    pub fn run(self: *ServeLoop, stop: *const supervisor.Stop) anyerror!void {
        while (!stop.requested()) {
            // Wake often enough for `sleep` streams while any are pending.
            try self.server.poll(if (self.sleep.pending.items.len != 0) 10 else 100);
            const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
            try self.sleep.tick(now_ms);
            self.config.watch(now_ms) catch |err| {
                if (err == error.OutOfMemory) return err;
                // Report only the refinement code; never dump a secret value.
                self.logger.warn("config watcher: reload failed", .{ .code = self.config.failure.code });
            };
            // Cheap atomic stores; picks up both `config set` and file reloads.
            self.logger.setConfig(self.config.current().log);
            try self.events.tick();
        }
    }
};
const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    stopped: *const std.atomic.Value(bool),
    pub fn serve(self: *Daemon, path: proto.SocketOptions) anyerror!void {
        // Records go to $XDG_STATE_HOME/venom/venom-echo/venom-echo.log; stderr
        // only shows warnings and errors unless the `log` config says otherwise.
        var logger = log.Logger.init(.{ .source = App.schema.tool, .stderr = self.stderr, .file = self.openLog() });
        defer logger.deinit();
        var events = try proto.events.Log.init(self.gpa, App.schema.tool, .{}, null);
        defer events.deinit();
        const config_path = try cfg.configPath(self.gpa, App.schema.tool, self.environ);
        defer self.gpa.free(config_path);
        // `<dir>/venom-echo/defaults.zon` in $XDG_CONFIG_DIRS
        // is a read-only layer below config.zon.
        const defaults_paths = try cfg.defaultsPaths(self.gpa, App.schema.tool, self.environ);
        defer cfg.freePaths(self.gpa, defaults_paths);
        var config = try ConfigStore.init(self.gpa, .{ .io = self.io, .path = config_path, .defaults = defaults_paths, .validate = validateConfig, .events = &events });
        defer config.deinit();
        events.snapshot = proto.events.Snapshot.init(&config);
        logger.setConfig(config.current().log);
        var echo: Echo = .{ .config = &config };
        var counter: Counter = .{};
        var counter_inc = counter.inc();
        var sleep: Sleep = .{ .gpa = self.gpa, .now_ms = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms)) };
        defer sleep.deinit();
        var events_check: EventsCheck = .{ .events = &events };
        var config_check: ConfigCheck = .{ .config = &config };
        var server_check: cli.doctor.ServerCheck = .{ .server = undefined };
        const checks = [_]cli.doctor.Check{ .init("config", &config_check), .init("runtime", &server_check), .init("events", &events_check) };
        // The complete-schema digest: advertised in hello and compared by doctor.
        const digest = try App.digest(self.gpa);
        var standard: cli.Standard(App) = .init(.{ .notes = skill_notes, .home = self.environ.getPosix("HOME"), .checks = &checks, .schema = &digest });
        const handlers = [_]proto.Binding{ .{ .verb = "echo", .handler = proto.VerbHandler.init(&echo) }, .{ .verb = "counter.inc", .handler = proto.VerbHandler.typed(Counter.IncParams, &counter_inc) }, .{ .verb = "counter.get", .handler = proto.VerbHandler.init(&counter) }, .{ .verb = "sleep", .handler = proto.VerbHandler.typed(Sleep.Params, &sleep) }, .{ .verb = "events", .handler = proto.VerbHandler.init(&events) } } ++ config.bindings() ++ standard.bindings();
        var dispatcher = try proto.Dispatcher.init(self.gpa, &App.schema, &handlers, .{}, null);
        defer dispatcher.deinit();
        sleep.dispatcher = &dispatcher;
        var server = try proto.Server.init(self.gpa, .{
            .hello = .{ .identity = .{ .name = App.schema.tool, .version = "0.0.0" }, .caps = &.{"cancel"}, .schema = &digest },
            .path = path,
        }, dispatcher.handler());
        defer server.deinit();
        server_check.server = &server;
        logger.info("listening", .{ .socket = server.path, .pid = std.c.getpid() });
        // The status file sits next to the socket, so it follows --socket.
        const status_path = try xdg.siblingPath(self.gpa, server.path, "status.json");
        defer self.gpa.free(status_path);
        {
            var sup = supervisor.Supervisor.init(self.gpa, .{ .status_path = status_path, .logger = &logger });
            defer sup.deinit();
            var loop: ServeLoop = .{ .io = self.io, .server = &server, .events = &events, .config = &config, .logger = &logger, .sleep = &sleep };
            try sup.addThread("serve", supervisor.Task.init(&loop), .{});
            sup.run(self.stopped, .{});
        }
        dispatcher.cancelAll();
        server.shutdown();
        while (server.connections.items.len != 0) try server.poll(100);
        logger.info("stopped", .{});
    }
    fn openLog(self: *Daemon) ?std.c.fd_t {
        const file = xdg.path(self.gpa, .state, App.schema.tool, App.schema.tool ++ ".log", .{ .environ = self.environ, .uid = std.c.getuid() }) catch return null;
        defer self.gpa.free(file);
        return log.openFile(self.gpa, file) catch null;
    }
};
pub fn main(init: std.process.Init) !void {
    const stopped = supervisor.installSignalHandlers();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    var daemon: Daemon = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .stderr = &err.interface, .stopped = stopped };
    const status = try App.run(init.gpa, argv[1..], .{
        .stdout = &out.interface,
        .stderr = &err.interface,
        .environ = init.minimal.environ,
        .bootstrap = cli.Bootstrap.init(&daemon),
        .interrupted = stopped,
    });
    try out.interface.flush();
    try err.interface.flush();
    if (status != 0) std.process.exit(status);
}

// --- tests: the product handlers against the real dispatcher -------------

const testing = std.testing;
/// The product verbs alone (no shared bundles), as the dispatcher sees them.
const test_model = cli.manifest.normalize(input);

const Stub = struct {
    pub fn call(_: *Stub, c: *proto.Call) anyerror!void {
        try c.ok(.{ .text = "" });
    }
};
/// One NDJSON connection over a socketpair; responses are read from memory.
const Peer = struct {
    conn: proto.Connection,
    other: std.c.fd_t,
    lines: std.ArrayList(proto.Response) = .empty,
    fn init() !Peer {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
        var conn = proto.Connection.init(testing.allocator, fds[0]);
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        try conn.caps.append(testing.allocator, "cancel");
        return .{ .conn = conn, .other = fds[1] };
    }
    fn deinit(self: *Peer) void {
        self.clear();
        self.lines.deinit(testing.allocator);
        self.conn.deinit();
        proto.os.close(self.other);
    }
    fn clear(self: *Peer) void {
        for (self.lines.items) |*r| r.deinit();
        self.lines.clearRetainingCapacity();
    }
    fn send(self: *Peer, d: *proto.Dispatcher, line: []const u8) ![]proto.Response {
        try d.message(&self.conn, .{ .ndjson = line });
        return self.take();
    }
    fn take(self: *Peer) ![]proto.Response {
        self.clear();
        var it = std.mem.splitScalar(u8, self.conn.output.items, '\n');
        while (it.next()) |l| if (l.len > 0) try self.lines.append(testing.allocator, try proto.Response.parse(testing.allocator, l));
        self.conn.output.clearRetainingCapacity();
        return self.lines.items;
    }
};
const Fixture = struct {
    stub: Stub = .{},
    counter: Counter = .{},
    inc: Counter.Inc = undefined,
    sleep: Sleep = .{ .gpa = testing.allocator },
    dispatcher: proto.Dispatcher = undefined,
    fn init(self: *Fixture) !void {
        self.inc = self.counter.inc();
        const bindings = [_]proto.Binding{
            .{ .verb = "echo", .handler = proto.VerbHandler.init(&self.stub) },
            .{ .verb = "counter.inc", .handler = proto.VerbHandler.typed(Counter.IncParams, &self.inc) },
            .{ .verb = "counter.get", .handler = proto.VerbHandler.init(&self.counter) },
            .{ .verb = "sleep", .handler = proto.VerbHandler.typed(Sleep.Params, &self.sleep) },
        };
        self.dispatcher = try proto.Dispatcher.init(testing.allocator, &test_model, &bindings, .{}, null);
        self.sleep.dispatcher = &self.dispatcher;
    }
    fn deinit(self: *Fixture) void {
        self.dispatcher.deinit();
        self.sleep.deinit();
    }
};
fn one(lines: []proto.Response) !proto.Response {
    try testing.expectEqual(@as(usize, 1), lines.len);
    return lines[0];
}
fn okInt(r: proto.Response, field: []const u8) !i64 {
    try testing.expect(r.body == .ok);
    return r.body.ok.object.get(field).?.integer;
}
fn errCode(r: proto.Response) []const u8 {
    return if (r.body == .@"error") r.body.@"error".code else "";
}

test "echo: counter is read-only by default and mutates only with write" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    try testing.expectEqual(@as(i64, 0), try okInt(try one(try peer.send(&f.dispatcher, "{\"id\":1,\"verb\":\"counter.get\"}")), "value"));
    // Without a registry a caller has read only: denied before the handler.
    try testing.expectEqualStrings("denied.write", errCode(try one(try peer.send(&f.dispatcher, "{\"id\":2,\"verb\":\"counter.inc\"}"))));
    try testing.expectEqual(@as(u64, 0), f.counter.value);

    var registry = try proto.grants.Registry.init(testing.allocator, "venom-echo", .{});
    defer registry.deinit();
    peer.conn.registry = &registry;
    peer.conn.identity = .{ .principal = proto.grants.unknown };
    try testing.expectEqualStrings("denied.write", errCode(try one(try peer.send(&f.dispatcher, "{\"id\":3,\"verb\":\"counter.inc\"}"))));
    peer.conn.identity = .{ .principal = proto.grants.owner };
    try testing.expectEqual(@as(i64, 1), try okInt(try one(try peer.send(&f.dispatcher, "{\"id\":4,\"verb\":\"counter.inc\"}")), "value"));
    try testing.expectEqual(@as(i64, 8), try okInt(try one(try peer.send(&f.dispatcher, "{\"id\":5,\"verb\":\"counter.inc\",\"params\":{\"by\":7}}")), "value"));
    try testing.expectEqualStrings("invalid_params.range", errCode(try one(try peer.send(&f.dispatcher, "{\"id\":6,\"verb\":\"counter.inc\",\"params\":{\"by\":0}}"))));
    try testing.expectEqual(@as(i64, 8), try okInt(try one(try peer.send(&f.dispatcher, "{\"id\":7,\"verb\":\"counter.get\"}")), "value"));
    // Overflow past 2^53-1 is a conflict and leaves the value unchanged.
    f.counter.value = @intCast(proto.schema.max_safe_integer - 1);
    try testing.expectEqualStrings("conflict.counter_overflow", errCode(try one(try peer.send(&f.dispatcher, "{\"id\":8,\"verb\":\"counter.inc\",\"params\":{\"by\":2}}"))));
    try testing.expectEqual(proto.schema.max_safe_integer, try okInt(try one(try peer.send(&f.dispatcher, "{\"id\":9,\"verb\":\"counter.inc\"}")), "value"));
}

test "echo: sleep streams ticks on later turns, then finishes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    try f.sleep.tick(1000);
    try testing.expectEqual(@as(usize, 0), (try peer.send(&f.dispatcher, "{\"id\":1,\"verb\":\"sleep\",\"params\":{\"ms\":10,\"ticks\":3}}")).len);
    try f.sleep.tick(1009);
    try testing.expectEqual(@as(usize, 0), (try peer.take()).len);
    try f.sleep.tick(1010);
    var lines = try peer.take();
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(@as(i64, 1), lines[0].body.item.object.get("tick").?.integer);
    // A late turn catches up every due tick in order, then the final ok.
    try f.sleep.tick(1100);
    lines = try peer.take();
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqual(@as(i64, 2), lines[0].body.item.object.get("tick").?.integer);
    try testing.expectEqual(@as(i64, 3), lines[1].body.item.object.get("tick").?.integer);
    try testing.expectEqual(@as(i64, 3), try okInt(lines[2], "ticks"));
    try testing.expectEqual(@as(usize, 0), f.sleep.pending.items.len);
    // ms = 0 completes on the next turn.
    _ = try peer.send(&f.dispatcher, "{\"id\":2,\"verb\":\"sleep\",\"params\":{\"ms\":0}}");
    try f.sleep.tick(1100);
    lines = try peer.take();
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqual(@as(i64, 1), try okInt(lines[1], "ticks"));
}

test "echo: sleep terminal error and cancellation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    _ = try peer.send(&f.dispatcher, "{\"id\":1,\"verb\":\"sleep\",\"params\":{\"ms\":5,\"ticks\":5,\"fail_at\":2}}");
    try f.sleep.tick(100);
    var lines = try peer.take();
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expect(lines[0].body == .item);
    try testing.expectEqualStrings("failed.sleep_aborted", errCode(lines[1]));
    try testing.expectEqual(@as(u8, 1), lines[1].body.@"error".exitCode());
    try testing.expectEqual(@as(usize, 0), f.sleep.pending.items.len);

    // A cancelled call is dropped on the next turn without further output.
    _ = try peer.send(&f.dispatcher, "{\"id\":2,\"verb\":\"sleep\",\"params\":{\"ms\":50,\"ticks\":5}}");
    lines = try peer.send(&f.dispatcher, "{\"id\":3,\"verb\":\"cancel\",\"params\":{\"id\":2}}");
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("cancelled", errCode(lines[0]));
    try f.sleep.tick(1000);
    try testing.expectEqual(@as(usize, 0), (try peer.take()).len);
    try testing.expectEqual(@as(usize, 0), f.sleep.pending.items.len);

    // So is one whose connection closed.
    _ = try peer.send(&f.dispatcher, "{\"id\":4,\"verb\":\"sleep\",\"params\":{\"ms\":50}}");
    f.dispatcher.closed(&peer.conn);
    try f.sleep.tick(2000);
    try testing.expectEqual(@as(usize, 0), f.sleep.pending.items.len);
    try testing.expectEqual(@as(usize, 0), (try peer.take()).len);
}
