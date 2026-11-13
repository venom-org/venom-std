const std = @import("std");
const proto = @import("proto");
const cli = @import("root.zig");
const mcp = cli.mcp;
const t = std.testing;
const a = t.allocator;
const c = std.c;
const Value = std.json.Value;

const G = cli.Generator(.{
    .format = 1,
    .tool = "mcp-test",
    .summary = "MCP adapter test",
    .verbs = .{
        // The verb-schema worked example, verbatim.
        .{
            .name = "echo",
            .summary = "Return the supplied text",
            .params = .{
                .{ .name = "text", .summary = "Text to return", .type = .{ .kind = .string }, .required = true },
                .{ .name = "style", .summary = "Output casing", .type = .{ .kind = .string, .choices = .{ "plain", "upper" } }, .default = "plain" },
            },
            .result = .{ .kind = .object, .fields = .{
                .{ .name = "text", .summary = "Returned text", .type = .{ .kind = .string }, .required = true },
            } },
            .grant = .read,
        },
        .{
            .name = "count",
            .summary = "Stream n items",
            .params = .{.{ .name = "n", .summary = "Items", .type = .{ .kind = .integer, .min = 0, .max = 5000 }, .required = true }},
            .streams = true,
            .item = .{ .kind = .object, .fields = .{.{ .name = "i", .summary = "Index", .type = .{ .kind = .integer }, .required = true }} },
            .result = .{ .kind = .object, .fields = .{.{ .name = "total", .summary = "Total", .type = .{ .kind = .integer }, .required = true }} },
            .grant = .read,
        },
        .{ .name = "watch", .summary = "Never finishes", .streams = true, .item = .{ .kind = .string }, .result = .{ .kind = .null }, .grant = .read },
        .{ .name = "pane.set_title", .summary = "Busy", .result = .{ .kind = .null }, .grant = .write },
    },
});

test "mcp: reversible tool names" {
    try t.expectEqualStrings("pane_dsplit", mcp.toolName("pane.split"));
    try t.expectEqualStrings("pane__split", mcp.toolName("pane_split"));
    try t.expectEqualStrings("pane_dset__title", mcp.toolName("pane.set_title"));
    try t.expectEqualStrings("echo", mcp.toolName("echo"));
}

test "mcp: catalog matches the verb schema and omits local bootstrap verbs" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tools = (try mcp.catalog(G, arena.allocator())).object.get("tools").?.array.items;
    var names: std.ArrayList(u8) = .empty;
    for (tools) |tool| {
        try names.appendSlice(arena.allocator(), tool.object.get("name").?.string);
        try names.append(arena.allocator(), ' ');
    }
    try t.expectEqualStrings("audit count doctor echo grant_dissue grant_dlist grant_drevoke pane_dset__title ping skill skill_dinstall watch whoami ", names.items);

    const expected_tool =
        \\{"name":"echo","description":"Return the supplied text","inputSchema":{"type":"object","properties":{"text":{"type":"string","description":"Text to return"},"style":{"type":"string","enum":["plain","upper"],"description":"Output casing","default":"plain"}},"required":["text"],"additionalProperties":false},"outputSchema":{"type":"object","properties":{"result":{"type":"object","properties":{"text":{"type":"string","description":"Returned text"}},"required":["text"],"additionalProperties":false}},"required":["result"],"additionalProperties":false}}
    ;
    try t.expectEqualStrings(expected_tool, try std.json.Stringify.valueAlloc(arena.allocator(), tools[3], .{}));

    const count = try std.json.Stringify.valueAlloc(arena.allocator(), tools[1], .{});
    try t.expect(std.mem.indexOf(u8, count, "at most 1024 items and 1 MiB") != null);
    try t.expect(std.mem.indexOf(u8, count, "\"minimum\":0,\"maximum\":5000") != null);
    try t.expect(std.mem.indexOf(u8, count, "\"required\":[\"items\",\"result\"]") != null);
    const ping = try std.json.Stringify.valueAlloc(arena.allocator(), tools[7], .{});
    try t.expect(std.mem.indexOf(u8, ping, "\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}") != null);
}

/// Feed `input` on a closed pipe, run the adapter to EOF, return its stdout.
fn session(arena: std.mem.Allocator, input: []const u8, socket: ?[]const u8) ![]const u8 {
    var fds: [2]c.fd_t = undefined;
    try t.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try t.expectEqual(@as(isize, @intCast(input.len)), c.write(fds[1], input.ptr, input.len));
    _ = c.close(fds[1]);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try mcp.serve(G, a, .{ .input = fds[0], .output = &out.writer, .path = .{ .socket = socket }, .version = "1.2.3" });
    return arena.dupe(u8, out.written());
}

