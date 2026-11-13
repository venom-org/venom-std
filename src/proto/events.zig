//! The event log. All methods run on the daemon reactor thread. Products
//! serialize state commit + append on that thread, and provide a consistent
//! snapshot view. No I/O or callbacks may re-enter the log during recovery.
const std = @import("std");
const os = @import("os.zig");
const d = @import("dispatch.zig");
const g = @import("grants.zig");
const s = @import("schema.zig");
const iface = @import("iface");
const Value = std.json.Value;
pub const catalog = @import("event_catalog.zig");
extern "c" fn getentropy(*anyopaque, usize) c_int;
pub const manifest = @import("events_manifest.zon");
pub const max_seq: u64 = 9007199254740991;
pub const Limits = struct {
    age_ms: i64 = 600_000,
    count: usize = 10_000,
    bytes: usize = 16 * 1024 * 1024,
    snapshot_bytes: usize = 8 * 1024 * 1024,
};
/// Product-owned current entity; event_types names all log types selecting it.
/// Snapshot callback allocates its view in the supplied bounded allocator.
pub const Entity = struct {
    resource: []const u8,
    entity_type: []const u8,
    content: []const u8,
    event_types: []const []const u8,
};
pub const Snapshot = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { capture: *const fn (*anyopaque, std.mem.Allocator) anyerror![]const Entity };
    pub fn init(impl: anytype) Snapshot {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .capture = capture };
            fn capture(ptr: *anyopaque, a: std.mem.Allocator) anyerror![]const Entity {
                return iface.cast(T, ptr).capture(a);
            }
        }.vt };
    }
};
const Entry = struct { seq: u64, at: i64, bytes: []u8, resource: []u8, type: []u8 };
const Subscription = struct { dispatcher: *d.Dispatcher, ticket: d.Ticket, seq: u64, checkpoint_at: i64, policy_revision: u64, generation: u64 };
pub const Log = struct {
    gpa: std.mem.Allocator,
    source: []u8,
    limits: Limits,
    snapshot: ?Snapshot,
    catalog: []const catalog.Entry = &catalog.entries,
    entries: std.ArrayList(Entry) = .empty,
    head: usize = 0,
    used: usize = 0,
    high: u64 = 0,
    generation: u64 = 0,
    subscriptions: std.ArrayList(Subscription) = .empty,

    pub fn init(a: std.mem.Allocator, tool: []const u8, limits: Limits, snapshot: ?Snapshot) !Log {
        if (!s.validToolName(tool) or limits.age_ms < 0) return error.InvalidOptions;
        return .{ .gpa = a, .source = try newSource(a, tool), .limits = limits, .snapshot = snapshot };
    }
    pub fn deinit(self: *Log) void {
        while (self.head < self.entries.items.len) self.evict();
        self.entries.deinit(self.gpa);
        self.subscriptions.deinit(self.gpa);
        self.gpa.free(self.source);
    }
    fn evict(self: *Log) void {
        const e = self.entries.items[self.head];
        self.used -= e.bytes.len;
        self.gpa.free(e.bytes);
        self.gpa.free(e.resource);
        self.gpa.free(e.type);
        self.head += 1;
    }
    pub fn trim(self: *Log, now: i64) void {
        while (self.head < self.entries.items.len) {
            const e = self.entries.items[self.head];
            if (self.entries.items.len - self.head <= self.limits.count and self.used <= self.limits.bytes and now - e.at < self.limits.age_ms) break;
            self.evict();
        }
        if (self.head > 0 and self.head * 2 >= self.entries.items.len) {
            const n = self.entries.items.len - self.head;
            std.mem.copyForwards(Entry, self.entries.items[0..n], self.entries.items[self.head..]);
            self.entries.items.len = n;
            self.head = 0;
        }
    }
    pub fn low(self: *const Log) u64 {
        return if (self.head < self.entries.items.len) self.entries.items[self.head].seq else self.high + 1;
    }
    /// Include in the product's doctor result.
    pub fn status(self: *Log) struct { source: []const u8, low: u64, high: u64, bytes: usize, limits: Limits } {
        self.trim(os.nowMs());
        return .{ .source = self.source, .low = self.low(), .high = self.high, .bytes = self.used, .limits = self.limits };
    }
    /// Allocates a reversible event before a fallible external state commit.
    /// Until commit/abort, do not append, tick, trim or reenter this log.
    pub const Prepared = struct {
        log: *Log,
        entry: Entry,
        source: ?[]u8,
        expected_high: u64,
        pub fn abort(self: Prepared) void {
            self.log.gpa.free(self.entry.bytes);
            self.log.gpa.free(self.entry.resource);
            self.log.gpa.free(self.entry.type);
            if (self.source) |source| self.log.gpa.free(source);
        }
        pub fn commit(self: Prepared) void {
            const log = self.log;
            std.debug.assert(log.high == self.expected_high);
            std.debug.assert(self.entry.seq == (if (self.source != null) @as(u64, 1) else log.high + 1));
            if (self.source) |source| {
                while (log.head < log.entries.items.len) log.evict();
                log.entries.clearRetainingCapacity();
                log.head = 0;
                log.gpa.free(log.source);
                log.source = source;
                log.generation += 1;
            }
            log.entries.appendAssumeCapacity(self.entry);
            log.high = self.entry.seq;
            log.used += self.entry.bytes.len;
            log.trim(os.nowMs());
        }
    };
    pub fn append(self: *Log, resource: []const u8, kind: []const u8, data: anytype) !void {
        const prepared = try self.prepare(resource, kind, data);
        prepared.commit();
    }
    pub fn prepare(self: *Log, resource: []const u8, kind: []const u8, data: anytype) !Prepared {
        const rotating = self.high == max_seq;
        const source = if (rotating) try newSource(self.gpa, self.source[0..std.mem.indexOfScalar(u8, self.source, '/').?]) else self.source;
        errdefer if (rotating) self.gpa.free(source);
        const next = if (rotating) 1 else self.high + 1;
        if (!validResource(resource) or !s.validVerbName(kind) or std.mem.eql(u8, kind, "state.snapshot") or std.mem.eql(u8, kind, "stream.checkpoint")) return error.InvalidEvent;
        var stamp: [32]u8 = undefined;
        const bytes = try std.json.Stringify.valueAlloc(self.gpa, .{ .seq = next, .ts = try timestamp(&stamp), .source = source, .type = kind, .data = data }, .{ .emit_null_optional_fields = false });
        errdefer self.gpa.free(bytes);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const value = try std.json.parseFromSliceLeaky(Value, alloc, bytes, .{});
        var payload = value.object.get("data").?;
        const colon = std.mem.indexOfScalar(u8, resource, ':').?;
        for (self.catalog) |entry| {
            if (!std.mem.eql(u8, kind, entry.name)) continue;
            if (!std.mem.eql(u8, resource[0..colon], entry.resource_kind)) return error.InvalidEvent;
            var path: s.Path = .{ .gpa = alloc };
            if (try s.validateValue(alloc, .{ .kind = .object, .fields = entry.fields }, &payload, &path, false) != null) return error.InvalidEvent;
            // A pane event names its own pane; other kinds (e.g. a venom
            // `run:<id>`) may carry a `pane` reference to another resource.
            if (std.mem.eql(u8, entry.resource_kind, "pane")) if (payload.object.get("pane")) |pane| if (!std.mem.eql(u8, pane.string, resource[colon + 1 ..])) return error.InvalidEvent;
            if (std.mem.eql(u8, entry.resource_kind, "config") and !std.mem.eql(u8, resource, "config:root")) return error.InvalidEvent;
            break;
        } else return error.InvalidEvent;
        const r = try self.gpa.dupe(u8, resource);
        errdefer self.gpa.free(r);
        const t = try self.gpa.dupe(u8, kind);
        errdefer self.gpa.free(t);
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        return .{ .log = self, .entry = .{ .seq = next, .at = os.nowMs(), .bytes = bytes, .resource = r, .type = t }, .source = if (rotating) source else null, .expected_high = self.high };
    }
    pub fn call(self: *Log, c: *d.Call) anyerror!void {
        self.trim(os.nowMs());
        const types = c.params.object.get("types").?.array.items;
        const resources = c.params.object.get("resources").?.array.items;
        for (types) |v| if (!validSelector(v.string)) return c.fail("invalid_params.event_filter", "invalid type selector", .{ .param = "types" });
        for (resources) |v| if (!validResource(v.string)) return c.fail("invalid_params.event_filter", "invalid resource selector", .{ .param = "resources" });
        if (!scope(c)) return c.fail("denied.event_scope", "event scope denied", struct {}{});
        const after = c.params.object.get("after").?.string;
        var reason: ?[]const u8 = null;
        var seq: u64 = 0;
        if (after.len == 0) {
            reason = "initial";
        } else {
            const cursor = parseCursor(after) catch return c.fail("invalid_params.event_cursor", "invalid cursor", .{ .param = "after" });
            seq = cursor.seq;
            if (!std.mem.eql(u8, cursor.source, self.source)) reason = "source_changed" else if (seq > self.high) return c.fail("invalid_params.event_cursor", "cursor exceeds watermark", .{ .param = "after" }) else if (seq < self.low() - 1) reason = "expired";
        }
        // Reserve before emitting anything; no snapshot/live registration race
        // because capture and replay execute synchronously on the reactor.
        const follow = c.params.object.get("follow").?.bool;
        if (follow) try self.subscriptions.ensureUnusedCapacity(self.gpa, 1);
        const dispatcher = c.dispatcher;
        const ticket = c.ticket;
        if (reason) |why| try self.recover(c, why) else try self.replay(c, seq);
        const open = dispatcher.get(ticket) orelse return;
        try self.control(open, "stream.checkpoint", struct {}{});
        if (!follow) return open.ok(struct {}{});
        self.subscriptions.appendAssumeCapacity(.{ .dispatcher = dispatcher, .ticket = ticket, .seq = self.high, .checkpoint_at = os.nowMs(), .policy_revision = if (c.conn.registry) |reg| reg.policy_revision else 0, .generation = self.generation });
    }
    fn recover(self: *Log, c: *d.Call, reason: []const u8) !void {
        // FixedBufferAllocator bounds both product read view and chunk metadata.
        const memory = try self.gpa.alloc(u8, self.limits.snapshot_bytes);
        defer self.gpa.free(memory);
        var fixed = std.heap.FixedBufferAllocator.init(memory);
        const entities = if (self.snapshot) |snap| snap.vtable.capture(snap.ptr, fixed.allocator()) catch |err| {
            if (err == error.OutOfMemory) return c.fail("unavailable.event_gap", "snapshot budget exhausted", struct {}{});
            return err;
        } else &.{};
        const WireEntity = struct { resource: []const u8, entity_type: []const u8, content: []const u8 };
        const visible = fixed.allocator().alloc(WireEntity, entities.len) catch return c.fail("unavailable.event_gap", "snapshot budget exhausted", struct {}{});
        var n: usize = 0;
        var stamp: [32]u8 = undefined;
        const ts = try timestamp(&stamp);
        for (entities) |e| {
            if (!selectedResource(c, e.resource) or !allowed(c, e.resource)) continue;
            var matches = false;
            for (e.event_types) |kind| if (selectedType(c, kind)) {
                matches = true;
                break;
            };
            if (!matches) continue;
            visible[n] = .{ .resource = e.resource, .entity_type = e.entity_type, .content = e.content };
            n += 1;
        }
        var start: usize = 0;
        while (true) {
            var end = start;
            while (end < n) {
                const bytes = try self.envelope(self.high, ts, "state.snapshot", .{ .reason = reason, .entities = visible[start .. end + 1], .complete = end + 1 == n });
                defer self.gpa.free(bytes);
                if (!fits(c, bytes.len)) break;
                end += 1;
            }
            if (end == start and start < n) return c.fail("unsupported.event_size", "snapshot entity exceeds max_frame", struct {}{});
            const bytes = try self.envelope(self.high, ts, "state.snapshot", .{ .reason = reason, .entities = visible[start..end], .complete = end == n });
            defer self.gpa.free(bytes);
            try send(c, bytes);
            if (end == n) break;
            start = end;
        }
    }
    fn envelope(self: *Log, seq: u64, ts: []const u8, kind: []const u8, data: anytype) ![]u8 {
        return std.json.Stringify.valueAlloc(self.gpa, .{ .seq = seq, .ts = ts, .source = self.source, .type = kind, .data = data }, .{});
    }
    fn control(self: *Log, c: *d.Call, kind: []const u8, data: anytype) !void {
        var stamp: [32]u8 = undefined;
        const bytes = try self.envelope(self.high, try timestamp(&stamp), kind, data);
        defer self.gpa.free(bytes);
        try send(c, bytes);
    }
    fn replay(self: *Log, c: *d.Call, seq: u64) !void {
        for (self.entries.items[self.head..]) |e| {
            if (e.seq > seq and selectedType(c, e.type) and selectedResource(c, e.resource) and allowed(c, e.resource)) try send(c, e.bytes);
        }
    }
    /// Call at least every five seconds, after Dispatcher.tick(). Also call
    /// after appends before returning to poll, to avoid unnecessary retention gaps.
    pub fn tick(self: *Log) !void {
        const now = os.nowMs();
        self.trim(now);
        var i: usize = 0;
        while (i < self.subscriptions.items.len) {
            const sub = &self.subscriptions.items[i];
            const c = sub.dispatcher.get(sub.ticket) orelse {
                _ = self.subscriptions.swapRemove(i);
                continue;
            };
            const dispatcher = sub.dispatcher;
            const ticket = sub.ticket;
            self.deliver(c, sub, now) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (dispatcher.get(ticket)) |open| try open.fail("unavailable.event_gap", "event delivery failed", struct {}{});
            };
            if (dispatcher.get(ticket) == null) {
                _ = self.subscriptions.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }
    fn deliver(self: *Log, c: *d.Call, sub: *Subscription, now: i64) !void {
        if (!scope(c) or (if (c.conn.registry) |reg| reg.policy_revision != sub.policy_revision else false)) return c.fail("denied.event_scope", "event scope changed", struct {}{});
        if (sub.generation != self.generation or sub.seq < self.low() - 1) return c.fail("unavailable.event_gap", "retained history lost", struct {}{});
        try self.replay(c, sub.seq);
        sub.seq = self.high;
        if (now - sub.checkpoint_at >= 5000) {
            try self.control(c, "stream.checkpoint", struct {}{});
            sub.checkpoint_at = now;
        }
    }
};
fn fits(c: *const d.Call, size: usize) bool {
    // Connection.sendMessage applies the NDJSON limit before CONTROL wrapping.
    return size + c.id_json.len + 16 <= c.conn.max_frame;
}
fn send(c: *d.Call, bytes: []const u8) !void {
    if (!fits(c, bytes.len)) {
        try c.fail("unsupported.event_size", "event exceeds max_frame", struct {}{});
        return error.EventSize;
    }
    // Parse in temporary storage; Call.item validates against the product schema.
    var arena = std.heap.ArenaAllocator.init(c.dispatcher.gpa);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), bytes, .{});
    try c.item(value);
}
fn allowed(c: *const d.Call, resource: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, resource, ':') orelse return false;
    const reg = c.conn.registry orelse return true;
    const kind = resource[0..colon];
    const id = resource[colon + 1 ..];
    const now = g.nowSeconds();
    if (!reg.allows(c.conn.identity, .read, .{ .kind = kind, .id = id }, now)) return false;
    // Principal events reach only the principal, its
    // ancestors and admin. An unparseable ID is visible to admin alone.
    if (!std.mem.eql(u8, kind, "principal")) return true;
    if (g.parseId(id)) |target| return reg.principalVisible(c.conn.identity, target, now);
    return reg.connectionLive(c.conn.identity, now) and reg.allows(c.conn.identity, .admin, null, now);
}
fn scope(c: *const d.Call) bool {
    if (c.conn.registry) |reg| {
        if (!reg.allows(c.conn.identity, .read, null, g.nowSeconds())) return false;
        for (c.params.object.get("resources").?.array.items) |r| if (!allowed(c, r.string)) return false;
    }
    return true;
}
fn selectedType(c: *const d.Call, kind: []const u8) bool {
    const values = c.params.object.get("types").?.array.items;
    if (values.len == 0) return true;
    for (values) |v| if (matchesType(v.string, kind)) return true;
    return false;
}
fn selectedResource(c: *const d.Call, resource: []const u8) bool {
    const values = c.params.object.get("resources").?.array.items;
    if (values.len == 0) return true;
    for (values) |v| if (std.mem.eql(u8, v.string, resource)) return true;
    return false;
}
pub fn matchesType(selector: []const u8, kind: []const u8) bool {
    if (std.mem.endsWith(u8, selector, ".*")) return kind.len > selector.len - 1 and std.mem.startsWith(u8, kind, selector[0 .. selector.len - 1]);
    return std.mem.eql(u8, selector, kind);
}
pub fn validSelector(value: []const u8) bool {
    return s.validVerbName(if (std.mem.endsWith(u8, value, ".*")) value[0 .. value.len - 2] else value);
}
pub fn validResource(value: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (colon == 0 or colon + 1 == value.len or !std.ascii.isLower(value[0])) return false;
    for (value[0..colon]) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    for (value[colon + 1 ..]) |ch| if (ch == ':' or ch < 32 or ch == 127) return false;
    const view = std.unicode.Utf8View.init(value) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (cp >= 0x80 and cp <= 0x9f) return false;
    return true;
}
pub const Cursor = struct { source: []const u8, seq: u64 };
pub fn parseCursor(value: []const u8) !Cursor {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidCursor;
    const source = value[0..colon];
    const slash = std.mem.indexOfScalar(u8, source, '/') orelse return error.InvalidCursor;
    if (!s.validToolName(source[0..slash])) return error.InvalidCursor;
    const uuid = source[slash + 1 ..];
    if (uuid.len != 36) return error.InvalidCursor;
    for (uuid, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return error.InvalidCursor;
        } else if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'))) return error.InvalidCursor;
    }
    if (uuid[14] != '4' or std.mem.indexOfScalar(u8, "89ab", uuid[19]) == null) return error.InvalidCursor;
    const number = value[colon + 1 ..];
    if (number.len == 0 or (number.len > 1 and number[0] == '0')) return error.InvalidCursor;
    for (number) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidCursor;
    const seq = std.fmt.parseInt(u64, number, 10) catch return error.InvalidCursor;
    if (seq > max_seq) return error.InvalidCursor;
    return .{ .source = source, .seq = seq };
}
fn timestamp(buf: []u8) ![]const u8 {
    var ts: os.c.timespec = undefined;
    if (os.c.clock_gettime(os.c.CLOCK.REALTIME, &ts) != 0) return error.ClockUnavailable;
    var base: [32]u8 = undefined;
    const seconds = try @import("audit.zig").timestamp(@intCast(ts.sec), &base);
    return std.fmt.bufPrint(buf, "{s}.{d:0>3}Z", .{ seconds[0 .. seconds.len - 1], @as(u32, @intCast(@divTrunc(ts.nsec, 1_000_000))) });
}
test {
    _ = @import("events_tests.zig");
}

