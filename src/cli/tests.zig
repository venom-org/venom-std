const std = @import("std");
const cli = @import("root.zig");
const G = cli.Generator(.{
    .format = 1,
    .tool = "test",
    .summary = "Test CLI",
    .verbs = .{
        .{ .name = "pane", .summary = "Parent", .result = .{ .kind = .null }, .grant = .read },
        .{ .name = "pane.set_title", .summary = "Child", .params = .{
            .{ .name = "text", .summary = "Text", .type = .{ .kind = .string }, .required = true },
            .{ .name = "enabled", .summary = "Toggle", .type = .{ .kind = .boolean }, .default = false },
            .{ .name = "count", .summary = "Count", .type = .{ .kind = .integer, .min = -10, .max = 10 } },
        }, .result = .{ .kind = .null }, .grant = .write },
    },
});
test "cli: canonical and dotted command paths, interspersed options and defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const []const u8{
        &.{ "--json", "pane", "--text", "hi", "set-title", "--count=-2" },
        &.{ "pane.set_title", "--text=hi", "--count=-2", "--json" },
    }) |argv| {
        const call = try G.parse(arena.allocator(), argv);
        try std.testing.expect(call.failure == null);
        try std.testing.expect(call.json);
        try std.testing.expectEqualStrings("pane.set_title", call.name);
        try std.testing.expectEqualStrings("hi", call.params.object.get("text").?.string);
        try std.testing.expectEqual(@as(i64, -2), call.params.object.get("count").?.integer);
        try std.testing.expectEqual(false, call.params.object.get("enabled").?.bool);
    }
    const leading = try G.parse(arena.allocator(), &.{ "pane.set_title", "--text=x", "--count=002" });
    try std.testing.expect(leading.failure == null);
    try std.testing.expectEqual(@as(i64, 2), leading.params.object.get("count").?.integer);
    const parent = try G.parse(arena.allocator(), &.{"pane"});
    try std.testing.expectEqualStrings("pane", parent.name);
}

test "cli: usage errors preserve --json and validation refinements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Case = struct { argv: []const []const u8, code: []const u8 };
    for ([_]Case{
        .{ .argv = &.{ "unknown", "--json" }, .code = "invalid_params.usage" },
        .{ .argv = &.{ "pane", "unknown", "--json" }, .code = "invalid_params.usage" },
        .{ .argv = &.{ "pane", "set-title", "--json" }, .code = "invalid_params.missing" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--text=y", "--json" }, .code = "invalid_params.usage" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--enabled", "true", "--json" }, .code = "invalid_params.type" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--enabled=yes", "--json" }, .code = "invalid_params.type" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--count", "-2", "--json" }, .code = "invalid_params.usage" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--count=2.0", "--json" }, .code = "invalid_params.type" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--count=11", "--json" }, .code = "invalid_params.range" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--count=99999999999999999", "--json" }, .code = "invalid_params.range" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--timeout=10", "--json" }, .code = "invalid_params.unknown" },
        .{ .argv = &.{ "pane", "set-title", "--text=x", "--json", "--", "extra" }, .code = "invalid_params.usage" },
        .{ .argv = &.{ "pane", "--json", "--json" }, .code = "invalid_params.usage" },
    }) |c| {
        const call = try G.parse(arena.allocator(), c.argv);
        try std.testing.expect(call.json);
        try std.testing.expect(call.failure != null);
        try std.testing.expectEqualStrings(c.code, call.failure.?.code);
    }
    const valid = try G.parse(arena.allocator(), &.{ "pane", "set-title", "--text=--json", "--enabled=false", "--" });
    try std.testing.expect(valid.failure == null);
    try std.testing.expect(!valid.json);
    try std.testing.expectEqualStrings("--json", valid.params.object.get("text").?.string);
}

test "cli: generated help and errors render without contacting daemon" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    const opts: cli.RunOptions = .{ .stdout = &out.writer, .stderr = &err.writer };
    try std.testing.expectEqual(@as(u8, 0), try G.run(std.testing.allocator, &.{ "pane", "set-title", "--help", "--json" }, opts));
    var help = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer help.deinit();
    const text = help.value.object.get("help").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "pane set-title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--enabled <boolean>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "default: false") != null);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try G.run(std.testing.allocator, &.{ "pane", "set-title", "--json" }, opts));
    var failure = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer failure.deinit();
    try std.testing.expectEqualStrings("invalid_params.missing", failure.value.object.get("error").?.object.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 0), err.written().len);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try G.run(std.testing.allocator, &.{ "pane", "set-title" }, opts));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expect(err.written().len != 0);
}

