const std = @import("std");
const p = @import("root.zig");
const os = @import("os.zig");
const c = os.c;
const a = std.testing.allocator;
const t = std.testing;
const S = p.schema;

const text_result: S.Type = .{ .kind = .object, .fields = &.{.{ .name = "text", .summary = "Text", .type = .{ .kind = .string }, .required = true }} };
const model: S.Schema = .{
    .tool = "venom-test",
    .summary = "Dispatch tests",
    .verbs = &.{
        .{
            .name = "echo",
            .summary = "Return the supplied text",
            .params = &.{
                .{ .name = "text", .summary = "Text to return", .type = .{ .kind = .string }, .required = true },
                .{ .name = "style", .summary = "Casing", .type = .{ .kind = .string, .choices = &.{ "plain", "upper" } }, .default = "\"plain\"" },
            },
            .result = text_result,
            .errors = &.{.{ .code = "conflict.echo_busy", .summary = "Busy" }},
            .grant = .read,
        },
        .{
            .name = "later",
            .summary = "Answered on a later turn",
            .params = &.{.{ .name = "tag", .summary = "Tag", .type = .{ .kind = .string } }},
            .result = .{ .kind = .string },
            .grant = .read,
        },
        .{
            .name = "count",
            .summary = "Stream n items",
            .params = &.{.{ .name = "n", .summary = "Items", .type = .{ .kind = .integer, .min = 0, .max = 100 }, .required = true }},
            .result = .{ .kind = .object, .fields = &.{.{ .name = "total", .summary = "Total", .type = .{ .kind = .integer }, .required = true }} },
            .streams = true,
            .item = .{ .kind = .object, .fields = &.{.{ .name = "i", .summary = "Index", .type = .{ .kind = .integer }, .required = true }} },
            .grant = .read,
        },
        .{
            .name = "watch",
            .summary = "Stream until cancelled",
            .result = .{ .kind = .null },
            .streams = true,
            .item = .{ .kind = .integer },
            .grant = .read,
        },
        .{ .name = "bad", .summary = "Returns an invalid result", .result = text_result, .grant = .none },
        .{ .name = "boom", .summary = "Handler fails", .result = .{ .kind = .null }, .grant = .none },
        .{ .name = "pane.set_title", .summary = "Dotted verb", .result = .{ .kind = .null }, .grant = .write },
    },
};

const Echo = struct {
    calls: usize = 0,
    pub const Params = struct { text: []const u8, style: []const u8 };
    pub fn call(self: *Echo, call_: *p.Call, params: Params) anyerror!void {
        self.calls += 1;
        if (std.mem.eql(u8, params.text, "busy")) return call_.fail("conflict.echo_busy", "echo is busy", .{ .retry = true });
        if (std.mem.eql(u8, params.style, "upper")) return call_.ok(.{ .text = try std.ascii.allocUpperString(call_.arena(), params.text) });
        return call_.ok(.{ .text = params.text });
    }
};
const Later = struct {
    tickets: std.ArrayList(p.Ticket) = .empty,
    pub fn call(self: *Later, call_: *p.Call) anyerror!void {
        try self.tickets.append(a, call_.ticket);
    }
};
const Count = struct {
    pub const Params = struct { n: i64 };
    pub fn call(_: *Count, call_: *p.Call, params: Params) anyerror!void {
        var i: i64 = 0;
        while (i < params.n) : (i += 1) try call_.item(.{ .i = i });
        return call_.ok(.{ .total = params.n });
    }
};
const Bad = struct {
    pub fn call(_: *Bad, call_: *p.Call) anyerror!void {
        return call_.ok(.{ .text = 5 });
    }
};
const Boom = struct {
    pub fn call(_: *Boom, _: *p.Call) anyerror!void {
        return error.Kaboom;
    }
};
const Nop = struct {
    calls: usize = 0,
    pub fn call(self: *Nop, call_: *p.Call) anyerror!void {
        self.calls += 1;
        return call_.ok(null);
    }
};

const Verbs = struct {
    echo: Echo = .{},
    later: Later = .{},
    watch: Later = .{},
    count: Count = .{},
    bad: Bad = .{},
    boom: Boom = .{},
    nop: Nop = .{},

    fn deinit(self: *Verbs) void {
        self.later.tickets.deinit(a);
        self.watch.tickets.deinit(a);
    }
    fn bindings(self: *Verbs) [7]p.Binding {
        return .{
            .{ .verb = "echo", .handler = p.VerbHandler.typed(Echo.Params, &self.echo) },
            .{ .verb = "later", .handler = p.VerbHandler.init(&self.later) },
            .{ .verb = "count", .handler = p.VerbHandler.typed(Count.Params, &self.count) },
            .{ .verb = "watch", .handler = p.VerbHandler.init(&self.watch) },
            .{ .verb = "bad", .handler = p.VerbHandler.init(&self.bad) },
            .{ .verb = "boom", .handler = p.VerbHandler.init(&self.boom) },
            .{ .verb = "pane.set_title", .handler = p.VerbHandler.init(&self.nop) },
        };
    }
    fn dispatcher(self: *Verbs, options: p.DispatcherOptions) !p.Dispatcher {
        const b = self.bindings();
        return p.Dispatcher.init(a, &model, &b, options, null);
    }
};

