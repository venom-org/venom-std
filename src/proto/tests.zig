const std = @import("std");
const p = @import("root.zig");
const os = @import("os.zig");
const c = os.c;
const a = std.testing.allocator;
const identity: p.Identity = .{ .name = "venom-test", .version = "0" };
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    parent: [:0]u8,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const parent = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
        errdefer a.free(parent);
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(parent, 0o700));
        return .{ .tmp = tmp, .parent = parent, .path = try std.fmt.allocPrintSentinel(a, "{s}/test.sock", .{parent}, 0) };
    }
    fn deinit(self: *Fixture) void {
        a.free(self.path);
        a.free(self.parent);
        self.tmp.cleanup();
    }
    fn options(self: Fixture) p.ServerOptions {
        return .{ .hello = .{ .identity = identity }, .path = .{ .socket = self.path } };
    }
    fn client(self: Fixture, protocol: p.Protocol, versions: []const i64) !p.Client {
        return p.Client.init(a, .{ .tool = identity.name, .path = self.options().path, .hello = .{ .identity = identity, .versions = versions }, .protocol = protocol });
    }
    fn raw(self: Fixture) !p.Connection {
        const fd = try os.socket();
        errdefer os.close(fd);
        var addr = try os.address(self.path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.ConnectFailed;
        return p.Connection.init(a, fd);
    }
};
fn handshake(server: *p.Server, client: *p.Client) !void {
    const deadline = os.nowMs() + 2000;
    while (os.nowMs() < deadline) {
        try server.poll(0);
        if (try client.pollHello(1)) return;
    }
    return error.TestTimeout;
}
fn receive(server: *p.Server, conn: *p.Connection) !p.Message {
    const deadline = os.nowMs() + 2000;
    while (os.nowMs() < deadline) {
        try conn.flush();
        try server.poll(0);
        if (try conn.next()) |msg| return msg;
        _ = try conn.read();
    }
    return error.TestTimeout;
}
fn expectContains(bytes: []const u8, expected: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
}
const Echo = struct {
    json: usize = 0,
    binary: usize = 0,
    pub fn message(self: *Echo, conn: *p.Connection, msg: p.Message) anyerror!void {
        switch (msg) {
            .ndjson => |bytes| {
                self.json += 1;
                // Transport-test handler: validates that '{' was preserved.
                try std.testing.expectEqual(@as(u8, '{'), bytes[0]);
                try conn.sendMessage(.{ .ndjson = "{\"id\":1,\"ok\":{}}" });
            },
            .frame => {
                self.binary += 1;
                try conn.sendMessage(msg);
            },
        }
    }
    pub fn closed(_: *Echo, _: *p.Connection) void {}
    pub fn allowFrame(_: *Echo, conn: *const p.Connection, kind: u16) bool {
        return kind == 0x100 and conn.hasCap("venom-test.bytes");
    }
};

