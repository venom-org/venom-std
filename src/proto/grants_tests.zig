const std = @import("std");
const g = @import("grants.zig");
const proc = @import("process.zig");
const p = @import("root.zig");
const os = @import("os.zig");
const c = os.c;
const a = std.testing.allocator;
const t = std.testing;
const human: g.Identity = .{ .principal = g.owner };

fn issue(r: *g.Registry, caller: g.Identity, gs: []const g.Grant, now: i64) !g.Id {
    const issued = try r.issueChild(caller, .{ .grants = gs }, now);
    a.free(issued.token);
    return issued.principal;
}

test "exact rights, unknown is read-only, policy reload applies live" {
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    inline for (std.meta.tags(g.Right)) |held| inline for (std.meta.tags(g.Right)) |needed| {
        const expected = needed == .none or held == needed or held == .admin or (needed == .read and (held == .write or held == .spawn or held == .respond or held == .files));
        try t.expectEqual(expected, g.implies(held, needed));
    };
    try t.expect(r.allows(.{}, .read, null, now));
    try t.expect(!r.allows(.{}, .write, null, now));
    try t.expect(!r.allows(.{}, .spawn, null, now));
    try t.expectError(error.InvalidUnknownPolicy, r.setPolicy(.{ .unknown = &.{.{ .right = .write, .scope = "*" }} }));
    try r.setPolicy(.{ .unknown = &.{} });
    try t.expect(!r.allows(.{}, .read, null, now));
    try t.expect(r.allows(.{}, .none, null, now));
}

test "tokens, caps, attenuation, expiry and cascade" {
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const read = [_]g.Grant{.{ .right = .read, .scope = "*" }};
    const broad = try r.issueChild(human, .{ .grants = &.{.{ .right = .admin, .scope = "*" }} }, now);
    defer a.free(broad.token);
    const narrow = try issue(&r, human, &read, now);
    var outside: g.Identity = .{};
    try t.expectEqual(@as(?g.TokenFailure, null), r.authenticate(&outside, broad.token, now));
    try t.expect(r.allows(outside, .admin, null, now));
    var capped: g.Identity = .{ .floor = .{ .bound = narrow } };
    try t.expectEqual(@as(?g.TokenFailure, null), r.authenticate(&capped, broad.token, now));
    try t.expect(!r.allows(capped, .write, null, now));
    try t.expect(r.allows(capped, .read, null, now));
    try t.expectError(error.Denied, r.issueChild(capped, .{ .grants = &read }, now));
    const parent = try issue(&r, human, &.{ .{ .right = .spawn, .scope = "pane:*" }, .{ .right = .write, .scope = "pane:*" } }, now);
    const parent_conn: g.Identity = .{ .principal = parent };
    try t.expectError(error.Delegation, r.issueChild(parent_conn, .{ .grants = &.{.{ .right = .admin, .scope = "*" }} }, now));
    const child = try r.issueChild(parent_conn, .{ .grants = &.{.{ .right = .write, .scope = "pane:p1" }}, .ttl = 2 }, now);
    defer a.free(child.token);
    var conn: g.Identity = .{};
    try t.expectEqual(@as(?g.TokenFailure, null), r.authenticate(&conn, child.token, now));
    try t.expect(r.allows(conn, .write, .{ .kind = "pane", .id = "p1" }, now));
    try t.expect(!r.allows(conn, .write, .{ .kind = "pane", .id = "p2" }, now));
    try t.expect(!r.allows(conn, .write, null, now + 2));
    var expired: g.Identity = .{};
    try t.expectEqual(g.TokenFailure.expired, r.authenticate(&expired, child.token, now + 2).?);
    try r.revoke(human, parent, now);
    try t.expect(!r.connectionLive(conn, now));
    try t.expectEqual(g.TokenFailure.revoked, r.authenticate(&expired, child.token, now).?);
    const owner_token = try r.ownerToken();
    defer a.free(owner_token);
    var managed: g.Identity = .{ .floor = .{ .bound = narrow } };
    try t.expectEqual(g.TokenFailure.owner_context, r.authenticate(&managed, owner_token, now).?);
    managed.floor = .orphan;
    try t.expectEqual(g.TokenFailure.owner_context, r.authenticate(&managed, owner_token, now).?);
    managed.floor = .outside;
    managed.below_manager = true;
    try t.expectEqual(g.TokenFailure.owner_context, r.authenticate(&managed, owner_token, now).?);
    try t.expectEqual(g.unknown, managed.principal);
    managed.below_manager = false;
    try t.expectEqual(@as(?g.TokenFailure, null), r.authenticate(&managed, owner_token, now));
    for ([_][]const u8{ "garbage", "vnt1.other.owner.123", "vnt1.test.g999.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "vnt1.test.owner.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }) |bad| {
        var unknown: g.Identity = .{};
        try t.expectEqual(g.TokenFailure.invalid, r.authenticate(&unknown, bad, now).?);
    }
}