test "cli: compound JSON values validate recursively without coercion" {
    const Compound = cli.Generator(.{ .format = 1, .tool = "compound", .summary = "Compound", .verbs = .{.{
        .name = "check",
        .summary = "Check",
        .grant = .read,
        .params = .{
            .{ .name = "records", .summary = "Records", .type = .{ .kind = .array, .items = .{ .kind = .object, .fields = .{
                .{ .name = "weight", .summary = "Weight", .type = .{ .kind = .number, .min = 0 }, .default = 1.5 },
            } } }, .default = .{.{}} },
            .{ .name = "empty", .summary = "Null", .type = .{ .kind = .null } },
        },
        .result = .{ .kind = .null },
    }} });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const call = try Compound.parse(arena.allocator(), &.{ "check", "--records=[{}]", "--empty=null" });
    try std.testing.expect(call.failure == null);
    try std.testing.expectEqual(@as(f64, 1.5), call.params.object.get("records").?.array.items[0].object.get("weight").?.float);
    const defaults = try Compound.parse(arena.allocator(), &.{"check"});
    try std.testing.expect(defaults.failure == null);
    const invalid = try Compound.parse(arena.allocator(), &.{ "check", "--records=[{\"weight\":\"1\"}]" });
    try std.testing.expectEqualStrings("invalid_params.type", invalid.failure.?.code);
    try std.testing.expectEqualStrings("records.0.weight", invalid.failure.?.param.?);
}

