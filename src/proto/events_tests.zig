const std = @import("std");
const e = @import("events.zig");
const p = @import("root.zig");
const os = @import("os.zig");
const a = std.testing.allocator;
const t = std.testing;
// Normalize the same static declaration as cli, without depending on cli.
const str: p.schema.Type = .{ .kind = .string };
const obj: p.schema.Type = .{ .kind = .object, .fields = &.{} };
const strings: p.schema.Type = .{ .kind = .array, .items = &str };
const entity: p.schema.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "resource", .summary = "Resource", .type = str, .required = true },
    .{ .name = "entity_type", .summary = "Type", .type = str, .required = true },
    .{ .name = "content", .summary = "Content", .type = str, .required = true },
} };
const data: p.schema.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "reason", .summary = "Reason", .type = str },
    .{ .name = "entities", .summary = "Entities", .type = .{ .kind = .array, .items = &entity } },
    .{ .name = "complete", .summary = "Complete", .type = .{ .kind = .boolean } },
    .{ .name = "restart_required", .summary = "Restart", .type = .{ .kind = .boolean } },
} };
const model: p.schema.Schema = .{ .tool = "venom-test", .summary = "Events tests", .verbs = &.{.{
    .name = "events",
    .summary = "Events",
    .grant = .read,
    .streams = true,
    .params = &.{
        .{ .name = "after", .summary = "Cursor", .type = str, .default = "\"\"" },
        .{ .name = "types", .summary = "Types", .type = strings, .default = "[]" },
        .{ .name = "resources", .summary = "Resources", .type = strings, .default = "[]" },
        .{ .name = "follow", .summary = "Follow", .type = .{ .kind = .boolean }, .default = "false" },
    },
    .result = obj,
    .item = .{ .kind = .object, .fields = &.{
        .{ .name = "seq", .summary = "Seq", .type = .{ .kind = .integer }, .required = true },
        .{ .name = "ts", .summary = "Timestamp", .type = str, .required = true },
        .{ .name = "source", .summary = "Source", .type = str, .required = true },
        .{ .name = "type", .summary = "Type", .type = str, .required = true },
        .{ .name = "data", .summary = "Data", .type = data, .required = true },
    } },
}} };
fn connection() p.Connection {
    var c = p.Connection.init(a, -1);
    c.protocol = .ndjson;
    c.ready = true;
    return c;
}
fn dispatcher(log: *e.Log) !p.Dispatcher {
    return p.Dispatcher.init(a, &model, &.{.{ .verb = "events", .handler = p.VerbHandler.init(log) }}, .{}, null);
}
fn request(d: *p.Dispatcher, c: *p.Connection, params: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .id = 1, .verb = "events", .params = params }, .{});
    defer a.free(bytes);
    try d.message(c, .{ .ndjson = bytes });
}
fn has(c: *p.Connection, text: []const u8) !void {
    if (std.mem.indexOf(u8, c.output.items, text) == null) {
        std.debug.print("missing {s} in {s}\n", .{ text, c.output.items });
        return error.TestUnexpectedResult;
    }
}
fn cursor(log: *e.Log, seq: u64) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ log.source, seq });
}

