const std = @import("std");
const iface = @import("iface");
const os = @import("os.zig");
const c = os.c;
const wire = @import("wire.zig");
const hello = @import("hello.zig");
const xdg = @import("xdg");
const Connection = wire.Connection;
const grants = @import("grants.zig");
const proc = @import("process.zig");
const managers = @import("managers.zig");
const bound = @import("bound.zig");
const audit = @import("audit.zig");

/// Called only after negotiation. Slices are borrowed until the callback returns.
/// Callbacks must return promptly; queue output with conn.sendMessage(). A tool
/// frame is accepted only if allowFrame verifies its negotiated capability.
/// `closed` runs once for every connection that reached the handler's server,
/// just before the connection is freed, so per-connection state can be dropped.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Optional reactor maintenance; invoked at least once per second.
    tick: ?*const fn (*anyopaque) anyerror!void = null,
    pub const VTable = struct {
        message: *const fn (*anyopaque, *Connection, wire.Message) anyerror!void,
        allowFrame: *const fn (*anyopaque, *const Connection, u16) bool,
        closed: *const fn (*anyopaque, *Connection) void,
    };
    pub fn init(impl: anytype) Handler {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        if (@hasDecl(T, "tick")) iface.assertImplements(struct { tick: *const fn (*anyopaque) anyerror!void }, T);
        return .{ .ptr = impl, .tick = if (@hasDecl(T, "tick")) &struct {
            fn tick(ptr: *anyopaque) anyerror!void {
                return iface.cast(T, ptr).tick();
            }
        }.tick else null, .vtable = &struct {
            const vt: VTable = .{ .message = message, .allowFrame = allowFrame, .closed = closed };
            fn message(ptr: *anyopaque, conn: *Connection, msg: wire.Message) anyerror!void {
                return iface.cast(T, ptr).message(conn, msg);
            }
            fn allowFrame(ptr: *anyopaque, conn: *const Connection, kind: u16) bool {
                return iface.cast(T, ptr).allowFrame(conn, kind);
            }
            fn closed(ptr: *anyopaque, conn: *Connection) void {
                iface.cast(T, ptr).closed(conn);
            }
        }.vt };
    }
};
pub const Options = struct {
    hello: hello.Options,
    path: os.SocketOptions = .{},
    max_connections: usize = 1024,
    output_limit: usize = 8 * 1024 * 1024,
    /// Optional externally-owned registry. Otherwise the server creates one.
    registry: ?*grants.Registry = null,
    audit: ?*audit.Log = null,
    /// Products that start processes for people or agents must enable this at
    /// serve. It also marks the daemon as a manager, so a
    /// supervisor of daemons calls `process.subreaper()` itself instead.
    subreaper: bool = false,
    /// Audit config is exposed here until cfg merges the shared grants section.
    audit_path: ?[]const u8 = null,
    audit_max_bytes: usize = 16 * 1024 * 1024,
    audit_keep: u8 = 2,
};