test "cli: comma_list flags take a,b as well as JSON; other string arrays stay JSON only" {
    const Lists = cli.Generator(.{ .format = 1, .tool = "lists", .summary = "Lists", .verbs = .{.{
        .name = "check",
        .summary = "Check",
        .grant = .read,
        .params = .{
            .{ .name = "repos", .summary = "Repos", .type = .{ .kind = .array, .comma_list = true, .items = .{ .kind = .string } } },
            .{ .name = "modes", .summary = "Modes", .type = .{ .kind = .array, .comma_list = true, .items = .{ .kind = .string, .choices = .{ "r", "w" } } } },
            .{ .name = "argv", .summary = "Command", .type = .{ .kind = .array, .items = .{ .kind = .string } } },
        },
        .result = .{ .kind = .null },
    }} });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expectStrings = struct {
        fn check(call: anytype, name: []const u8, want: []const []const u8) !void {
            try std.testing.expect(call.failure == null);
            const items = call.params.object.get(name).?.array.items;
            try std.testing.expectEqual(want.len, items.len);
            for (want, items) |w, item| try std.testing.expectEqualStrings(w, item.string);
        }
    }.check;

    // Comma-separated, in both flag spellings, and one item without a comma.
    try expectStrings(try Lists.parse(a, &.{ "check", "--repos", "venom-term,venom-std" }), "repos", &.{ "venom-term", "venom-std" });
    try expectStrings(try Lists.parse(a, &.{ "check", "--repos=a,b,c" }), "repos", &.{ "a", "b", "c" });
    try expectStrings(try Lists.parse(a, &.{ "check", "--repos=solo" }), "repos", &.{"solo"});
    // Spaces are data, not separators.
    try expectStrings(try Lists.parse(a, &.{ "check", "--repos=a b, c" }), "repos", &.{ "a b", " c" });

    // JSON still works, and is how an item keeps its comma.
    try expectStrings(try Lists.parse(a, &.{ "check", "--repos=[\"a,b\",\"c\"]" }), "repos", &.{ "a,b", "c" });
    try expectStrings(try Lists.parse(a, &.{ "check", "--repos= [\"a,b\"]" }), "repos", &.{"a,b"});
    try expectStrings(try Lists.parse(a, &.{ "check", "--repos=[]" }), "repos", &.{});

    // A broken JSON array is an error, not the two items `["a"` and `"b`.
    const broken = try Lists.parse(a, &.{ "check", "--repos=[\"a\",\"b" });
    try std.testing.expectEqualStrings("invalid_params.type", broken.failure.?.code);
    try std.testing.expectEqualStrings("repos", broken.failure.?.param.?);

    // Empty items are typos; an empty list is spelled [].
    for ([_][]const u8{ "--repos=", "--repos=a,,b", "--repos=a,", "--repos=,a" }) |flag| {
        const empty = try Lists.parse(a, &.{ "check", flag });
        try std.testing.expectEqualStrings("invalid_params.type", empty.failure.?.code);
    }

    // Items still go through the schema.
    try std.testing.expect((try Lists.parse(a, &.{ "check", "--modes=r,w" })).failure == null);
    const bad_mode = try Lists.parse(a, &.{ "check", "--modes=r,x" });
    try std.testing.expectEqualStrings("modes.1", bad_mode.failure.?.param.?);

    // Without the opt-in, a non-JSON value still fails: no command gets split.
    for ([_][]const u8{ "--argv=printf,%s,hello,world", "--argv=solo" }) |flag| {
        const refused = try Lists.parse(a, &.{ "check", flag });
        try std.testing.expectEqualStrings("invalid_params.type", refused.failure.?.code);
        try std.testing.expectEqualStrings("argv", refused.failure.?.param.?);
    }
    try expectStrings(try Lists.parse(a, &.{ "check", "--argv=[\"printf\",\"a,b\"]" }), "argv", &.{ "printf", "a,b" });

    // Help and the docs name only the flags that opted in.
    const help = try Lists.help(a, "check");
    const repos_line = help[std.mem.indexOf(u8, help, "--repos").?..];
    try std.testing.expect(std.mem.indexOf(u8, repos_line[0..std.mem.indexOfScalar(u8, repos_line, '\n').?], "comma-separated") != null);
    const argv_line = help[std.mem.indexOf(u8, help, "--argv").?..];
    try std.testing.expect(std.mem.indexOf(u8, argv_line[0..std.mem.indexOfScalar(u8, argv_line, '\n').?], "comma-separated") == null);

    // The manifest carries the member only when true, and MCP never does.
    const model = try std.json.Stringify.valueAlloc(a, try cli.digest.manifest(Lists, a), .{});
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, model, "\"comma_list\":true"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, model, "comma_list"));
    const tools = try std.json.Stringify.valueAlloc(a, try cli.mcp.catalog(Lists, a), .{});
    try std.testing.expect(std.mem.indexOf(u8, tools, "comma_list") == null);
}