/// A ready NDJSON connection over a socketpair; output is inspected in memory.
const Peer = struct {
    conn: p.Connection,
    other: c.fd_t,
    lines: std.ArrayList(p.Response) = .empty,

    fn init(cancel: bool) !Peer {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
        var conn = p.Connection.init(a, fds[0]);
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        if (cancel) try conn.caps.append(a, "cancel");
        return .{ .conn = conn, .other = fds[1] };
    }
    fn deinit(self: *Peer) void {
        self.clear();
        self.lines.deinit(a);
        self.conn.deinit();
        os.close(self.other);
    }
    fn clear(self: *Peer) void {
        for (self.lines.items) |*r| r.deinit();
        self.lines.clearRetainingCapacity();
    }
    /// Send one line and return every response line it produced.
    fn send(self: *Peer, d: *p.Dispatcher, line: []const u8) ![]p.Response {
        try d.message(&self.conn, .{ .ndjson = line });
        return self.take();
    }
    fn take(self: *Peer) ![]p.Response {
        self.clear();
        var it = std.mem.splitScalar(u8, self.conn.output.items, '\n');
        while (it.next()) |l| if (l.len > 0) try self.lines.append(a, try p.Response.parse(a, l));
        self.conn.output.clearRetainingCapacity();
        return self.lines.items;
    }
    fn raw(self: *Peer, d: *p.Dispatcher, line: []const u8) ![]u8 {
        try d.message(&self.conn, .{ .ndjson = line });
        defer self.conn.output.clearRetainingCapacity();
        return a.dupe(u8, self.conn.output.items);
    }
};

fn expectError(r: p.Response, id: ?i64, code: []const u8) !void {
    try t.expect(r.body == .@"error");
    try t.expectEqualStrings(code, r.body.@"error".code);
    if (id) |i| try t.expectEqual(i, r.id.?.integer) else try t.expect(r.id == null);
}
fn expectOne(lines: []p.Response) !p.Response {
    try t.expectEqual(@as(usize, 1), lines.len);
    return lines[0];
}
fn param(r: p.Response) []const u8 {
    return r.body.@"error".data.?.object.get("param").?.string;
}

test "dispatch: handlers are bound from the verb schema" {
    var v: Verbs = .{};
    defer v.deinit();
    var b = v.bindings();
    var diag: S.Diagnostic = .{};
    try t.expectError(error.MissingHandler, p.Dispatcher.init(a, &model, b[0..6], .{}, &diag));
    try t.expectEqualStrings("pane.set_title", diag.verb);
    var extra: [8]p.Binding = undefined;
    @memcpy(extra[0..7], &b);
    extra[7] = .{ .verb = "nope", .handler = b[0].handler };
    try t.expectError(error.UnknownVerb, p.Dispatcher.init(a, &model, &extra, .{}, &diag));
    try t.expectEqualStrings("nope", diag.verb);
    extra[7] = .{ .verb = "echo", .handler = b[0].handler };
    try t.expectError(error.DuplicateHandler, p.Dispatcher.init(a, &model, &extra, .{}, &diag));
    try t.expectEqualStrings("echo", diag.verb);
    const reserved: S.Schema = .{ .tool = "x", .summary = "x", .verbs = &.{.{ .name = "cancel", .summary = "x", .result = .{ .kind = .null }, .grant = .none }} };
    try t.expectError(error.InvalidSchema, p.Dispatcher.init(a, &reserved, &.{}, .{}, &diag));
    try t.expectEqualStrings("cancel", diag.verb);
    var d = try p.Dispatcher.init(a, &model, &b, .{}, &diag);
    d.deinit();
}