test "concurrent NDJSON and binary hello, idle peer, negotiated caps, ping and routing" {
    var f = try Fixture.init();
    defer f.deinit();
    var echo: Echo = .{};
    var opts = f.options();
    opts.hello.caps = &.{"venom-test.bytes"};
    opts.hello.versions = &.{ 1, 2 };
    opts.hello.max_frame = 32768;
    var server = try p.Server.init(a, opts, p.Handler.init(&echo));
    defer server.deinit();
    var idle = try f.raw();
    defer idle.deinit();
    var json = try f.client(.ndjson, &.{ 2, 1 });
    defer json.deinit();
    var binary = try p.Client.init(a, .{ .tool = identity.name, .path = opts.path, .protocol = .binary, .hello = .{
        .identity = identity,
        .caps = &.{ "unknown", "venom-test.bytes" },
        .max_frame = 8192,
    } });
    defer binary.deinit();
    try handshake(&server, &json);
    try handshake(&server, &binary);
    try std.testing.expectEqual(@as(i64, 2), json.connection.version);
    try std.testing.expectEqual(@as(u32, 8192), binary.connection.max_frame);
    try std.testing.expect(binary.connection.hasCap("venom-test.bytes"));
    try std.testing.expect(!binary.connection.hasCap("unknown"));
    try std.testing.expectEqual(@as(usize, 3), server.connections.items.len);
    try json.connection.sendMessage(.{ .ndjson = "{\"id\":1,\"verb\":\"ping\"}" });
    try binary.connection.sendMessage(.{ .frame = .{ .kind = 0x100, .stream = 1, .payload = "hi\x00\n" } });
    try expectContains((try receive(&server, &json.connection)).ndjson, "\"ok\"");
    const reply = (try receive(&server, &binary.connection)).frame;
    try std.testing.expectEqual(@as(u16, 0x100), reply.kind);
    try std.testing.expectEqual(@as(u32, 1), reply.stream);
    try std.testing.expectEqualStrings("hi\x00\n", reply.payload);
    try binary.connection.sendMessage(.{ .frame = .{ .kind = p.Kind.ping, .payload = "opaque" } });
    const pong = (try receive(&server, &binary.connection)).frame;
    try std.testing.expectEqual(@as(u16, p.Kind.pong), pong.kind);
    try std.testing.expectEqualStrings("opaque", pong.payload);
    try binary.connection.sendMessage(.{ .ndjson = "{\"id\":1,\"verb\":\"ping\"}" });
    try std.testing.expectEqual(@as(u16, p.Kind.control), (try receive(&server, &binary.connection)).frame.kind);
    try std.testing.expectEqual(@as(usize, 2), echo.json);
    try std.testing.expectEqual(@as(usize, 1), echo.binary);
}

test "version mismatch reports supported versions and closes in both protocols" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    defer server.deinit();
    inline for (.{ p.Protocol.ndjson, p.Protocol.binary }) |protocol| {
        var client = try f.client(protocol, &.{99});
        defer client.deinit();
        try std.testing.expectError(error.VersionMismatch, handshake(&server, &client));
        // The server closes only after flushing its error reply.
        try server.poll(0);
        try server.poll(0);
        try std.testing.expectError(error.Disconnected, client.receive(10));
    }
}

test "unknown preambles receive NDJSON error with original byte and supported list" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    defer server.deinit();
    for ([_]u8{ ' ', 'G', 0xf6, 0xff, 0 }) |byte| {
        var raw = try f.raw();
        defer raw.deinit();
        try raw.queue(&.{byte});
        raw.protocol = .ndjson;
        const line = (try receive(&server, &raw)).ndjson;
        try expectContains(line, "protocol.bad_preamble");
        try expectContains(line, "\"supported\":[123,245]");
    }
}

test "socket lock serializes live servers; stale socket recovered; permissions and PID" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    var live = true;
    defer if (live) server.deinit();
    try std.testing.expectError(error.AlreadyRunning, p.Server.init(a, f.options(), null));
    const st = try os.statAt(c.AT.FDCWD, f.path, c.AT.SYMLINK_NOFOLLOW);
    try std.testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
    var pid: [32]u8 = undefined;
    _ = c.lseek(server.lock, 0, c.SEEK.SET);
    try std.testing.expect(c.read(server.lock, &pid, pid.len) > 0);
    // Simulate a crash: kernel closes descriptors, but socket pathname remains.
    const stale_fd = server.fd;
    const stale_lock = server.lock;
    const saved_dir = server.dir;
    const saved_path = server.path;
    server.connections.deinit(a);
    server.polls.deinit(a);
    os.close(stale_fd);
    os.close(stale_lock);
    os.close(saved_dir);
    a.free(saved_path);
    a.free(server.owner_path);
    a.free(server.bound_path);
    if (server.owns_audit) {
        server.audit_log.deinit();
        a.destroy(server.audit_log);
    }
    server.registry.deinit();
    a.destroy(server.registry);
    live = false;
    try std.testing.expectError(error.NotRunning, f.client(.ndjson, &.{1}));
    var replacement = try p.Server.init(a, f.options(), null);
    replacement.deinit();
    try std.testing.expectError(error.FileNotFound, os.statAt(c.AT.FDCWD, f.path, c.AT.SYMLINK_NOFOLLOW));
}

