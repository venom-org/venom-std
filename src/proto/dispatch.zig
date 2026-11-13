//! NDJSON requests dispatched to handlers bound to the
//! verbs of a schema, with concurrent in-flight calls matched by
//! `id`, streamed `item`s, `cancel`, `ping` and the error model.
//!
//! A `Dispatcher` is the `Server`'s handler. For each request it parses
//! `{id, verb, params}`, validates params against the verb (inserting
//! defaults), and calls the verb's handler with a `*Call`. The handler may
//! answer at once (`call.ok`, `call.fail`), stream (`call.item` …, then a
//! final response), or keep `call.ticket` and answer on a later turn of the
//! daemon loop via `dispatcher.get(ticket)`. `get` returns null once the call
//! has ended (answered, cancelled, or its connection closed), so a stale
//! ticket is always safe; a `*Call` must not be kept across reactor turns.
const std = @import("std");
const iface = @import("iface");
const os = @import("os.zig");
const wire = @import("wire.zig");
const server = @import("server.zig");
const errors = @import("errors.zig");
const schema = @import("schema.zig");
const Connection = wire.Connection;
const grants = @import("grants.zig");
const grant_verbs = @import("grant_verbs.zig");
const Value = std.json.Value;

/// Names one in-flight call for its whole life; never reused.
pub const Ticket = u64;

/// A request id: a JSON integer within ±(2^53−1), or a string ≤ 64 bytes.
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn fromValue(value: Value) ?Id {
        return switch (value) {
            .integer => |i| if (@abs(i) <= schema.max_safe_integer) .{ .integer = i } else null,
            .string => |s| if (s.len <= 64) .{ .string = s } else null,
            else => null,
        };
    }
    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .integer => |i| b == .integer and b.integer == i,
            .string => |s| b == .string and std.mem.eql(u8, b.string, s),
        };
    }
    pub fn jsonStringify(self: Id, jws: anytype) !void {
        switch (self) {
            inline else => |v| try jws.write(v),
        }
    }
};

/// One parsed request line, or why it was rejected.
pub const Parsed = union(enum) {
    request: struct { id: Id, verb: []const u8, params: Value },
    rejected: struct { id: ?Id, code: []const u8 },
};

/// Parse one NDJSON line (without its `\n`) into `arena`. Never fails on
/// input, only on allocation. Strings are copied, so the result outlives
/// `line`.
pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) error{OutOfMemory}!Parsed {
    const value = std.json.parseFromSliceLeaky(Value, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .rejected = .{ .id = null, .code = "protocol.parse" } },
    };
    if (value != .object) return .{ .rejected = .{ .id = null, .code = "protocol.parse" } };
    const id = Id.fromValue(value.object.get("id") orelse .null) orelse
        return .{ .rejected = .{ .id = null, .code = "protocol.invalid_request" } };
    const verb = value.object.get("verb") orelse .null;
    const params = value.object.get("params") orelse Value{ .object = .empty };
    if (verb != .string or params != .object) return .{ .rejected = .{ .id = id, .code = "protocol.invalid_request" } };
    return .{ .request = .{ .id = id, .verb = verb.string, .params = params } };
}

/// A verb implementation. `impl.call(*Call)` must return promptly; it either
/// finishes the call or keeps `call.ticket` to finish it later. An error
/// return ends a still-open call with `internal`.
pub const VerbHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        call: *const fn (*anyopaque, *Call) anyerror!void,
    };

    pub fn init(impl: anytype) VerbHandler {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .call = call };
            fn call(ptr: *anyopaque, c: *Call) anyerror!void {
                return iface.cast(T, ptr).call(c);
            }
        }.vt };
    }

    /// A typed handler: `impl.call(*Call, Params)` receives the validated
    /// params (defaults applied) decoded into `Params`. Slices in `Params`
    /// live as long as the call.
    pub fn typed(comptime Params: type, impl: anytype) VerbHandler {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(struct { call: *const fn (*anyopaque, *Call, Params) anyerror!void }, T);
        return .{
            .ptr = impl,
            .vtable = &struct {
                const vt: VTable = .{ .call = call };
                fn call(ptr: *anyopaque, c: *Call) anyerror!void {
                    const params = std.json.parseFromValueLeaky(Params, c.arena(), c.params, .{ .ignore_unknown_fields = true }) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        // The Zig type disagrees with the schema: a daemon bug.
                        return c.fail("internal.params", "handler params type does not match the verb schema", .{ .type = @typeName(Params) });
                    };
                    return iface.cast(T, ptr).call(c, params);
                }
            }.vt,
        };
    }
};