test "dispatch: requests, malformed input and the error model" {
    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{});
    defer d.deinit();
    var peer = try Peer.init(true);
    defer peer.deinit();

    // The protocol's reference request/response examples, byte for byte.
    const cases = [_][2][]const u8{
        .{ "{\"id\":2,\"verb\":\"echo\",\"params\":{\"text\":\"hi\"}}", "{\"id\":2,\"ok\":{\"text\":\"hi\"}}\n" },
        .{ "{\"id\":3,\"verb\":\"echo\",\"params\":{}}", "{\"id\":3,\"error\":{\"code\":\"invalid_params.missing\",\"message\":\"missing required param 'text'\",\"data\":{\"param\":\"text\"}}}\n" },
        .{ "{\"id\":2,\"verb\":\"echo\",\"params\":{\"text\":\"hi\",\"style\":\"upper\"}}", "{\"id\":2,\"ok\":{\"text\":\"HI\"}}\n" },
        .{ "{\"id\":\"p\",\"verb\":\"ping\"}", "{\"id\":\"p\",\"ok\":{}}\n" },
    };
    for (cases) |case| {
        const out = try peer.raw(&d, case[0]);
        defer a.free(out);
        try t.expectEqualStrings(case[1], out);
    }

    const errors_table = [_]struct { line: []const u8, id: ?i64, code: []const u8, exit: u8 }{
        .{ .line = "not json", .id = null, .code = "protocol.parse", .exit = 9 },
        .{ .line = "[1,2]", .id = null, .code = "protocol.parse", .exit = 9 },
        .{ .line = "{\"id\":1,\"id\":2,\"verb\":\"ping\"}", .id = null, .code = "protocol.parse", .exit = 9 },
        .{ .line = "{\"verb\":\"ping\"}", .id = null, .code = "protocol.invalid_request", .exit = 9 },
        .{ .line = "{\"id\":1.5,\"verb\":\"ping\"}", .id = null, .code = "protocol.invalid_request", .exit = 9 },
        .{ .line = "{\"id\":9007199254740992,\"verb\":\"ping\"}", .id = null, .code = "protocol.invalid_request", .exit = 9 },
        .{ .line = "{\"id\":\"" ++ &@as([65]u8, @splat('x')) ++ "\",\"verb\":\"ping\"}", .id = null, .code = "protocol.invalid_request", .exit = 9 },
        .{ .line = "{\"id\":4}", .id = 4, .code = "protocol.invalid_request", .exit = 9 },
        .{ .line = "{\"id\":4,\"verb\":7}", .id = 4, .code = "protocol.invalid_request", .exit = 9 },
        .{ .line = "{\"id\":4,\"verb\":\"echo\",\"params\":[]}", .id = 4, .code = "protocol.invalid_request", .exit = 9 },
        .{ .line = "{\"id\":4,\"verb\":\"hello\",\"params\":{\"proto\":[1]}}", .id = 4, .code = "protocol.hello_order", .exit = 9 },
        .{ .line = "{\"id\":5,\"verb\":\"nope\"}", .id = 5, .code = "unsupported.verb", .exit = 10 },
        .{ .line = "{\"id\":5,\"verb\":\"Echo\"}", .id = 5, .code = "unsupported.verb", .exit = 10 },
        .{ .line = "{\"id\":6,\"verb\":\"echo\",\"params\":{\"text\":\"hi\",\"x\":1}}", .id = 6, .code = "invalid_params.unknown", .exit = 2 },
        .{ .line = "{\"id\":6,\"verb\":\"echo\",\"params\":{\"text\":3}}", .id = 6, .code = "invalid_params.type", .exit = 2 },
        .{ .line = "{\"id\":6,\"verb\":\"echo\",\"params\":{\"text\":\"a\",\"style\":\"x\"}}", .id = 6, .code = "invalid_params.enum", .exit = 2 },
        .{ .line = "{\"id\":6,\"verb\":\"count\",\"params\":{\"n\":101}}", .id = 6, .code = "invalid_params.range", .exit = 2 },
        .{ .line = "{\"id\":6,\"verb\":\"ping\",\"params\":{\"x\":1}}", .id = 6, .code = "invalid_params.unknown", .exit = 2 },
        .{ .line = "{\"id\":7,\"verb\":\"echo\",\"params\":{\"text\":\"busy\"}}", .id = 7, .code = "conflict.echo_busy", .exit = 5 },
        .{ .line = "{\"id\":8,\"verb\":\"bad\"}", .id = 8, .code = "internal.result", .exit = 11 },
        .{ .line = "{\"id\":8,\"verb\":\"boom\"}", .id = 8, .code = "internal", .exit = 11 },
    };
    for (errors_table) |case| {
        const r = try expectOne(try peer.send(&d, case.line));
        try expectError(r, case.id, case.code);
        try t.expectEqual(case.exit, r.exitCode());
        try t.expect(r.body.@"error".message.len > 0);
    }
    try t.expectEqualStrings("x", param((try peer.send(&d, errors_table[13].line))[0]));
    try t.expectEqualStrings("Kaboom", (try peer.send(&d, errors_table[20].line))[0].body.@"error".message);
    try t.expectEqualStrings("text", param((try peer.send(&d, errors_table[19].line))[0]));

    // Unknown members of the request object are ignored;
    // dotted verbs and string ids work; a failed request leaves the connection usable.
    var r = try expectOne(try peer.send(&d, "{\"future\":{\"x\":[1]},\"id\":\"q\",\"verb\":\"pane.set_title\"}"));
    try t.expectEqualStrings("q", r.id.?.string);
    try t.expectEqualStrings("denied.write", r.body.@"error".code);
    r = try expectOne(try peer.send(&d, "  {\"id\":9,\"verb\":\"echo\",\"params\":{\"text\":\"a\\nb\"}}  \r"));
    try t.expectEqualStrings("a\nb", r.body.ok.object.get("text").?.string);
    try t.expectEqual(@as(usize, 0), d.inflight());
    try t.expectEqual(@as(usize, 4), v.echo.calls);
}