test "events: exclusive replay then live, filters preserve sequence, cancellation prunes tickets" {
    var log = try e.Log.init(a, "venom-test", .{}, null);
    defer log.deinit();
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    try log.append("config:root", "config.reloaded", .{ .restart_required = false });
    var d = try dispatcher(&log);
    defer d.deinit();
    var c = connection();
    defer c.deinit();
    const after = try cursor(&log, 1);
    defer a.free(after);
    try request(&d, &c, .{ .after = after, .follow = true, .types = .{"config.*"} });
    try has(&c, "config.reloaded");
    try t.expect(std.mem.indexOf(u8, c.output.items, "config.changed") == null);
    try has(&c, "stream.checkpoint");
    c.output.clearRetainingCapacity();
    try log.append("config:root", "config.changed", .{ .restart_required = true });
    try log.tick();
    try has(&c, "\"seq\":3");
    try has(&c, "config.changed");
    d.closed(&c);
    try log.tick();
    try t.expectEqual(0, log.subscriptions.items.len);
}
test "events: initial, expired and foreign-source snapshots; invalid and future cursors" {
    var log = try e.Log.init(a, "venom-test", .{ .count = 1 }, null);
    defer log.deinit();
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    try log.append("config:root", "config.changed", .{ .restart_required = true });
    var d = try dispatcher(&log);
    defer d.deinit();
    var c = connection();
    defer c.deinit();
    try request(&d, &c, struct {}{});
    try has(&c, "\"reason\":\"initial\"");
    try has(&c, "\"ok\":{}");
    const old = try cursor(&log, 0);
    defer a.free(old);
    try request(&d, &c, .{ .after = old });
    try has(&c, "\"reason\":\"expired\"");
    try request(&d, &c, .{ .after = "other/01234567-89ab-4cde-8fab-0123456789ab:0" });
    try has(&c, "source_changed");
    const future = try cursor(&log, 3);
    defer a.free(future);
    try request(&d, &c, .{ .after = future });
    try has(&c, "invalid_params.event_cursor");
    try request(&d, &c, .{ .types = .{"bad*"} });
    try has(&c, "invalid_params.event_filter");
    try request(&d, &c, .{ .resources = .{"pane:*:p1"} });
    try has(&c, "\"param\":\"resources\"");
}
test "events: retention age and bytes, oversized event evicts through its position" {
    var log = try e.Log.init(a, "venom-test", .{}, null);
    defer log.deinit();
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    log.trim(os.nowMs() + 600_001);
    try t.expectEqual(2, log.low());
    log.limits.bytes = 1;
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    try t.expectEqual(3, log.low());
    try t.expectEqual(0, log.used);
}
test "events: follower fails on retention gap and disconnects on backpressure" {
    var log = try e.Log.init(a, "venom-test", .{ .count = 1 }, null);
    defer log.deinit();
    var d = try dispatcher(&log);
    defer d.deinit();
    var c = connection();
    defer c.deinit();
    try request(&d, &c, .{ .follow = true });
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    try log.append("config:root", "config.changed", .{ .restart_required = true });
    try log.tick();
    try has(&c, "unavailable.event_gap");
    try request(&d, &c, .{ .follow = true });
    c.output_limit = c.output.items.len;
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    try log.tick();
    try t.expect(c.closing);
    try t.expectEqual(0, d.calls.count());
}
test "events: selector and cursor syntax" {
    try t.expect(e.matchesType("pane.*", "pane.created"));
    try t.expect(!e.matchesType("pane.*", "panes.created"));
    try t.expect(!e.matchesType("pane.*", "pane"));
    for ([_][]const u8{ "", "p*", "pane..*", "Pane.*" }) |v| try t.expect(!e.validSelector(v));
    for ([_][]const u8{ "p:", "p:a:b", "p:a\n", "p:a\u{85}", "P:a" }) |v| try t.expect(!e.validResource(v));
    for ([_][]const u8{ "tool/01234567-89ab-4cde-8fab-0123456789ab:01", "tool/01234567-89ab-4cde-8fab-0123456789ab:+1", "tool/01234567-89ab-4cde-8fab-0123456789ab:9007199254740992" }) |v| try t.expectError(error.InvalidCursor, e.parseCursor(v));
}