test "refuses non-socket files, symlink sockets, insecure dirs and symlink locks" {
    var f = try Fixture.init();
    defer f.deinit();
    const fd = c.open(f.path, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    os.close(fd);
    try std.testing.expectError(error.NotASocket, p.Server.init(a, f.options(), null));
    _ = c.unlink(f.path);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("missing", f.path));
    try std.testing.expectError(error.NotASocket, p.Server.init(a, f.options(), null));
    _ = c.unlink(f.path);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(f.parent, 0o755));
    try std.testing.expectError(error.InsecurePath, p.Server.init(a, f.options(), null));
    try std.testing.expectError(error.InsecurePath, f.client(.ndjson, &.{1}));
    _ = c.chmod(f.parent, 0o700);
    const lock = try @import("xdg").lockPath(a, f.path);
    defer a.free(lock);
    _ = c.unlink(lock);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("missing", lock));
    try std.testing.expectError(error.InsecurePath, p.Server.init(a, f.options(), null));
}

test "client path length and unavailable daemon errors" {
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectError(error.NotRunning, f.client(.ndjson, &.{1}));
    const missing = try std.fmt.allocPrintSentinel(a, "{s}/absent/test.sock", .{f.parent}, 0);
    defer a.free(missing);
    try std.testing.expectError(error.NotRunning, p.Client.init(a, .{ .tool = identity.name, .hello = .{ .identity = identity }, .path = .{ .socket = missing } }));
    const long: [108]u8 = @splat('a');
    var opts = f.options();
    opts.path.socket = &long;
    try std.testing.expectError(error.PathTooLong, p.Server.init(a, opts, null));
    try std.testing.expectError(error.PathTooLong, p.Client.init(a, .{ .tool = identity.name, .hello = opts.hello, .path = opts.path }));
}

test "fragmented binary header uses big endian and enforces hello-first and frame limit" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    defer server.deinit();
    var raw = try f.raw();
    defer raw.deinit();
    try raw.queue(&.{ 0xf5, 0, p.Kind.hello, 0 });
    try raw.flush();
    try server.poll(0);
    try server.poll(0);
    try std.testing.expect(!server.connections.items[0].ready);
    try raw.queue(&.{ 0, 0, 0, 0, 0, 0, 13 });
    try raw.queue("{\"proto\":[1]}");
    raw.protocol = .binary;
    try std.testing.expectEqual(@as(u16, p.Kind.hello_ok), (try receive(&server, &raw)).frame.kind);
    // Declared payload exceeds the limit: reject before allocating/reading it.
    try raw.queue(&.{ 0, p.Kind.ping, 0, 0, 0, 0, 0x01, 0, 0, 0 });
    try expectContains((try receive(&server, &raw)).frame.payload, "protocol.too_large");
    var nohello = try f.raw();
    defer nohello.deinit();
    nohello.protocol = .binary;
    try nohello.queue(&.{0xf5});
    try nohello.sendMessage(.{ .frame = .{ .kind = p.Kind.ping, .payload = "" } });
    try expectContains((try receive(&server, &nohello)).frame.payload, "protocol.hello_required");
}

test "NDJSON preserves opening brace across fragmented hello; hello order and implicit v1" {
    var f = try Fixture.init();
    defer f.deinit();
    var echo: Echo = .{};
    var server = try p.Server.init(a, f.options(), p.Handler.init(&echo));
    defer server.deinit();
    var raw = try f.raw();
    defer raw.deinit();
    raw.protocol = .ndjson;
    try raw.queue("{");
    try raw.flush();
    try server.poll(0);
    try server.poll(0);
    try raw.queue("\"id\":\"bootstrap\",\"verb\":\"hello\",\"params\":{\"proto\":[1],\"future\":true}}\n");
    try expectContains((try receive(&server, &raw)).ndjson, "\"id\":\"bootstrap\"");
    try raw.sendMessage(.{ .ndjson = "{\"id\":2,\"verb\":\"hello\",\"params\":{\"proto\":[1]}}" });
    try expectContains((try receive(&server, &raw)).ndjson, "protocol.hello_order");
    var implicit = try f.raw();
    defer implicit.deinit();
    implicit.protocol = .ndjson;
    try implicit.sendMessage(.{ .ndjson = "{\"id\":1,\"verb\":\"ping\"}" });
    _ = try receive(&server, &implicit);
    try std.testing.expectEqual(@as(usize, 1), echo.json);
    try implicit.sendMessage(.{ .ndjson = "{\"id\":2,\"verb\":\"hello\",\"params\":{\"proto\":[1]}}" });
    try expectContains((try receive(&server, &implicit)).ndjson, "protocol.hello_order");
}