test "dispatch: concurrent calls are matched by id and may finish out of order" {
    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{ .max_inflight = 3 });
    defer d.deinit();
    var peer = try Peer.init(true);
    defer peer.deinit();

    try t.expectEqual(@as(usize, 0), (try peer.send(&d, "{\"id\":1,\"verb\":\"later\",\"params\":{\"tag\":\"one\"}}")).len);
    try t.expectEqual(@as(usize, 0), (try peer.send(&d, "{\"id\":\"1\",\"verb\":\"later\",\"params\":{\"tag\":\"str\"}}")).len);
    // Same id while the first is in flight; integer 1 and string "1" differ.
    try expectError(try expectOne(try peer.send(&d, "{\"id\":1,\"verb\":\"echo\",\"params\":{\"text\":\"x\"}}")), 1, "protocol.duplicate_id");
    // A fast request overtakes the slow ones.
    var r = try expectOne(try peer.send(&d, "{\"id\":2,\"verb\":\"echo\",\"params\":{\"text\":\"fast\"}}"));
    try t.expectEqual(@as(i64, 2), r.id.?.integer);
    try t.expectEqual(@as(usize, 2), d.inflight());
    try t.expectEqual(@as(usize, 0), (try peer.send(&d, "{\"id\":3,\"verb\":\"later\"}")).len);
    r = try expectOne(try peer.send(&d, "{\"id\":4,\"verb\":\"later\"}"));
    try expectError(r, 4, "unavailable.busy");
    try t.expectEqual(@as(u8, 6), r.exitCode());

    // Finish in reverse order; each response carries its own id.
    const tickets = v.later.tickets.items;
    var i = tickets.len;
    while (i > 0) {
        i -= 1;
        const call = d.get(tickets[i]).?;
        const tag = if (call.params.object.get("tag")) |tag| tag.string else "none";
        try call.ok(tag);
        try t.expect(d.get(tickets[i]) == null);
    }
    const out = try peer.take();
    try t.expectEqual(@as(usize, 3), out.len);
    try t.expectEqual(@as(i64, 3), out[0].id.?.integer);
    try t.expectEqualStrings("none", out[0].body.ok.string);
    try t.expectEqualStrings("1", out[1].id.?.string);
    try t.expectEqualStrings("str", out[1].body.ok.string);
    try t.expectEqual(@as(i64, 1), out[2].id.?.integer);
    try t.expectEqualStrings("one", out[2].body.ok.string);
    try t.expectEqual(@as(usize, 0), d.inflight());
    // A finished id may be reused.
    r = try expectOne(try peer.send(&d, "{\"id\":1,\"verb\":\"echo\",\"params\":{\"text\":\"again\"}}"));
    try t.expect(r.body == .ok);
}