const View = struct {
    entities: []const e.Entity,
    pub fn capture(self: *View, alloc: std.mem.Allocator) anyerror![]const e.Entity {
        return alloc.dupe(e.Entity, self.entities);
    }
};
test "events: snapshot filters, chunking, oversized entity and bounded view" {
    var view: View = .{ .entities = &.{
        .{ .resource = "config:root", .entity_type = "config", .content = "{\"value\":\"redacted\"}", .event_types = &.{"config.changed"} },
        .{ .resource = "pane:p1", .entity_type = "pane", .content = "{\"pane\":\"p1\"}", .event_types = &.{"pane.created"} },
    } };
    var log = try e.Log.init(a, "venom-test", .{}, e.Snapshot.init(&view));
    defer log.deinit();
    var d = try dispatcher(&log);
    defer d.deinit();
    var c = connection();
    defer c.deinit();
    try request(&d, &c, .{ .types = .{"config.*"} });
    try has(&c, "redacted");
    try t.expect(std.mem.indexOf(u8, c.output.items, "pane:p1") == null);
    c.output.clearRetainingCapacity();
    c.max_frame = 335;
    try request(&d, &c, struct {}{});
    try has(&c, "\"complete\":false");
    try has(&c, "\"complete\":true");
    try has(&c, "stream.checkpoint");
    c.output.clearRetainingCapacity();
    c.max_frame = 200;
    try request(&d, &c, struct {}{});
    try has(&c, "unsupported.event_size");
    c.output.clearRetainingCapacity();
    c.max_frame = p.default_max_frame;
    log.limits.snapshot_bytes = 1;
    try request(&d, &c, struct {}{});
    try has(&c, "unavailable.event_gap");
}
test "events: read scopes apply to replay and snapshot; policy reload invalidates followers" {
    var view: View = .{ .entities = &.{
        .{ .resource = "config:root", .entity_type = "config", .content = "{}", .event_types = &.{"config.changed"} },
        .{ .resource = "pane:p1", .entity_type = "pane", .content = "{}", .event_types = &.{"pane.created"} },
    } };
    var log = try e.Log.init(a, "venom-test", .{}, e.Snapshot.init(&view));
    defer log.deinit();
    var reg = try p.grants.Registry.init(a, "venom-test", .{ .unknown = &.{.{ .right = .read, .scope = "config:root" }} });
    defer reg.deinit();
    var d = try dispatcher(&log);
    defer d.deinit();
    var c = connection();
    defer c.deinit();
    c.registry = &reg;
    try request(&d, &c, .{ .resources = .{"pane:p1"} });
    try has(&c, "denied.event_scope");
    try t.expect(std.mem.indexOf(u8, c.output.items, "state.snapshot") == null);
    c.output.clearRetainingCapacity();
    try request(&d, &c, .{ .follow = true });
    try has(&c, "config:root");
    try t.expect(std.mem.indexOf(u8, c.output.items, "pane:p1") == null);
    try reg.setPolicy(.{ .unknown = &.{.{ .right = .read, .scope = "pane:p1" }} });
    try log.tick();
    try has(&c, "denied.event_scope");
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    c.output.clearRetainingCapacity();
    const after = try cursor(&log, 0);
    defer a.free(after);
    try request(&d, &c, .{ .after = after });
    try has(&c, "stream.checkpoint");
    try t.expect(std.mem.indexOf(u8, c.output.items, "config.changed") == null);
}
test "events: catalog rejects missing, forbidden, mismatched and unknown data before committing" {
    var log = try e.Log.init(a, "venom-test", .{}, null);
    defer log.deinit();
    try t.expectError(error.InvalidEvent, log.append("config:root", "config.changed", struct {}{}));
    try t.expectError(error.InvalidEvent, log.append("config:root", "config.changed", .{ .restart_required = false, .secret = "no" }));
    try t.expectError(error.InvalidEvent, log.append("pane:p1", "pane.removed", .{ .pane = "p2" }));
    try t.expectError(error.InvalidEvent, log.append("config:other", "config.changed", .{ .restart_required = false }));
    try t.expectError(error.InvalidEvent, log.append("pane:p1", "unknown.event", struct {}{}));
    try t.expectEqual(0, log.high);
    try t.expectEqual(0, log.used);
}

test "events: command.started takes an optional cmdline string" {
    var log = try e.Log.init(a, "venom-test", .{}, null);
    defer log.deinit();
    try log.append("pane:p1", "command.started", .{ .pane = "p1", .command = "p1/c0" });
    try log.append("pane:p1", "command.started", .{ .pane = "p1", .command = "p1/c1", .cmdline = "ping google.com" });
    try t.expectError(error.InvalidEvent, log.append("pane:p1", "command.started", .{ .pane = "p1", .command = "p1/c2", .cmdline = 7 }));
    try t.expectError(error.InvalidEvent, log.append("pane:p1", "command.finished", .{ .pane = "p1", .command = "p1/c1", .reason = "osc133", .cmdline = "x" }));
    try t.expectEqual(2, log.high);
}

test "events: only pane-kind events must name their own pane; others may reference one" {
    const s = @import("schema.zig");
    const pane: s.Field = .{ .name = "pane", .summary = "pane", .type = .{ .kind = .string }, .required = true };
    const run: s.Field = .{ .name = "run", .summary = "run", .type = .{ .kind = .string }, .required = true };
    const catalog = e.catalog.entries ++ [_]e.catalog.Entry{.{ .name = "run.started", .resource_kind = "run", .fields = &.{ run, pane } }};
    var log = try e.Log.init(a, "venom-test", .{}, null);
    defer log.deinit();
    log.catalog = &catalog;
    try t.expectError(error.InvalidEvent, log.append("pane:p1", "pane.removed", .{ .pane = "p2" }));
    try log.append("run:r0", "run.started", .{ .run = "r0", .pane = "p2" });
    try t.expectEqual(1, log.high);
}

