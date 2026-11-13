//! Grant registry and live authorization. IDs are never reused. Registry
//! strings are owned by its arena; callers must not keep pointers across issue.
const std = @import("std");
const os = @import("os.zig");
const process = @import("process.zig");
const managers = @import("managers.zig");
pub const Right = @import("schema.zig").Grant;
pub const Grant = struct { right: Right, scope: []const u8 };
pub const Kind = enum { owner, unknown, pane, agent, token, process };
pub const Id = u64;
pub const owner: Id = 0;
pub const unknown: Id = 1;
pub const Resource = struct {
    kind: []const u8,
    id: []const u8,
    pub fn eql(a: Resource, b: Resource) bool {
        return std.mem.eql(u8, a.kind, b.kind) and std.mem.eql(u8, a.id, b.id);
    }
};
pub const Containment = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        parentOf: *const fn (*anyopaque, Resource) ?Resource,
        ownerOf: *const fn (*anyopaque, Resource) ?Id,
    };
    pub fn init(impl: anytype) Containment {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        const iface = @import("iface");
        iface.assertImplements(VTable, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .parentOf = parentOf, .ownerOf = ownerOf };
            fn parentOf(ptr: *anyopaque, r: Resource) ?Resource {
                return iface.cast(T, ptr).parentOf(r);
            }
            fn ownerOf(ptr: *anyopaque, r: Resource) ?Id {
                return iface.cast(T, ptr).ownerOf(r);
            }
        }.vt };
    }
};
pub const Principal = struct {
    id: Id,
    kind: Kind,
    parent: ?Id,
    grants: []const Grant,
    expires: ?i64 = null, // Unix seconds; formatted at the wire boundary.
    root: ?process.Ref = null,
    token_hash: ?[32]u8 = null,
    label: []const u8 = "",
    pane: ?[]const u8 = null,
    revoked: bool = false,
    /// Preserve a creating connection's additional floor on delegated tokens.
    cap: ?Id = null,
    /// Tool namespace; null reads as `user` (see Registry.namespaceOf).
    namespace: ?[]const u8 = null,
    /// A `process` principal read back from the bound file, not issued by this
    /// daemon's owner.
    restored: bool = false,
};
/// venomx's owner namespace. Deprecated: the owner's (reserved) namespace is
/// the registry's tool, `Registry.ownerNamespace()`.
pub const owner_namespace = "venomx";
/// The namespace of a principal that has none.
pub const default_namespace = "user";
/// A namespace is `[a-z][a-z0-9-]{0,31}`, like a tool name.
pub fn validNamespace(s: []const u8) bool {
    if (s.len == 0 or s.len > 32 or !std.ascii.isLower(s[0])) return false;
    for (s[1..]) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    return true;
}
pub const Floor = union(enum) { outside, orphan, bound: Id };
pub const Identity = struct {
    principal: Id = unknown,
    floor: Floor = .outside,
    chain: process.Chain = .{},
    peer_pid: os.c.pid_t = 0,
    /// A process above the peer starts processes for others (a
    /// manager). It changes nothing but the owner token's refusal.
    below_manager: bool = false,
};
/// What `unknown` and the interactive profile hold while isolation is off.
/// `respond`, `files` and `admin` stay out.
pub const open_grants: []const Grant = &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = "*" }, .{ .right = .spawn, .scope = "*" } };
pub const Policy = struct {
    unknown: []const Grant = &.{.{ .right = .read, .scope = "*" }},
    interactive: []const Grant = &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = "self" }, .{ .right = .spawn, .scope = "self" } },
    max_token_ttl: u32 = 86400,
    /// Whether callers are kept apart by their grants. The product picks the
    /// default (venomx: false). Off, `unknown` and interactive panes hold
    /// `open_grants`, and namespaces are names only. `unknown` and
    /// `interactive` are kept, validated, for when it is turned back on.
    isolation: bool = true,
    pub fn check(self: Policy) !void {
        if (self.max_token_ttl == 0) return error.InvalidPolicy;
        for (self.unknown) |g| if (g.right != .read) return error.InvalidUnknownPolicy;
        for (self.unknown) |g| try validateGrant(g);
        for (self.interactive) |g| try validateGrant(g);
    }
};
pub const IssueOptions = struct {
    kind: Kind = .token,
    grants: ?[]const Grant = null,
    ttl: ?u32 = null,
    root: ?process.Ref = null,
    pane: ?[]const u8 = null,
    label: []const u8 = "",
    /// Null inherits the issuer's namespace, except that the
    /// owner's tokens and agents have none (they read as `user`). The owner
    /// and `admin` callers may pass any namespace but the registry's tool
    /// (`venomx` in venomx); others only their own.
    namespace: ?[]const u8 = null,
};
pub const Issued = struct { principal: Id, token: []const u8, expires: ?i64 };
pub const TokenFailure = enum { invalid, expired, revoked, binding, owner_context };
pub const Change = struct {
    event: []const u8,
    principal: Id,
    target: ?Id = null,
    cascade: usize = 0,
    pid: os.c.pid_t = 0,
    /// With `pid`, the process's starttime: a `restored` record names its process.
    start: u64 = 0,
    verb: []const u8 = "",
    right: Right = .none,
    code: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};