test "dispatch: streaming items precede one final response; cancel ends a stream" {
    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{});
    defer d.deinit();
    var peer = try Peer.init(true);
    defer peer.deinit();

    var out = try peer.send(&d, "{\"id\":1,\"verb\":\"count\",\"params\":{\"n\":3}}");
    try t.expectEqual(@as(usize, 4), out.len);
    for (out[0..3], 0..) |r, i| {
        try t.expect(!r.final());
        try t.expectEqual(@as(i64, @intCast(i)), r.body.item.object.get("i").?.integer);
    }
    try t.expect(out[3].final());
    try t.expectEqual(@as(i64, 3), out[3].body.ok.object.get("total").?.integer);
    try t.expectEqual(@as(usize, 1), (try peer.send(&d, "{\"id\":1,\"verb\":\"count\",\"params\":{\"n\":0}}")).len);

    // An open-ended stream, fed on later turns, then cancelled.
    try t.expectEqual(@as(usize, 0), (try peer.send(&d, "{\"id\":7,\"verb\":\"watch\"}")).len);
    const ticket = v.watch.tickets.items[0];
    try d.get(ticket).?.item(41);
    try d.get(ticket).?.item(42);
    out = try peer.take();
    try t.expectEqual(@as(usize, 2), out.len);
    try t.expectEqual(@as(i64, 42), out[1].body.item.integer);
    try t.expectError(error.NotStreaming, blk: {
        try t.expectEqual(@as(usize, 0), (try peer.send(&d, "{\"id\":9,\"verb\":\"later\"}")).len);
        break :blk d.get(v.later.tickets.items[0]).?.item(1);
    });
    try d.get(v.later.tickets.items[0]).?.ok("done");
    _ = try peer.take();

    out = try peer.send(&d, "{\"id\":8,\"verb\":\"cancel\",\"params\":{\"id\":7}}");
    try t.expectEqual(@as(usize, 2), out.len);
    try expectError(out[0], 7, "cancelled");
    try t.expectEqual(@as(u8, 8), out[0].exitCode());
    try t.expectEqual(@as(i64, 8), out[1].id.?.integer);
    try t.expect(out[1].body.ok == .null);
    try t.expect(d.get(ticket) == null);

    try expectError(try expectOne(try peer.send(&d, "{\"id\":8,\"verb\":\"cancel\",\"params\":{\"id\":7}}")), 8, "not_found.request");
    try expectError(try expectOne(try peer.send(&d, "{\"id\":8,\"verb\":\"cancel\",\"params\":{}}")), 8, "invalid_params.missing");
    try expectError(try expectOne(try peer.send(&d, "{\"id\":8,\"verb\":\"cancel\",\"params\":{\"id\":[]}}")), 8, "invalid_params.type");
    try expectError(try expectOne(try peer.send(&d, "{\"id\":8,\"verb\":\"cancel\",\"params\":{\"id\":7,\"x\":0}}")), 8, "invalid_params.unknown");

    // An item that does not match the schema ends the stream with internal.result.
    try t.expectEqual(@as(usize, 0), (try peer.send(&d, "{\"id\":10,\"verb\":\"watch\"}")).len);
    const t2 = v.watch.tickets.items[1];
    try t.expectError(error.InvalidResult, d.get(t2).?.item("not an integer"));
    try expectError(try expectOne(try peer.take()), 10, "internal.result");
    try t.expect(d.get(t2) == null);

    // Without the negotiated capability, cancel is refused.
    var plain = try Peer.init(false);
    defer plain.deinit();
    const r = try expectOne(try plain.send(&d, "{\"id\":1,\"verb\":\"cancel\",\"params\":{\"id\":7}}"));
    try expectError(r, 1, "unsupported.capability");
    try t.expectEqual(@as(u8, 10), r.exitCode());
    try t.expectEqual(@as(usize, 0), d.inflight());
}

test "dispatch: closing a connection drops its calls; cancelAll ends the rest" {
    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{});
    defer d.deinit();
    var one = try Peer.init(true);
    defer one.deinit();
    var two = try Peer.init(true);
    defer two.deinit();
    // The same id on two connections is not a duplicate.
    _ = try one.send(&d, "{\"id\":1,\"verb\":\"watch\"}");
    _ = try two.send(&d, "{\"id\":1,\"verb\":\"watch\"}");
    _ = try two.send(&d, "{\"id\":2,\"verb\":\"later\"}");
    try t.expectEqual(@as(usize, 3), d.inflight());
    d.closed(&one.conn);
    try t.expect(d.get(v.watch.tickets.items[0]) == null);
    try t.expect(d.get(v.watch.tickets.items[1]) != null);
    try t.expectEqual(@as(usize, 2), d.inflight());
    d.cancelAll();
    const out = try two.take();
    try t.expectEqual(@as(usize, 2), out.len);
    for (out) |r| {
        try t.expectEqualStrings("cancelled.shutdown", r.body.@"error".code);
        try t.expectEqual(@as(u8, 8), r.exitCode());
    }
    try t.expectEqual(@as(usize, 0), d.inflight());
    // A call left open is freed by deinit without leaking.
    _ = try two.send(&d, "{\"id\":3,\"verb\":\"later\"}");
}

test "dispatch: oversized results become internal.too_large and end the call" {
    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{});
    defer d.deinit();
    var peer = try Peer.init(true);
    defer peer.deinit();
    peer.conn.max_frame = 4096;
    _ = try peer.send(&d, "{\"id\":1,\"verb\":\"later\"}");
    const big = try a.alloc(u8, 5000);
    defer a.free(big);
    @memset(big, 'x');
    try t.expectError(error.TooLarge, d.get(v.later.tickets.items[0]).?.ok(big));
    try expectError(try expectOne(try peer.take()), 1, "internal.too_large");
    try t.expectEqual(@as(usize, 0), d.inflight());
}

// --- end to end through Server and Client ---

const identity: p.Identity = .{ .name = "venom-test", .version = "0" };

fn waitFor(server: *p.Server, client: *p.Client, gpa: std.mem.Allocator) !p.Response {
    const deadline = os.nowMs() + 2000;
    while (os.nowMs() < deadline) {
        try server.poll(0);
        if (try client.receive(1)) |msg| {
            const bytes = switch (msg) {
                .ndjson => |l| l,
                .frame => |f| f.payload,
            };
            return p.Response.parse(gpa, bytes);
        }
    }
    return error.TestTimeout;
}