const Tree = struct {
    creator: g.Id,
    pub fn parentOf(_: *Tree, resource: g.Resource) ?g.Resource {
        if (std.mem.eql(u8, resource.kind, "pane") and !std.mem.eql(u8, resource.id, "missing")) return .{ .kind = "session", .id = "s1" };
        return null;
    }
    pub fn ownerOf(self: *Tree, resource: g.Resource) ?g.Id {
        return if (std.mem.eql(u8, resource.id, "p1")) self.creator else null;
    }
};
test "containment, self, missing resources, principal visibility, approval" {
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const parent = try issue(&r, human, &.{ .{ .right = .spawn, .scope = "*" }, .{ .right = .write, .scope = "session:s1" } }, now);
    var tree: Tree = .{ .creator = parent };
    r.containment = g.Containment.init(&tree);
    const child = try issue(&r, .{ .principal = parent }, &.{.{ .right = .write, .scope = "pane:p1" }}, now);
    tree.creator = child;
    try t.expect(r.allows(.{ .principal = parent }, .write, .{ .kind = "pane", .id = "p1" }, now));
    try t.expect(!r.allows(.{ .principal = parent }, .write, .{ .kind = "pane", .id = "missing" }, now));
    const self_id = try issue(&r, human, &.{.{ .right = .write, .scope = "self" }}, now);
    tree.creator = self_id;
    try t.expect(r.allows(.{ .principal = self_id }, .write, .{ .kind = "pane", .id = "p1" }, now));
    try t.expect(!r.allows(.{ .principal = self_id }, .write, .{ .kind = "pane", .id = "p2" }, now));
    try t.expect(r.principalVisible(.{ .principal = parent }, child, now));
    try t.expect(!r.canRespond(parent, parent));
    try t.expect(!r.canRespond(child, parent));
    try t.expect(r.canRespond(self_id, parent));
    for ([_][]const u8{ "", "pane:", ":p1", "pane:p*", "path:relative", "path:/a/../b" }) |scope| try t.expectError(error.InvalidScope, g.validateGrant(.{ .right = .files, .scope = scope }));
    try t.expect(g.pathContains("/proj", "/proj/child"));
    try t.expect(!g.pathContains("/proj", "/project2"));
}

test "ancestry starttime, nearest binding, outside and bound token theft" {
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const root = try proc.stat(c.getpid());
    const bound = try r.issueChild(human, .{ .kind = .agent, .root = root.ref, .grants = &.{.{ .right = .write, .scope = "*" }} }, now);
    defer a.free(bound.token);
    const chain = proc.walk(c.getpid(), -1);
    const identity = r.resolve(chain, c.getpid(), now);
    try t.expectEqual(bound.principal, identity.principal);
    var outside: g.Identity = .{};
    try t.expectEqual(g.TokenFailure.binding, r.authenticate(&outside, bound.token, now).?);
    var inside = identity;
    try t.expectEqual(@as(?g.TokenFailure, null), r.authenticate(&inside, bound.token, now));
    r.entries.items[@intCast(bound.principal)].root.?.start += 1;
    try t.expectEqual(g.unknown, r.resolve(chain, c.getpid(), now).principal);
    const unknown = r.resolve(.{}, 0, now);
    try t.expectEqual(g.unknown, unknown.principal);
    var failed = chain;
    failed.failed = true;
    try t.expectEqual(g.Floor.orphan, r.resolve(failed, c.getpid(), now).floor);
}

test "audit is secret-free, rotates, and failures do not alter authorization" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);
    const dir_z = try a.dupeSentinel(u8, dir, 0);
    defer a.free(dir_z);
    try t.expectEqual(@as(c_int, 0), c.chmod(dir_z, 0o700));
    const path = try std.fmt.allocPrint(a, "{s}/audit.ndjson", .{dir});
    defer a.free(path);
    var log = try p.audit.Log.init(a, .{ .path = path, .source = "test/instance", .max_bytes = 1, .keep = 2 });
    defer log.deinit();
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    r.observer = log.observer();
    _ = try issue(&r, human, &.{.{ .right = .read, .scope = "*" }}, g.nowSeconds());
    try t.expect(log.writable);
    const rotated = try std.fmt.allocPrintSentinel(a, "{s}.1", .{path}, 0);
    defer a.free(rotated);
    const fd = c.open(rotated, .{ .ACCMODE = .RDONLY });
    try t.expect(fd >= 0);
    defer os.close(fd);
    var bytes: [4096]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    try t.expect(n > 0);
    try t.expect(std.mem.indexOf(u8, bytes[0..@intCast(n)], "vnt1.") == null);
    var broken = try p.audit.Log.init(a, .{ .path = "/proc/no-such-dir/audit", .source = "test/instance" });
    defer broken.deinit();
    broken.record(.{ .event = "denied", .principal = g.unknown });
    try t.expect(!broken.writable);
    try t.expect(!r.allows(.{}, .admin, null, g.nowSeconds()));
}

