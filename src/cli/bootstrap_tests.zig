const std = @import("std");
const cli = @import("root.zig");
const t = std.testing;
const input = .{ .format = 1, .tool = "startup-test", .summary = "Bootstrap fixture", .verbs = .{
    .{ .name = "create", .summary = "Create resource", .grant = .write, .params = .{.{ .name = "name", .summary = "Name", .type = .{ .kind = .string }, .required = true }}, .result = .{ .kind = .object, .fields = .{} }, .errors = .{.{ .code = "invalid_params.name", .summary = "Name fails a product rule" }} },
} };
const G = cli.WithBootstrap(cli.manifest.normalize(input), &.{}, .{
    .serve_params = .{.{ .name = "lifetime", .summary = "Daemon lifetime policy", .type = .{ .kind = .string, .choices = .{ "persistent", "on-demand" } }, .default = "persistent" }},
    .startup = .{ .verb = "create", .summary = "Only ordinary local CLI creation may start a missing daemon; MCP never starts it." },
});
const Hook = struct {
    prepared: usize = 0,
    launched: usize = 0,
    mode: enum { deadline, failed, config, context, decline, cancel, expired, reject, reject_class, reject_undeclared, reject_other_class } = .deadline,
    flag: std.atomic.Value(bool) = .init(false),
    pub fn prepare(self: *@This(), ctx: cli.runtime.Startup.Context) anyerror!?u32 {
        self.prepared += 1;
        try t.expect(std.fs.path.isAbsolute(ctx.path.socket.?));
        return switch (self.mode) {
            .config => error.StartupConfig,
            .context => error.StartupContext,
            .decline => null,
            .reject => blk: {
                var data: std.json.Value = .{ .object = .empty };
                try data.object.put(ctx.allocator, "param", .{ .string = "name" });
                break :blk ctx.reject("invalid_params.name", "invalid name", data);
            },
            .reject_class => ctx.reject("invalid_params", "invalid name", .{ .object = .empty }),
            .reject_undeclared => ctx.reject("invalid_params.other", "invalid name", .{ .object = .empty }),
            .reject_other_class => ctx.reject("denied.name", "invalid name", .{ .object = .empty }),
            .expired => blk: {
                var fds: [1]std.c.pollfd = undefined;
                _ = std.c.poll(&fds, 0, 110);
                break :blk 100;
            },
            else => 100,
        };
    }
    pub fn launch(self: *@This(), _: cli.runtime.Startup.Context) anyerror!void {
        self.launched += 1;
        if (self.mode == .cancel) self.flag.store(true, .monotonic);
        if (self.mode == .failed) return error.StartupFailed;
    }
    pub fn poll(_: *@This(), _: cli.runtime.Startup.Context) anyerror!cli.runtime.Startup.Status {
        return .pending;
    }
};
const Daemon = struct {
    calls: usize = 0,
    pub fn serve(self: *@This(), _: @import("proto").SocketOptions, params: std.json.Value) anyerror!void {
        self.calls += 1;
        try t.expectEqualStrings("on-demand", params.object.get("lifetime").?.string);
    }
};
test "bootstrap: compiled metadata agrees across artifacts and stays local" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try G.parse(a, &.{"serve"});
    try t.expectEqualStrings("persistent", call.params.object.get("lifetime").?.string);
    try t.expect(G.schema.find("serve") == null);
    const tools = (try cli.mcp.catalog(G, a)).object.get("tools").?.array.items;
    for (tools) |tool| try t.expect(!std.mem.eql(u8, "serve", tool.object.get("name").?.string));
    const canonical = try cli.digest.canonical(G, a);
    try t.expect(std.mem.indexOf(u8, canonical, "lifetime") != null);
    try t.expect(std.mem.indexOf(u8, canonical, "unavailable.startup_result") != null);
    const base = try cli.Generator(input).digest(a);
    const extended = try G.digest(a);
    try t.expect(!std.mem.eql(u8, &base, &extended));
    try t.expect(std.mem.indexOf(u8, try G.help(a, "serve"), "--lifetime") != null);
    var docs: std.Io.Writer.Allocating = .init(a);
    try cli.docs.writeMarkdown(G, &docs.writer);
    try t.expect(std.mem.indexOf(u8, docs.written(), "lifetime") != null);
    try t.expect(std.mem.indexOf(u8, docs.written(), G.startup_policy.?.summary) != null);
    const skill = try cli.skill.render(G, a, "");
    try t.expect(std.mem.indexOf(u8, skill, G.startup_policy.?.summary) != null);
    for ([_]cli.completions.Shell{ .bash, .zsh, .fish }) |shell| {
        var out: std.Io.Writer.Allocating = .init(a);
        try cli.completions.write(G, a, &out.writer, shell);
        try t.expect(std.mem.indexOf(u8, out.written(), "lifetime") != null);
    }
}
test "bootstrap: validate before callbacks; bounded failures, cancellation and no hook" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    var daemon: Daemon = .{};
    var hook: Hook = .{};
    var options: cli.RunOptions = .{ .stdout = &out.writer, .stderr = &err.writer, .bootstrap = cli.Bootstrap.initWithParams(&daemon), .startup = cli.runtime.Startup.init(&hook), .interrupted = &hook.flag };
    try t.expectEqual(@as(u8, 2), try G.run(t.allocator, &.{ "serve", "--lifetime=bad", "--json" }, options));
    try t.expectEqual(@as(usize, 0), daemon.calls);
    try t.expectEqual(@as(u8, 0), try G.run(t.allocator, &.{ "serve", "--lifetime=on-demand", "--json" }, options));
    try t.expectEqual(@as(usize, 1), daemon.calls);
    try t.expectEqual(@as(u8, 2), try G.run(t.allocator, &.{ "create", "--json" }, options));
    try t.expectEqual(@as(usize, 0), hook.prepared);
    const argv = &.{ "create", "--name=work", "--socket=/tmp/venom-com254-no-such-dir/test.sock", "--json" };
    for ([_]struct { mode: @TypeOf(hook.mode), code: []const u8, exit: u8, launches: usize }{
        .{ .mode = .deadline, .code = "unavailable.startup_deadline", .exit = 6, .launches = 1 },
        .{ .mode = .failed, .code = "unavailable.startup_failed", .exit = 6, .launches = 1 },
        .{ .mode = .config, .code = "invalid_params.startup_config", .exit = 2, .launches = 0 },
        .{ .mode = .context, .code = "denied.startup_context", .exit = 4, .launches = 0 },
        .{ .mode = .decline, .code = "unavailable.not_running", .exit = 6, .launches = 0 },
        .{ .mode = .reject, .code = "invalid_params.name", .exit = 2, .launches = 0 },
        .{ .mode = .reject_class, .code = "invalid_params", .exit = 2, .launches = 0 },
        .{ .mode = .reject_undeclared, .code = "internal", .exit = 11, .launches = 0 },
        .{ .mode = .reject_other_class, .code = "internal", .exit = 11, .launches = 0 },
        .{ .mode = .cancel, .code = "cancelled", .exit = 8, .launches = 1 },
        .{ .mode = .expired, .code = "unavailable.startup_deadline", .exit = 6, .launches = 0 },
    }) |case| {
        hook = .{ .mode = case.mode };
        out.clearRetainingCapacity();
        try t.expectEqual(case.exit, try G.run(t.allocator, argv, options));
        try t.expectEqual(@as(usize, 1), hook.prepared);
        try t.expectEqual(case.launches, hook.launched);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out.written(), .{});
        defer parsed.deinit();
        const e = parsed.value.object.get("error").?.object;
        try t.expectEqualStrings(case.code, e.get("code").?.string);
        switch (case.mode) {
            .reject => {
                try t.expectEqualStrings("invalid name", e.get("message").?.string);
                try t.expectEqualStrings("name", e.get("data").?.object.get("param").?.string);
            },
            .decline => {
                try t.expectEqualStrings("No daemon at the selected socket", e.get("message").?.string);
                try t.expectEqualStrings(argv[2]["--socket=".len..], e.get("data").?.object.get("socket").?.string);
            },
            else => {},
        }
    }
    options.startup = null;
    hook = .{};
    try t.expectEqual(@as(u8, 6), try G.run(t.allocator, argv, options));
    try t.expectEqual(@as(usize, 0), hook.prepared);
}
test "bootstrap: missing daemon names the absolute socket; doctor's fix starts it" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    const options: cli.RunOptions = .{ .stdout = &out.writer, .stderr = &err.writer };
    var cwd: [4096]u8 = undefined;
    const here = std.mem.sliceTo(std.c.getcwd(&cwd, cwd.len).?, 0);
    const long = "/tmp/" ++ @as([120]u8, @splat('x')) ++ ".sock";
    for ([_]struct { argv: []const []const u8, code: []const u8, exit: u8, socket: ?[]const u8, fix: ?[]const u8 }{
        .{ .argv = &.{ "doctor", "--socket=/tmp/venom-com275-no-such-dir/t.sock", "--json" }, .code = "unavailable.not_running", .exit = 6, .socket = "/tmp/venom-com275-no-such-dir/t.sock", .fix = "startup-test serve" },
        .{ .argv = &.{ "ping", "--socket=venom-com275-missing/r.sock", "--json" }, .code = "unavailable.not_running", .exit = 6, .socket = "venom-com275-missing/r.sock", .fix = null },
        .{ .argv = &.{ "doctor", "--socket=" ++ long, "--json" }, .code = "unavailable.path_too_long", .exit = 6, .socket = null, .fix = "ls -ld -- \"${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}\"" },
    }) |case| {
        out.clearRetainingCapacity();
        try t.expectEqual(case.exit, try G.run(t.allocator, case.argv, options));
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out.written(), .{});
        defer parsed.deinit();
        const e = parsed.value.object.get("error").?.object;
        try t.expectEqualStrings(case.code, e.get("code").?.string);
        const data = e.get("data").?;
        if (case.socket) |want| {
            try t.expectEqualStrings("No daemon at the selected socket", e.get("message").?.string);
            const got = data.object.get("socket").?.string;
            try t.expect(std.fs.path.isAbsolute(got));
            if (std.fs.path.isAbsolute(want)) try t.expectEqualStrings(want, got) else {
                const joined = try std.fs.path.join(t.allocator, &.{ here, want });
                defer t.allocator.free(joined);
                try t.expectEqualStrings(joined, got);
            }
        } else try t.expect(data == .null or data.object.get("socket") == null);
        if (case.fix) |want| try t.expectEqualStrings(want, data.object.get("fix").?.string) else try t.expect(data.object.get("fix") == null);
    }
}