test "deadlines, slow reader bound, unknown frames and graceful binary shutdown" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    var live = true;
    defer if (live) server.deinit();
    var idle = try f.raw();
    defer idle.deinit();
    try server.poll(0);
    server.connections.items[0].deadline_ms = os.nowMs() - 1;
    try server.poll(0);
    try std.testing.expectEqual(@as(usize, 0), server.connections.items.len);
    var client = try f.client(.binary, &.{1});
    defer client.deinit();
    try handshake(&server, &client);
    const conn = server.connections.items[0];
    conn.output_limit = 8;
    try std.testing.expectError(error.SlowReader, conn.sendMessage(.{ .frame = .{ .kind = p.Kind.ping, .payload = "" } }));
    conn.output_limit = 8 * 1024 * 1024;
    try client.connection.sendMessage(.{ .frame = .{ .kind = 0x100, .payload = "" } });
    try expectContains((try receive(&server, &client.connection)).frame.payload, "protocol.bad_frame");
    var clean = try f.client(.binary, &.{1});
    defer clean.deinit();
    try handshake(&server, &clean);
    server.deinit();
    live = false;
    _ = try clean.connection.read();
    try std.testing.expectEqual(@as(u16, p.Kind.close), (try clean.connection.next()).?.frame.kind);
}

test "runtime dir symlink is rejected even with trailing slash; missing runtime dir is private" {
    var f = try Fixture.init();
    defer f.deinit();
    const link = try std.fmt.allocPrintSentinel(a, "{s}/linked", .{f.parent}, 0);
    defer a.free(link);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(".", link));
    const path = try std.fmt.allocPrintSentinel(a, "{s}//test.sock", .{link}, 0);
    defer a.free(path);
    var opts = f.options();
    opts.path.socket = path;
    try std.testing.expectError(error.InsecurePath, p.Server.init(a, opts, null));
    try std.testing.expectError(error.InsecurePath, p.Client.init(a, .{ .tool = identity.name, .path = opts.path, .hello = opts.hello }));
    const created = try std.fmt.allocPrintSentinel(a, "{s}/created/test.sock", .{f.parent}, 0);
    defer a.free(created);
    opts.path.socket = created;
    var server = try p.Server.init(a, opts, null);
    defer server.deinit();
    const st = try os.statAt(server.dir, ".", c.AT.SYMLINK_NOFOLLOW);
    try std.testing.expectEqual(@as(u32, 0o700), st.mode & 0o777);
}

test "invalid hello can be retried; malformed line recovers; implicit hello is permanently v1" {
    var f = try Fixture.init();
    defer f.deinit();
    var opts = f.options();
    opts.hello.versions = &.{2};
    var server = try p.Server.init(a, opts, null);
    defer server.deinit();
    var implicit = try f.raw();
    defer implicit.deinit();
    implicit.protocol = .ndjson;
    try implicit.sendMessage(.{ .ndjson = "{\"id\":1,\"verb\":\"ping\"}" });
    const mismatch = (try receive(&server, &implicit)).ndjson;
    try expectContains(mismatch, "protocol.version_mismatch");
    try expectContains(mismatch, "\"supported\":[2]");
    var raw = try f.raw();
    defer raw.deinit();
    raw.protocol = .ndjson;
    try raw.sendMessage(.{ .ndjson = "{bad json}" });
    try expectContains((try receive(&server, &raw)).ndjson, "protocol.parse");
    try raw.sendMessage(.{ .ndjson = "{\"id\":1,\"verb\":\"hello\",\"params\":{\"proto\":[2],\"max_frame\":4095}}" });
    try expectContains((try receive(&server, &raw)).ndjson, "invalid_params.hello");
    try raw.sendMessage(.{ .ndjson = "{\"id\":2,\"verb\":\"hello\",\"params\":{\"proto\":[2]}}" });
    try expectContains((try receive(&server, &raw)).ndjson, "\"proto\":2");
}

