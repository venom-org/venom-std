const std = @import("std");
const cli = @import("root.zig");
const t = std.testing;
const input = .{ .format = 1, .tool = "local-test", .summary = "Local fixture", .verbs = .{
    .{ .name = "remote", .summary = "Remote", .grant = .read, .result = .{ .kind = .null } },
} };
const G = cli.WithBootstrap(cli.manifest.normalize(input), &.{}, .{ .local = .{
    .{ .name = "attach", .summary = "Attach UI", .interactive = true, .result = .{ .kind = .object, .fields = .{} } },
    .{ .name = "inspect", .summary = "Inspect locally", .params = .{.{ .name = "mode", .summary = "Mode", .type = .{ .kind = .string }, .default = "result" }}, .result = .{ .kind = .object, .fields = .{} }, .errors = .{.{ .code = "not_found.target", .summary = "Missing target" }}, .examples = .{.{ .params = .{}, .result = .{} }} },
} });
const Handler = struct {
    pub const commands = .{ "attach", "inspect" };
    calls: usize = 0,
    pub fn call(self: *@This(), ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
        self.calls += 1;
        try t.expectEqualStrings("/missing/local.sock", ctx.path.socket.?);
        if (std.mem.eql(u8, ctx.name, "attach")) return .{ .result = .{ .object = .empty } };
        const mode = ctx.params.object.get("mode").?.string;
        if (std.mem.eql(u8, mode, "failure")) return .{ .failure = .{ .code = "not_found.target", .message = "missing" } };
        if (std.mem.eql(u8, mode, "cancel")) return .{ .failure = .{ .code = "cancelled", .message = "interrupted" } };
        if (std.mem.eql(u8, mode, "undeclared")) return .{ .failure = .{ .code = "not_found.other", .message = "bad" } };
        if (std.mem.eql(u8, mode, "invalid")) return .{ .result = .null };
        if (std.mem.eql(u8, mode, "status")) return .{ .status = 4 };
        if (std.mem.eql(u8, mode, "bad-status")) return .{ .status = 12 };
        return .{ .result = .{ .object = .empty } };
    }
};
test "local: every generated surface, digest and MCP exclusion" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "attach", "inspect" }) |name| {
        try t.expect(G.schema.find(name) == null);
        try t.expect(std.mem.indexOf(u8, try G.help(a, ""), name) != null);
    }
    const tools = (try cli.mcp.catalog(G, a)).object.get("tools").?.array.items;
    for (tools) |tool| try t.expect(!G.isProductLocal(tool.object.get("name").?.string));
    var out: std.Io.Writer.Allocating = .init(a);
    try cli.docs.writeMarkdown(G, &out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "local-test attach") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "local-test inspect") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "MCP tool: none (local command)") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "Interactive: needs a terminal on stdin and stdout") != null);
    out.clearRetainingCapacity();
    try cli.docs.writeMan(G, &out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "Interactive: needs a terminal") != null);
    const skill = try cli.skill.render(G, a, "");
    try t.expect(std.mem.indexOf(u8, skill, "attach") == null);
    try t.expect(std.mem.indexOf(u8, skill, "## Local commands") != null);
    try t.expect(std.mem.indexOf(u8, skill, "local-test inspect") != null);
    for ([_]cli.completions.Shell{ .bash, .zsh, .fish }) |shell| {
        out.clearRetainingCapacity();
        try cli.completions.write(G, a, &out.writer, shell);
        try t.expect(std.mem.indexOf(u8, out.written(), "attach") != null);
        try t.expect(std.mem.indexOf(u8, out.written(), "inspect") != null);
        try t.expect(std.mem.indexOf(u8, out.written(), "mode") != null);
    }
    const model = try cli.digest.manifest(G, a);
    for (model.object.get("verbs").?.array.items) |v| {
        const name = v.object.get("name").?.string;
        if (G.isProductLocal(name)) {
            try t.expectEqualStrings("local", v.object.get("dispatch").?.string);
            try t.expectEqualStrings("none", v.object.get("grant").?.string);
            try t.expectEqual(G.isInteractive(name), v.object.get("interactive").?.bool);
        } else try t.expect(v.object.get("dispatch") == null);
    }
}
test "local: validate, render outcomes and reject non-terminals before handler" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    var handler: Handler = .{};
    const options = .{ .stdout = &out.writer, .stderr = &err.writer, .local = cli.Local.init(&handler), .stdin = @as(std.c.fd_t, -1), .stdout_fd = @as(std.c.fd_t, -1) };
    try t.expectEqual(@as(u8, 10), try G.run(t.allocator, &.{ "attach", "--json", "--socket=/missing/local.sock" }, options));
    try t.expect(std.mem.indexOf(u8, out.written(), "unsupported.terminal") != null);
    try t.expectEqual(@as(usize, 0), handler.calls);
    for ([_]struct { mode: []const u8, status: u8, code: ?[]const u8 }{
        .{ .mode = "result", .status = 0, .code = null },
        .{ .mode = "failure", .status = 3, .code = "not_found.target" },
        .{ .mode = "cancel", .status = 8, .code = "cancelled" },
        .{ .mode = "undeclared", .status = 11, .code = "internal.local" },
        .{ .mode = "invalid", .status = 11, .code = "internal.result" },
        .{ .mode = "status", .status = 4, .code = null },
        .{ .mode = "bad-status", .status = 11, .code = "internal.local" },
    }) |case| {
        out.clearRetainingCapacity();
        const arg = try std.fmt.allocPrint(t.allocator, "--mode={s}", .{case.mode});
        defer t.allocator.free(arg);
        try t.expectEqual(case.status, try G.run(t.allocator, &.{ "inspect", arg, "--json", "--socket=/missing/local.sock" }, options));
        if (case.code) |code| {
            const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out.written(), .{});
            defer parsed.deinit();
            try t.expectEqualStrings(code, parsed.value.object.get("error").?.object.get("code").?.string);
            try t.expectEqual(@as(usize, 0), err.written().len);
        }
    }
    out.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 0), try G.run(t.allocator, &.{ "inspect", "--socket=/missing/local.sock" }, options));
    try t.expectEqualStrings("", out.written());
    try t.expectEqual(@as(u8, 0), try G.run(t.allocator, &.{ "inspect", "--json", "--socket=/missing/local.sock" }, options));
    try t.expectEqualStrings("{}\n", out.written());
}