test "dispatch: end to end over NDJSON and binary CONTROL, with pipelining and close" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer a.free(parent);
    try t.expectEqual(@as(c_int, 0), c.chmod(parent, 0o700));
    const path = try std.fmt.allocPrint(a, "{s}/d.sock", .{parent});
    defer a.free(path);

    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{});
    defer d.deinit();
    var server = try p.Server.init(a, .{ .hello = .{ .identity = identity, .caps = &.{"cancel"} }, .path = .{ .socket = path } }, d.handler());
    defer server.deinit();

    inline for (.{ p.Protocol.ndjson, p.Protocol.binary }) |protocol| {
        var client = try p.Client.init(a, .{ .tool = identity.name, .path = .{ .socket = path }, .protocol = protocol, .hello = .{ .identity = identity, .caps = &.{"cancel"} } });
        defer client.deinit();
        const deadline = os.nowMs() + 2000;
        while (!try client.pollHello(1)) {
            try server.poll(0);
            if (os.nowMs() > deadline) return error.TestTimeout;
        }
        try t.expect(client.connection.hasCap("cancel"));

        // Pipelined: a slow call, a fast call, a stream.
        try client.request(1, "later", .{});
        try client.request("two", "echo", .{ .text = "hi" });
        try client.request(3, "count", .{ .n = 2 });
        var r = try waitFor(&server, &client, a);
        try t.expectEqualStrings("two", r.id.?.string);
        try t.expectEqualStrings("hi", r.body.ok.object.get("text").?.string);
        r.deinit();
        for (0..3) |i| {
            r = try waitFor(&server, &client, a);
            defer r.deinit();
            try t.expectEqual(@as(i64, 3), r.id.?.integer);
            try t.expectEqual(i == 2, r.final());
        }
        // The slow call finishes on a later turn of the daemon loop.
        try d.get(v.later.tickets.getLast()).?.ok("late");
        r = try waitFor(&server, &client, a);
        try t.expectEqual(@as(i64, 1), r.id.?.integer);
        try t.expectEqualStrings("late", r.body.ok.string);
        r.deinit();

        // A stream left open is dropped when the client goes away.
        try client.request(4, "watch", .{});
        const until = os.nowMs() + 2000;
        while (d.inflight() == 0) {
            if (os.nowMs() > until) return error.TestTimeout;
            try client.connection.flush();
            try server.poll(1);
        }
    }
    for (0..20) |_| {
        if (server.connections.items.len == 0) break;
        try server.poll(1);
    }
    try t.expectEqual(@as(usize, 0), server.connections.items.len);
    try t.expectEqual(@as(usize, 0), d.inflight());
}

// --- fuzzing the NDJSON request parser and dispatcher ---

/// Feed `input`, split at newlines, to a dispatcher. Every line must produce
/// exactly one final response, every response line must be valid, nothing
/// may leak, and no call may stay in flight (all verbs here finish at once).
fn checkLines(_: void, input: []const u8) !void {
    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{});
    defer d.deinit();
    var peer = try Peer.init(true);
    defer peer.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        // `later` and `watch` wait for the test; skip them so every line finishes.
        if (std.mem.indexOf(u8, line, "later") != null or std.mem.indexOf(u8, line, "watch") != null) continue;
        try d.message(&peer.conn, .{ .ndjson = line });
        var finals: usize = 0;
        var it = std.mem.splitScalar(u8, peer.conn.output.items, '\n');
        while (it.next()) |out| {
            if (out.len == 0) continue;
            var r = p.Response.parse(a, out) catch |err| {
                std.debug.print("bad response {s} for {s}\n", .{ out, line });
                return err;
            };
            defer r.deinit();
            if (r.final()) finals += 1;
            if (r.body == .@"error") try t.expect(p.errors.knownCode(r.body.@"error".code));
        }
        peer.conn.output.clearRetainingCapacity();
        try t.expectEqual(@as(usize, 1), finals);
        try t.expectEqual(@as(usize, 0), d.inflight());
    }
}

const corpus = [_][]const u8{
    "{\"id\":1,\"verb\":\"echo\",\"params\":{\"text\":\"hi\",\"style\":\"upper\"}}",
    "{\"id\":\"x\",\"verb\":\"count\",\"params\":{\"n\":5}}\n{\"id\":2,\"verb\":\"ping\"}",
    "{\"id\":3,\"verb\":\"cancel\",\"params\":{\"id\":3}}",
    "{\"id\":4,\"verb\":\"bad\"}\n{\"id\":5,\"verb\":\"boom\"}\n{\"id\":6,\"verb\":\"pane.set_title\"}",
    "{\"id\":7,\"verb\":\"echo\",\"params\":{\"text\":\"\\u0000\\ud83d\\ude00\",\"x\":[[[[{}]]]]}}",
    "{\"id\":-9007199254740991,\"verb\":\"echo\",\"params\":{\"text\":\"busy\"}}",
    "{\"id\":1e3,\"verb\":\"ping\"}\n[\n{\n\"\n{\"id\":{},\"verb\":\"ping\"}\n{}}",
    "{\"id\":8,\"verb\":\"count\",\"params\":{\"n\":1e400}}\n{\"id\":8,\"verb\":\"count\",\"params\":{\"n\":-0}}",
};