fn newSource(a: std.mem.Allocator, tool: []const u8) ![]u8 {
    var uuid: [16]u8 = undefined;
    if (getentropy(&uuid, uuid.len) != 0) return error.EntropyUnavailable;
    uuid[6] = (uuid[6] & 15) | 0x40;
    uuid[8] = (uuid[8] & 63) | 0x80;
    const hex = std.fmt.bytesToHex(uuid, .lower);
    return std.fmt.allocPrint(a, "{s}/{s}-{s}-{s}-{s}-{s}", .{ tool, hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

/// Reader-side validation keeps known fields typed but accepts compatible
/// additions recursively. Publisher validation remains closed. The original
/// value is preserved so forwarders/renderers can retain unknown event data.
pub fn validateItem(a: std.mem.Allocator, descriptor: s.Type, value: Value) !?s.Failure {
    var projection = try knownFields(a, descriptor, value);
    var path: s.Path = .{ .gpa = a };
    return s.validateValue(a, descriptor, &projection, &path, false);
}
fn knownFields(a: std.mem.Allocator, descriptor: s.Type, value: Value) error{OutOfMemory}!Value {
    if (descriptor.kind == .object and value == .object) {
        var out: Value = .{ .object = .empty };
        for (descriptor.fields.?) |field| if (value.object.get(field.name)) |v| {
            try out.object.put(a, field.name, try knownFields(a, field.type, v));
        };
        return out;
    }
    if (descriptor.kind == .array and value == .array) {
        var out: Value = .{ .array = std.json.Array.init(a) };
        for (value.array.items) |v| try out.array.append(try knownFields(a, descriptor.items.?.*, v));
        return out;
    }
    return value;
}