/// Every output line parsed, in order. Each must be a JSON-RPC 2.0 message.
fn lines(arena: std.mem.Allocator, out: []const u8) ![]Value {
    var list: std.ArrayList(Value) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| if (line.len > 0) {
        const v = try std.json.parseFromSliceLeaky(Value, arena, line, .{});
        try t.expectEqualStrings("2.0", v.object.get("jsonrpc").?.string);
        try list.append(arena, v);
    };
    return list.items;
}

fn errorCode(v: Value) i64 {
    return v.object.get("error").?.object.get("code").?.integer;
}

/// The Venom error wrapper inside an isError tool result.
fn toolFailure(arena: std.mem.Allocator, v: Value) !Value {
    const result = v.object.get("result").?.object;
    try t.expect(result.get("isError").?.bool);
    try t.expect(result.get("structuredContent") == null);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    return (try std.json.parseFromSliceLeaky(Value, arena, text, .{})).object.get("error").?;
}

test "mcp: JSON-RPC lifecycle and envelope errors without a daemon" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const out = try session(aa,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":"p","method":"ping"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\not json
        \\{"jsonrpc":"1.0","id":3,"method":"ping"}
        \\{"jsonrpc":"2.0","id":4,"method":"resources/list"}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","arguments":[]}}
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo","arguments":{}}}
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x","style":"loud"}}}
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"serve"}}
        \\{"jsonrpc":"2.0","id":1.5,"method":"ping"}
        \\
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}
    , ".zig-cache/tmp/venom-mcp-test-missing/none.sock");
    const r = try lines(aa, out);
    try t.expectEqual(@as(usize, 13), r.len);

    const init = r[0].object.get("result").?.object;
    try t.expectEqual(@as(i64, 1), r[0].object.get("id").?.integer);
    try t.expectEqualStrings("2025-06-18", init.get("protocolVersion").?.string);
    try t.expectEqualStrings("mcp-test", init.get("serverInfo").?.object.get("name").?.string);
    try t.expectEqualStrings("1.2.3", init.get("serverInfo").?.object.get("version").?.string);
    try t.expect(init.get("capabilities").?.object.get("tools") != null);

    try t.expectEqualStrings("p", r[1].object.get("id").?.string);
    try t.expectEqual(@as(usize, 0), r[1].object.get("result").?.object.count());
    try t.expectEqual(@as(usize, 13), r[2].object.get("result").?.object.get("tools").?.array.items.len);
    try t.expectEqual(@as(i64, -32700), errorCode(r[3]));
    try t.expect(r[3].object.get("id").? == .null);
    try t.expectEqual(@as(i64, -32600), errorCode(r[4]));
    try t.expectEqual(@as(i64, -32601), errorCode(r[5]));
    try t.expectEqual(@as(i64, -32602), errorCode(r[6])); // unknown tool
    try t.expectEqual(@as(i64, -32602), errorCode(r[7])); // non-object arguments

    // Validation happens in the adapter, with the CLI's codes and paths.
    const missing = try toolFailure(aa, r[8]);
    try t.expectEqualStrings("invalid_params.missing", missing.object.get("code").?.string);
    try t.expectEqualStrings("text", missing.object.get("data").?.object.get("param").?.string);
    try t.expectEqualStrings("invalid_params.enum", (try toolFailure(aa, r[9])).object.get("code").?.string);
    try t.expectEqual(@as(i64, -32602), errorCode(r[10])); // local bootstrap is not a tool
    try t.expectEqual(@as(i64, -32600), errorCode(r[11])); // fractional id
    // A valid call with no daemon is a tool error, not a JSON-RPC error.
    try t.expectEqual(@as(i64, 10), r[12].object.get("id").?.integer);
    const down = try toolFailure(aa, r[12]);
    try t.expect(std.mem.startsWith(u8, down.object.get("code").?.string, "unavailable") or std.mem.startsWith(u8, down.object.get("code").?.string, "invalid_params.socket"));
}