test "pipelined small messages survive processing budgets and client write-half close" {
    var f = try Fixture.init();
    defer f.deinit();
    var echo: Echo = .{};
    var server = try p.Server.init(a, f.options(), p.Handler.init(&echo));
    defer server.deinit();
    var raw = try f.raw();
    defer raw.deinit();
    raw.protocol = .ndjson;
    for (0..400) |_| try raw.queue("{\"id\":1,\"verb\":\"ping\"}\n");
    while (raw.output.items.len > 0) try raw.flush();
    try std.testing.expectEqual(@as(c_int, 0), c.shutdown(raw.fd, c.SHUT.WR));
    var replies: usize = 0;
    const deadline = os.nowMs() + 2000;
    while (replies < 400 and os.nowMs() < deadline) {
        try server.poll(0);
        while (try raw.next()) |_| replies += 1;
        _ = try raw.read();
    }
    while (try raw.next()) |_| replies += 1;
    try std.testing.expectEqual(@as(usize, 400), echo.json);
    try std.testing.expectEqual(@as(usize, 400), replies);
}

test "slow output cannot stall healthy peers or allocate beyond queue limit" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    defer server.deinit();
    var slow = try f.client(.binary, &.{1});
    defer slow.deinit();
    try handshake(&server, &slow);
    const conn = server.connections.items[0];
    const small: c_int = 4096;
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(conn.fd, c.SOL.SOCKET, c.SO.SNDBUF, &small, @sizeOf(c_int)));
    const bytes = try a.alloc(u8, conn.max_frame);
    defer a.free(bytes);
    @memset(bytes, 42);
    for (0..7) |_| try conn.sendMessage(.{ .frame = .{ .kind = 0x100, .stream = 1, .payload = bytes } });
    try std.testing.expectError(error.SlowReader, conn.sendMessage(.{ .frame = .{ .kind = 0x100, .stream = 1, .payload = bytes } }));
    var healthy = try f.client(.ndjson, &.{1});
    defer healthy.deinit();
    try handshake(&server, &healthy);
    try std.testing.expect(healthy.connection.ready);
    try std.testing.expect(conn.output.items.len > conn.sent);
}

test "graceful shutdown drains binary CLOSE and releases connections before deinit" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    defer server.deinit();
    var client = try f.client(.binary, &.{1});
    defer client.deinit();
    try handshake(&server, &client);
    server.shutdown();
    try std.testing.expectEqual(@as(c.fd_t, -1), server.fd);
    const deadline = os.nowMs() + 2000;
    while (server.connections.items.len != 0 and os.nowMs() < deadline) try server.poll(0);
    try std.testing.expectEqual(@as(usize, 0), server.connections.items.len);
    _ = try client.connection.read();
    try std.testing.expectEqual(@as(u16, p.Kind.close), (try client.connection.next()).?.frame.kind);
    try std.testing.expectError(error.AlreadyRunning, p.Server.init(a, f.options(), null));
}

fn allocationLifecycle(gpa: std.mem.Allocator, f: Fixture) !void {
    var opts = f.options();
    opts.hello.caps = &.{"example"};
    var server = try p.Server.init(gpa, opts, null);
    defer server.deinit();
    var client = try p.Client.init(gpa, .{ .tool = identity.name, .path = opts.path, .hello = .{ .identity = identity, .caps = &.{"example"} } });
    defer client.deinit();
    try handshake(&server, &client);
}

test "allocation failures release descriptors, locks and handshake buffers" {
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationLifecycle, .{f});
}