extern "c" fn fork() c.pid_t;
extern "c" fn pause() c_int;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn prctl(c_int, ...) c_int;
const PidPacket = extern struct { pid: c.pid_t, generation: u32 };
fn report(fd: c.fd_t, generation: u32) void {
    const packet: PidPacket = .{ .pid = c.getpid(), .generation = generation };
    if (c.write(fd, @ptrCast(&packet), @sizeOf(PidPacket)) != @sizeOf(PidPacket)) _exit(91);
}
fn readPacket(fd: c.fd_t) !PidPacket {
    var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    try os.poll(&fds, 2000);
    if (fds[0].revents & c.POLL.IN == 0) return error.TestTimeout;
    var packet: PidPacket = undefined;
    if (c.read(fd, @ptrCast(&packet), @sizeOf(PidPacket)) != @sizeOf(PidPacket)) return error.TestFailed;
    return packet;
}
test "real root, child, grandchild, nested binding and subreaper orphan" {
    if (!os.is_linux) return error.SkipZigTest;
    try proc.subreaper();
    defer _ = prctl(36, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    var fds: [2]c.fd_t = undefined;
    try t.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer os.close(fds[0]);
    defer os.close(fds[1]);
    const root_pid = fork();
    if (root_pid == 0) {
        report(fds[1], 0);
        const child_pid = fork();
        if (child_pid == 0) {
            report(fds[1], 1);
            const grandchild_pid = fork();
            if (grandchild_pid == 0) {
                report(fds[1], 2);
                while (true) _ = pause();
            }
            if (grandchild_pid < 0) _exit(92);
            while (true) _ = pause();
        }
        if (child_pid < 0) _exit(93);
        while (true) _ = pause();
    }
    try t.expect(root_pid > 0);
    var pids: [3]c.pid_t = .{ root_pid, 0, 0 };
    defer {
        for (pids) |pid| if (pid > 0) {
            _ = c.kill(pid, .KILL);
        };
        for (pids) |pid| if (pid > 0) {
            _ = c.waitpid(pid, null, 0);
        };
    }
    for (0..3) |_| {
        const packet = try readPacket(fds[0]);
        pids[packet.generation] = packet.pid;
    }
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const root = try r.issueChild(human, .{ .kind = .agent, .root = (try proc.stat(root_pid)).ref, .grants = &.{.{ .right = .admin, .scope = "*" }} }, now);
    defer a.free(root.token);
    for (pids) |pid| try t.expectEqual(root.principal, r.resolve(proc.walk(pid, c.getpid()), pid, now).principal);
    const nested = try r.issueChild(.{ .principal = root.principal }, .{ .kind = .agent, .root = (try proc.stat(pids[1])).ref, .grants = &.{.{ .right = .read, .scope = "*" }} }, now);
    defer a.free(nested.token);
    const cached = r.resolve(proc.walk(pids[2], c.getpid()), pids[2], now);
    try t.expectEqual(nested.principal, cached.principal);
    // Killing both parents reparents the surviving grandchild to our subreaper.
    _ = c.kill(pids[1], .KILL);
    _ = c.kill(root_pid, .KILL);
    _ = c.waitpid(root_pid, null, 0);
    _ = c.waitpid(pids[1], null, 0);
    pids[0] = 0;
    pids[1] = 0;
    const deadline = os.nowMs() + 2000;
    while ((try proc.stat(pids[2])).parent != c.getpid()) {
        if (os.nowMs() > deadline) return error.TestTimeout;
        _ = c.sched_yield();
    }
    const orphan = r.resolve(proc.walk(pids[2], c.getpid()), pids[2], now);
    try t.expect(orphan.floor == .orphan);
    try t.expectEqual(g.unknown, orphan.principal);
    try t.expect(!r.allows(orphan, .write, null, now));
    // Identity stays cached, but the old principal loses rights live.
    r.sweep(now);
    try t.expect(!r.connectionLive(cached, now));
}

test "canonical path, symlink escape, dot-dot, new destination and component boundary" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);
    const scope = try std.fmt.allocPrint(a, "path:{s}", .{dir});
    defer a.free(scope);
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const id = try issue(&r, human, &.{.{ .right = .files, .scope = scope }}, now);
    const identity: g.Identity = .{ .principal = id };
    const destination = try std.fmt.allocPrint(a, "{s}/new/file", .{dir});
    defer a.free(destination);
    const canonical = try p.authorizePath(a, &r, identity, .files, destination, now);
    defer a.free(canonical);
    try t.expectEqualStrings(destination, canonical);
    const escaped = try std.fmt.allocPrint(a, "{s}/../escape", .{dir});
    defer a.free(escaped);
    try t.expectError(error.Denied, p.authorizePath(a, &r, identity, .files, escaped, now));
    const link = try std.fmt.allocPrintSentinel(a, "{s}/link", .{dir}, 0);
    defer a.free(link);
    try t.expectEqual(@as(c_int, 0), c.symlink("/", link));
    const linked = try std.fmt.allocPrint(a, "{s}/link/etc", .{dir});
    defer a.free(linked);
    try t.expectError(error.Denied, p.authorizePath(a, &r, identity, .files, linked, now));
    const tricky = try std.fmt.allocPrint(a, "{s}/new/../link/etc", .{dir});
    defer a.free(tricky);
    try t.expectError(error.Denied, p.authorizePath(a, &r, identity, .files, tricky, now));
    const dangling = try std.fmt.allocPrintSentinel(a, "{s}/dangling", .{dir}, 0);
    defer a.free(dangling);
    try t.expectEqual(@as(c_int, 0), c.symlink("/no-such-venom-test-directory", dangling));
    const dangling_child = try std.fmt.allocPrint(a, "{s}/dangling/child", .{dir});
    defer a.free(dangling_child);
    try t.expectError(error.Denied, p.authorizePath(a, &r, identity, .files, dangling_child, now));
}

