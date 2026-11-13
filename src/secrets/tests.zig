const std = @import("std");
const proto = @import("proto");
const cli = @import("cli");
const secrets = @import("root.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const t = std.testing;

fn mode(dir: std.Io.Dir, path: []const u8) !u32 {
    const st = try dir.statFile(io, path, .{});
    return @intCast(st.permissions.toMode() & 0o777);
}

test "secrets: round-trip set/get/list/rm, persisted across reopen" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const binary = "\x00\xffkey\x00with nulls\n";
    {
        var s = try secrets.Store.open(a, io, tmp.dir, .{});
        defer s.deinit();
        try t.expectEqual(@as(usize, 0), s.list().len);
        try t.expect(try s.set("openai", "sk-old"));
        try t.expect(try s.set("anthropic", "sk-ant-123"));
        try t.expect(!try s.set("openai", "sk-new"));
        try t.expect(try s.set("bin.v1_x-y", binary));
        try t.expect(try s.set("empty", ""));
        try t.expect(try s.set("gone", "x"));
        try t.expect(try s.remove("gone"));
        try t.expect(!try s.remove("gone"));
        try t.expectEqualStrings("sk-new", s.get("openai").?);
        try t.expect(s.get("gone") == null);
    }
    try t.expectEqual(@as(u32, 0o600), try mode(tmp.dir, "secrets.key"));
    try t.expectEqual(@as(u32, 0o600), try mode(tmp.dir, "secrets.bin"));

    // Nothing is stored in the clear.
    const raw = try tmp.dir.readFileAlloc(io, "secrets.bin", a, .unlimited);
    defer a.free(raw);
    for ([_][]const u8{ "sk-ant-123", "sk-new", "anthropic", "openai" }) |needle|
        try t.expect(std.mem.indexOf(u8, raw, needle) == null);

    var s = try secrets.Store.open(a, io, tmp.dir, .{});
    defer s.deinit();
    const names = s.list();
    try t.expectEqual(@as(usize, 4), names.len);
    for (names, [_][]const u8{ "anthropic", "bin.v1_x-y", "empty", "openai" }) |e, want|
        try t.expectEqualStrings(want, e.name);
    try t.expectEqualStrings("sk-ant-123", s.get("anthropic").?);
    try t.expectEqualStrings(binary, s.get("bin.v1_x-y").?);
    try t.expectEqualStrings("", s.get("empty").?);
    try t.expectEqualStrings("sk-new", s.get("openai").?);
}

test "secrets: names, sizes and limits are validated" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var s = try secrets.Store.open(a, io, tmp.dir, .{});
    defer s.deinit();
    for ([_][]const u8{ "", ".hidden", "-x", "a/b", "a b", "../x", "é", &@as([65]u8, @splat('x')) }) |bad| {
        try t.expect(!secrets.validName(bad));
        try t.expectError(error.InvalidName, s.set(bad, "v"));
    }
    for ([_][]const u8{ "a", "A1", "anthropic", "api.key_2-b", &@as([64]u8, @splat('x')) }) |good| try t.expect(secrets.validName(good));
    const big = try a.alloc(u8, secrets.max_value + 1);
    defer a.free(big);
    @memset(big, 'x');
    try t.expectError(error.ValueTooLarge, s.set("big", big));
    try t.expect(try s.set("max", big[0..secrets.max_value]));
    try t.expectEqual(@as(usize, 1), s.list().len);
}

test "secrets: seal/unseal round-trips with a fresh salt and nonce each time" {
    var key: secrets.Key = .{ .bytes = @splat(7) };
    defer key.wipe();
    const one = try secrets.seal(a, io, &key, "payload");
    defer a.free(one);
    const two = try secrets.seal(a, io, &key, "payload");
    defer a.free(two);
    try t.expect(!std.mem.eql(u8, one, two));
    for ([_][]const u8{ one, two }) |blob| {
        const plain = try secrets.unseal(a, &key, blob);
        defer a.free(plain);
        try t.expectEqualStrings("payload", plain);
    }
}

test "secrets: tamper detection on every byte, truncation and the wrong key" {
    var key: secrets.Key = .{ .bytes = @splat(1) };
    defer key.wipe();
    const blob = try secrets.seal(a, io, &key, "\x01\x00\x00\x00\x01\x00a\x02\x00\x00\x00hi");
    defer a.free(blob);
    const copy = try a.dupe(u8, blob);
    defer a.free(copy);
    // Header (magic, salt, nonce), ciphertext and tag are all authenticated.
    for (0..copy.len) |i| {
        copy[i] ^= 0x01;
        defer copy[i] ^= 0x01;
        const err = secrets.unseal(a, &key, copy);
        if (i < secrets.magic.len) try t.expectError(error.InvalidStore, err) else try t.expectError(error.AuthenticationFailed, err);
    }
    for (0..copy.len) |n| {
        const err = secrets.unseal(a, &key, copy[0..n]);
        if (err) |_| return error.TestUnexpectedResult else |e| try t.expect(e == error.InvalidStore or e == error.AuthenticationFailed);
    }
    var other: secrets.Key = .{ .bytes = @splat(2) };
    defer other.wipe();
    try t.expectError(error.AuthenticationFailed, secrets.unseal(a, &other, blob));
    const plain = try secrets.unseal(a, &key, copy);
    defer a.free(plain);
}

