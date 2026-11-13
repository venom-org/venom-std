const std = @import("std");
const os = @import("os.zig");
const c = os.c;
const wire = @import("wire.zig");
const hello = @import("hello.zig");

pub const Options = struct {
    tool: []const u8,
    path: os.SocketOptions = .{},
    hello: hello.Options,
    protocol: wire.Protocol = .ndjson,
    /// Overrides the tool-specific environment token. Never logged.
    token: ?[]const u8 = null,
};

/// Non-blocking client. init queues hello; repeatedly call pollHello while the
/// daemon runs its reactor, then use connection.sendMessage/flush and receive.
/// No background thread or hidden event loop is created. deinit owns cleanup.
pub const Client = struct {
    connection: wire.Connection,
    options: Options,
    connecting: bool = false,
    token_failure: ?@import("grants.zig").TokenFailure = null,

    pub fn init(gpa: std.mem.Allocator, options: Options) !Client {
        try hello.validate(options.hello);
        if (options.protocol == .sniff) return error.InvalidOptions;
        const path = try os.socketPath(gpa, options.tool, options.path);
        defer gpa.free(path);
        var addr = try os.address(path);
        const dir = try os.runtimeDir(gpa, path, false);
        defer os.close(dir);
        const fd = try os.socket();
        errdefer os.close(fd);
        var connecting = false;
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) switch (c.errno(-1)) {
            .NOENT, .CONNREFUSED => return error.NotRunning,
            .INPROGRESS => connecting = true,
            .AGAIN => return error.WouldBlock,
            else => return error.ConnectFailed,
        };
        var conn = wire.Connection.init(gpa, fd);
        // fd is closed by the outer errdefer on initialization failure.
        errdefer {
            conn.input.deinit(gpa);
            conn.output.deinit(gpa);
        }
        conn.protocol = options.protocol;
        conn.max_frame = options.hello.max_frame;
        const env_token = if (options.token == null) try @import("credentials.zig").fromEnvironment(gpa, options.tool, options.path) else null;
        defer if (env_token) |t| {
            std.crypto.secureZero(u8, t);
            gpa.free(t);
        };
        const token = options.token orelse env_token;
        const auth: ?struct { token: []const u8 } = if (token) |t| .{ .token = t } else null;
        const params = .{ .auth = auth, .proto = options.hello.versions, .client = options.hello.identity, .caps = options.hello.caps, .max_frame = options.hello.max_frame };
        const bytes = if (options.protocol == .binary) try hello.encode(gpa, params) else try hello.encode(gpa, .{ .id = 0, .verb = "hello", .params = params });
        defer gpa.free(bytes);
        if (options.protocol == .binary) {
            try conn.queue(&.{0xf5});
            try conn.sendMessage(.{ .frame = .{ .kind = wire.Kind.hello, .payload = bytes } });
        } else try conn.sendMessage(.{ .ndjson = bytes });
        return .{ .connection = conn, .options = options, .connecting = connecting };
    }
    pub fn deinit(self: *Client) void {
        self.connection.deinit();
        self.* = undefined;
    }
    /// Wait at most timeout_ms and complete one read/write turn. Returns true
    /// after validating the server's selection; version mismatch is explicit.
    pub fn pollHello(self: *Client, timeout_ms: i32) !bool {
        const conn = &self.connection;
        if (conn.ready) return true;
        if (os.nowMs() >= conn.deadline_ms) return error.Timeout;
        const message = try self.receive(@min(timeout_ms, @as(i32, @intCast(@max(0, conn.deadline_ms - os.nowMs()))))) orelse return false;
        const bytes = switch (message) {
            .ndjson => |line| line,
            .frame => |f| blk: {
                if (f.stream != 0 or (f.kind != wire.Kind.hello_ok and f.kind != wire.Kind.err)) return error.InvalidHello;
                break :blk f.payload;
            },
        };
        const parsed = try std.json.parseFromSlice(std.json.Value, conn.gpa, bytes, .{ .allocate = .alloc_always });
        var retained = false;
        defer if (!retained) parsed.deinit();
        var value = parsed.value;
        if (conn.protocol == .ndjson) {
            const id = hello.field(value, "id") orelse return error.InvalidHello;
            if (id != .integer or id.integer != 0) return error.InvalidHello;
        }
        const err = if (conn.protocol == .binary) (if (message.frame.kind == wire.Kind.err) value else null) else hello.field(value, "error");
        if (err) |e| {
            const code = hello.field(e, "code") orelse return error.InvalidHello;
            if (code == .string and std.mem.eql(u8, code.string, "protocol.version_mismatch")) return error.VersionMismatch;
            if (code == .string and std.mem.eql(u8, code.string, "denied.token")) {
                const data = hello.field(e, "data") orelse .null;
                const reason = hello.field(data, "reason") orelse .null;
                self.token_failure = if (reason == .string) std.meta.stringToEnum(@import("grants.zig").TokenFailure, reason.string) orelse .invalid else .invalid;
                return error.DeniedToken;
            }
            return error.InvalidHello;
        }
        if (conn.protocol == .ndjson) value = hello.field(value, "ok") orelse return error.InvalidHello;
        const version = hello.field(value, "proto") orelse return error.InvalidHello;
        if (version != .integer) return error.InvalidHello;
        var offered = false;
        for (self.options.hello.versions) |v| if (v == version.integer) {
            offered = true;
        };
        if (!offered) return error.VersionMismatch;
        const max = hello.field(value, "max_frame") orelse return error.InvalidHello;
        if (max != .integer or max.integer < 4096 or max.integer > self.options.hello.max_frame) return error.InvalidHello;
        const caps = hello.field(value, "caps") orelse return error.InvalidHello;
        if (caps != .array) return error.InvalidHello;
        const server = hello.field(value, "server") orelse return error.InvalidHello;
        const name = hello.field(server, "name") orelse return error.InvalidHello;
        const build = hello.field(server, "version") orelse return error.InvalidHello;
        if (name != .string or build != .string) return error.InvalidHello;
        for (caps.array.items) |cap| {
            if (cap != .string) return error.InvalidHello;
            offered = false;
            for (self.options.hello.caps) |v| if (std.mem.eql(u8, v, cap.string)) {
                offered = true;
            };
            if (!offered) return error.InvalidHello;
        }
        try conn.caps.ensureUnusedCapacity(conn.gpa, caps.array.items.len);
        for (caps.array.items) |cap| conn.caps.appendAssumeCapacity(cap.string);
        conn.hello = parsed;
        retained = true;
        conn.version = version.integer;
        conn.max_frame = @intCast(max.integer);
        conn.ready = true;
        return true;
    }
    /// Queue a verb request; flushed by receive. `id` (integer
    /// or string ≤ 64 bytes) must be unique among in-flight requests. Decode
    /// replies with `Response.parse`.
    pub fn request(self: *Client, id: anytype, verb: []const u8, params: anytype) !void {
        const conn = &self.connection;
        // `.{}` is an empty tuple, which JSON-encodes as `[]`; params must be an object.
        const object = if (@TypeOf(params) == @TypeOf(.{})) struct {}{} else params;
        const bytes = try hello.encode(conn.gpa, .{ .id = id, .verb = verb, .params = object });
        defer conn.gpa.free(bytes);
        try conn.sendMessage(.{ .ndjson = bytes });
    }
    /// Borrowed message valid until the next receive call. Flushes queued output
    /// while waiting for input; null means no complete message this turn.
    pub fn receive(self: *Client, timeout_ms: i32) !?wire.Message {
        if (timeout_ms < 0) return error.InvalidOptions;
        const conn = &self.connection;
        if (try conn.next()) |msg| return msg;
        var fds = [_]c.pollfd{.{ .fd = conn.fd, .events = c.POLL.IN | (if (self.connecting or conn.output.items.len > 0) c.POLL.OUT else @as(i16, 0)), .revents = 0 }};
        try os.poll(&fds, timeout_ms);
        const flags = fds[0].revents;
        if (flags & (c.POLL.ERR | c.POLL.NVAL) != 0) return error.Disconnected;
        if (self.connecting and flags & c.POLL.OUT != 0) {
            var status: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(conn.fd, c.SOL.SOCKET, c.SO.ERROR, &status, &len) < 0 or status != 0) return error.ConnectFailed;
            self.connecting = false;
        }
        if (flags & c.POLL.OUT != 0) try conn.flush();
        if (flags & c.POLL.IN != 0) _ = conn.read() catch |err| return if (err == error.EndOfStream) error.Disconnected else err;
        if (try conn.next()) |msg| return msg;
        if (flags & c.POLL.HUP != 0) return error.Disconnected;
        return null;
    }
};