test "owner file lifecycle, fresh secrets, binary and NDJSON token failure closes" {
    var f = try Fixture.init();
    defer f.deinit();
    var server = try p.Server.init(a, f.options(), null);
    var active = true;
    defer if (active) server.deinit();
    var original: [256]u8 = undefined;
    const fd = c.open(server.owner_path, .{ .ACCMODE = .RDONLY });
    try std.testing.expect(fd >= 0);
    const n = c.read(fd, &original, original.len);
    os.close(fd);
    try std.testing.expect(n > 0);
    try std.testing.expect(server.grantDiagnostics().owner_file);
    for ([_]p.Protocol{ .ndjson, .binary }) |protocol| {
        var client = try p.Client.init(a, .{ .tool = identity.name, .path = f.options().path, .hello = .{ .identity = identity }, .protocol = protocol, .token = "vnt1.bad.owner.invalid" });
        defer client.deinit();
        try std.testing.expectError(error.DeniedToken, handshake(&server, &client));
        try std.testing.expectEqual(p.grants.TokenFailure.invalid, client.token_failure.?);
        for (0..10) |_| try server.poll(0);
        try std.testing.expectEqual(@as(usize, 0), server.connections.items.len);
    }
    const old_path = try a.dupeSentinel(u8, server.owner_path, 0);
    defer a.free(old_path);
    server.deinit();
    active = false;
    try std.testing.expectError(error.FileNotFound, os.statAt(c.AT.FDCWD, old_path, c.AT.SYMLINK_NOFOLLOW));
    var replacement = try p.Server.init(a, f.options(), null);
    defer replacement.deinit();
    const fresh_fd = c.open(replacement.owner_path, .{ .ACCMODE = .RDONLY });
    try std.testing.expect(fresh_fd >= 0);
    defer os.close(fresh_fd);
    var fresh: [256]u8 = undefined;
    const m = c.read(fresh_fd, &fresh, fresh.len);
    try std.testing.expect(m > 0);
    try std.testing.expect(!std.mem.eql(u8, original[0..@intCast(n)], fresh[0..@intCast(m)]));
}

test "unavailable audit leaves rights unchanged and doctor reports failure" {
    var f = try Fixture.init();
    defer f.deinit();
    var opts = f.options();
    opts.audit_path = "/proc/no-such-venom-audit-directory/audit.ndjson";
    var server = try p.Server.init(a, opts, null);
    defer server.deinit();
    try std.testing.expect(!server.grantDiagnostics().audit_writable);
    const now = p.grants.nowSeconds();
    try std.testing.expect(server.registry.allows(.{}, .read, null, now));
    try std.testing.expect(!server.registry.allows(.{}, .write, null, now));
}

test "consumed input and sent output leave no stale bytes in spare capacity" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer os.close(fds[1]);
    var conn = p.Connection.init(a, fds[0]);
    defer conn.deinit();
    conn.protocol = .ndjson;
    const lines = "{\"secret\":\"canary-one\"}\n{\"x\":2}\n";
    try std.testing.expectEqual(@as(isize, lines.len), c.write(fds[1], lines, lines.len));
    try std.testing.expect(try conn.read());
    try std.testing.expectEqualStrings("{\"secret\":\"canary-one\"}", (try conn.next()).?.ndjson);
    try std.testing.expectEqualStrings("{\"x\":2}", (try conn.next()).?.ndjson);
    try std.testing.expect(try conn.next() == null);
    try std.testing.expect(std.mem.indexOf(u8, conn.input.allocatedSlice(), "canary") == null);
    try conn.output.appendSlice(a, "{\"token\":\"canary-two\"}\n");
    try conn.flush();
    try std.testing.expectEqual(@as(usize, 0), conn.output.items.len);
    try std.testing.expect(std.mem.indexOf(u8, conn.output.allocatedSlice(), "canary") == null);
}