test "local: successful result exit and human failure rendering" {
    const ExitApp = cli.WithBootstrap(cli.manifest.normalize(input), &.{}, .{ .local = .{.{
        .name = "status",
        .summary = "Result status",
        .result = .{ .kind = .object, .fields = .{.{ .name = "status", .summary = "Status", .type = .{ .kind = .integer, .min = 0, .max = 255 }, .required = true }} },
        .exit = .{ .kind = .result, .field = "status" },
    }} });
    const Status = struct {
        pub const commands = .{"status"};
        pub fn call(_: *@This(), ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
            var value: std.json.Value = .{ .object = .empty };
            try value.object.put(ctx.allocator, "status", .{ .integer = 23 });
            return .{ .result = value };
        }
    };
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    var status: Status = .{};
    try t.expectEqual(@as(u8, 23), try ExitApp.run(t.allocator, &.{ "status", "--json" }, .{ .stdout = &out.writer, .stderr = &err.writer, .local = cli.Local.init(&status) }));
    try t.expectEqualStrings("{\"status\":23}\n", out.written());
    out.clearRetainingCapacity();
    var handler: Handler = .{};
    try t.expectEqual(@as(u8, 3), try G.run(t.allocator, &.{ "inspect", "--mode=failure", "--socket=/missing/local.sock" }, .{ .stdout = &out.writer, .stderr = &err.writer, .local = cli.Local.init(&handler) }));
    try t.expectEqualStrings("", out.written());
    try t.expectEqualStrings("missing\n", err.written());
}

test "local: several example-bearing commands generate examples at default quota" {
    const App = cli.WithBootstrap(cli.manifest.normalize(input), &.{}, .{ .local = .{
        .{ .name = "login.uninstall", .summary = "Remove login integration", .result = .{ .kind = .object, .fields = .{
            .{ .name = "removed", .summary = "Removed", .type = .{ .kind = .boolean }, .required = true },
            .{ .name = "path", .summary = "Path", .type = .{ .kind = .string }, .required = true },
        } }, .examples = .{.{ .params = .{}, .result = .{ .removed = true, .path = "/tmp/login-entry" } }} },
        .{ .name = "login.install", .summary = "Install login integration", .params = .{
            .{ .name = "force", .summary = "Replace existing entry", .type = .{ .kind = .boolean }, .default = false },
        }, .result = .{ .kind = .object, .fields = .{
            .{ .name = "installed", .summary = "Installed", .type = .{ .kind = .boolean }, .required = true },
            .{ .name = "path", .summary = "Path", .type = .{ .kind = .string }, .required = true },
        } }, .examples = .{
            .{ .params = .{}, .result = .{ .installed = true, .path = "/tmp/login-entry" } },
            .{ .params = .{ .force = true }, .result = .{ .installed = true, .path = "/tmp/replaced-entry" } },
        } },
        .{ .name = "env", .summary = "Print environment", .result = .{ .kind = .object, .fields = .{
            .{ .name = "socket", .summary = "Socket", .type = .{ .kind = .string }, .required = true },
        } }, .examples = .{.{ .params = .{}, .result = .{ .socket = "/tmp/venom.sock" } }} },
    } });
    // Access the lazy declaration without raising the caller's branch quota.
    try t.expectEqual(@as(usize, 4), App.examples.len);
    try t.expectEqualStrings("env", App.examples[0].verb);
    try t.expectEqualStrings("login.install", App.examples[1].verb);
    try t.expectEqualStrings("{}", App.examples[1].params);
    try t.expectEqualStrings("{\"force\":true}", App.examples[2].params);
    try t.expectEqualStrings("force", App.examples[2].args[0].flag);
    try t.expectEqualStrings("true", App.examples[2].args[0].value);
    try t.expect(App.examples[2].args[0].equals);
    try t.expectEqualStrings("login.uninstall", App.examples[3].verb);
    try t.expectEqualStrings("{\"removed\":true,\"path\":\"/tmp/login-entry\"}", App.examples[3].result);

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try cli.docs.writeMarkdown(App, &out.writer);
    for ([_][]const u8{ "local-test env", "local-test login install", "local-test login uninstall", "--force=true" }) |text| {
        try t.expect(std.mem.indexOf(u8, out.written(), text) != null);
    }
}