test "cli: streams suppress final ok, validate results and preserve error data" {
    const proto = @import("proto");
    const verb: proto.schema.Verb = .{
        .name = "stream",
        .summary = "Stream",
        .grant = .read,
        .streams = true,
        .item = .{ .kind = .string },
        .result = .{ .kind = .object, .fields = &.{.{ .name = "status", .summary = "Exit", .type = .{ .kind = .integer, .min = 0, .max = 255 }, .required = true }} },
        .exit = .{ .result = "status" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    const opts: cli.RunOptions = .{ .stdout = &out.writer, .stderr = &err.writer };
    try std.testing.expectEqual(@as(?u8, null), try cli.runtime.render(a, &verb, true, .{ .item = .{ .string = "first" } }, opts));
    var result = try std.json.parseFromSlice(std.json.Value, a, "{\"status\":23}", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(?u8, 23), try cli.runtime.render(a, &verb, true, .{ .ok = result.value }, opts));
    try std.testing.expectEqualStrings("\"first\"\n", out.written());
    try std.testing.expectEqual(@as(?u8, 11), try cli.runtime.render(a, &verb, true, .{ .ok = .null }, opts));
    out.clearRetainingCapacity();
    const data = try std.json.parseFromSlice(std.json.Value, a, "{\"scope\":\"secret\"}", .{});
    defer data.deinit();
    try std.testing.expectEqual(@as(?u8, 4), try cli.runtime.render(a, &verb, true, .{ .@"error" = .{ .code = "denied.scope", .message = "No access", .data = data.value } }, opts));
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"denied.scope\",\"message\":\"No access\",\"data\":{\"scope\":\"secret\"}}}\n", out.written());
}

test "cli: manifest nullable descriptors round-trip and accept explicit null items" {
    const proto = @import("proto");
    const schema = comptime cli.manifest.normalize(.{
        .format = 1,
        .tool = "test",
        .summary = "Test CLI",
        .verbs = .{.{
            .name = "watch",
            .summary = "Stream",
            .grant = .read,
            .streams = true,
            .item = .{ .kind = .object, .fields = .{
                .{ .name = "agent", .summary = "Agent", .type = .{ .kind = .string }, .required = true },
                .{ .name = "parent", .summary = "Parent or null", .type = .{ .kind = .string, .nullable = true }, .required = true },
                .{ .name = "tags", .summary = "Tags", .type = .{ .kind = .array, .nullable = true, .items = .{ .kind = .integer, .nullable = true, .min = 0 } } },
                .{ .name = "meta", .summary = "Meta", .type = .{ .kind = .object, .nullable = true, .fields = .{} } },
            } },
            .result = .{ .kind = .string, .nullable = true, .choices = .{"done"} },
            .errors = .{.{ .code = "conflict.busy", .summary = "Busy", .data = .{ .kind = .object, .fields = .{.{ .name = "holder", .summary = "Holder", .type = .{ .kind = .string, .nullable = true } }} } }},
            .examples = .{
                .{ .params = .{}, .result = null },
                .{ .params = .{}, .result = "done" },
            },
        }},
    });
    const verb = comptime schema.find("watch").?;
    const item = verb.item.?;
    try std.testing.expect(!item.nullable);
    try std.testing.expect(item.fields.?[1].type.nullable);
    try std.testing.expect(!item.fields.?[0].type.nullable);
    try std.testing.expect(item.fields.?[2].type.nullable);
    try std.testing.expect(item.fields.?[2].type.items.?.nullable);
    try std.testing.expectEqual(@as(?f64, 0), item.fields.?[2].type.items.?.min);
    try std.testing.expect(item.fields.?[3].type.nullable);
    try std.testing.expect(verb.result.nullable);
    try std.testing.expect(verb.errors[0].data.?.fields.?[0].type.nullable);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"agent\":\"a1\",\"parent\":null}",
        "{\"agent\":\"a1\",\"parent\":\"a0\",\"tags\":[1,null],\"meta\":null}",
        "{\"agent\":\"a1\",\"parent\":null,\"tags\":null,\"meta\":{}}",
    }) |text| {
        var value = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        var path: proto.schema.Path = .{ .gpa = a };
        try std.testing.expectEqual(@as(?proto.schema.Failure, null), try proto.schema.validateValue(a, item, &value, &path, false));
    }
    // Nullable does not relax other members: missing, wrong type, and a null
    // in a non-nullable field still fail.
    for ([_][]const u8{
        "{\"agent\":\"a1\"}",
        "{\"agent\":null,\"parent\":null}",
        "{\"agent\":\"a1\",\"parent\":7}",
        "{\"agent\":\"a1\",\"parent\":null,\"tags\":[-1]}",
    }) |text| {
        var value = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        var path: proto.schema.Path = .{ .gpa = a };
        try std.testing.expect(try proto.schema.validateValue(a, item, &value, &path, false) != null);
    }
    var null_item: std.json.Value = .null;
    var path: proto.schema.Path = .{ .gpa = a };
    try std.testing.expect(try proto.schema.validateValue(a, item, &null_item, &path, false) != null);

    // Generated surfaces see the same model: MCP says anyOf [string, null].
    const mcp_schema = try cli.mcp.typeSchema(a, item.fields.?[1].type);
    try std.testing.expectEqual(@as(usize, 2), mcp_schema.object.get("anyOf").?.array.items.len);
    // Examples with an explicit null result keep it as JSON null.
    const examples = comptime cli.manifest.examples(.{ .verbs = .{.{
        .name = "watch",
        .result = .{ .kind = .string, .nullable = true },
        .examples = .{.{ .params = .{}, .result = null }},
    }} });
    try std.testing.expectEqualStrings("null", examples[0].result);
}

test {
    _ = @import("mcp_tests.zig");
    _ = @import("gen_tests.zig");
    _ = @import("digest_tests.zig");
}