test "delegation preserves a connection's independent floor cap" {
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const floor = try issue(&r, human, &.{.{ .right = .spawn, .scope = "pane:p1" }}, now);
    const broad = try issue(&r, human, &.{.{ .right = .admin, .scope = "*" }}, now);
    const caller: g.Identity = .{ .principal = broad, .floor = .{ .bound = floor } };
    const delegated = try r.issueChild(caller, .{}, now);
    defer a.free(delegated.token);
    var outside: g.Identity = .{};
    try t.expectEqual(@as(?g.TokenFailure, null), r.authenticate(&outside, delegated.token, now));
    try t.expect(!r.allows(outside, .admin, null, now));
    try t.expect(!r.allows(outside, .write, null, now));
    try t.expect(r.allows(outside, .spawn, .{ .kind = "pane", .id = "p1" }, now));
    try t.expect(!r.allows(outside, .spawn, .{ .kind = "pane", .id = "p2" }, now));
    try r.revoke(human, floor, now);
    try t.expect(!r.connectionLive(outside, now));
}

test "a concrete containing scope cannot delegate a wildcard selector" {
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    var tree: Tree = .{ .creator = g.owner };
    r.containment = g.Containment.init(&tree);
    const now = g.nowSeconds();
    const parent = try issue(&r, human, &.{ .{ .right = .spawn, .scope = "*" }, .{ .right = .write, .scope = "session:s1" } }, now);
    try t.expectError(error.Delegation, r.issueChild(.{ .principal = parent }, .{ .grants = &.{.{ .right = .write, .scope = "pane:*" }} }, now));
}

fn issueNs(r: *g.Registry, caller: g.Identity, gs: []const g.Grant, namespace: ?[]const u8, now: i64) !g.Id {
    const issued = try r.issueChild(caller, .{ .grants = gs, .namespace = namespace }, now);
    a.free(issued.token);
    return issued.principal;
}