test "dispatch: NDJSON corpus and random mutations never break the one-final-response rule" {
    for (corpus) |input| try checkLines({}, input);
    // Deterministic mutation pass so plain `zig build test` covers more than the corpus.
    var prng = std.Random.DefaultPrng.init(0x7e40_207);
    const rand = prng.random();
    const alphabet = "{}[]\",:\\0123456789-.eE\n ";
    var buf: [512]u8 = undefined;
    for (0..3000) |_| {
        const seed = corpus[rand.uintLessThan(usize, corpus.len)];
        const len = @min(seed.len, buf.len);
        @memcpy(buf[0..len], seed[0..len]);
        for (0..rand.uintAtMost(usize, 4)) |_| {
            const at = rand.uintLessThan(usize, len);
            buf[at] = switch (rand.uintLessThan(u8, 4)) {
                0 => rand.int(u8),
                1 => alphabet[rand.uintLessThan(usize, alphabet.len)],
                2 => '"',
                else => buf[rand.uintLessThan(usize, len)],
            };
        }
        try checkLines({}, buf[0..len]);
    }
}

fn fuzzOne(_: void, smith: *t.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    try checkLines({}, buf[0..n]);
}

test "dispatch: fuzz NDJSON requests" {
    try t.fuzz({}, fuzzOne, .{});
}

test "GR-01/06: deny before handler, explicit allow, none and live stream revocation" {
    var v: Verbs = .{};
    defer v.deinit();
    var d = try v.dispatcher(.{});
    defer d.deinit();
    var peer = try Peer.init(true);
    defer peer.deinit();
    var registry = try p.grants.Registry.init(a, "venom-test", .{});
    defer registry.deinit();
    peer.conn.registry = &registry;
    const denied = try expectOne(try peer.send(&d, "{\"id\":1,\"verb\":\"pane.set_title\"}"));
    try expectError(denied, 1, "denied.write");
    try t.expectEqual(@as(usize, 0), v.nop.calls);
    const issued = try registry.issueChild(.{ .principal = p.grants.owner }, .{ .grants = &.{.{ .right = .write, .scope = "*" }} }, p.grants.nowSeconds());
    defer a.free(issued.token);
    peer.conn.identity.principal = issued.principal;
    const allowed = try expectOne(try peer.send(&d, "{\"id\":2,\"verb\":\"pane.set_title\"}"));
    try t.expect(allowed.body == .ok);
    try t.expectEqual(@as(usize, 1), v.nop.calls);
    _ = try peer.send(&d, "{\"id\":3,\"verb\":\"watch\"}");
    try t.expectEqual(@as(usize, 1), d.inflight());
    try registry.revoke(.{ .principal = p.grants.owner }, issued.principal, p.grants.nowSeconds());
    try d.tick();
    try expectError(try expectOne(try peer.take()), 3, "denied.read");
    try t.expectEqual(@as(usize, 0), d.inflight());
    peer.conn.identity = .{};
    try registry.setPolicy(.{ .unknown = &.{} });
    // boom is none; its internal failure proves the ungated handler ran.
    try expectError(try expectOne(try peer.send(&d, "{\"id\":4,\"verb\":\"boom\"}")), 4, "internal");
}

const NamespaceEcho = struct {
    pub fn call(_: *NamespaceEcho, call_: *p.Call) anyerror!void {
        return call_.ok(.{ .text = call_.namespace() });
    }
};