pub const Binding = struct { verb: []const u8, handler: VerbHandler };

pub const Options = struct {
    /// Receives binary tool frames (and stream-scoped CLOSE/ERROR frames).
    /// Without it, tool frames are refused with `protocol.bad_frame`.
    frames: ?server.Handler = null,
    /// In-flight calls allowed per connection; more get `unavailable.busy`.
    max_inflight: usize = 1024,
};

/// An in-flight request. Valid until it is finished or cancelled, and never
/// beyond the current reactor turn: keep `ticket`, not the pointer.
pub const Call = struct {
    dispatcher: *Dispatcher,
    ticket: Ticket,
    conn: *Connection,
    verb: *const schema.Verb,
    id: Id,
    /// Validated params with defaults applied; an object.
    params: Value,
    arena_state: std.heap.ArenaAllocator,
    id_json: []const u8 = "",
    audit_resource: ?[]const u8 = null,

    /// Call before looking up a resource. false means the call has ended.
    pub fn authorize(self: *Call, right: grants.Right, resource: grants.Resource) !bool {
        const allowed = if (self.conn.registry) |r| r.allows(self.conn.identity, right, resource, grants.nowSeconds()) else right == .none or right == .read;
        if (allowed) return true;
        var principal_buf: [24]u8 = undefined;
        const code = denialCode(right);
        const resource_name = try std.fmt.allocPrint(self.arena(), "{s}:{s}", .{ resource.kind, resource.id });
        self.audit_resource = resource_name;
        try self.fail(code, "caller lacks the required grant", .{ .right = @tagName(right), .resource = resource_name, .principal = grants.name(self.conn.identity.principal, &principal_buf) });
        return false;
    }

    /// The caller's tool namespace, for checking namespaced ids:
    /// `venomx` for the owner, `user` when none was issued or no registry is attached.
    pub fn namespace(self: *const Call) []const u8 {
        const r = self.conn.registry orelse return grants.default_namespace;
        return r.namespaceOf(self.conn.identity.principal);
    }

    /// Memory that lives exactly as long as the call.
    pub fn arena(self: *Call) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Send one `item` of a streaming verb. `value` must match the verb's
    /// `item` type; if it does not, the call ends with `internal.result` and
    /// error.InvalidResult is returned. On error.OutOfMemory the call stays
    /// open; on any other error it has ended.
    pub fn item(self: *Call, value: anytype) !void {
        const t = self.verb.item orelse return error.NotStreaming;
        const d = self.dispatcher;
        const bytes = try self.payload(t, value);
        defer d.gpa.free(bytes);
        d.respond(self.conn, self.id_json, "item", bytes) catch |err| {
            self.abort(err);
            return err;
        };
    }

    /// Finish the call with a result matching the verb's `result` type. On a
    /// schema mismatch the client gets `internal.result` and
    /// error.InvalidResult is returned. On error.OutOfMemory the call stays
    /// open; otherwise it has ended and `self` is invalid.
    pub fn ok(self: *Call, value: anytype) !void {
        const d = self.dispatcher;
        const bytes = try self.payload(self.verb.result, value);
        defer d.gpa.free(bytes);
        try self.finish("ok", bytes);
    }

    /// Finish the call with an error. `code` must be a known-class code
    /// (`<class>.<detail>`); `data` is any JSON-encodable value, or null for none.
    /// Same ending rules as `ok`.
    pub fn fail(self: *Call, code: []const u8, message: []const u8, data: anytype) !void {
        std.debug.assert(errors.knownCode(code));
        const d = self.dispatcher;
        if (std.mem.startsWith(u8, code, "denied.")) if (self.conn.registry) |r| r.denied(self.conn.identity, self.verb.name, self.verb.grant, code, self.audit_resource);
        const bytes = try encodeError(d.gpa, code, message, data);
        defer d.gpa.free(bytes);
        try self.finish("error", bytes);
    }

    fn finish(self: *Call, kind: []const u8, bytes: []const u8) !void {
        const d = self.dispatcher;
        d.respond(self.conn, self.id_json, kind, bytes) catch |err| {
            self.abort(err);
            return err;
        };
        d.end(self);
    }

    /// The response could not be queued. Out of memory leaves the call open
    /// for the caller to retry or fail; anything else ends it, telling the
    /// client where possible.
    fn abort(self: *Call, err: anyerror) void {
        if (err == error.OutOfMemory) return;
        const d = self.dispatcher;
        if (err == error.TooLarge) {
            if (encodeError(d.gpa, if (std.mem.eql(u8, self.verb.name, "events")) "unsupported.event_size" else "internal.too_large", "response exceeds max_frame", null)) |bytes| {
                defer d.gpa.free(bytes);
                d.respond(self.conn, self.id_json, "error", bytes) catch {};
            } else |_| {}
        } else if (err == error.SlowReader) {
            // A peer that does not read its responses is closed.
            self.conn.closing = true;
            self.conn.deadline_ms = os.nowMs() + 10_000;
        }
        d.end(self);
    }

    /// Encode `value` and check it against `t`.
    fn payload(self: *Call, t: schema.Type, value: anytype) ![]u8 {
        const d = self.dispatcher;
        const bytes = try encode(d.gpa, value);
        errdefer d.gpa.free(bytes);
        var scratch = std.heap.ArenaAllocator.init(d.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var parsed = std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // We just encoded it.
        };
        var path: schema.Path = .{ .gpa = a };
        if (try schema.validateValue(a, t, &parsed, &path, false)) |failure| {
            const msg = errors.defaultMessage("internal.result");
            const err_bytes = try encodeError(d.gpa, "internal.result", msg, .{ .param = failure.path, .reason = @tagName(failure.detail) });
            defer d.gpa.free(err_bytes);
            d.respond(self.conn, self.id_json, "error", err_bytes) catch {};
            d.end(self);
            return error.InvalidResult;
        }
        return bytes;
    }
};