test "namespace issuance, attenuation, inheritance and the user fallback" {
    var r = try g.Registry.init(a, "venomx", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const spawn = [_]g.Grant{ .{ .right = .spawn, .scope = "*" }, .{ .right = .write, .scope = "*" } };
    // Fallbacks: the owner is venomx; unknown and owner children without the parameter are user.
    try t.expectEqualStrings("venomx", r.namespaceOf(g.owner));
    try t.expectEqualStrings("user", r.namespaceOf(g.unknown));
    const plain = try issueNs(&r, human, &spawn, null, now);
    try t.expectEqualStrings("user", r.namespaceOf(plain));
    try t.expectEqual(@as(?[]const u8, null), r.get(plain).?.namespace);
    // Validation: [a-z][a-z0-9-]{0,31}.
    for ([_][]const u8{ "", "Venom", "1venom", "-x", "venom_os", "venom.os", "abcdefghijklmnopqrstuvwxyz0123456" }) |bad|
        try t.expectError(error.InvalidNamespace, r.issueChild(human, .{ .grants = &spawn, .namespace = bad }, now));
    _ = try issueNs(&r, human, &spawn, "a-0-0-0-0-0-0-0-0-0-0-0-0-0-0-z", now);
    // The owner may issue any namespace but venomx.
    try t.expectError(error.NamespaceDenied, r.issueChild(human, .{ .grants = &spawn, .namespace = "venomx" }, now));
    const venom = try issueNs(&r, human, &spawn, "venom", now);
    try t.expectEqualStrings("venom", r.namespaceOf(venom));
    // An admin principal may also issue any namespace but venomx.
    const admin = try issueNs(&r, human, &.{.{ .right = .admin, .scope = "*" }}, null, now);
    const admin_conn: g.Identity = .{ .principal = admin };
    try t.expectEqualStrings("venom-os", r.namespaceOf(try issueNs(&r, admin_conn, &spawn, "venom-os", now)));
    try t.expectError(error.NamespaceDenied, r.issueChild(admin_conn, .{ .grants = &spawn, .namespace = "venomx" }, now));
    // Any other issuer may only pass its own namespace, and children inherit it.
    const venom_conn: g.Identity = .{ .principal = venom };
    try t.expectError(error.NamespaceDenied, r.issueChild(venom_conn, .{ .grants = &spawn, .namespace = "venom-os" }, now));
    try t.expectError(error.NamespaceDenied, r.issueChild(venom_conn, .{ .grants = &spawn, .namespace = "user" }, now));
    try t.expectError(error.NamespaceDenied, r.issueChild(venom_conn, .{ .grants = &spawn, .namespace = "venomx" }, now));
    const own = try issueNs(&r, venom_conn, &spawn, "venom", now);
    try t.expectEqualStrings("venom", r.namespaceOf(own));
    const inherited = try issueNs(&r, venom_conn, &spawn, null, now);
    try t.expectEqualStrings("venom", r.namespaceOf(inherited));
    const pane = try r.issueChild(.{ .principal = inherited }, .{ .kind = .pane, .pane = "p1", .grants = &.{.{ .right = .write, .scope = "self" }} }, now);
    defer a.free(pane.token);
    try t.expectEqualStrings("venom", r.namespaceOf(pane.principal));
    // A user-namespaced, non-admin issuer may pass only user.
    const plain_conn: g.Identity = .{ .principal = plain };
    try t.expectError(error.NamespaceDenied, r.issueChild(plain_conn, .{ .grants = &spawn, .namespace = "venom" }, now));
    try t.expectEqualStrings("user", r.namespaceOf(try issueNs(&r, plain_conn, &spawn, "user", now)));
    try t.expectEqualStrings("user", r.namespaceOf(try issueNs(&r, plain_conn, &spawn, null, now)));
    // An admin token used under a bound non-admin floor is not an admin issuer.
    const floor = try issueNs(&r, human, &spawn, "venom", now);
    const capped: g.Identity = .{ .principal = admin, .floor = .{ .bound = floor } };
    try t.expectError(error.NamespaceDenied, r.issueChild(capped, .{ .grants = &spawn, .namespace = "venom-os" }, now));
}

test "a pane the owner creates inherits the owner's namespace; its tokens and agents do not" {
    var r = try g.Registry.init(a, "venomx", .{});
    defer r.deinit();
    const now: i64 = 1000;
    const spawn = [_]g.Grant{.{ .right = .spawn, .scope = "*" }};
    const pane = try r.issueChild(human, .{ .kind = .pane, .pane = "p0" }, now);
    defer a.free(pane.token);
    try t.expectEqualStrings("venomx", r.namespaceOf(pane.principal));
    // The rights are a pane's defaults: the namespace adds none.
    const rights = r.get(pane.principal).?.grants;
    try t.expectEqual(r.policy.interactive.len, rights.len);
    for (r.policy.interactive, rights) |want, got| {
        try t.expectEqual(want.right, got.right);
        try t.expectEqualStrings(want.scope, got.scope);
    }
    // The owner's tokens and agents still read as `user`.
    try t.expectEqualStrings("user", r.namespaceOf(try issueNs(&r, human, &spawn, null, now)));
    const agent = try r.issueChild(human, .{ .kind = .agent, .grants = &spawn }, now);
    defer a.free(agent.token);
    try t.expectEqualStrings("user", r.namespaceOf(agent.principal));
    // An explicit namespace still wins, and the reserved one is still refused.
    const named = try r.issueChild(human, .{ .kind = .pane, .pane = "p1", .namespace = "venom" }, now);
    defer a.free(named.token);
    try t.expectEqualStrings("venom", r.namespaceOf(named.principal));
    try t.expectError(error.NamespaceDenied, r.issueChild(human, .{ .kind = .pane, .pane = "p2", .namespace = "venomx" }, now));
    // What the pane issues inherits from the pane; it cannot pass anything else.
    const child_conn: g.Identity = .{ .principal = try issueNs(&r, .{ .principal = pane.principal }, &.{}, null, now) };
    try t.expectEqualStrings("venomx", r.namespaceOf(child_conn.principal));
    try t.expectError(error.NamespaceDenied, r.issueChild(.{ .principal = pane.principal }, .{ .grants = &.{}, .namespace = "user" }, now));
    try t.expectError(error.NamespaceDenied, r.issueChild(.{ .principal = pane.principal }, .{ .grants = &.{}, .namespace = "venom" }, now));
}

test "the owner namespace is the registry's tool, not a fixed venomx" {
    var r = try g.Registry.init(a, "venom", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const spawn = [_]g.Grant{ .{ .right = .spawn, .scope = "*" }, .{ .right = .write, .scope = "*" } };
    try t.expectEqualStrings("venom", r.ownerNamespace());
    try t.expectEqualStrings("venom", r.namespaceOf(g.owner));
    // The tool's own namespace is reserved; venomx is an ordinary one here.
    try t.expectError(error.NamespaceDenied, r.issueChild(human, .{ .grants = &spawn, .namespace = "venom" }, now));
    const admin = try issueNs(&r, human, &.{.{ .right = .admin, .scope = "*" }}, null, now);
    try t.expectError(error.NamespaceDenied, r.issueChild(.{ .principal = admin }, .{ .grants = &spawn, .namespace = "venom" }, now));
    const vx = try issueNs(&r, human, &spawn, "venomx", now);
    try t.expectEqualStrings("venomx", r.namespaceOf(vx));
    try t.expectEqualStrings("venomx", r.namespaceOf(try issueNs(&r, .{ .principal = vx }, &spawn, null, now)));
}

test "a process principal has no token, and only the owner, an admin or another may bind" {
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const me = try proc.stat(c.getpid());
    const spawner = try issue(&r, human, &.{.{ .right = .spawn, .scope = "*" }}, now);
    const admin = try issue(&r, human, &.{.{ .right = .admin, .scope = "*" }}, now);
    const agent = try r.issueChild(human, .{ .kind = .agent, .grants = &.{.{ .right = .spawn, .scope = "*" }} }, now);
    defer a.free(agent.token);
    const gs = [_]g.Grant{ .{ .right = .read, .scope = "*" }, .{ .right = .spawn, .scope = "*" } };
    // `spawn` is not enough, so an agent can't bind the human's shell.
    try t.expectError(error.BindDenied, r.issueChild(.{ .principal = spawner }, .{ .kind = .process, .root = me.ref, .grants = &.{.{ .right = .spawn, .scope = "*" }} }, now));
    try t.expectError(error.BindDenied, r.issueChild(.{ .principal = agent.principal }, .{ .kind = .process, .root = me.ref, .grants = &.{.{ .right = .spawn, .scope = "*" }} }, now));
    try t.expect(r.mayBind(.{ .principal = admin }, now));
    try t.expect(!r.mayBind(.{}, now));
    try t.expectError(error.InvalidKind, r.issueChild(human, .{ .kind = .process, .grants = &gs }, now));

    const bound = try r.issueChild(human, .{ .kind = .process, .root = me.ref, .grants = &gs, .label = "control" }, now);
    defer a.free(bound.token);
    try t.expectEqual(@as(usize, 0), bound.token.len);
    try t.expectEqual(@as(?i64, null), bound.expires);
    try t.expectEqual(@as(?[32]u8, null), r.get(bound.principal).?.token_hash);
    try t.expect(r.bound_dirty);

    // Ancestry alone resolves to it, and it may bind in its turn.
    const identity = r.resolve(proc.walk(c.getpid(), -1), c.getpid(), now);
    try t.expectEqual(bound.principal, identity.principal);
    try t.expect(r.mayBind(identity, now));
    // Twice on one process would make `resolve` pick by accident.
    try t.expectError(error.ProcessBound, r.issueChild(human, .{ .kind = .process, .root = me.ref, .grants = &gs }, now));

    // Its children and tokens stay covered by it; an agent under it can't bind.
    try t.expectError(error.Delegation, r.issueChild(identity, .{ .kind = .process, .root = .{ .pid = 2, .start = 1 }, .grants = &.{.{ .right = .write, .scope = "*" }} }, now));
    const under = try r.issueChild(identity, .{ .kind = .agent, .grants = &.{.{ .right = .spawn, .scope = "*" }} }, now);
    defer a.free(under.token);
    try t.expect(!r.mayBind(.{ .principal = under.principal, .floor = .{ .bound = bound.principal } }, now));

    r.bound_dirty = false;
    try r.revoke(human, bound.principal, now);
    try t.expect(r.bound_dirty);
    try t.expectEqual(g.unknown, r.resolve(proc.walk(c.getpid(), -1), c.getpid(), now).principal);
}

test "a process principal is that process's alone, and a marked process can't be bound" {
    if (!os.is_linux) return error.SkipZigTest;
    var r = try g.Registry.init(a, "test", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const gs = [_]g.Grant{ .{ .right = .read, .scope = "*" }, .{ .right = .respond, .scope = "*" }, .{ .right = .spawn, .scope = "*" } };
    // A view (this process), with a shell below it and that shell's child.
    var fds: [2]c.fd_t = undefined;
    try t.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer os.close(fds[0]);
    defer os.close(fds[1]);
    const shell = fork();
    if (shell == 0) {
        report(fds[1], 0);
        const job = fork();
        if (job == 0) {
            report(fds[1], 1);
            while (true) _ = pause();
        }
        while (true) _ = pause();
    }
    try t.expect(shell > 0);
    var pids: [2]c.pid_t = .{ shell, 0 };
    defer {
        for (pids) |pid| if (pid > 0) {
            _ = c.kill(pid, .KILL);
        };
        _ = c.waitpid(shell, null, 0);
    }
    for (0..2) |_| {
        const packet = try readPacket(fds[0]);
        pids[packet.generation] = packet.pid;
    }
    const view = try r.issueChild(human, .{ .kind = .process, .root = (try proc.stat(c.getpid())).ref, .grants = &gs, .namespace = "person" }, now);
    defer a.free(view.token);
    const as_view = r.resolve(proc.walk(c.getpid(), -1), c.getpid(), now);
    try t.expectEqual(view.principal, as_view.principal);
    try t.expect(r.allows(as_view, .respond, null, now));
    for (pids) |pid| {
        const below = r.resolve(proc.walk(pid, -1), pid, now);
        try t.expectEqual(g.unknown, below.principal);
        try t.expect(below.floor == .outside);
        try t.expect(!r.allows(below, .respond, null, now));
        try t.expect(!r.mayBind(below, now));
    }
    // What a process principal binds does nothing for what is below that pid:
    // here, the shell is bound, and only the shell gains.
    const bound_shell = try r.issueChild(as_view, .{ .kind = .process, .root = (try proc.stat(shell)).ref, .grants = &gs }, now);
    defer a.free(bound_shell.token);
    try t.expectEqual(bound_shell.principal, r.resolve(proc.walk(shell, -1), shell, now).principal);
    try t.expectEqual(g.unknown, r.resolve(proc.walk(pids[1], -1), pids[1], now).principal);
    // An ordinary bound principal still covers its subtree.
    var agents = try g.Registry.init(a, "test", .{});
    defer agents.deinit();
    const agent = try agents.issueChild(human, .{ .kind = .agent, .root = (try proc.stat(shell)).ref, .grants = &gs }, now);
    defer a.free(agent.token);
    try t.expectEqual(agent.principal, agents.resolve(proc.walk(pids[1], -1), pids[1], now).principal);

    // A manager, such as a venomx daemon, can't be bound.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer a.free(parent);
    const dir = c.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try t.expect(dir >= 0);
    defer os.close(dir);
    var managed = try g.Registry.init(a, "test", .{});
    defer managed.deinit();
    managed.marker_dir = dir;
    const me = (try proc.stat(c.getpid())).ref;
    try p.managers.mark(dir);
    try t.expect(p.managers.marked(dir, me));
    try t.expectError(error.ProcessManager, managed.issueChild(human, .{ .kind = .process, .root = me, .grants = &gs }, now));
    p.managers.unmark(dir);
    try t.expect(!p.managers.marked(dir, me));
    const unmarked = try managed.issueChild(human, .{ .kind = .process, .root = me, .grants = &gs }, now);
    a.free(unmarked.token);
}

test "isolation off widens unknown and interactive panes, not respond, files or admin" {
    var r = try g.Registry.init(a, "test", .{ .isolation = false });
    defer r.deinit();
    const now = g.nowSeconds();
    const pane: g.Resource = .{ .kind = "pane", .id = "p0" };
    const outside: g.Identity = .{};
    try t.expect(!r.isolated());
    try t.expect(r.allows(outside, .write, pane, now));
    try t.expect(r.allows(outside, .spawn, null, now));
    try t.expect(!r.allows(outside, .respond, null, now));
    try t.expect(!r.allows(outside, .files, null, now));
    try t.expect(!r.allows(outside, .admin, null, now));
    // An escapee of a pane tree (ORPHAN) is capped by `unknown`, now wide.
    try t.expect(r.allows(.{ .floor = .orphan }, .write, pane, now));
    // The owner's pane with no `grants` gets the open profile.
    const shell = try r.issueChild(human, .{ .kind = .pane, .pane = "p1" }, now);
    defer a.free(shell.token);
    try t.expectEqual(g.open_grants.len, r.get(shell.principal).?.grants.len);
    try t.expect(r.allows(.{ .principal = shell.principal }, .write, pane, now));
    // The unknown caller may issue, but only within what it holds.
    const issued = try r.issueChild(outside, .{ .grants = &.{.{ .right = .write, .scope = "pane:p0" }} }, now);
    defer a.free(issued.token);
    try t.expectError(error.Delegation, r.issueChild(outside, .{ .grants = &.{.{ .right = .respond, .scope = "*" }} }, now));
    // Tokens stay as narrow as issued.
    const narrow = try issue(&r, human, &.{.{ .right = .read, .scope = "*" }}, now);
    try t.expect(!r.allows(.{ .principal = narrow }, .write, pane, now));
}

test "below another manager, isolation off still means grants.unknown" {
    var r = try g.Registry.init(a, "test", .{ .isolation = false });
    defer r.deinit();
    const now = g.nowSeconds();
    const pane: g.Resource = .{ .kind = "pane", .id = "p0" };
    const agent: g.Identity = .{ .below_manager = true };
    try t.expect(r.allows(agent, .read, pane, now));
    try t.expect(!r.allows(agent, .write, pane, now));
    try t.expect(!r.allows(agent, .spawn, null, now));
    try t.expect(!r.allows(.{ .floor = .orphan, .below_manager = true }, .write, pane, now));
    try t.expectError(error.Denied, r.issueChild(agent, .{ .grants = &.{.{ .right = .read, .scope = "*" }} }, now));
    try r.setPolicy(.{ .isolation = false, .unknown = &.{} });
    try t.expect(!r.allows(agent, .read, pane, now));
    try t.expect(r.allows(.{}, .write, pane, now));
}

test "turning isolation on brings the configured lists back" {
    var r = try g.Registry.init(a, "test", .{ .isolation = false, .unknown = &.{} });
    defer r.deinit();
    const now = g.nowSeconds();
    try t.expect(r.allows(.{}, .write, null, now));
    try r.setPolicy(.{ .unknown = &.{} });
    try t.expect(r.isolated());
    try t.expect(!r.allows(.{}, .read, null, now));
    const shell = try r.issueChild(human, .{ .kind = .pane, .pane = "p1" }, now);
    defer a.free(shell.token);
    try t.expectEqual((g.Policy{}).interactive.len, r.get(shell.principal).?.grants.len);
    try r.setPolicy(.{ .isolation = false });
    try t.expect(r.allows(.{}, .write, null, now));
    // Off still validates the lists.
    try t.expectError(error.InvalidUnknownPolicy, r.setPolicy(.{ .isolation = false, .unknown = &.{.{ .right = .write, .scope = "*" }} }));
}

test "namespaces are names only with isolation off, the owner's stays reserved" {
    var r = try g.Registry.init(a, "venomx", .{});
    defer r.deinit();
    const now = g.nowSeconds();
    const tool = try r.issueChild(human, .{ .grants = &.{.{ .right = .spawn, .scope = "*" }}, .namespace = "venom" }, now);
    defer a.free(tool.token);
    try t.expect(r.mayUseNamespace(tool.principal, "venom"));
    try t.expect(!r.mayUseNamespace(tool.principal, "user"));
    try t.expect(r.mayUseNamespace(g.owner, "user"));
    try t.expect(!r.mayUseNamespace(g.owner, "venomx"));
    try t.expectError(error.NamespaceDenied, r.issueChild(.{ .principal = tool.principal }, .{ .namespace = "other" }, now));
    try r.setPolicy(.{ .isolation = false });
    try t.expect(r.mayUseNamespace(tool.principal, "user"));
    try t.expect(r.mayUseNamespace(g.unknown, "anything"));
    try t.expect(!r.mayUseNamespace(tool.principal, "venomx"));
    const other = try r.issueChild(.{ .principal = tool.principal }, .{ .namespace = "other" }, now);
    defer a.free(other.token);
    try t.expectEqualStrings("other", r.namespaceOf(other.principal));
    try t.expectError(error.NamespaceDenied, r.issueChild(.{ .principal = tool.principal }, .{ .namespace = "venomx" }, now));
}