test "owner token refused below a marked process, not beside it" {
    if (!os.is_linux) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    // The server is a process of its own: a peer below its daemon is ORPHAN.
    const daemon = fork();
    try std.testing.expect(daemon >= 0);
    if (daemon == 0) {
        var server = p.Server.init(std.heap.c_allocator, f.options(), null) catch _exit(90);
        while (true) server.poll(50) catch _exit(91);
    }
    defer {
        _ = c.kill(daemon, c.SIG.KILL);
        _ = c.waitpid(daemon, null, 0);
    }
    const owner_path = try std.fmt.allocPrintSentinel(a, "{s}/test.owner", .{f.parent}, 0);
    defer a.free(owner_path);
    var token: [256]u8 = undefined;
    var n: isize = 0;
    const deadline = os.nowMs() + 5000;
    while (n <= 0 and os.nowMs() < deadline) {
        const fd = c.open(owner_path, .{ .ACCMODE = .RDONLY });
        if (fd >= 0) {
            n = c.read(fd, &token, token.len);
            os.close(fd);
        }
    }
    try std.testing.expect(n > 0);
    const owner_token = token[0..@intCast(n)];
    const present = struct {
        fn call(fx: Fixture, t: ?[]const u8) !?p.grants.TokenFailure {
            const until = os.nowMs() + 5000;
            // The owner file comes before the listening socket.
            var client = while (true) break p.Client.init(a, .{ .tool = identity.name, .path = fx.options().path, .hello = .{ .identity = identity }, .token = t }) catch |err| {
                if (err != error.NotRunning or os.nowMs() > until) return err;
                continue;
            };
            defer client.deinit();
            while (os.nowMs() < until) {
                if (client.pollHello(50) catch |err| {
                    if (err == error.DeniedToken) return client.token_failure;
                    return err;
                }) return null;
            }
            return error.TestTimeout;
        }
    }.call;
    try std.testing.expectEqual(@as(?p.grants.TokenFailure, null), try present(f, owner_token));
    // This test's parent stands in for a manager above the peer.
    const parent = try p.process.stat(c.getppid());
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/manager-{d}-{d}", .{ f.parent, parent.ref.pid, parent.ref.start }, 0);
    defer a.free(marker);
    const marked = c.open(marker, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c.mode_t, 0o600));
    try std.testing.expect(marked >= 0);
    os.close(marked);
    defer _ = c.unlink(marker);
    try std.testing.expectEqual(@as(?p.grants.TokenFailure, .owner_context), try present(f, owner_token));
    // Only the owner token: with no credential the caller is still `unknown`.
    try std.testing.expectEqual(@as(?p.grants.TokenFailure, null), try present(f, null));
}