const Key = struct { conn: *Connection, id: Id };
const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(@intFromPtr(k.conn));
        switch (k.id) {
            .integer => |i| {
                h.update("i");
                h.update(std.mem.asBytes(&i));
            },
            .string => |s| {
                h.update("s");
                h.update(s);
            },
        }
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.conn == b.conn and a.id.eql(b.id);
    }
};

/// Routes NDJSON requests to verb handlers. Must not move after `handler()`
/// is taken; must outlive the `Server` it is attached to.
pub const Dispatcher = struct {
    gpa: std.mem.Allocator,
    schema: *const schema.Schema,
    /// Parallel to `schema.verbs`.
    handlers: []?VerbHandler,
    options: Options,
    next_ticket: Ticket = 1,
    calls: std.AutoArrayHashMapUnmanaged(Ticket, *Call) = .empty,
    ids: std.HashMapUnmanaged(Key, Ticket, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    counts: std.AutoHashMapUnmanaged(*Connection, usize) = .empty,

    /// Validate `model` and bind exactly one handler to each of its verbs.
    /// A missing, unknown or repeated binding is an error; `diag.verb` names
    /// it. `model` must outlive the dispatcher.
    pub fn init(gpa: std.mem.Allocator, model: *const schema.Schema, bindings: []const Binding, options: Options, diag: ?*schema.Diagnostic) !Dispatcher {
        var scratch: schema.Diagnostic = .{};
        const d = diag orelse &scratch;
        try schema.check(model, d);
        if (options.max_inflight == 0) return error.InvalidOptions;
        const handlers = try gpa.alloc(?VerbHandler, model.verbs.len);
        errdefer gpa.free(handlers);
        for (model.verbs, handlers) |verb, *slot| {
            d.* = .{ .verb = verb.name };
            var found: ?VerbHandler = null;
            for (bindings) |b| if (std.mem.eql(u8, b.verb, verb.name)) {
                if (found != null) return error.DuplicateHandler;
                found = b.handler;
            };
            if (grant_verbs.find(verb.name)) |shared| {
                if (found != null or verb.grant != shared.grant) return error.InvalidSharedVerb;
                slot.* = null;
            } else slot.* = found orelse return error.MissingHandler;
        }
        for (bindings) |b| if (model.find(b.verb) == null) {
            d.* = .{ .verb = b.verb };
            return error.UnknownVerb;
        };
        d.* = .{};
        return .{ .gpa = gpa, .schema = model, .handlers = handlers, .options = options };
    }

    /// Frees every in-flight call without answering it. Call after the
    /// server is gone, or after `cancelAll` and a drain.
    pub fn deinit(self: *Dispatcher) void {
        while (self.calls.count() > 0) self.end(self.calls.values()[0]);
        self.calls.deinit(self.gpa);
        self.ids.deinit(self.gpa);
        self.counts.deinit(self.gpa);
        self.gpa.free(self.handlers);
        self.* = undefined;
    }

    /// The `Server` handler interface for this dispatcher.
    pub fn handler(self: *Dispatcher) server.Handler {
        return server.Handler.init(self);
    }

    /// The call for `ticket`, or null if it has ended.
    pub fn get(self: *Dispatcher, ticket: Ticket) ?*Call {
        return self.calls.get(ticket);
    }

    /// Number of in-flight calls across all connections.
    pub fn inflight(self: *const Dispatcher) usize {
        return self.calls.count();
    }

    /// End every in-flight call with `cancelled.shutdown` (daemon stopping).
    pub fn cancelAll(self: *Dispatcher) void {
        while (self.calls.count() > 0) {
            const call = self.calls.values()[0];
            const ticket = call.ticket;
            call.fail("cancelled.shutdown", "daemon shutting down", null) catch {};
            if (self.get(ticket)) |open| self.end(open);
        }
    }

    /// End streaming calls as soon as their effective grant is lost. Products
    /// must additionally re-check read scopes when filtering each event/item.
    pub fn tick(self: *Dispatcher) anyerror!void {
        var i: usize = 0;
        while (i < self.calls.count()) {
            const active = self.calls.values()[i];
            if (active.verb.streams and gate(active.conn, active.verb.grant) != null) {
                const ticket = active.ticket;
                const code = if (std.mem.eql(u8, active.verb.name, "events")) "denied.event_scope" else denialCode(active.verb.grant);
                active.fail(code, "stream authorization revoked", null) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    if (self.get(ticket)) |open| self.end(open);
                };
            } else i += 1;
        }
    }

    // --- server.Handler ---

    pub fn message(self: *Dispatcher, conn: *Connection, msg: wire.Message) anyerror!void {
        switch (msg) {
            .ndjson => |line| try self.request(conn, line),
            .frame => if (self.options.frames) |f| try f.vtable.message(f.ptr, conn, msg),
        }
    }

    pub fn allowFrame(self: *Dispatcher, conn: *const Connection, kind: u16) bool {
        const f = self.options.frames orelse return false;
        return f.vtable.allowFrame(f.ptr, conn, kind);
    }

    pub fn closed(self: *Dispatcher, conn: *Connection) void {
        var i: usize = 0;
        while (i < self.calls.count()) {
            const call = self.calls.values()[i];
            if (call.conn == conn) self.end(call) else i += 1;
        }
        _ = self.counts.remove(conn);
        if (self.options.frames) |f| f.vtable.closed(f.ptr, conn);
    }

    // --- internals ---

    fn request(self: *Dispatcher, conn: *Connection, line: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        var adopted = false;
        defer if (!adopted) arena_state.deinit();
        const arena = arena_state.allocator();

        const req = switch (try parseRequest(arena, line)) {
            .rejected => |r| return self.reject(conn, r.id, r.code, errors.defaultMessage(r.code), null),
            .request => |req| req,
        };
        var params = req.params;
        if (self.ids.contains(.{ .conn = conn, .id = req.id }))
            return self.reject(conn, req.id, "protocol.duplicate_id", errors.defaultMessage("protocol.duplicate_id"), .{ .id = req.id });

        if (std.mem.eql(u8, req.verb, "ping")) {
            if (try schema.validateParams(arena, &.{}, &params)) |f| return self.rejectParams(conn, req.id, f);
            return self.reply(conn, req.id, "ok", "{}");
        }
        if (std.mem.eql(u8, req.verb, "cancel")) return self.cancel(conn, req.id, params);
        if (std.mem.eql(u8, req.verb, "hello"))
            return self.reject(conn, req.id, "protocol.hello_order", errors.defaultMessage("protocol.hello_order"), null);

        const verb = self.schema.find(req.verb) orelse grant_verbs.find(req.verb) orelse
            return self.reject(conn, req.id, "unsupported.verb", "unknown verb", .{ .verb = req.verb });
        const denial = gate(conn, verb.grant);
        if (verb.grant == .admin) if (conn.audit) |log| log.record(.{ .event = "admin", .principal = conn.identity.principal, .pid = conn.identity.peer_pid, .verb = verb.name, .right = verb.grant, .code = denial });
        if (denial) |code| {
            if (conn.registry) |r| r.denied(conn.identity, verb.name, verb.grant, code, null);
            var principal_buf: [24]u8 = undefined;
            return self.reject(conn, req.id, code, "caller lacks the required grant", .{ .right = @tagName(verb.grant), .principal = grants.name(conn.identity.principal, &principal_buf) });
        }
        if (try schema.validateParams(arena, verb.params, &params)) |f| return self.rejectParams(conn, req.id, f);
        const count = self.counts.get(conn) orelse 0;
        if (count >= self.options.max_inflight)
            return self.reject(conn, req.id, "unavailable.busy", "too many requests in flight on this connection", .{ .max_inflight = self.options.max_inflight });

        const call = try self.gpa.create(Call);
        errdefer self.gpa.destroy(call);
        const ticket = self.next_ticket;
        call.* = .{
            .dispatcher = self,
            .ticket = ticket,
            .conn = conn,
            .verb = verb,
            .id = req.id,
            .params = params,
            .arena_state = arena_state,
        };
        // From here the call's arena owns everything parsed above.
        adopted = true;
        errdefer call.arena_state.deinit();
        call.id_json = try encode(call.arena(), req.id);
        try self.calls.ensureUnusedCapacity(self.gpa, 1);
        try self.ids.ensureUnusedCapacity(self.gpa, 1);
        try self.counts.put(self.gpa, conn, count + 1);
        self.calls.putAssumeCapacity(ticket, call);
        self.ids.putAssumeCapacity(.{ .conn = conn, .id = call.id }, ticket);
        self.next_ticket += 1;

        const outcome = if (grant_verbs.find(verb.name) != null) grant_verbs.call(self, call) else blk: {
            const h = self.handlers[(@intFromPtr(verb) - @intFromPtr(self.schema.verbs.ptr)) / @sizeOf(schema.Verb)].?;
            break :blk h.vtable.call(h.ptr, call);
        };
        outcome catch |err| {
            if (self.get(ticket)) |open| {
                open.fail("internal", @errorName(err), .{ .verb = verb.name }) catch {};
                // Never leave a failed handler's call dangling.
                if (self.get(ticket)) |still| self.end(still);
            }
            if (err == error.OutOfMemory) return err;
        };
    }

    fn cancel(self: *Dispatcher, conn: *Connection, id: Id, params: Value) !void {
        if (!conn.hasCap("cancel"))
            return self.reject(conn, id, "unsupported.capability", "capability 'cancel' was not negotiated", .{ .capability = "cancel" });
        for (params.object.keys()) |key| if (!std.mem.eql(u8, key, "id"))
            return self.rejectParams(conn, id, .{ .detail = .unknown, .path = key });
        const raw = params.object.get("id") orelse return self.rejectParams(conn, id, .{ .detail = .missing, .path = "id" });
        const target = Id.fromValue(raw) orelse return self.rejectParams(conn, id, .{ .detail = .type, .path = "id" });
        const ticket = self.ids.get(.{ .conn = conn, .id = target }) orelse
            return self.reject(conn, id, "not_found.request", "no request with this id is in flight", .{ .id = target });
        try self.calls.get(ticket).?.fail("cancelled", errors.defaultMessage("cancelled"), null);
        return self.reply(conn, id, "ok", "null");
    }

    fn rejectParams(self: *Dispatcher, conn: *Connection, id: Id, f: schema.Failure) !void {
        var buf: [160]u8 = undefined;
        const name = f.path[0..@min(f.path.len, 64)];
        const msg = switch (f.detail) {
            .missing => std.fmt.bufPrint(&buf, "missing required param '{s}'", .{name}),
            .unknown => std.fmt.bufPrint(&buf, "unknown param '{s}'", .{name}),
            .type => std.fmt.bufPrint(&buf, "param '{s}' has the wrong type", .{name}),
            .@"enum" => std.fmt.bufPrint(&buf, "param '{s}' is not one of the allowed values", .{name}),
            .range => std.fmt.bufPrint(&buf, "param '{s}' is out of range", .{name}),
        } catch unreachable;
        return self.reject(conn, id, f.code(), msg, .{ .param = f.path });
    }

    fn reject(self: *Dispatcher, conn: *Connection, id: ?Id, code: []const u8, msg: []const u8, data: anytype) !void {
        const bytes = try encodeError(self.gpa, code, msg, data);
        defer self.gpa.free(bytes);
        return self.reply(conn, id, "error", bytes);
    }

    fn reply(self: *Dispatcher, conn: *Connection, id: ?Id, kind: []const u8, bytes: []const u8) !void {
        const id_json = try encode(self.gpa, id);
        defer self.gpa.free(id_json);
        return self.respond(conn, id_json, kind, bytes);
    }

    /// Queue `{"id":<id_json>,"<kind>":<bytes>}`.
    fn respond(self: *Dispatcher, conn: *Connection, id_json: []const u8, kind: []const u8, bytes: []const u8) !void {
        const line = try std.mem.concat(self.gpa, u8, &.{ "{\"id\":", id_json, ",\"", kind, "\":", bytes, "}" });
        defer self.gpa.free(line);
        try conn.sendMessage(.{ .ndjson = line });
    }

    fn end(self: *Dispatcher, call: *Call) void {
        _ = self.calls.swapRemove(call.ticket);
        _ = self.ids.remove(.{ .conn = call.conn, .id = call.id });
        if (self.counts.getPtr(call.conn)) |n| {
            n.* -= 1;
            if (n.* == 0) _ = self.counts.remove(call.conn);
        }
        call.arena_state.deinit();
        self.gpa.destroy(call);
    }
};

fn encode(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}
fn encodeError(gpa: std.mem.Allocator, code: []const u8, msg: []const u8, data: anytype) error{OutOfMemory}![]u8 {
    if (@TypeOf(data) == @TypeOf(null)) return encode(gpa, .{ .code = code, .message = msg });
    return encode(gpa, .{ .code = code, .message = msg, .data = data });
}

test {
    _ = @import("dispatch_tests.zig");
}

fn denialCode(right: grants.Right) []const u8 {
    return switch (right) {
        .none => "denied.revoked",
        .read => "denied.read",
        .write => "denied.write",
        .respond => "denied.respond",
        .files => "denied.files",
        .spawn => "denied.spawn",
        .admin => "denied.admin",
    };
}
fn gate(conn: *const Connection, right: grants.Right) ?[]const u8 {
    if (conn.registry) |r| {
        const now = grants.nowSeconds();
        if (!r.connectionLive(conn.identity, now)) return "denied.revoked";
        if (r.allows(conn.identity, right, null, now)) return null;
    } else if (right == .none or right == .read) return null;
    return denialCode(right);
}