test "secrets: a modified or foreign store file fails to open" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        var s = try secrets.Store.open(a, io, tmp.dir, .{});
        defer s.deinit();
        _ = try s.set("token", "secret-value");
        // A second store with its own keyfile, in the same directory.
        var foreign = try secrets.Store.open(a, io, tmp.dir, .{ .store = "other.bin", .keyfile = "other.key" });
        defer foreign.deinit();
        _ = try foreign.set("token", "attacker-value");
    }
    const good = try tmp.dir.readFileAlloc(io, "secrets.bin", a, .unlimited);
    defer a.free(good);

    // Flip a ciphertext byte in place.
    const bad = try a.dupe(u8, good);
    defer a.free(bad);
    bad[bad.len - 20] ^= 0x80;
    try tmp.dir.writeFile(io, .{ .sub_path = "secrets.bin", .data = bad });
    try t.expectError(error.AuthenticationFailed, secrets.Store.open(a, io, tmp.dir, .{}));

    // Swap in a file sealed under another key.
    try tmp.dir.copyFile("other.bin", tmp.dir, "secrets.bin", io, .{});
    try t.expectError(error.AuthenticationFailed, secrets.Store.open(a, io, tmp.dir, .{}));

    // Truncate.
    try tmp.dir.writeFile(io, .{ .sub_path = "secrets.bin", .data = good[0 .. good.len - 1] });
    try t.expectError(error.AuthenticationFailed, secrets.Store.open(a, io, tmp.dir, .{}));
    try tmp.dir.writeFile(io, .{ .sub_path = "secrets.bin", .data = good[0..10] });
    try t.expectError(error.InvalidStore, secrets.Store.open(a, io, tmp.dir, .{}));

    // The original still opens.
    try tmp.dir.writeFile(io, .{ .sub_path = "secrets.bin", .data = good });
    var s = try secrets.Store.open(a, io, tmp.dir, .{});
    defer s.deinit();
    try t.expectEqualStrings("secret-value", s.get("token").?);
}

test "secrets: keyfile is 0600 and an insecure or malformed one is refused" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var key = try secrets.Key.loadOrCreate(io, tmp.dir, "k");
    defer key.wipe();
    try t.expectEqual(@as(u32, 0o600), try mode(tmp.dir, "k"));
    var again = try secrets.Key.loadOrCreate(io, tmp.dir, "k");
    defer again.wipe();
    try t.expectEqualSlices(u8, &key.bytes, &again.bytes);

    const file = try tmp.dir.openFile(io, "k", .{});
    try file.setPermissions(io, .fromMode(0o644));
    file.close(io);
    try t.expectError(error.InsecureKeyfile, secrets.Key.loadOrCreate(io, tmp.dir, "k"));
    try t.expectError(error.InsecureKeyfile, secrets.Store.open(a, io, tmp.dir, .{ .keyfile = "k" }));

    try tmp.dir.writeFile(io, .{ .sub_path = "short", .data = "abc", .flags = .{ .permissions = .fromMode(0o600) } });
    try t.expectError(error.InvalidKeyfile, secrets.Key.loadOrCreate(io, tmp.dir, "short"));
    try tmp.dir.createDir(io, "dir", .fromMode(0o700));
    try t.expect(std.meta.isError(secrets.Key.loadOrCreate(io, tmp.dir, "dir")));
}

test "secrets: resolve a secret:<name> reference" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var s = try secrets.Store.open(a, io, tmp.dir, .{});
    defer s.deinit();
    try t.expectError(error.SecretNotFound, s.resolve("secret:anthropic"));
    _ = try s.set("anthropic", "sk-ant");
    try t.expectEqualStrings("sk-ant", try s.resolve("secret:anthropic"));
    try t.expectError(error.InvalidReference, s.resolve("anthropic"));
    try t.expectError(error.InvalidReference, s.resolve("secret:../x"));

    // The cfg.SecretStore adapter: a fresh name each time, never an overwrite.
    const one = try s.put(a, "api_key", "sk-1");
    defer a.free(one);
    const two = try s.put(a, "api_key", "sk-2");
    defer a.free(two);
    try t.expect(secrets.reference.valid(one) and std.mem.startsWith(u8, one, "secret:cfg-"));
    try t.expect(!std.mem.eql(u8, one, two));
    try t.expectEqualStrings("sk-1", try s.resolve(one));
    try t.expectEqualStrings("sk-2", try s.resolve(two));
}