test "grant.issue namespace, grant.list shows it, handlers see it" {
    const ns_model: S.Schema = .{ .tool = "venomx", .summary = "Namespace tests", .verbs = &.{.{ .name = "ns", .summary = "Caller namespace", .result = text_result, .grant = .none }} };
    var impl: NamespaceEcho = .{};
    var d = try p.Dispatcher.init(a, &ns_model, &.{.{ .verb = "ns", .handler = p.VerbHandler.init(&impl) }}, .{}, null);
    defer d.deinit();
    var peer = try Peer.init(false);
    defer peer.deinit();
    // Without a registry every caller is user.
    var r = try expectOne(try peer.send(&d, "{\"id\":1,\"verb\":\"ns\"}"));
    try t.expectEqualStrings("user", r.body.ok.object.get("text").?.string);
    var registry = try p.grants.Registry.init(a, "venomx", .{});
    defer registry.deinit();
    peer.conn.registry = &registry;
    peer.conn.identity.principal = p.grants.owner;
    r = try expectOne(try peer.send(&d, "{\"id\":2,\"verb\":\"ns\"}"));
    try t.expectEqualStrings("venomx", r.body.ok.object.get("text").?.string);
    try expectError(try expectOne(try peer.send(&d, "{\"id\":3,\"verb\":\"grant.issue\",\"params\":{\"grants\":[],\"namespace\":\"venomx\"}}")), 3, "denied.namespace");
    try expectError(try expectOne(try peer.send(&d, "{\"id\":4,\"verb\":\"grant.issue\",\"params\":{\"grants\":[],\"namespace\":\"Venom\"}}")), 4, "invalid_params.namespace");
    r = try expectOne(try peer.send(&d, "{\"id\":5,\"verb\":\"grant.issue\",\"params\":{\"grants\":[{\"right\":\"spawn\",\"scope\":\"*\"}],\"namespace\":\"venom\"}}"));
    const venom = p.grants.parseId(r.body.ok.object.get("principal").?.string).?;
    _ = try expectOne(try peer.send(&d, "{\"id\":6,\"verb\":\"grant.issue\",\"params\":{\"grants\":[]}}"));
    r = try expectOne(try peer.send(&d, "{\"id\":7,\"verb\":\"grant.list\"}"));
    const listed = r.body.ok.object.get("principals").?.array.items;
    try t.expectEqual(@as(usize, 3), listed.len);
    const expected = [_][]const u8{ "venomx", "venom", "user" };
    for (listed, expected) |entry, ns| try t.expectEqualStrings(ns, entry.object.get("namespace").?.string);
    peer.conn.identity.principal = venom;
    r = try expectOne(try peer.send(&d, "{\"id\":8,\"verb\":\"ns\"}"));
    try t.expectEqualStrings("venom", r.body.ok.object.get("text").?.string);
    r = try expectOne(try peer.send(&d, "{\"id\":9,\"verb\":\"whoami\"}"));
    try t.expectEqualStrings("venom", r.body.ok.object.get("namespace").?.string);
    try expectError(try expectOne(try peer.send(&d, "{\"id\":10,\"verb\":\"grant.issue\",\"params\":{\"grants\":[],\"namespace\":\"venom-os\"}}")), 10, "denied.namespace");
    r = try expectOne(try peer.send(&d, "{\"id\":11,\"verb\":\"grant.issue\",\"params\":{\"grants\":[]}}"));
    try t.expectEqualStrings("venom", registry.namespaceOf(p.grants.parseId(r.body.ok.object.get("principal").?.string).?));
}

test "grant.issue with pid binds with no token, and refuses other callers" {
    const bind_model: S.Schema = .{ .tool = "venom", .summary = "Bind tests", .verbs = &.{} };
    var d = try p.Dispatcher.init(a, &bind_model, &.{}, .{}, null);
    defer d.deinit();
    var peer = try Peer.init(false);
    defer peer.deinit();
    var registry = try p.grants.Registry.init(a, "venom", .{});
    defer registry.deinit();
    peer.conn.registry = &registry;
    const parent = std.c.getppid();
    var line_buf: [256]u8 = undefined;
    const issue = try std.fmt.bufPrint(&line_buf, "{{\"id\":1,\"verb\":\"grant.issue\",\"params\":{{\"grants\":[],\"pid\":{d},\"label\":\"p\"}}}}", .{parent});

    // A token with `spawn` and no `admin` may not, whatever the pid.
    const spawner = try registry.issueChild(.{ .principal = p.grants.owner }, .{ .grants = &.{.{ .right = .spawn, .scope = "*" }} }, p.grants.nowSeconds());
    defer a.free(spawner.token);
    peer.conn.identity.principal = spawner.principal;
    try expectError(try expectOne(try peer.send(&d, issue)), 1, "denied.bind");
    try expectError(try expectOne(try peer.send(&d, "{\"id\":1,\"verb\":\"grant.issue\",\"params\":{\"grants\":[],\"pid\":2147483647}}")), 1, "denied.bind");

    peer.conn.identity.principal = p.grants.owner;
    try expectError(try expectOne(try peer.send(&d, "{\"id\":1,\"verb\":\"grant.issue\",\"params\":{\"grants\":[],\"pid\":2147483647}}")), 1, "not_found.process");
    var self_buf: [128]u8 = undefined;
    try expectError(try expectOne(try peer.send(&d, try std.fmt.bufPrint(&self_buf, "{{\"id\":1,\"verb\":\"grant.issue\",\"params\":{{\"grants\":[],\"pid\":{d}}}}}", .{std.c.getpid()}))), 1, "invalid_params.pid");

    const r = try expectOne(try peer.send(&d, issue));
    try t.expect(r.body.ok.object.get("token") == null);
    try t.expect(r.body.ok.object.get("expires").? == .null);
    try t.expect(std.mem.startsWith(u8, r.body.ok.object.get("principal").?.string, "g"));
    try expectError(try expectOne(try peer.send(&d, issue)), 1, "conflict.process_bound");
}