test "a daemon with the subreaper is marked while it runs" {
    if (!os.is_linux) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    defer _ = prctl(36, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    const me = try p.process.stat(c.getpid());
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/manager-{d}-{d}", .{ f.parent, me.ref.pid, me.ref.start }, 0);
    defer a.free(marker);
    var options = f.options();
    options.subreaper = true;
    var server = try p.Server.init(a, options, null);
    const st = try os.statAt(c.AT.FDCWD, marker, c.AT.SYMLINK_NOFOLLOW);
    try std.testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
    server.deinit();
    try std.testing.expectError(error.FileNotFound, os.statAt(c.AT.FDCWD, marker, c.AT.SYMLINK_NOFOLLOW));
}
extern "c" fn prctl(c_int, ...) c_int;
extern "c" fn fork() c.pid_t;
extern "c" fn _exit(c_int) noreturn;

extern "c" fn pause() c_int;

test "a process principal survives a restart while its process lives" {
    if (!os.is_linux) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const live = fork();
    if (live == 0) while (true) {
        _ = pause();
    };
    defer {
        _ = c.kill(live, .KILL);
        _ = c.waitpid(live, null, 0);
    }
    const view = fork();
    if (view == 0) while (true) {
        _ = pause();
    };
    defer {
        _ = c.kill(view, .KILL);
        _ = c.waitpid(view, null, 0);
    }
    const dead = fork();
    if (dead == 0) while (true) {
        _ = pause();
    };
    var dead_reaped = false;
    defer if (!dead_reaped) {
        _ = c.kill(dead, .KILL);
        _ = c.waitpid(dead, null, 0);
    };
    const now = p.grants.nowSeconds();
    const human: p.grants.Identity = .{ .principal = p.grants.owner };
    const gs = [_]p.grants.Grant{ .{ .right = .read, .scope = "*" }, .{ .right = .spawn, .scope = "*" } };
    const dead_ref = (try p.process.stat(dead)).ref;
    const live_ref = (try p.process.stat(live)).ref;
    var bound_name: [:0]u8 = undefined;
    {
        var server = try p.Server.init(a, f.options(), null);
        defer server.deinit();
        bound_name = try a.dupeSentinel(u8, server.bound_path, 0);
        const parent = try server.registry.issueChild(human, .{ .kind = .process, .root = live_ref, .grants = &gs, .label = "control pane", .namespace = "person" }, now);
        a.free(parent.token);
        // A child stays under its parent; one that dies, or holds admin, does not come back.
        const child = try server.registry.issueChild(.{ .principal = parent.principal, .floor = .{ .bound = parent.principal } }, .{ .kind = .process, .root = (try p.process.stat(view)).ref, .grants = &.{.{ .right = .read, .scope = "*" }}, .label = "view" }, now);
        a.free(child.token);
        const gone = try server.registry.issueChild(human, .{ .kind = .process, .root = dead_ref, .grants = &gs }, now);
        a.free(gone.token);
        const admin = try server.registry.issueChild(human, .{ .kind = .process, .root = .{ .pid = 1, .start = (try p.process.stat(1)).ref.start }, .grants = &.{.{ .right = .admin, .scope = "*" }} }, now);
        a.free(admin.token);
        // A token in the registry is not kept.
        const token = try server.registry.issueChild(human, .{ .grants = &gs }, now);
        a.free(token.token);
        try server.poll(0);
    }
    defer a.free(bound_name);
    const st = try os.statAt(c.AT.FDCWD, bound_name, c.AT.SYMLINK_NOFOLLOW);
    try std.testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
    _ = c.kill(dead, .KILL);
    _ = c.waitpid(dead, null, 0);
    dead_reaped = true;
    {
        // A log of its own: the first server's `issued` records aren't this one's.
        var opts = f.options();
        const audit_path = try std.fmt.allocPrint(a, "{s}/restored.ndjson", .{f.parent});
        defer a.free(audit_path);
        opts.audit_path = audit_path;
        var server = try p.Server.init(a, opts, null);
        defer server.deinit();
        var found: ?p.grants.Principal = null;
        var count: usize = 0;
        for (server.registry.entries.items) |e| if (e.kind == .process) {
            count += 1;
            if (e.root.?.eql(live_ref)) found = e;
        };
        try std.testing.expectEqual(@as(usize, 2), count);
        try std.testing.expectEqualStrings("control pane", found.?.label);
        try std.testing.expectEqualStrings("person", server.registry.namespaceOf(found.?.id));
        try std.testing.expectEqual(p.grants.owner, found.?.parent.?);
        try std.testing.expectEqual(@as(?i64, null), found.?.expires);
        const who = server.registry.resolve(p.process.walk(view, -1), view, now);
        try std.testing.expectEqualStrings("view", server.registry.get(who.principal).?.label);
        try std.testing.expectEqual(found.?.id, server.registry.get(who.principal).?.parent.?);
        try std.testing.expect(found.?.restored);
        // Audit shows who and that nobody asked: no owner `issued` for it.
        const records = try server.audit_log.recent(arena.allocator(), 20);
        var restored: usize = 0;
        for (records) |record| {
            const event = record.object.get("event").?.string;
            try std.testing.expect(!std.mem.eql(u8, event, "issued"));
            if (std.mem.eql(u8, event, "restored")) {
                restored += 1;
                const peer = record.object.get("peer").?.object;
                try std.testing.expect(peer.get("pid").?.integer > 0);
                try std.testing.expect(peer.get("start").?.integer > 0);
            }
        }
        try std.testing.expectEqual(@as(usize, 2), restored);
    }
    // Forged or odd files restore nothing and don't stop the daemon.
    const forged = try std.fmt.allocPrint(a, "[{{\"id\":5,\"parent\":0,\"pid\":{d},\"start\":{d},\"grants\":[{{\"right\":\"admin\",\"scope\":\"*\"}}]}}]", .{ live_ref.pid, live_ref.start });
    defer a.free(forged);
    for ([_][]const u8{ "not json", forged }) |bytes| {
        const fd = c.open(bound_name, .{ .ACCMODE = .WRONLY, .TRUNC = true });
        try std.testing.expect(fd >= 0);
        _ = c.write(fd, bytes.ptr, bytes.len);
        os.close(fd);
        var server = try p.Server.init(a, f.options(), null);
        defer server.deinit();
        for (server.registry.entries.items) |e| try std.testing.expect(e.kind != .process);
    }
}
