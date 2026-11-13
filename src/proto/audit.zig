//! Append-only secret-free audit records. Failure is diagnostic, never policy.
const std = @import("std");
const os = @import("os.zig");
const c = os.c;
const grants = @import("grants.zig");
pub const Options = struct { path: []const u8, source: []const u8, max_bytes: usize = 16 * 1024 * 1024, keep: u8 = 2 };
pub const Record = struct {
    event: []const u8,
    principal: grants.Id,
    pid: c.pid_t = 0,
    start: u64 = 0,
    verb: []const u8 = "",
    right: grants.Right = .none,
    resource: ?[]const u8 = null,
    code: ?[]const u8 = null,
    target: ?grants.Id = null,
    cascade: ?usize = null,
};
pub const Log = struct {
    gpa: std.mem.Allocator,
    options: Options,
    writable: bool = true,
    downstream: ?grants.Observer = null,
    pub fn init(gpa: std.mem.Allocator, options: Options) !Log {
        if (options.path.len == 0 or options.max_bytes == 0) return error.InvalidOptions;
        const path = try gpa.dupe(u8, options.path);
        errdefer gpa.free(path);
        return .{ .gpa = gpa, .options = .{ .path = path, .source = try gpa.dupe(u8, options.source), .max_bytes = options.max_bytes, .keep = options.keep } };
    }
    pub fn deinit(self: *Log) void {
        self.gpa.free(self.options.path);
        self.gpa.free(self.options.source);
    }
    pub fn observer(self: *Log) grants.Observer {
        return .{ .ptr = self, .changed = changed };
    }
    fn changed(ptr: *anyopaque, change: grants.Change) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.record(.{ .event = change.event, .principal = change.principal, .target = change.target, .cascade = change.cascade, .pid = change.pid, .start = change.start, .verb = change.verb, .right = change.right, .code = change.code, .resource = change.resource });
        if (self.downstream) |observer_| observer_.changed(observer_.ptr, change);
    }
    pub fn record(self: *Log, r: Record) void {
        self.append(r) catch {
            self.writable = false;
            return;
        };
        self.writable = true;
    }
    /// Read a bounded tail of the current file. Caller supplies an arena.
    pub fn recent(self: *Log, arena: std.mem.Allocator, limit: usize) ![]std.json.Value {
        const path = try arena.dupeSentinel(u8, self.options.path, 0);
        const fd = c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
        if (fd < 0) return error.AuditUnavailable;
        defer os.close(fd);
        const end = c.lseek(fd, 0, c.SEEK.END);
        if (end < 0) return error.AuditUnavailable;
        const start = @max(0, end - 1024 * 1024);
        if (c.lseek(fd, start, c.SEEK.SET) < 0) return error.AuditUnavailable;
        const buf = try arena.alloc(u8, @intCast(end - start));
        var len: usize = 0;
        while (len < buf.len) {
            const n = c.read(fd, buf.ptr + len, buf.len - len);
            if (n <= 0) return error.AuditUnavailable;
            len += @intCast(n);
        }
        var lines = std.mem.splitScalar(u8, buf, '\n');
        if (start > 0) _ = lines.next();
        var list: std.ArrayList(std.json.Value) = .empty;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{ .allocate = .alloc_always }) catch continue;
            try list.append(arena, v);
        }
        return list.items[list.items.len - @min(limit, list.items.len) ..];
    }
    pub fn probe(self: *Log) error{OutOfMemory}!void {
        const fd = self.open() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.writable = false;
            return;
        };
        os.close(fd);
        self.writable = true;
    }
    fn open(self: *Log) !c.fd_t {
        const path = try self.gpa.dupeSentinel(u8, self.options.path, 0);
        defer self.gpa.free(path);
        const dir = try os.runtimeDir(self.gpa, path, true);
        defer os.close(dir);
        const base = path[path.len - std.fs.path.basename(path).len .. :0];
        const fd = c.openat(dir, base, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.AuditUnavailable;
        errdefer os.close(fd);
        const st = try os.statAt(dir, base, c.AT.SYMLINK_NOFOLLOW);
        if (st.mode & c.S.IFMT != c.S.IFREG or st.uid != c.getuid() or st.mode & 0o077 != 0 or st.nlink != 1) return error.InsecurePath;
        return fd;
    }
    fn append(self: *Log, r: Record) !void {
        var idbuf: [24]u8 = undefined;
        var targetbuf: [24]u8 = undefined;
        var tsbuf: [32]u8 = undefined;
        const ts = try timestamp(grants.nowSeconds(), &tsbuf);
        // Only schema names, IDs, and the named resource are admitted here.
        // Never accept request params or token credentials as audit fields.
        var exebuf: [4096]u8 = undefined;
        var procbuf: [64:0]u8 = undefined;
        const exe: ?[]const u8 = blk: {
            if (!os.is_linux or r.pid <= 0) break :blk null;
            const procpath = try std.fmt.bufPrintSentinel(&procbuf, "/proc/{d}/exe", .{r.pid}, 0);
            const n = c.readlink(procpath, &exebuf, exebuf.len);
            break :blk if (n > 0) exebuf[0..@intCast(n)] else null;
        };
        const bytes = try std.json.Stringify.valueAlloc(self.gpa, .{ .ts = ts, .source = self.options.source, .event = r.event, .principal = grants.name(r.principal, &idbuf), .peer = .{ .pid = r.pid, .exe = exe, .start = if (r.start != 0) r.start else null }, .verb = r.verb, .right = @tagName(r.right), .resource = r.resource, .code = r.code, .target = if (r.target) |id| grants.name(id, &targetbuf) else null, .cascade = r.cascade }, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(bytes);
        const path = try self.gpa.dupeSentinel(u8, self.options.path, 0);
        defer self.gpa.free(path);
        const dir = try os.runtimeDir(self.gpa, path, true);
        defer os.close(dir);
        const base = path[path.len - std.fs.path.basename(path).len .. :0];
        const fd = try self.open();
        defer os.close(fd);
        const line = try std.fmt.allocPrint(self.gpa, "{s}\n", .{bytes});
        defer self.gpa.free(line);
        if (c.write(fd, line.ptr, line.len) != line.len) return error.AuditUnavailable;
        const size = c.lseek(fd, 0, c.SEEK.END);
        if (size < 0) return error.AuditUnavailable;
        if (@as(u64, @intCast(size)) > self.options.max_bytes) try self.rotate(dir, base);
    }
    fn rotate(self: *Log, dir: c.fd_t, base: [:0]const u8) !void {
        if (self.options.keep == 0) {
            if (c.unlinkat(dir, base, 0) != 0) return error.AuditUnavailable;
            return;
        }
        var i: u8 = self.options.keep;
        while (i > 0) : (i -= 1) {
            const dst = try std.fmt.allocPrintSentinel(self.gpa, "{s}.{d}", .{ base, i }, 0);
            defer self.gpa.free(dst);
            const src = if (i == 1) try self.gpa.dupeSentinel(u8, base, 0) else try std.fmt.allocPrintSentinel(self.gpa, "{s}.{d}", .{ base, i - 1 }, 0);
            defer self.gpa.free(src);
            if (c.renameat(dir, src, dir, dst) != 0 and c.errno(-1) != .NOENT) return error.AuditUnavailable;
        }
    }
};
pub fn timestamp(seconds: i64, buf: []u8) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, seconds)) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, @backingInt(md.month), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

