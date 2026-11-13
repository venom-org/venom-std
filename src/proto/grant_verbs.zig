//! Shared grant verb schema bundle. merge() is also used by the CLI generator;
//! Dispatcher binds these handlers itself. Product handlers cannot override it.
const std = @import("std");
const s = @import("schema.zig");
const g = @import("grants.zig");
const audit = @import("audit.zig");
const dispatch = @import("dispatch.zig");
const proc = @import("process.zig");
const os = @import("os.zig");
const string: s.Type = .{ .kind = .string };
const nullable_string: s.Type = .{ .kind = .string, .nullable = true };
const integer: s.Type = .{ .kind = .integer };
const grant: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "right", .summary = "Capability", .type = .{ .kind = .string, .choices = &.{ "none", "read", "write", "respond", "files", "spawn", "admin" } }, .required = true },
    .{ .name = "scope", .summary = "Resource selector", .type = string, .required = true },
} };
const grant_array: s.Type = .{ .kind = .array, .items = &grant };
const strings: s.Type = .{ .kind = .array, .items = &string };
// Grant records carry an explicit null for an absent parent and expiry.
const principal: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "principal", .summary = "Principal ID", .type = string, .required = true },
    .{ .name = "kind", .summary = "Principal kind", .type = string, .required = true },
    .{ .name = "parent", .summary = "Issuing principal", .type = nullable_string },
    .{ .name = "grants", .summary = "Issued grants", .type = grant_array, .required = true },
    .{ .name = "expires", .summary = "Expiry in RFC 3339 UTC", .type = nullable_string },
    .{ .name = "pane", .summary = "Bound pane", .type = string },
    .{ .name = "label", .summary = "Human label", .type = string },
    .{ .name = "namespace", .summary = "Tool namespace; user when none was issued", .type = string, .required = true },
    .{ .name = "capped_by", .summary = "Additional floor cap", .type = strings },
    .{ .name = "restored", .summary = "Read back from the bound file at this daemon's start, not issued by it", .type = .{ .kind = .boolean } },
} };
const peer: s.Type = .{ .kind = .object, .fields = &.{ .{ .name = "pid", .summary = "Peer PID", .type = integer, .required = true }, .{ .name = "exe", .summary = "Peer executable", .type = string }, .{ .name = "start", .summary = "Process start time, on a restored record: this names the bound process, not a peer", .type = integer } } };
const record: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "ts", .summary = "UTC timestamp", .type = string, .required = true },
    .{ .name = "source", .summary = "Daemon instance", .type = string, .required = true },
    .{ .name = "event", .summary = "Audit event", .type = string, .required = true },
    .{ .name = "principal", .summary = "Principal", .type = string, .required = true },
    .{ .name = "peer", .summary = "OS attribution", .type = peer, .required = true },
    .{ .name = "verb", .summary = "Verb", .type = string, .required = true },
    .{ .name = "right", .summary = "Required grant", .type = string, .required = true },
    .{ .name = "resource", .summary = "Named resource", .type = string },
    .{ .name = "code", .summary = "Denial code", .type = string },
    .{ .name = "target", .summary = "Target principal", .type = string },
    .{ .name = "cascade", .summary = "Descendant count", .type = integer },
} };
pub const verbs = [_]s.Verb{
    .{ .name = "whoami", .summary = "Show the caller and its issued grants (unknown callers are read-only; denied.* exits 4)", .grant = .none, .result = principal },
    .{ .name = "grant.list", .summary = "List visible principals", .grant = .read, .params = &.{.{ .name = "principal", .summary = "Principal to list", .type = string }}, .result = .{ .kind = .object, .fields = &.{.{ .name = "principals", .summary = "Visible principal records", .type = .{ .kind = .array, .items = &principal }, .required = true }} } },
    .{ .name = "grant.issue", .summary = "Issue an attenuated token, returned once; with pid, bind a principal to that process instead, with no token", .grant = .spawn, .params = &.{
        .{ .name = "grants", .summary = "Requested grants", .type = grant_array, .required = true },
        .{ .name = "ttl", .summary = "Lifetime in seconds", .type = .{ .kind = .integer, .min = 1, .max = 4294967295 } },
        .{ .name = "label", .summary = "Human label", .type = string },
        .{ .name = "namespace", .summary = "Tool namespace ([a-z][a-z0-9-]{0,31}); defaults to the issuer's. Owner and admin may pass any but the daemon's tool name (venomx), others only their own", .type = string },
        .{ .name = "pid", .summary = "Bind to this process alone, not those below it: no token, no expiry unless ttl is given, and kept across a restart of this daemon while the process lives. Only the owner, an admin or a process principal may", .type = .{ .kind = .integer, .min = 2, .max = 2147483647 } },
    }, .result = .{ .kind = .object, .fields = &.{
        .{ .name = "principal", .summary = "New ID", .type = string, .required = true },
        .{ .name = "token", .summary = "Secret token, returned once; none with pid", .type = string },
        .{ .name = "expires", .summary = "Expiry; null for a bound principal with no ttl", .type = nullable_string, .required = true },
    } } },
    .{ .name = "grant.revoke", .summary = "Revoke a principal and its descendants", .grant = .spawn, .params = &.{.{ .name = "principal", .summary = "Principal to revoke", .type = string, .required = true }}, .result = .{ .kind = .object, .fields = &.{.{ .name = "revoked", .summary = "Revoked IDs", .type = strings, .required = true }} } },
    .{ .name = "audit", .summary = "Read recent audit records", .grant = .admin, .params = &.{.{ .name = "limit", .summary = "Maximum records", .type = .{ .kind = .integer, .min = 1, .max = 1000 }, .default = "100" }}, .result = .{ .kind = .object, .fields = &.{.{ .name = "records", .summary = "Audit records, newest last", .type = .{ .kind = .array, .items = &record }, .required = true }} } },
};
pub fn find(name: []const u8) ?*const s.Verb {
    for (&verbs) |*v| if (std.mem.eql(u8, name, v.name)) return v;
    return null;
}
pub fn merge(comptime model: s.Schema) s.Schema {
    for (model.verbs) |v| if (find(v.name) != null) @compileError("product cannot override shared grant verbs");
    const all = model.verbs[0..model.verbs.len].* ++ verbs;
    return .{ .format = model.format, .tool = model.tool, .summary = model.summary, .verbs = &all };
}
pub fn principalValue(a: std.mem.Allocator, reg: *const g.Registry, identity: g.Identity, id: g.Id) !std.json.Value {
    const p = reg.get(id).?;
    var idbuf: [24]u8 = undefined;
    var parentbuf: [24]u8 = undefined;
    var tsbuf: [32]u8 = undefined;
    var floorbuf: [24]u8 = undefined;
    const floor: ?[]const u8 = switch (identity.floor) {
        .outside => null,
        .orphan => "unknown",
        .bound => |f| if (f != id and !reg.descendant(id, f)) g.name(f, &floorbuf) else null,
    };
    const caps: ?[1][]const u8 = if (floor) |f| .{f} else null;
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .principal = g.name(id, &idbuf), .kind = @tagName(p.kind), .parent = if (p.parent) |n| g.name(n, &parentbuf) else null, .grants = p.grants, .expires = if (p.expires) |e| try audit.timestamp(e, &tsbuf) else null, .pane = p.pane, .label = if (p.label.len > 0) p.label else null, .namespace = reg.namespaceOf(id), .capped_by = caps, .restored = if (p.restored) true else null }, .{ .emit_null_optional_fields = false });
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    if (p.parent == null) try value.object.put(a, "parent", .null);
    if (p.expires == null) try value.object.put(a, "expires", .null);
    return value;
}
pub fn call(_: *@import("dispatch.zig").Dispatcher, c: *dispatch.Call) anyerror!void {
    const reg = c.conn.registry orelse return c.fail("internal.registry", "no grant registry attached", null);
    const now = g.nowSeconds();
    const a = c.arena();
    const name = c.verb.name;
    if (std.mem.eql(u8, name, "whoami")) return c.ok(try principalValue(a, reg, c.conn.identity, c.conn.identity.principal));
    if (std.mem.eql(u8, name, "grant.issue")) {
        const values = c.params.object.get("grants").?.array.items;
        const gs = try a.alloc(g.Grant, values.len);
        for (values, gs) |v, *entry| entry.* = .{ .right = std.meta.stringToEnum(g.Right, v.object.get("right").?.string).?, .scope = v.object.get("scope").?.string };
        const ttl = c.params.object.get("ttl");
        const label = c.params.object.get("label");
        const namespace = c.params.object.get("namespace");
        const pid = c.params.object.get("pid");
        // Checked before the process is looked at, so a caller that may not
        // bind learns nothing about which pids exist.
        if (pid != null and !reg.mayBind(c.conn.identity, now)) return c.fail("denied.bind", "only the owner, an admin or a process principal may bind a process", null);
        const root: ?proc.Ref = if (pid) |v| blk: {
            const n: os.c.pid_t = @intCast(v.integer);
            if (n == os.c.getpid()) return c.fail("invalid_params.pid", "cannot bind the daemon itself", null);
            const st = proc.stat(n) catch return c.fail("not_found.process", "no such process", .{ .pid = v.integer });
            break :blk st.ref;
        } else null;
        const issued = reg.issueChild(c.conn.identity, .{ .kind = if (root != null) .process else .token, .root = root, .grants = gs, .ttl = if (ttl) |t| @intCast(t.integer) else null, .label = if (label) |l| l.string else "", .namespace = if (namespace) |n| n.string else null }, now) catch |err| return switch (err) {
            error.InvalidNamespace => c.fail("invalid_params.namespace", "namespace must match [a-z][a-z0-9-]{0,31}", null),
            error.NamespaceDenied => c.fail("denied.namespace", "caller may not issue this namespace", .{ .namespace = namespace.?.string }),
            error.ProcessBound => c.fail("conflict.process_bound", "a principal is already bound to this process", .{ .pid = pid.?.integer }),
            error.ProcessManager => c.fail("conflict.process_manager", "this process starts processes for others, so it can't be bound", .{ .pid = pid.?.integer }),
            error.BindDenied => c.fail("denied.bind", "only the owner, an admin or a process principal may bind a process", null),
            else => c.fail(switch (err) {
                error.InvalidScope => "invalid_params.grant_scope",
                error.InvalidLabel => "invalid_params.label",
                error.InvalidTtl => "invalid_params.ttl",
                error.OutOfMemory => return err,
                else => "denied.delegation",
            }, "cannot issue requested grants", null),
        };
        defer {
            std.crypto.secureZero(u8, @constCast(issued.token));
            reg.gpa.free(issued.token);
        }
        var idbuf: [24]u8 = undefined;
        var tsbuf: [32]u8 = undefined;
        if (root != null) {
            // Grant records carry an explicit null for an absent expiry.
            var bound: std.json.ObjectMap = .empty;
            try bound.put(a, "principal", .{ .string = g.name(issued.principal, &idbuf) });
            try bound.put(a, "expires", if (issued.expires) |e| .{ .string = try audit.timestamp(e, &tsbuf) } else .null);
            return c.ok(std.json.Value{ .object = bound });
        }
        return c.ok(.{ .principal = g.name(issued.principal, &idbuf), .token = issued.token, .expires = try audit.timestamp(issued.expires.?, &tsbuf) });
    }
    if (std.mem.eql(u8, name, "audit")) {
        const log = c.conn.audit orelse return c.fail("unavailable.audit", "audit log unavailable", null);
        return c.ok(.{ .records = try log.recent(a, @intCast(c.params.object.get("limit").?.integer)) });
    }
    const target_text = if (c.params.object.get("principal")) |p| p.string else null;
    const target = if (target_text) |t| g.parseId(t) orelse return c.fail("invalid_params.principal", "invalid principal ID", null) else if (reg.allows(c.conn.identity, .admin, null, now)) g.owner else c.conn.identity.principal;
    if (!reg.principalVisible(c.conn.identity, target, now)) return c.fail("denied.read", "principal is outside caller scope", null);
    const p = reg.get(target) orelse return c.fail("not_found.principal", "principal not found", null);
    if (std.mem.eql(u8, name, "grant.list")) {
        var list: std.ArrayList(std.json.Value) = .empty;
        for (reg.entries.items) |entry| if (!entry.revoked and reg.descendant(entry.id, p.id) and reg.principalVisible(c.conn.identity, entry.id, now)) try list.append(a, try principalValue(a, reg, .{}, entry.id));
        return c.ok(.{ .principals = list.items });
    }
    var revoked: std.ArrayList([]const u8) = .empty;
    for (reg.entries.items) |entry| if (!entry.revoked and reg.descendant(entry.id, target)) {
        var buf: [24]u8 = undefined;
        try revoked.append(a, try a.dupe(u8, g.name(entry.id, &buf)));
    };
    reg.revoke(c.conn.identity, target, now) catch return c.fail("denied.spawn", "cannot revoke principal", null);
    return c.ok(.{ .revoked = revoked.items });
}