test "events: safe integer exhaustion rotates epoch, invalidates followers and recovers old cursors" {
    var log = try e.Log.init(a, "venom-test", .{}, null);
    defer log.deinit();
    log.high = e.max_seq;
    const old = try cursor(&log, e.max_seq);
    defer a.free(old);
    var d = try dispatcher(&log);
    defer d.deinit();
    var c = connection();
    defer c.deinit();
    try request(&d, &c, .{ .after = old, .follow = true });
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    try t.expectEqual(1, log.high);
    try t.expect(!std.mem.startsWith(u8, old, log.source));
    try log.tick();
    try has(&c, "unavailable.event_gap");
    c.output.clearRetainingCapacity();
    try request(&d, &c, .{ .after = old });
    try has(&c, "source_changed");
}
test "events: oversized log delivery is an event size error, not a silent omission" {
    var log = try e.Log.init(a, "venom-test", .{}, null);
    defer log.deinit();
    try log.append("config:root", "config.changed", .{ .restart_required = false });
    var d = try dispatcher(&log);
    defer d.deinit();
    var c = connection();
    defer c.deinit();
    c.max_frame = 160;
    const after = try cursor(&log, 0);
    defer a.free(after);
    try request(&d, &c, .{ .after = after });
    try has(&c, "unsupported.event_size");
    try t.expect(std.mem.indexOf(u8, c.output.items, "stream.checkpoint") == null);
    try t.expectEqual(0, d.calls.count());
}

test "events: readers tolerate future fields and types, preserving required field validation" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"seq":1,"ts":"2026-11-06T00:00:00.000Z","source":"venom-test/01234567-89ab-4cde-8fab-0123456789ab","type":"future.event","future":true,"data":{"future":{"any":42},"entities":[{"resource":"config:root","entity_type":"config","content":"{}","future":true}]}}
    , .{});
    try t.expect(try e.validateItem(alloc, model.verbs[0].item.?, value) == null);
    try t.expect(value.object.contains("future"));
    var bad = value;
    try bad.object.put(alloc, "seq", .{ .string = "1" });
    try t.expect(try e.validateItem(alloc, model.verbs[0].item.?, bad) != null);
}