pub const Observer = struct { ptr: *anyopaque, changed: *const fn (*anyopaque, Change) void };

pub const Registry = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tool: []const u8,
    entries: std.ArrayList(Principal) = .empty,
    policy: Policy,
    /// Changes invalidate event projections, including empty-resource subscriptions.
    policy_revision: u64 = 0,
    /// A `process` principal came or went since the server last saved them
    /// (see `bound.zig`).
    bound_dirty: bool = false,
    /// The server's socket directory, where managers keep their markers. A
    /// manager can't be bound (`issueChild`). Null without a server.
    marker_dir: ?os.c.fd_t = null,
    containment: ?Containment = null,
    observer: ?Observer = null,

    pub fn init(gpa: std.mem.Allocator, tool: []const u8, policy: Policy) !Registry {
        if (!@import("xdg").validTool(tool)) return error.InvalidTool;
        try policy.check();
        var r: Registry = .{ .gpa = gpa, .arena = .init(gpa), .tool = tool, .policy = policy };
        errdefer r.deinit();
        r.tool = try r.arena.allocator().dupe(u8, tool);
        try r.entries.append(gpa, .{ .id = owner, .kind = .owner, .parent = null, .grants = &.{.{ .right = .admin, .scope = "*" }} });
        try r.entries.append(gpa, .{ .id = unknown, .kind = .unknown, .parent = null, .grants = &.{} });
        r.policy.interactive = try r.copyGrants(policy.interactive);
        r.policy.unknown = try r.copyGrants(policy.unknown);
        r.entries.items[unknown].grants = r.unknownGrants();
        return r;
    }
    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.gpa);
        self.arena.deinit();
    }
    pub fn get(self: *const Registry, id: Id) ?*const Principal {
        return if (id < self.entries.items.len) &self.entries.items[@intCast(id)] else null;
    }
    /// The owner's namespace, reserved for the product's built-ins: the
    /// registry's tool (`venomx` in venomx).
    pub fn ownerNamespace(self: *const Registry) []const u8 {
        return self.tool;
    }
    /// Effective tool namespace: the registry's tool for the owner,
    /// the issued namespace otherwise, and `user` when there is none.
    pub fn namespaceOf(self: *const Registry, id: Id) []const u8 {
        if (id == owner) return self.ownerNamespace();
        const p = self.get(id) orelse return default_namespace;
        return p.namespace orelse default_namespace;
    }
    pub fn setPolicy(self: *Registry, policy: Policy) !void {
        try policy.check();
        const u = try self.copyGrants(policy.unknown);
        const i = try self.copyGrants(policy.interactive);
        self.policy = .{ .unknown = u, .interactive = i, .max_token_ttl = policy.max_token_ttl, .isolation = policy.isolation };
        self.entries.items[unknown].grants = self.unknownGrants();
        self.policy_revision += 1;
    }
    /// Isolation on: principals are kept apart and namespaces checked.
    pub fn isolated(self: *const Registry) bool {
        return self.policy.isolation;
    }
    /// What `unknown` holds: `grants.unknown`, or `open_grants` with isolation off.
    fn unknownGrants(self: *const Registry) []const Grant {
        return if (self.policy.isolation) self.policy.unknown else open_grants;
    }
    /// The profile of a pane the owner creates with no `grants`.
    pub fn interactiveGrants(self: *const Registry) []const Grant {
        return if (self.policy.isolation) self.policy.interactive else open_grants;
    }
    /// May `principal` use namespace `ns` for its own ids? The
    /// owner's namespace never; with isolation off any other; otherwise the
    /// owner any, everyone else only its own.
    pub fn mayUseNamespace(self: *const Registry, principal: Id, ns: []const u8) bool {
        if (std.mem.eql(u8, ns, self.ownerNamespace())) return false;
        if (!self.policy.isolation or principal == owner) return true;
        return std.mem.eql(u8, ns, self.namespaceOf(principal));
    }
    /// With isolation off, a caller with `unknown` rights below another tool's
    /// manager is still held to `grants.unknown`.
    fn belowManagerCapped(self: *const Registry, identity: Identity) bool {
        return !self.policy.isolation and identity.below_manager and (identity.principal == unknown or identity.floor == .orphan);
    }
    fn listAllows(self: *const Registry, gs: []const Grant, right: Right, resource: ?Resource) bool {
        for (gs) |g| if (implies(g.right, right) and (g.right == .admin or resource == null or self.scopeAllows(unknown, g.scope, resource.?))) return true;
        return false;
    }
    fn copyGrants(self: *Registry, gs: []const Grant) ![]const Grant {
        return copyGrantsTo(self.arena.allocator(), gs);
    }
    fn copyGrantsTo(a: std.mem.Allocator, gs: []const Grant) ![]const Grant {
        const copy = try a.dupe(Grant, gs);
        for (copy) |*g| g.scope = if (std.mem.startsWith(u8, g.scope, "path:")) blk: {
            const path = try @import("paths.zig").canonical(a, g.scope[5..]);
            break :blk try std.fmt.allocPrint(a, "path:{s}", .{path});
        } else try a.dupe(u8, g.scope);
        return copy;
    }
    pub fn descendant(self: *const Registry, child: Id, ancestor: Id) bool {
        var id = child;
        // Each parent ID precedes its child; cycles cannot be created.
        while (true) {
            if (id == ancestor) return true;
            id = (self.get(id) orelse return false).parent orelse return false;
        }
    }
    pub fn live(self: *const Registry, id: Id, now: i64) bool {
        var next: ?Id = id;
        while (next) |n| {
            const p = self.get(n) orelse return false;
            if (p.revoked or (p.expires != null and p.expires.? <= now)) return false;
            if (p.root) |root| if (!process.alive(root)) return false;
            if (p.cap) |cap| if (!self.live(cap, now)) return false;
            next = p.parent;
        }
        return true;
    }
    pub fn connectionLive(self: *const Registry, identity: Identity, now: i64) bool {
        if (!self.live(identity.principal, now)) return false;
        return switch (identity.floor) {
            .bound => |id| self.live(id, now),
            else => true,
        };
    }
    /// Refreshes automatic revocations; invoke from the reactor, even when idle.
    pub fn sweep(self: *Registry, now: i64) void {
        for (2..self.entries.items.len) |i| {
            const p = self.entries.items[i];
            if (!p.revoked and !self.live(p.id, now)) self.revokeTree(p.id, if (p.expires != null and p.expires.? <= now) "expired" else if (p.root != null and !process.alive(p.root.?)) "exited" else "revoked");
        }
    }
    pub fn denied(self: *Registry, identity: Identity, verb: []const u8, right: Right, code: []const u8, resource: ?[]const u8) void {
        self.notify(.{ .event = "denied", .principal = identity.principal, .pid = identity.peer_pid, .verb = verb, .right = right, .code = code, .resource = resource });
    }
    fn notify(self: *Registry, change: Change) void {
        if (self.observer) |o| o.changed(o.ptr, change);
    }
    fn revokeTree(self: *Registry, id: Id, reason: []const u8) void {
        var count: usize = 0;
        for (self.entries.items) |*p| if (!p.revoked and self.descendant(p.id, id)) {
            p.revoked = true;
            count += 1;
            if (p.kind == .process) self.bound_dirty = true;
        };
        if (count > 0) self.notify(.{ .event = "revoked", .principal = id, .target = id, .cascade = count - 1, .reason = reason });
    }
    pub fn revoke(self: *Registry, caller: Identity, target: Id, now: i64) !void {
        if (target <= unknown) return error.Denied;
        if (!self.allows(caller, .admin, null, now) and
            !(self.allows(caller, .spawn, null, now) and self.descendant(target, caller.principal))) return error.Denied;
        if (self.get(target) == null) return error.NotFound;
        self.revokeTree(target, "revoked");
    }
    pub fn canRespond(self: *const Registry, responder: Id, raiser: Id) bool {
        return !self.descendant(responder, raiser);
    }
    /// Who may bind a process with `grant.issue`. Binding
    /// changes what every process below it resolves to, the human's shell
    /// included, so `spawn` is not enough.
    pub fn mayBind(self: *const Registry, caller: Identity, now: i64) bool {
        if (caller.principal == owner) return self.connectionLive(caller, now);
        if (self.allows(caller, .admin, null, now)) return true;
        const p = self.get(caller.principal) orelse return false;
        return p.kind == .process and self.connectionLive(caller, now);
    }
    /// A live principal already has this process as its root.
    pub fn boundTo(self: *const Registry, root: process.Ref, now: i64) bool {
        for (self.entries.items) |p| if (p.root) |r| if (r.eql(root) and !p.revoked and self.live(p.id, now)) return true;
        return false;
    }
    /// A `process` principal from before a restart (`bound.zig`). Its parent is
    /// `owner` or one restored before it, and its grants meet the ancestors' at
    /// check time, as any principal's do.
    pub fn restoreProcess(self: *Registry, parent: Id, root: process.Ref, gs: []const Grant, label: []const u8, namespace: ?[]const u8, expires: ?i64) !Id {
        const a = self.arena.allocator();
        const id: Id = @intCast(self.entries.items.len);
        try self.entries.append(self.gpa, .{ .id = id, .kind = .process, .parent = parent, .grants = try self.copyGrants(gs), .expires = expires, .root = root, .label = try a.dupe(u8, label), .namespace = if (namespace) |ns| try a.dupe(u8, ns) else null, .restored = true });
        self.bound_dirty = true;
        // Not `issued`: no one asked for this now. Anyone could have written the file.
        self.notify(.{ .event = "restored", .principal = parent, .target = id, .pid = root.pid, .start = root.start });
        return id;
    }
    pub fn issueChild(self: *Registry, caller: Identity, options: IssueOptions, now: i64) !Issued {
        if (!self.allows(caller, .spawn, null, now)) return error.Denied;
        if (options.kind != .pane and options.kind != .agent and options.kind != .token and options.kind != .process) return error.InvalidKind;
        if (options.kind == .token and options.root != null) return error.InvalidKind;
        if (options.kind == .process) {
            const root = options.root orelse return error.InvalidKind;
            if (!self.mayBind(caller, now)) return error.BindDenied;
            if (self.boundTo(root, now)) return error.ProcessBound;
            if (self.marker_dir) |dir| if (managers.marked(dir, root)) return error.ProcessManager;
        }
        if (options.kind == .pane and options.pane == null) return error.InvalidKind;
        if (options.label.len > 64) return error.InvalidLabel;
        for (options.label) |ch| if (ch < 32 or ch == 127) return error.InvalidLabel;
        const parent = self.get(caller.principal).?.*;
        // Without the parameter, a pane of the owner's inherits the owner's
        // namespace, like any other pane. Any other owner child
        // has no namespace (reads as `user`).
        const namespace: ?[]const u8 = if (options.namespace) |ns| blk: {
            if (!validNamespace(ns)) return error.InvalidNamespace;
            if (caller.principal == owner or self.allows(caller, .admin, null, now)) {
                if (std.mem.eql(u8, ns, self.ownerNamespace())) return error.NamespaceDenied;
            } else if (!self.mayUseNamespace(caller.principal, ns)) return error.NamespaceDenied;
            break :blk ns;
        } else if (caller.principal != owner) parent.namespace else if (options.kind == .pane) self.ownerNamespace() else null;
        const raw_gs = options.grants orelse if (caller.principal == owner and options.kind == .pane) self.interactiveGrants() else parent.grants;
        for (raw_gs) |entry| try validateGrant(entry);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const gs = try copyGrantsTo(scratch.allocator(), raw_gs);
        for (gs) |g| {
            try validateGrant(g);
            if (options.grants != null and !self.covers(caller, g, now)) return error.Delegation;
        }
        const a = self.arena.allocator();
        var expires: ?i64 = null;
        if (options.ttl) |ttl| {
            if (ttl == 0) return error.InvalidTtl;
            expires = now + @as(i64, if (options.root == null) @min(ttl, self.policy.max_token_ttl) else ttl);
        } else if (options.root == null) expires = now + @as(i64, self.policy.max_token_ttl);
        if (parent.expires) |e| expires = if (expires) |x| @min(e, x) else e;
        const id: Id = @intCast(self.entries.items.len);
        var hash: [32]u8 = undefined;
        // A process principal has no credential: only its ancestry resolves to it.
        const bearer = options.kind != .process;
        const token = if (bearer) try self.makeToken(id, &hash) else try self.gpa.alloc(u8, 0);
        errdefer self.gpa.free(token);
        const p: Principal = .{ .id = id, .kind = options.kind, .parent = caller.principal, .grants = try self.copyGrants(gs), .expires = expires, .root = options.root, .pane = if (options.pane) |s| try a.dupe(u8, s) else null, .label = try a.dupe(u8, options.label), .namespace = if (namespace) |ns| try a.dupe(u8, ns) else null, .token_hash = if (bearer) hash else null, .cap = switch (caller.floor) {
            .outside => null,
            .orphan => unknown,
            .bound => |f| if (self.descendant(caller.principal, f)) null else f,
        } };
        try self.entries.append(self.gpa, p);
        if (options.kind == .process) self.bound_dirty = true;
        self.notify(.{ .event = "issued", .principal = caller.principal, .target = id });
        // Secret belongs to the caller, not the registry, and is returned once.
        return .{ .principal = id, .token = token, .expires = expires };
    }
    pub fn ownerToken(self: *Registry) ![]const u8 {
        var hash: [32]u8 = undefined;
        const token = try self.makeToken(owner, &hash);
        self.entries.items[owner].token_hash = hash;
        return token;
    }
    fn makeToken(self: *Registry, id: Id, hash: *[32]u8) ![]const u8 {
        var secret: [32]u8 = undefined;
        // getentropy is an OS CSPRNG on Linux and Darwin.
        if (getentropy(&secret, secret.len) != 0) return error.EntropyUnavailable;
        defer std.crypto.secureZero(u8, &secret);
        std.crypto.hash.sha2.Sha256.hash(&secret, hash, .{});
        var encoded: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &secret);
        var buf: [24]u8 = undefined;
        return std.fmt.allocPrint(self.gpa, "vnt1.{s}.{s}.{s}", .{ self.tool, name(id, &buf), encoded });
    }
    /// Authenticate only once during hello. Failure never falls back to unknown.
    pub fn authenticate(self: *Registry, identity: *Identity, token: []const u8, now: i64) ?TokenFailure {
        var parts = std.mem.splitScalar(u8, token, '.');
        if (!std.mem.eql(u8, parts.next() orelse return .invalid, "vnt1")) return .invalid;
        if (!std.mem.eql(u8, parts.next() orelse return .invalid, self.tool)) return .invalid;
        const id = parseId(parts.next() orelse return .invalid) orelse return .invalid;
        const secret = parts.next() orelse return .invalid;
        if (secret.len != 43 or parts.next() != null) return .invalid;
        var raw: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        std.base64.url_safe_no_pad.Decoder.decode(&raw, secret) catch return .invalid;
        // Require canonical encoding (including unused bits of the last byte).
        var canonical: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&canonical, &raw);
        if (!std.mem.eql(u8, secret, &canonical)) return .invalid;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&raw, &hash, .{});
        const p = self.get(id) orelse return .invalid;
        const expected = p.token_hash orelse return .invalid;
        if (!std.crypto.timing_safe.eql([32]u8, hash, expected)) return .invalid;
        if (p.revoked) return .revoked;
        if (p.expires) |e| if (e <= now) return .expired;
        if (!self.live(id, now)) return .revoked;
        if (id == owner) {
            if (identity.floor != .outside or identity.below_manager) return .owner_context;
        } else if (p.root) |root| {
            if (identity.floor == .orphan or !identity.chain.contains(root)) return .binding;
        }
        identity.principal = id;
        return null;
    }
    pub fn resolve(self: *Registry, chain: process.Chain, peer_pid: os.c.pid_t, now: i64) Identity {
        var result: Identity = .{ .chain = chain, .peer_pid = peer_pid };
        var nearest: ?Id = null;
        for (chain.refs[0..chain.len], 0..) |r, depth| {
            for (self.entries.items) |p| {
                // A `process` principal is that process's
                // alone. Its children are someone else's code: a view's shell, or
                // a model's Bash in its take-over.
                if (p.kind == .process and depth != 0) continue;
                if (p.root) |root| if (root.eql(r) and self.live(p.id, now) and nearest == null) {
                    nearest = p.id;
                };
            }
        }
        if (chain.failed) result.floor = .orphan else if (nearest) |id| {
            result.floor = .{ .bound = id };
            result.principal = id;
        } else if (chain.orphan) result.floor = .orphan;
        return result;
    }
    /// Gate with resource=null; handlers must check actual resources separately.
    pub fn allows(self: *const Registry, identity: Identity, right: Right, resource: ?Resource, now: i64) bool {
        if (!self.connectionLive(identity, now)) return false;
        if (right == .none) return true;
        if (!self.chainAllows(identity.principal, right, resource)) return false;
        if (self.belowManagerCapped(identity) and !self.listAllows(self.policy.unknown, right, resource)) return false;
        return switch (identity.floor) {
            .outside => true,
            .orphan => self.chainAllows(unknown, right, resource),
            .bound => |id| self.chainAllows(id, right, resource),
        };
    }
    fn chainAllows(self: *const Registry, id: Id, right: Right, resource: ?Resource) bool {
        var next: ?Id = id;
        while (next) |n| {
            const p = self.get(n) orelse return false;
            var allowed = false;
            for (p.grants) |g| if (implies(g.right, right) and (g.right == .admin or resource == null or self.scopeAllows(n, g.scope, resource.?))) {
                allowed = true;
                break;
            };
            if (!allowed) return false;
            if (p.cap) |cap| if (!self.chainAllows(cap, right, resource)) return false;
            next = p.parent;
        }
        return true;
    }
    pub fn authorize(self: *const Registry, identity: Identity, right: Right, resource: Resource, now: i64) error{Denied}!void {
        if (!self.allows(identity, right, resource, now)) return error.Denied;
    }
    fn scopeAllows(self: *const Registry, principal: Id, scope: []const u8, resource: Resource) bool {
        if (std.mem.eql(u8, scope, "*")) return true;
        if (selector(scope)) |s| if (std.mem.eql(u8, s.id, "*")) return std.mem.eql(u8, s.kind, resource.kind);
        if (std.mem.startsWith(u8, scope, "path:")) return std.mem.eql(u8, resource.kind, "path") and pathContains(scope[5..], resource.id);
        if (std.mem.eql(u8, resource.kind, "principal")) {
            if (selector(scope)) |s| if (std.mem.eql(u8, s.kind, "principal")) {
                const ancestor = parseId(s.id) orelse return std.mem.eql(u8, s.id, "*");
                const target = parseId(resource.id) orelse return false;
                return self.descendant(target, ancestor);
            };
        }
        var current: ?Resource = resource;
        for (0..128) |_| {
            const r = current orelse return false;
            if (std.mem.eql(u8, scope, "self")) {
                const p = self.get(principal) orelse return false;
                if (p.pane) |pane| if (std.mem.eql(u8, r.kind, "pane") and std.mem.eql(u8, pane, r.id)) return true;
                if (self.containment) |c| if (c.vtable.ownerOf(c.ptr, r)) |id| if (self.descendant(id, principal)) return true;
            } else if (selector(scope)) |s| {
                if (std.mem.eql(u8, s.kind, r.kind) and (std.mem.eql(u8, s.id, "*") or std.mem.eql(u8, s.id, r.id))) return true;
            }
            current = self.parentOf(r);
        }
        return false;
    }
    fn parentOf(self: *const Registry, r: Resource) ?Resource {
        // Principal IDs need temporary formatting; containment on these is
        // handled directly by callers of principalVisible, not product callbacks.
        if (std.mem.eql(u8, r.kind, "principal")) return null;
        const c = self.containment orelse return null;
        return c.vtable.parentOf(c.ptr, r);
    }
    pub fn principalVisible(self: *const Registry, caller: Identity, target: Id, now: i64) bool {
        return self.connectionLive(caller, now) and (self.descendant(target, caller.principal) or self.allows(caller, .admin, null, now));
    }
    fn covers(self: *const Registry, caller: Identity, g: Grant, now: i64) bool {
        if (!self.connectionLive(caller, now)) return false;
        if (!self.chainCovers(caller.principal, g)) return false;
        // `grants.unknown` is read-only, so a capped caller covers no delegation.
        if (self.belowManagerCapped(caller) and g.right != .read) return false;
        return switch (caller.floor) {
            .outside => true,
            .orphan => self.chainCovers(unknown, g),
            .bound => |id| self.chainCovers(id, g),
        };
    }
    fn chainCovers(self: *const Registry, id: Id, requested: Grant) bool {
        var next: ?Id = id;
        while (next) |n| {
            const p = self.get(n) orelse return false;
            var covered = false;
            for (p.grants) |g| {
                if (!implies(g.right, requested.right)) continue;
                if (g.right == .admin or std.mem.eql(u8, g.scope, "*") or std.mem.eql(u8, g.scope, requested.scope)) {
                    covered = true;
                    break;
                }
                if (std.mem.startsWith(u8, g.scope, "path:") and std.mem.startsWith(u8, requested.scope, "path:")) {
                    if (pathContains(g.scope[5..], requested.scope[5..])) {
                        covered = true;
                        break;
                    }
                } else if (selector(requested.scope)) |r| {
                    if (std.mem.eql(u8, r.id, "*")) continue;
                    if (self.scopeAllows(n, g.scope, r)) {
                        covered = true;
                        break;
                    }
                }
            }
            if (!covered) return false;
            if (p.cap) |cap| if (!self.chainCovers(cap, requested)) return false;
            next = p.parent;
        }
        return true;
    }
};
extern "c" fn getentropy(*anyopaque, usize) c_int;
pub fn nowSeconds() i64 {
    var ts: os.c.timespec = undefined;
    if (os.c.clock_gettime(os.c.CLOCK.REALTIME, &ts) != 0) unreachable;
    return @intCast(ts.sec);
}
pub fn name(id: Id, buf: *[24]u8) []const u8 {
    return switch (id) {
        owner => "owner",
        unknown => "unknown",
        else => std.fmt.bufPrint(buf, "g{d}", .{id - 1}) catch unreachable,
    };
}
pub fn parseId(s: []const u8) ?Id {
    if (std.mem.eql(u8, s, "owner")) return owner;
    if (std.mem.eql(u8, s, "unknown")) return unknown;
    if (s.len < 2 or s[0] != 'g' or s[1] == '0') return null;
    for (s[1..]) |ch| if (!std.ascii.isDigit(ch)) return null;
    const n = std.fmt.parseInt(u64, s[1..], 10) catch return null;
    return std.math.add(u64, n, 1) catch null;
}
pub fn implies(held: Right, needed: Right) bool {
    return needed == .none or held == .admin or held == needed or (needed == .read and (held == .write or held == .respond or held == .files or held == .spawn));
}
pub fn pathContains(parent: []const u8, child: []const u8) bool {
    const p = std.mem.trimEnd(u8, parent, "/");
    return std.mem.eql(u8, p, child) or (std.mem.startsWith(u8, child, p) and child.len > p.len and child[p.len] == '/');
}
fn selector(s: []const u8) ?Resource {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    if (colon == 0 or colon + 1 == s.len) return null;
    return .{ .kind = s[0..colon], .id = s[colon + 1 ..] };
}
pub fn validateGrant(g: Grant) !void {
    const s = g.scope;
    if (g.right == .none) return error.InvalidScope;
    if (g.right == .admin and !std.mem.eql(u8, s, "*")) return error.InvalidScope;
    if (std.mem.eql(u8, s, "*") or std.mem.eql(u8, s, "self")) return;
    const r = selector(s) orelse return error.InvalidScope;
    if (std.mem.eql(u8, r.kind, "path")) {
        if (g.right != .files or !std.fs.path.isAbsolute(r.id)) return error.InvalidScope;
        var it = std.mem.splitScalar(u8, r.id, '/');
        while (it.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.InvalidScope;
    } else {
        if (!std.ascii.isLower(r.kind[0])) return error.InvalidScope;
        for (r.kind[1..]) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_') return error.InvalidScope;
        if (!std.mem.eql(u8, r.id, "*")) for (r.id) |ch| if (ch == ':' or ch == '*' or ch < 32 or ch == 127) return error.InvalidScope;
    }
    for (s) |ch| if (ch < 32 or ch == 127) return error.InvalidScope;
}
