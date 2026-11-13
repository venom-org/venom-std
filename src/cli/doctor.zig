//! The shared `doctor` verb. Products register checks;
//! each one reports results with a stable id, `ok`/`warn`/`fail`, a human
//! message and a runnable POSIX-shell `fix` (a harmless recheck when ok).
//! The report's `status` is 1 if any check failed, else 0, and becomes the
//! CLI exit status. Checks must be read-only and never run their fixes.
const std = @import("std");
const proto = @import("proto");
const iface = @import("iface");
const docs = @import("docs.zig");
const Allocator = std.mem.Allocator;

pub const Status = enum { ok, warn, fail };
pub const Result = struct { id: []const u8, status: Status, message: []const u8, fix: []const u8 };

/// Collects results. All memory belongs to `arena`.
pub const Report = struct {
    arena: Allocator,
    tool: []const u8,
    /// The caller's compiled schema digest, if it supplied one.
    client_schema: ?[]const u8 = null,
    results: std.ArrayList(Result) = .empty,

    pub fn add(self: *Report, id: []const u8, outcome: Status, message: []const u8, fix: []const u8) !void {
        try self.results.append(self.arena, .{ .id = id, .status = outcome, .message = message, .fix = fix });
    }
    pub fn print(self: *Report, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args);
    }
    /// `fmt` with its one `{s}` replaced by `arg`, POSIX-shell-quoted.
    pub fn command(self: *Report, comptime fmt: []const u8, arg: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        try docs.shell(&out.writer, arg);
        return std.fmt.allocPrint(self.arena, fmt, .{out.written()});
    }
    pub fn status(self: *const Report) u8 {
        for (self.results.items) |r| if (r.status == .fail) return 1;
        return 0;
    }
};

/// A registered check. It may add several results, each with its own id.
pub const Check = struct {
    /// Used for a synthetic `fail` result if `run` itself errors.
    id: []const u8,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (*anyopaque, *Report) anyerror!void,
    };

    pub fn init(id: []const u8, impl: anytype) Check {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        return .{ .id = id, .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .run = run };
            fn run(ptr: *anyopaque, report: *Report) anyerror!void {
                return iface.cast(T, ptr).run(report);
            }
        }.vt };
    }
};

/// The `doctor` verb handler. Bind it with `proto.VerbHandler.init`.
/// After the product checks it appends `schema.digest`: `warn` when the caller's `client_schema` differs from the
/// daemon's advertised `schema`, otherwise `ok`. A missing digest on either
/// side is reported as `ok` (not checked), never as a failure.
pub const Doctor = struct {
    tool: []const u8,
    checks: []const Check = &.{},
    /// The digest this daemon advertises in `hello.schema`, if any.
    schema: ?[]const u8 = null,

    pub fn call(self: *Doctor, c: *proto.Call) anyerror!void {
        var report: Report = .{ .arena = c.arena(), .tool = self.tool };
        if (c.params.object.get("client_schema")) |v| report.client_schema = v.string;
        for (self.checks) |check| check.vtable.run(check.ptr, &report) catch |err| {
            if (err == error.OutOfMemory) return err;
            try report.add(check.id, .fail, try report.print("check could not run: {s}", .{@errorName(err)}), try report.command("{s} doctor --json", self.tool));
        };
        if (c.conn.identity.below_manager) try report.add("grants.below_manager", .warn, "a manager's marker matches a process above this caller, so the owner token is refused here. Expected in a pane or a split; in a plain terminal, a marker was forged", "ls -l \"${XDG_RUNTIME_DIR:-/tmp}/venom\" | grep manager-");
        if (c.conn.registry) |reg| try processPrincipals(&report, reg, c.conn.identity, self.tool);
        try schemaCheck(&report, self.schema);
        try c.ok(.{ .status = report.status(), .checks = report.results.items });
    }
};

/// Process principals: who holds rights with no token, and which came from the
/// bound file, which anyone with this UID can write. Only to those who see the
/// whole tree in `grant.list` (the owner, or `admin`), and only when there are any:
/// `read` on any scope is not enough, and `unknown` has it.
/// `<TOOL>_TOKEN`, as credentials.zig reads it.
fn tokenVar(tool: []const u8, buf: *[40]u8) []const u8 {
    const n = @min(tool.len, buf.len - 6);
    for (tool[0..n], 0..) |ch, i| buf[i] = if (ch == '-') '_' else std.ascii.toUpper(ch);
    @memcpy(buf[n..][0..6], "_TOKEN");
    return buf[0 .. n + 6];
}
pub fn processPrincipals(r: *Report, reg: *const proto.grants.Registry, identity: proto.grants.Identity, tool: []const u8) !void {
    const now = proto.grants.nowSeconds();
    if (!reg.allows(identity, .admin, null, now)) return;
    var list: std.Io.Writer.Allocating = .init(r.arena);
    var count: usize = 0;
    for (reg.entries.items) |p| {
        if (p.kind != .process or p.revoked or !reg.live(p.id, now)) continue;
        const root = p.root orelse continue;
        var buf: [24]u8 = undefined;
        if (count > 0) try list.writer.writeAll(", ");
        try list.writer.print("{s} pid {d} \"{s}\"{s}", .{ proto.grants.name(p.id, &buf), root.pid, p.label, if (p.restored) " (restored)" else "" });
        count += 1;
    }
    if (count > 0) try r.add("grants.process_principals", .ok, try r.print("bound to a process, with no token: {s}. Restored ones came from the bound file, which any process of this user can write; revoke any you don't recognise", .{list.written()}), try r.command("{s} grant list --json", tool));
}