test "events: prepared append abort and commit preserve sequence and rotation" {
    var log = try e.Log.init(a, "events-test", .{}, null);
    defer log.deinit();
    const aborted = try log.prepare("config:root", "config.changed", .{ .restart_required = false });
    aborted.abort();
    try t.expectEqual(@as(u64, 0), log.high);
    try t.expectEqual(@as(usize, 0), log.entries.items.len);
    const committed = try log.prepare("config:root", "config.changed", .{ .restart_required = true });
    committed.commit();
    try t.expectEqual(@as(u64, 1), log.high);
    log.high = e.max_seq;
    const source = try a.dupe(u8, log.source);
    defer a.free(source);
    const rotation = try log.prepare("config:root", "config.reloaded", .{ .restart_required = false });
    rotation.abort();
    try t.expectEqualStrings(source, log.source);
    try t.expectEqual(e.max_seq, log.high);
    (try log.prepare("config:root", "config.reloaded", .{ .restart_required = false })).commit();
    try t.expectEqual(@as(u64, 1), log.high);
    try t.expect(!std.mem.eql(u8, source, log.source));
}
test "events: principal:<id> reaches only the principal, its ancestors and admin on live, replay, recover and scope" {
    const g = p.grants;
    const s = @import("schema.zig");
    const reason: s.Field = .{ .name = "reason", .summary = "reason", .type = .{ .kind = .string }, .required = true };
    const catalog = e.catalog.entries ++ [_]e.catalog.Entry{.{ .name = "principal.created", .resource_kind = "principal", .fields = &.{reason} }};
    var reg = try g.Registry.init(a, "venom-test", .{});
    defer reg.deinit();
    const now = g.nowSeconds();
    const read_all = [_]g.Grant{.{ .right = .read, .scope = "*" }};
    const ids = struct {
        fn issue(r: *g.Registry, caller: g.Id, gs: []const g.Grant, at: i64) !g.Id {
            const issued = try r.issueChild(.{ .principal = caller }, .{ .grants = gs }, at);
            a.free(issued.token);
            return issued.principal;
        }
    };
    const parent = try ids.issue(&reg, g.owner, &.{ .{ .right = .spawn, .scope = "*" }, .{ .right = .read, .scope = "*" } }, now);
    const target = try ids.issue(&reg, parent, &read_all, now);
    const sibling = try ids.issue(&reg, parent, &read_all, now);
    const admin = try ids.issue(&reg, g.owner, &.{.{ .right = .admin, .scope = "*" }}, now);
    var buf: [24]u8 = undefined;
    const resource = try std.fmt.allocPrint(a, "principal:{s}", .{g.name(target, &buf)});
    defer a.free(resource);
    // Snapshot entities for recover: the target, and an unparseable ID that only admin sees.
    var view: View = .{ .entities = &.{} };
    const entities = [_]e.Entity{
        .{ .resource = resource, .entity_type = "principal", .content = "recover-marker", .event_types = &.{"principal.created"} },
        .{ .resource = "principal:bogus", .entity_type = "principal", .content = "bogus-recover-marker", .event_types = &.{"principal.created"} },
    };
    view.entities = &entities;
    var log = try e.Log.init(a, "venom-test", .{}, e.Snapshot.init(&view));
    defer log.deinit();
    log.catalog = &catalog;
    try log.append(resource, "principal.created", .{ .reason = "replay-marker" });
    try log.append("principal:bogus", "principal.created", .{ .reason = "bogus-replay-marker" });
    var d = try dispatcher(&log);
    defer d.deinit();

    const Case = struct { who: g.Id, sees: bool };
    const cases = [_]Case{
        .{ .who = sibling, .sees = false },
        .{ .who = target, .sees = true },
        .{ .who = parent, .sees = true },
        .{ .who = admin, .sees = true },
    };
    var conns: [cases.len]p.Connection = undefined;
    for (&conns, cases) |*c, case| {
        c.* = connection();
        c.registry = &reg;
        c.identity = .{ .principal = case.who };
    }
    defer for (&conns) |*c| {
        d.closed(c);
        c.deinit();
    };
    const zero = try cursor(&log, 0);
    defer a.free(zero);
    const high = try cursor(&log, log.high);
    defer a.free(high);
    for (&conns, cases) |*c, case| {
        const admin_only = case.who == admin;
        // replay
        try request(&d, c, .{ .after = zero });
        try has(c, "stream.checkpoint");
        try t.expectEqual(case.sees, std.mem.indexOf(u8, c.output.items, "\"replay-marker") != null);
        try t.expectEqual(admin_only, std.mem.indexOf(u8, c.output.items, "bogus-replay-marker") != null);
        c.output.clearRetainingCapacity();
        // recover
        try request(&d, c, struct {}{});
        try has(c, "state.snapshot");
        try t.expectEqual(case.sees, std.mem.indexOf(u8, c.output.items, "\"recover-marker") != null);
        try t.expectEqual(admin_only, std.mem.indexOf(u8, c.output.items, "bogus-recover-marker") != null);
        c.output.clearRetainingCapacity();
        // scope: naming the resource is denied outright to callers who may not see it
        try request(&d, c, .{ .after = zero, .resources = .{resource} });
        try t.expectEqual(!case.sees, std.mem.indexOf(u8, c.output.items, "denied.event_scope") != null);
        try t.expectEqual(case.sees, std.mem.indexOf(u8, c.output.items, "\"replay-marker") != null);
        c.output.clearRetainingCapacity();
        try request(&d, c, .{ .after = zero, .resources = .{"principal:bogus"} });
        try t.expectEqual(!admin_only, std.mem.indexOf(u8, c.output.items, "denied.event_scope") != null);
        c.output.clearRetainingCapacity();
        // live: follow from the current watermark
        try request(&d, c, .{ .after = high, .follow = true });
        c.output.clearRetainingCapacity();
    }
    try log.append(resource, "principal.created", .{ .reason = "live-marker" });
    try log.append("principal:bogus", "principal.created", .{ .reason = "bogus-live-marker" });
    try log.tick();
    for (&conns, cases) |*c, case| {
        try t.expectEqual(case.sees, std.mem.indexOf(u8, c.output.items, "\"live-marker") != null);
        try t.expectEqual(case.who == admin, std.mem.indexOf(u8, c.output.items, "bogus-live-marker") != null);
        try t.expect(std.mem.indexOf(u8, c.output.items, "event_scope") == null);
    }
}
