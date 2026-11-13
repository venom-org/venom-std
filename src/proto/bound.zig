//! `process` principals outlive a restart of their daemon.
//! They hold no credential, so the one who bound them need not be there to do it
//! again. The file sits next to the socket, mode 0600, and survives a clean stop.
//! An entry comes back only if its `(pid, starttime)` still lives, under a new
//! ID, and never with `admin`: a same-UID process can edit this file, which is
//! outside the sanctioned channel, and that bounds what it gets.
//! A marked process isn't refused here, unlike at `grant.issue`: an agent view
//! is bound before it marks itself to run its own shells, and has to come back.
const std = @import("std");
const grants = @import("grants.zig");
const os = @import("os.zig");
const proc = @import("process.zig");
const c = os.c;

const max_bytes = 1 << 20;

const Entry = struct {
    id: u64,
    parent: u64,
    pid: i32,
    start: u64,
    grants: []const grants.Grant,
    label: []const u8 = "",
    namespace: ?[]const u8 = null,
    expires: ?i64 = null,
};

fn holdsAdmin(gs: []const grants.Grant) bool {
    for (gs) |g| if (g.right == .admin) return true;
    return false;
}

/// Replaces the file with what is live now; no such principal, no file.
pub fn save(gpa: std.mem.Allocator, reg: *const grants.Registry, dir: c.fd_t, name: [:0]const u8, now: i64) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var kept: std.AutoHashMapUnmanaged(u64, void) = .empty;
    try kept.put(a, grants.owner, {});
    // Entries are in ID order, so a parent comes before its children.
    for (reg.entries.items) |p| {
        if (p.kind != .process or p.revoked or p.cap != null or !reg.live(p.id, now) or holdsAdmin(p.grants)) continue;
        const parent = p.parent orelse continue;
        if (!kept.contains(parent)) continue;
        const root = p.root orelse continue;
        try kept.put(a, p.id, {});
        try entries.append(a, .{ .id = p.id, .parent = parent, .pid = root.pid, .start = root.start, .grants = p.grants, .label = p.label, .namespace = p.namespace, .expires = p.expires });
    }
    if (entries.items.len == 0) {
        if (c.unlinkat(dir, name, 0) != 0 and c.errno(-1) != .NOENT) return error.SystemResources;
        return;
    }
    const bytes = try std.json.Stringify.valueAlloc(a, entries.items, .{});
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.tmp", .{name}, 0);
    _ = c.unlinkat(dir, tmp, 0);
    const fd = c.openat(dir, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.InsecurePath;
    errdefer _ = c.unlinkat(dir, tmp, 0);
    defer os.close(fd);
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.SystemResources;
        rest = rest[@intCast(n)..];
    }
    if (c.renameat(dir, tmp, dir, name) != 0) return error.SystemResources;
}

/// Restores what the file holds. A file that is missing, not plainly ours, or
/// unreadable restores nothing: the panes are then `unknown`, which says so.
pub fn load(gpa: std.mem.Allocator, reg: *grants.Registry, dir: c.fd_t, name: [:0]const u8, now: i64) !void {
    const st = os.statAt(dir, name, c.AT.SYMLINK_NOFOLLOW) catch return;
    if ((st.mode & c.S.IFMT) != c.S.IFREG or st.uid != c.getuid() or st.mode & 0o077 != 0 or st.nlink != 1) return;
    const fd = c.openat(dir, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (fd < 0) return;
    defer os.close(fd);
    const bytes = try gpa.alloc(u8, max_bytes);
    defer gpa.free(bytes);
    var len: usize = 0;
    while (len < bytes.len) {
        const n = c.read(fd, bytes[len..].ptr, bytes.len - len);
        if (n < 0) return;
        if (n == 0) break;
        len += @intCast(n);
    }
    if (len == bytes.len) return;
    var parsed = std.json.parseFromSlice([]const Entry, gpa, bytes[0..len], .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    defer parsed.deinit();
    var ids: std.AutoHashMapUnmanaged(u64, grants.Id) = .empty;
    defer ids.deinit(gpa);
    try ids.put(gpa, grants.owner, grants.owner);
    // The next save writes the new IDs, or removes the file.
    reg.bound_dirty = true;
    for (parsed.value) |e| {
        const parent = ids.get(e.parent) orelse continue;
        const root: proc.Ref = .{ .pid = e.pid, .start = e.start };
        if (e.pid <= 1 or e.pid == c.getpid() or !proc.alive(root) or reg.boundTo(root, now)) continue;
        if (e.expires) |x| if (x <= now) continue;
        if (holdsAdmin(e.grants) or !validGrants(e.grants) or !validLabel(e.label)) continue;
        if (e.namespace) |ns| if (!grants.validNamespace(ns) or std.mem.eql(u8, ns, reg.ownerNamespace())) continue;
        try ids.put(gpa, e.id, try reg.restoreProcess(parent, root, e.grants, e.label, e.namespace, e.expires));
    }
}

fn validGrants(gs: []const grants.Grant) bool {
    for (gs) |g| grants.validateGrant(g) catch return false;
    return true;
}

fn validLabel(label: []const u8) bool {
    if (label.len > 64) return false;
    for (label) |ch| if (ch < 32 or ch == 127) return false;
    return true;
}