/// A real proto daemon serving the test model on its own thread.
const Daemon = struct {
    tmp: t.TmpDir,
    path: []u8,
    echo: Echo = .{},
    count: Count = .{},
    watch: Watch = .{},
    nop: Nop = .{},
    standard: cli.Standard(G) = .{},
    dispatcher: proto.Dispatcher = undefined,
    server: proto.Server = undefined,
    stop: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    const Echo = struct {
        pub fn call(_: *Echo, call_: *proto.Call) anyerror!void {
            const text = call_.params.object.get("text").?.string;
            const out = if (std.mem.eql(u8, call_.params.object.get("style").?.string, "upper")) try std.ascii.allocUpperString(call_.arena(), text) else text;
            try call_.ok(.{ .text = out });
        }
    };
    const Count = struct {
        pub fn call(_: *Count, call_: *proto.Call) anyerror!void {
            const n = call_.params.object.get("n").?.integer;
            var i: i64 = 0;
            while (i < n) : (i += 1) try call_.item(.{ .i = i });
            try call_.ok(.{ .total = n });
        }
    };
    /// Leaves the call open until it is cancelled.
    const Watch = struct {
        pub fn call(_: *Watch, _: *proto.Call) anyerror!void {}
    };
    const Nop = struct {
        pub fn call(_: *Nop, call_: *proto.Call) anyerror!void {
            try call_.fail("conflict.busy", "busy", .{ .retry = true });
        }
    };

    fn start() !*Daemon {
        const d = try a.create(Daemon);
        errdefer a.destroy(d);
        d.* = .{ .tmp = t.tmpDir(.{}), .path = undefined };
        errdefer d.tmp.cleanup();
        const parent = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{d.tmp.sub_path}, 0);
        defer a.free(parent);
        try t.expectEqual(@as(c_int, 0), c.chmod(parent, 0o700));
        d.path = try std.fmt.allocPrint(a, "{s}/d.sock", .{parent});
        errdefer a.free(d.path);
        const bindings = [_]proto.Binding{
            .{ .verb = "count", .handler = proto.VerbHandler.init(&d.count) },
            .{ .verb = "echo", .handler = proto.VerbHandler.init(&d.echo) },
            .{ .verb = "pane.set_title", .handler = proto.VerbHandler.init(&d.nop) },
            .{ .verb = "watch", .handler = proto.VerbHandler.init(&d.watch) },
        } ++ d.standard.bindings();
        d.dispatcher = try proto.Dispatcher.init(a, &G.schema, &bindings, .{}, null);
        errdefer d.dispatcher.deinit();
        d.server = try proto.Server.init(a, .{ .hello = .{ .identity = .{ .name = "mcp-test", .version = "0" }, .caps = &.{"cancel"} }, .path = .{ .socket = d.path } }, d.dispatcher.handler());
        errdefer d.server.deinit();
        d.thread = try std.Thread.spawn(.{}, loop, .{d});
        return d;
    }
    fn loop(d: *Daemon) void {
        while (!d.stop.load(.monotonic)) d.server.poll(10) catch {};
        d.dispatcher.cancelAll();
        d.server.shutdown();
        var turns: usize = 0;
        while (d.server.connections.items.len != 0 and turns < 200) : (turns += 1) d.server.poll(10) catch {};
    }
    fn deinit(d: *Daemon) void {
        d.stop.store(true, .monotonic);
        d.thread.join();
        d.server.deinit();
        d.dispatcher.deinit();
        a.free(d.path);
        d.tmp.cleanup();
        a.destroy(d);
    }
};

test "mcp: tools/call against a live daemon: results, streams, errors, limits, cancel" {
    const d = try Daemon.start();
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const out = try session(aa,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi","style":"upper"}}}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"count","arguments":{"n":3}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pane_dset__title"}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"count","arguments":{"n":1025}}}
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ping","arguments":null}}
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"watch"}}
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"user"}}
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"count","arguments":{"n":1024}}}
        \\
    , d.path);
    const r = try lines(aa, out);
    try t.expectEqual(@as(usize, 7), r.len); // no response for the cancelled request 7

    // The exact success shape: text content plus structuredContent.
    try t.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"result\":{\"text\":\"hi\"}}"}],"structuredContent":{"result":{"text":"hi"}},"isError":false}}
    , std.mem.sliceTo(out, '\n'));
    try t.expectEqualStrings("HI", r[1].object.get("result").?.object.get("structuredContent").?.object.get("result").?.object.get("text").?.string);

    const streamed = r[2].object.get("result").?.object.get("structuredContent").?.object;
    try t.expectEqual(@as(usize, 3), streamed.get("items").?.array.items.len);
    try t.expectEqual(@as(i64, 2), streamed.get("items").?.array.items[2].object.get("i").?.integer);
    try t.expectEqual(@as(i64, 3), streamed.get("result").?.object.get("total").?.integer);

    // Daemon errors are preserved verbatim.
    const busy = try toolFailure(aa, r[3]);
    try t.expectEqualStrings("denied.write", busy.object.get("code").?.string);
    try t.expectEqualStrings("unknown", busy.object.get("data").?.object.get("principal").?.string);

    try t.expectEqualStrings("unsupported.stream_limit", (try toolFailure(aa, r[4])).object.get("code").?.string);
    try t.expectEqual(@as(i64, 6), r[5].object.get("id").?.integer);
    try t.expect(!r[5].object.get("result").?.object.get("isError").?.bool);

    // After the cancellation, later requests are still served in order.
    try t.expectEqual(@as(i64, 8), r[6].object.get("id").?.integer);
    try t.expectEqual(@as(usize, 1024), r[6].object.get("result").?.object.get("structuredContent").?.object.get("items").?.array.items.len);
}