const model = blk: {
    @setEvalBranchQuota(100_000);
    break :blk cli.manifest.normalize(.{ .format = 1, .tool = "venom-test", .summary = "Secrets verbs", .verbs = secrets.manifest });
};

fn send(d: *proto.Dispatcher, conn: *proto.Connection, line: []const u8) !proto.Response {
    conn.output.clearRetainingCapacity();
    try d.message(conn, .{ .ndjson = line });
    const out = std.mem.trimEnd(u8, conn.output.items, "\n");
    try t.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    return proto.Response.parse(a, out);
}

fn expectCode(r: proto.Response, code: []const u8) !void {
    try t.expect(r.body == .@"error");
    try t.expectEqualStrings(code, r.body.@"error".code);
}

test "secrets: verbs require admin and drive the store" {
    inline for (secrets.manifest) |v| try t.expectEqual(.admin, v.grant);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var s = try secrets.Store.open(a, io, tmp.dir, .{});
    defer s.deinit();
    var handlers: secrets.Handlers = .init(&s);
    const b = handlers.bindings();
    var d = try proto.Dispatcher.init(a, &model, &b, .{}, null);
    defer d.deinit();
    var fds: [2]std.c.fd_t = undefined;
    try t.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[1]);
    var conn = proto.Connection.init(a, fds[0]);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;

    // Without a registry callers are read-only: every secrets verb is denied
    // before its handler runs.
    for ([_][]const u8{
        "{\"id\":1,\"verb\":\"secrets.set\",\"params\":{\"name\":\"k\",\"value\":\"v\"}}",
        "{\"id\":1,\"verb\":\"secrets.get\",\"params\":{\"name\":\"k\"}}",
        "{\"id\":1,\"verb\":\"secrets.list\"}",
        "{\"id\":1,\"verb\":\"secrets.rm\",\"params\":{\"name\":\"k\"}}",
    }) |line| {
        var r = try send(&d, &conn, line);
        defer r.deinit();
        try expectCode(r, "denied.admin");
    }
    try t.expectEqual(@as(usize, 0), s.list().len);

    var registry = try proto.grants.Registry.init(a, "venom-test", .{});
    defer registry.deinit();
    conn.registry = &registry;
    {
        var r = try send(&d, &conn, "{\"id\":2,\"verb\":\"secrets.list\"}");
        defer r.deinit();
        try expectCode(r, "denied.admin"); // unknown principal: read only
    }
    conn.identity.principal = proto.grants.owner;

    const cases = [_][2][]const u8{
        .{ "{\"id\":3,\"verb\":\"secrets.set\",\"params\":{\"name\":\"anthropic\",\"value\":\"sk-1\"}}", "{\"name\":\"anthropic\",\"created\":true}" },
        .{ "{\"id\":4,\"verb\":\"secrets.set\",\"params\":{\"name\":\"anthropic\",\"value\":\"sk-2\"}}", "{\"name\":\"anthropic\",\"created\":false}" },
        .{ "{\"id\":5,\"verb\":\"secrets.get\",\"params\":{\"name\":\"anthropic\"}}", "{\"name\":\"anthropic\",\"value\":\"sk-2\"}" },
        .{ "{\"id\":6,\"verb\":\"secrets.list\"}", "{\"names\":[\"anthropic\"]}" },
        .{ "{\"id\":7,\"verb\":\"secrets.rm\",\"params\":{\"name\":\"anthropic\"}}", "{\"name\":\"anthropic\",\"removed\":true}" },
        .{ "{\"id\":8,\"verb\":\"secrets.rm\",\"params\":{\"name\":\"anthropic\"}}", "{\"name\":\"anthropic\",\"removed\":false}" },
    };
    for (cases) |case| {
        var r = try send(&d, &conn, case[0]);
        defer r.deinit();
        try t.expect(r.body == .ok);
        const got = try std.json.Stringify.valueAlloc(a, r.body.ok, .{});
        defer a.free(got);
        try t.expectEqualStrings(case[1], got);
    }
    const errors = [_][2][]const u8{
        .{ "{\"id\":9,\"verb\":\"secrets.get\",\"params\":{\"name\":\"anthropic\"}}", "not_found.secret" },
        .{ "{\"id\":10,\"verb\":\"secrets.set\",\"params\":{\"name\":\"../x\",\"value\":\"v\"}}", "invalid_params.secret_name" },
    };
    for (errors) |case| {
        var r = try send(&d, &conn, case[0]);
        defer r.deinit();
        try expectCode(r, case[1]);
    }
}