/// Default state path. Environment is explicit, with passwd as the HOME fallback.
pub fn defaultPath(a: std.mem.Allocator, tool: []const u8, environ: ?std.process.Environ) ![]u8 {
    if (environ) |env| if (env.getPosix("XDG_STATE_HOME")) |state| if (state.len > 0) return std.fmt.allocPrint(a, "{s}/venom/{s}/audit.ndjson", .{ state, tool });
    const home = blk: {
        if (environ) |env| if (env.getPosix("HOME")) |home| if (home.len > 0) break :blk home;
        const pw = c.getpwuid(c.getuid()) orelse return error.NoHome;
        break :blk std.mem.span(pw.dir orelse return error.NoHome);
    };
    return std.fmt.allocPrint(a, "{s}/.local/state/venom/{s}/audit.ndjson", .{ home, tool });
}
/// Create missing parent directories without following symlinks. Existing
/// ancestors may have normal HOME permissions; Log checks the final directory.
pub fn makeParents(a: std.mem.Allocator, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const absolute = std.fs.path.isAbsolute(parent);
    var fd = c.open(if (absolute) "/" else ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return error.InsecurePath;
    defer os.close(fd);
    var parts = std.mem.tokenizeScalar(u8, parent, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.InsecurePath;
        const z = try a.dupeSentinel(u8, part, 0);
        defer a.free(z);
        if (c.mkdirat(fd, z, 0o700) != 0 and c.errno(-1) != .EXIST) return error.InsecurePath;
        const next = c.openat(fd, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (next < 0) return error.InsecurePath;
        os.close(fd);
        fd = next;
    }
}

extern "c" fn getentropy(*anyopaque, usize) c_int;
pub fn instanceSource(a: std.mem.Allocator, tool: []const u8) ![]const u8 {
    var instance: [16]u8 = undefined;
    if (getentropy(&instance, instance.len) != 0) return error.EntropyUnavailable;
    instance[6] = (instance[6] & 15) | 0x40;
    instance[8] = (instance[8] & 63) | 0x80;
    const hex = std.fmt.bytesToHex(instance, .lower);
    return std.fmt.allocPrint(a, "{s}/{s}-{s}-{s}-{s}-{s}", .{ tool, hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}