/// The CLI/daemon schema skew check. Skew is a warning: normal calls keep
/// working and the daemon still validates every request.
pub fn schemaCheck(r: *Report, daemon: ?[]const u8) !void {
    const fix = try r.command("{s} doctor --json", r.tool);
    const server = daemon orelse return r.add("schema.digest", .ok, "the daemon advertises no schema digest; CLI/daemon skew was not checked", fix);
    const client = r.client_schema orelse return r.add("schema.digest", .ok, try r.print("no client schema digest was supplied; the daemon runs {s}", .{server}), fix);
    if (std.mem.eql(u8, client, server)) return r.add("schema.digest", .ok, try r.print("CLI and daemon schemas match ({s})", .{server}), fix);
    try r.add("schema.digest", .warn, try r.print("CLI schema {s} differs from the daemon's {s}; the daemon may still be running an older binary, so restart it after upgrading", .{ client, server }), fix);
}

/// Built-in checks for a running `proto.Server`: socket path and runtime
/// directory, owner credential file, audit log and peer attribution.
pub const ServerCheck = struct {
    server: *const proto.Server,

    pub fn run(self: *ServerCheck, r: *Report) anyerror!void {
        const path: []const u8 = self.server.path;
        const dir = std.fs.path.dirname(path) orelse "/";
        const max = @typeInfo(@TypeOf(@as(std.c.sockaddr.un, undefined).path)).array.len - 1;
        if (path.len > max) {
            try r.add("runtime.socket_path", .fail, try r.print("socket path is {d} bytes; the limit is {d}", .{ path.len, max }), try r.command("{s} serve --help", r.tool));
        } else try r.add("runtime.socket_path", .ok, try r.print("socket path {s} fits ({d} of {d} bytes)", .{ path, path.len, max }), try r.command("ls -l -- {s}", path));

        const dir_z = try r.arena.dupeSentinel(u8, dir, 0);
        if (proto.os.statAt(std.c.AT.FDCWD, dir_z, std.c.AT.SYMLINK_NOFOLLOW)) |st| {
            if (st.mode & std.c.S.IFMT != std.c.S.IFDIR or st.uid != std.c.getuid()) {
                try r.add("runtime.directory", .fail, try r.print("runtime directory {s} is not a directory owned by this user", .{dir}), try r.command("ls -ld -- {s}", dir));
            } else if (st.mode & 0o077 != 0) {
                try r.add("runtime.directory", .fail, try r.print("runtime directory {s} has mode {o}; other users must have no access", .{ dir, st.mode & 0o777 }), try r.command("chmod 700 -- {s}", dir));
            } else try r.add("runtime.directory", .ok, try r.print("runtime directory {s} is private", .{dir}), try r.command("ls -ld -- {s}", dir));
        } else |_| try r.add("runtime.directory", .fail, try r.print("cannot inspect runtime directory {s}", .{dir}), try r.command("ls -ld -- {s}", dir));

        const d = self.server.grantDiagnostics();
        if (d.owner_file)
            try r.add("grants.owner_file", .ok, "owner credential file is private", try r.command("ls -l -- {s}", self.server.owner_path))
        else
            try r.add("grants.owner_file", .fail, "owner credential file is missing or not mode 0600; restart the daemon to recreate it", try r.command("ls -l -- {s}", self.server.owner_path));
        if (d.audit_writable)
            try r.add("grants.audit", .ok, "audit log is writable", try r.command("{s} doctor --json", r.tool))
        else
            try r.add("grants.audit", .fail, "audit log is not writable; grant decisions are not being recorded", "ls -ld -- \"${XDG_STATE_HOME:-$HOME/.local/state}/venom\"");
        var env_buf: [40]u8 = undefined;
        const env = tokenVar(r.tool, &env_buf);
        if (d.isolation)
            try r.add("grants.isolation", .ok, "isolation is on: callers are kept apart by their grants and namespaces are checked", try r.command("{s} config get --key grants.isolation", r.tool))
        else if (d.custom_lists)
            try r.add("grants.isolation", .warn, "isolation is off, so grants.unknown and grants.interactive are not used; turn isolation on for them to apply", try r.print("{s}=@owner {s} config set --key grants.isolation --value true", .{ env, r.tool }))
        else
            try r.add("grants.isolation", .ok, "isolation is off: this user's processes may read, write and spawn, like tmux; turn it on when agents run here", try r.print("{s}=@owner {s} config set --key grants.isolation --value true", .{ env, r.tool }));
        if (d.peerpidfd == .ok)
            try r.add("grants.peer_attribution", .ok, "peer process attribution uses pidfds", "uname -sr")
        else
            try r.add("grants.peer_attribution", .warn, "pidfds are unavailable; peer process attribution is best-effort", "uname -sr");
    }
};