/// Single-threaded poll reactor. Owns its socket, flock and connections. Options
/// and handler must outlive it. Call poll repeatedly; deinit performs shutdown.
/// Start/stop on the daemon thread: bind briefly changes the process umask.
pub const Server = struct {
    gpa: std.mem.Allocator,
    fd: c.fd_t,
    dir: c.fd_t,
    lock: c.fd_t,
    path: [:0]u8,
    options: Options,
    handler: ?Handler,
    connections: std.ArrayList(*Connection) = .empty,
    polls: std.ArrayList(c.pollfd) = .empty,
    registry: *grants.Registry,
    owns_registry: bool,
    owner_path: [:0]u8,
    /// `process` principals, kept across a restart.
    bound_path: [:0]u8,
    peerpidfd_available: bool = true,
    audit_log: *audit.Log,
    owns_audit: bool,
    saved_observer: ?grants.Observer,
    saved_downstream: ?grants.Observer,

    pub fn init(gpa: std.mem.Allocator, options: Options, handler: ?Handler) !Server {
        try hello.validate(options.hello);
        if (options.max_connections == 0 or options.output_limit < options.hello.max_frame + 10) return error.InvalidOptions;
        const path = try os.socketPath(gpa, options.hello.identity.name, options.path);
        errdefer gpa.free(path);
        var addr = try os.address(path);
        const dir = try os.runtimeDir(gpa, path, true);
        errdefer os.close(dir);
        const lockpath = try xdg.lockPath(gpa, path);
        defer gpa.free(lockpath);
        const lockname = lockpath[lockpath.len - std.fs.path.basename(lockpath).len .. :0];
        const lock = c.openat(dir, @ptrCast(lockname.ptr), .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c.mode_t, 0o600));
        if (lock < 0) return error.InsecurePath;
        errdefer os.close(lock);
        const lst = try os.statAt(dir, lockname, c.AT.SYMLINK_NOFOLLOW);
        if ((lst.mode & c.S.IFMT) != c.S.IFREG or lst.uid != c.getuid() or lst.mode & 0o077 != 0 or lst.nlink != 1) return error.InsecurePath;
        if (c.flock(lock, c.LOCK.EX | c.LOCK.NB) < 0) return switch (c.errno(-1)) {
            .AGAIN => error.AlreadyRunning,
            else => error.SystemResources,
        };
        const registry = options.registry orelse try gpa.create(grants.Registry);
        const owns_registry = options.registry == null;
        if (owns_registry) {
            registry.* = grants.Registry.init(gpa, options.hello.identity.name, .{}) catch |err| {
                gpa.destroy(registry);
                return err;
            };
        }
        errdefer if (owns_registry) {
            registry.deinit();
            gpa.destroy(registry);
        };
        if (!std.mem.eql(u8, registry.tool, options.hello.identity.name)) return error.InvalidOptions;
        if (options.subreaper) {
            try proc.subreaper();
            // Before the owner file exists, so no peer can use it unchecked.
            try managers.mark(dir);
        }
        errdefer if (options.subreaper) managers.unmark(dir);
        const base = if (std.mem.endsWith(u8, path, ".sock")) path[0 .. path.len - 5] else path;
        const owner_path = try std.fmt.allocPrintSentinel(gpa, "{s}.owner", .{base}, 0);
        errdefer gpa.free(owner_path);
        const owner_name = owner_path[owner_path.len - std.fs.path.basename(owner_path).len .. :0];
        if (c.unlinkat(dir, owner_name, 0) != 0 and c.errno(-1) != .NOENT) return error.InsecurePath;
        const owner_fd = c.openat(dir, owner_name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (owner_fd < 0) return error.InsecurePath;
        defer os.close(owner_fd);
        errdefer _ = c.unlinkat(dir, owner_name, 0);
        if (c.fchmod(owner_fd, 0o600) != 0) return error.InsecurePath;
        const owner_token = try registry.ownerToken();
        defer {
            std.crypto.secureZero(u8, @constCast(owner_token));
            gpa.free(owner_token);
        }
        if (c.write(owner_fd, owner_token.ptr, owner_token.len) != owner_token.len) return error.SystemResources;
        const log = options.audit orelse try gpa.create(audit.Log);
        const owns_audit = options.audit == null;
        errdefer if (owns_audit) gpa.destroy(log);
        if (owns_audit) {
            const audit_path = if (options.audit_path) |p| try gpa.dupe(u8, p) else audit.defaultPath(gpa, registry.tool, options.path.environ) catch |err| return err;
            defer gpa.free(audit_path);
            // A failed audit path is reported by diagnostics, not authorization.
            audit.makeParents(gpa, audit_path) catch |err| {
                if (err == error.OutOfMemory) return err;
            };
            const source = try audit.instanceSource(gpa, registry.tool);
            defer gpa.free(source);
            log.* = audit.Log.init(gpa, .{ .path = audit_path, .source = source, .max_bytes = options.audit_max_bytes, .keep = options.audit_keep }) catch |err| return err;
        }
        errdefer if (owns_audit) {
            log.deinit();
        };
        try log.probe();
        const saved_observer = registry.observer;
        const saved_downstream = log.downstream;
        log.downstream = saved_observer;
        errdefer log.downstream = saved_downstream;
        registry.observer = log.observer();
        errdefer registry.observer = saved_observer;
        registry.marker_dir = dir;
        errdefer registry.marker_dir = null;
        const bound_path = try std.fmt.allocPrintSentinel(gpa, "{s}.bound", .{base}, 0);
        errdefer gpa.free(bound_path);
        // Before the socket exists, so no peer resolves without them.
        const bound_name = bound_path[bound_path.len - std.fs.path.basename(bound_path).len .. :0];
        try bound.load(gpa, registry, dir, bound_name, grants.nowSeconds());
        const name = std.fs.path.basename(path);
        const name_z = path[path.len - name.len .. :0];
        if (os.statAt(dir, name_z, c.AT.SYMLINK_NOFOLLOW)) |st| {
            if ((st.mode & c.S.IFMT) != c.S.IFSOCK) return error.NotASocket;
            if (c.unlinkat(dir, name_z, 0) < 0) return error.SystemResources;
        } else |err| if (err != error.FileNotFound) return err;
        const fd = try os.socket();
        errdefer os.close(fd);
        {
            const mask = c.umask(0o177);
            defer _ = c.umask(mask);
            if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
        }
        errdefer _ = c.unlinkat(dir, name_z, 0);
        if (c.fchmodat(dir, name_z, 0o600, 0) < 0 or c.listen(fd, 128) < 0) return error.SystemResources;
        var pidbuf: [32]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pidbuf, "{d}\n", .{c.getpid()});
        if (c.ftruncate(lock, 0) < 0 or c.write(lock, pid.ptr, pid.len) != pid.len) return error.SystemResources;
        return .{ .gpa = gpa, .fd = fd, .dir = dir, .lock = lock, .path = path, .options = options, .handler = handler, .registry = registry, .owns_registry = owns_registry, .owner_path = owner_path, .bound_path = bound_path, .audit_log = log, .owns_audit = owns_audit, .saved_observer = saved_observer, .saved_downstream = saved_downstream };
    }
    /// Stop accepting and queue binary CLOSE frames. Continue polling until
    /// connections is empty to drain output (bounded by a ten-second deadline).
    pub fn shutdown(self: *Server) void {
        if (self.fd < 0) return;
        os.close(self.fd);
        self.fd = -1;
        for (self.connections.items) |conn| {
            if (conn.protocol == .binary and conn.ready and !conn.closing)
                conn.sendMessage(.{ .frame = .{ .kind = wire.Kind.close, .payload = "" } }) catch {};
            conn.closing = true;
            conn.deadline_ms = os.nowMs() + 10_000;
        }
    }
    /// Release all resources immediately. For a graceful drain, shutdown and
    /// poll first. When called directly, queued CLOSE/output is best effort.
    pub fn deinit(self: *Server) void {
        self.shutdown();
        for (self.connections.items) |conn| {
            conn.flush() catch {};
            if (self.handler) |h| h.vtable.closed(h.ptr, conn);
            conn.deinit();
            self.gpa.destroy(conn);
        }
        self.connections.deinit(self.gpa);
        self.polls.deinit(self.gpa);
        const name = std.fs.path.basename(self.path);
        _ = c.unlinkat(self.dir, @ptrCast(name.ptr), 0);
        _ = c.unlink(self.owner_path);
        self.gpa.free(self.owner_path);
        if (self.options.subreaper) managers.unmark(self.dir);
        self.saveBound() catch {};
        self.registry.marker_dir = null;
        self.gpa.free(self.bound_path);
        self.registry.observer = self.saved_observer;
        self.audit_log.downstream = self.saved_downstream;
        if (self.owns_audit) {
            self.audit_log.deinit();
            self.gpa.destroy(self.audit_log);
        }
        if (self.owns_registry) {
            self.registry.deinit();
            self.gpa.destroy(self.registry);
        }
        os.close(self.lock);
        os.close(self.dir);
        self.gpa.free(self.path);
        self.* = undefined;
    }
    /// Results consumed by the standard doctor bundle.
    pub fn grantDiagnostics(self: *const Server) struct { peerpidfd: enum { ok, warn }, subreaper: bool, owner_file: bool, audit_writable: bool, unknown_read_all: bool, isolation: bool, custom_lists: bool } {
        const st = os.statAt(c.AT.FDCWD, self.owner_path, c.AT.SYMLINK_NOFOLLOW) catch null;
        var read_all = false;
        for (self.registry.policy.unknown) |entry| if (std.mem.eql(u8, entry.scope, "*")) {
            read_all = true;
        };
        return .{ .peerpidfd = if (self.peerpidfd_available) .ok else .warn, .subreaper = self.options.subreaper, .owner_file = if (st) |s| s.uid == c.getuid() and s.mode & 0o777 == 0o600 and s.mode & c.S.IFMT == c.S.IFREG else false, .audit_writable = self.audit_log.writable, .unknown_read_all = read_all, .isolation = self.registry.isolated(), .custom_lists = !sameGrants(self.registry.policy.unknown, (grants.Policy{}).unknown) or !sameGrants(self.registry.policy.interactive, (grants.Policy{}).interactive) };
    }
    fn sameGrants(x: []const grants.Grant, y: []const grants.Grant) bool {
        if (x.len != y.len) return false;
        for (x, y) |l, r| if (l.right != r.right or !std.mem.eql(u8, l.scope, r.scope)) return false;
        return true;
    }
    fn remove(self: *Server, i: usize) void {
        const conn = self.connections.orderedRemove(i);
        if (self.handler) |h| h.vtable.closed(h.ptr, conn);
        conn.deinit();
        self.gpa.destroy(conn);
    }
    fn accept(self: *Server) !void {
        // Bounded accept work also gives established connections a turn.
        for (0..64) |_| {
            const fd = if (os.is_linux) c.accept4(self.fd, null, null, c.SOCK.NONBLOCK | c.SOCK.CLOEXEC) else c.accept(self.fd, null, null);
            if (fd < 0) return switch (c.errno(fd)) {
                .AGAIN, .INTR, .CONNABORTED => {},
                else => error.SystemResources,
            };
            if (self.connections.items.len >= self.options.max_connections or !os.sameUser(fd)) {
                os.close(fd);
                continue;
            }
            os.nonblocking(fd) catch {
                os.close(fd);
                continue;
            };
            const conn = self.gpa.create(Connection) catch |err| {
                os.close(fd);
                return err;
            };
            conn.* = Connection.init(self.gpa, fd);
            errdefer {
                conn.deinit();
                self.gpa.destroy(conn);
            }
            conn.registry = self.registry;
            conn.audit = self.audit_log;
            const pid = proc.peerPid(fd);
            const pidfd = proc.peerPidfd(fd);
            defer if (pidfd) |pfd| os.close(pfd);
            if (os.is_linux and pidfd == null) self.peerpidfd_available = false;
            var chain = proc.walk(pid, c.getpid());
            if (pidfd) |pfd| if (proc.exited(pfd)) {
                chain.orphan = true;
                chain.failed = true;
            };
            conn.identity = self.registry.resolve(chain, pid, grants.nowSeconds());
            conn.identity.below_manager = managers.below(self.dir, chain);
            conn.max_frame = @min(self.options.hello.max_frame, wire.default_max_frame);
            conn.output_limit = self.options.output_limit;
            try self.connections.append(self.gpa, conn);
        }
    }
    /// Wait up to timeout_ms (>= 0), service each peer fairly, and return.
    /// Handshake and close-drain deadlines are enforced even on idle peers.
    pub fn poll(self: *Server, timeout_ms: i32) !void {
        if (timeout_ms < 0) return error.InvalidOptions;
        self.registry.sweep(grants.nowSeconds());
        try self.saveBound();
        if (self.handler) |h| if (h.tick) |tick| try tick(h.ptr);
        var timeout = @min(timeout_ms, 1000);
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = self.connections.items[i];
            self.process(conn) catch |err| {
                self.remove(i);
                if (err == error.OutOfMemory) return err;
                continue;
            };
            if ((conn.closing and conn.output.items.len == 0) or ((!conn.ready or conn.closing) and os.nowMs() >= conn.deadline_ms)) {
                self.remove(i);
                continue;
            }
            if (!conn.ready or conn.closing) timeout = @min(timeout, @as(i32, @intCast(@max(0, conn.deadline_ms - os.nowMs()))));
            // A full processing budget may leave complete buffered messages.
            if (conn.consumed > 0) timeout = 0;
            i += 1;
        }
        self.polls.clearRetainingCapacity();
        try self.polls.append(self.gpa, .{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 });
        for (self.connections.items) |conn| try self.polls.append(self.gpa, .{
            .fd = conn.fd,
            .events = (if (conn.closing or conn.consumed > 0) @as(i16, 0) else c.POLL.IN) | (if (conn.output.items.len > 0) c.POLL.OUT else @as(i16, 0)),
            .revents = 0,
        });
        try os.poll(self.polls.items, timeout);
        // Reverse removal keeps the fd-to-connection mapping stable.
        var count = self.connections.items.len;
        while (count > 0) {
            count -= 1;
            const conn = self.connections.items[count];
            const flags = self.polls.items[count + 1].revents;
            self.service(conn, flags) catch |err| {
                self.remove(count);
                if (err == error.OutOfMemory) return err;
            };
        }
        if (self.polls.items[0].revents & c.POLL.IN != 0) try self.accept();
        try self.saveBound();
    }
    /// A failure other than memory stays dirty, so the next poll tries again.
    fn saveBound(self: *Server) !void {
        if (!self.registry.bound_dirty) return;
        const name = self.bound_path[self.bound_path.len - std.fs.path.basename(self.bound_path).len .. :0];
        bound.save(self.gpa, self.registry, self.dir, name, grants.nowSeconds()) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        };
        self.registry.bound_dirty = false;
    }
    fn service(self: *Server, conn: *Connection, flags: i16) !void {
        if (flags & (c.POLL.ERR | c.POLL.NVAL) != 0) return error.Disconnected;
        if (flags & c.POLL.IN != 0 and !conn.closing) {
            _ = conn.read() catch |err| {
                if (err == error.TooLarge) return self.fatal(conn, "protocol.too_large");
                if (err == error.EndOfStream) {
                    conn.closing = true;
                    conn.deadline_ms = os.nowMs() + 10_000;
                    return conn.flush();
                }
                return err;
            };
            try self.process(conn);
        }
        if (flags & c.POLL.OUT != 0) try conn.flush();
        if (flags & c.POLL.HUP != 0 and flags & c.POLL.IN == 0 and conn.consumed == 0 and conn.output.items.len == 0) return error.Disconnected;
    }
    fn fatal(self: *Server, conn: *Connection, code: []const u8) !void {
        _ = self;
        try hello.sendError(conn, .null, code, .{});
        conn.closing = true;
        conn.deadline_ms = os.nowMs() + 10_000;
    }
    fn process(self: *Server, conn: *Connection) !void {
        for (0..64) |_| {
            if (conn.closing) return;
            const message = (conn.next() catch |err| {
                if (err == error.BadPreamble) {
                    try hello.sendError(conn, .null, "protocol.bad_preamble", .{ .byte = conn.input.items[0], .supported = [_]u8{ 123, 245 } });
                    conn.closing = true;
                    conn.deadline_ms = os.nowMs() + 10_000;
                    return;
                }
                if (err == error.TooLarge) return self.fatal(conn, "protocol.too_large");
                return err;
            }) orelse return;
            switch (message) {
                .ndjson => |line| try self.control(conn, line, false),
                .frame => |f| {
                    if (!conn.ready) {
                        if (f.kind != wire.Kind.hello) return self.fatal(conn, "protocol.hello_required");
                        if (f.stream != 0) return self.fatal(conn, "protocol.bad_frame");
                        try self.handshake(conn, f.payload, .null, true);
                        continue;
                    }
                    switch (f.kind) {
                        wire.Kind.hello => return self.fatal(conn, "protocol.hello_order"),
                        wire.Kind.ping => {
                            if (f.stream != 0 or f.payload.len > 64) return self.fatal(conn, "protocol.bad_frame");
                            try conn.sendMessage(.{ .frame = .{ .kind = wire.Kind.pong, .payload = f.payload } });
                        },
                        wire.Kind.control => {
                            if (f.stream != 0 or std.mem.indexOfScalar(u8, f.payload, '\n') != null) return self.fatal(conn, "protocol.bad_frame");
                            try self.control(conn, f.payload, true);
                        },
                        wire.Kind.close, wire.Kind.err => {
                            if (f.stream == 0) {
                                conn.closing = true;
                                conn.deadline_ms = os.nowMs() + 10_000;
                            } else if (self.handler) |h| try h.vtable.message(h.ptr, conn, message);
                        },
                        wire.Kind.pong => {
                            if (f.stream != 0 or f.payload.len > 64) return self.fatal(conn, "protocol.bad_frame");
                        },
                        else => {
                            const h = self.handler orelse return self.fatal(conn, "protocol.bad_frame");
                            if (f.kind < 0x100 or !h.vtable.allowFrame(h.ptr, conn, f.kind)) return self.fatal(conn, "protocol.bad_frame");
                            try h.vtable.message(h.ptr, conn, message);
                        },
                    }
                },
            }
        }
    }
    fn control(self: *Server, conn: *Connection, line: []const u8, binary: bool) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, conn.gpa, line, .{ .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return err;
            // The control path only reports the parse error; full malformed-request
            // handling is in `dispatch`. Bootstrap must recover.
            return self.controlError(conn, .null, "protocol.parse", binary);
        };
        defer parsed.deinit();
        const id = hello.field(parsed.value, "id") orelse .null;
        const verb = hello.field(parsed.value, "verb");
        if (!hello.validId(id) or verb == null or verb.? != .string) return self.controlError(conn, if (hello.validId(id)) id else .null, "protocol.invalid_request", binary);
        if (std.mem.eql(u8, verb.?.string, "hello")) {
            if (conn.ready) return self.controlError(conn, id, "protocol.hello_order", binary);
            try self.handshake(conn, line, id, false);
            return;
        }
        if (!conn.ready) {
            var v1 = false;
            for (self.options.hello.versions) |v| if (v == 1) {
                v1 = true;
            };
            if (!v1) {
                try hello.sendError(conn, id, "protocol.version_mismatch", .{ .supported = self.options.hello.versions });
                conn.closing = true;
                return;
            }
            conn.ready = true;
            conn.version = 1;
            conn.max_frame = @min(self.options.hello.max_frame, wire.default_max_frame);
        }
        if (self.handler) |h| try h.vtable.message(h.ptr, conn, .{ .ndjson = line });
    }
    fn controlError(self: *Server, conn: *Connection, id: std.json.Value, code: []const u8, binary: bool) !void {
        _ = self;
        if (!binary) return hello.sendError(conn, id, code, .{});
        const bytes = try hello.encode(conn.gpa, .{ .id = id, .@"error" = .{ .code = code, .message = @import("errors.zig").defaultMessage(code) } });
        defer conn.gpa.free(bytes);
        try conn.sendMessage(.{ .ndjson = bytes });
    }
    fn handshake(self: *Server, conn: *Connection, bytes: []const u8, id: std.json.Value, binary: bool) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, conn.gpa, bytes, .{ .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.fatal(conn, "protocol.parse");
        };
        var retained = false;
        defer if (!retained) parsed.deinit();
        const params = if (binary) parsed.value else hello.field(parsed.value, "params") orelse .null;
        hello.negotiate(conn, params, self.options.hello) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.VersionMismatch) {
                try hello.sendError(conn, id, "protocol.version_mismatch", .{ .supported = self.options.hello.versions });
                conn.closing = true;
                return;
            }
            if (binary) return self.fatal(conn, "invalid_params.hello");
            return self.controlError(conn, id, "invalid_params.hello", false);
        };
        if (hello.field(params, "auth")) |auth| {
            const token = hello.field(auth, "token");
            const failure: ?grants.TokenFailure = if (auth != .object) .invalid else if (token) |t| (if (t == .string) self.registry.authenticate(&conn.identity, t.string, grants.nowSeconds()) else .invalid) else null;
            if (failure) |reason| {
                self.registry.denied(conn.identity, "hello", .none, "denied.token", null);
                try hello.sendError(conn, id, "denied.token", .{ .reason = @tagName(reason) });
                conn.closing = true;
                conn.deadline_ms = os.nowMs() + 10_000;
                return;
            }
        }
        if (conn.identity.principal == grants.owner) if (conn.audit) |log| log.record(.{ .event = "owner_auth", .principal = grants.owner, .pid = conn.identity.peer_pid, .verb = "hello" });
        conn.hello = parsed;
        retained = true;
        const result = try hello.result(conn, self.options.hello);
        defer conn.gpa.free(result);
        if (binary) {
            try conn.sendMessage(.{ .frame = .{ .kind = wire.Kind.hello_ok, .payload = result } });
        } else {
            const result_json = try std.json.parseFromSlice(std.json.Value, conn.gpa, result, .{});
            defer result_json.deinit();
            const response = try hello.encode(conn.gpa, .{ .id = id, .ok = result_json.value });
            defer conn.gpa.free(response);
            try conn.sendMessage(.{ .ndjson = response });
        }
        conn.ready = true;
    }
};
