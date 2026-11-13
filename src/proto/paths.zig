//! Canonical destination paths, including not-yet-created leaves. Handlers must
//! create the checked destination with O_NOFOLLOW (prefer openat on its parent).
const std = @import("std");
const os = @import("os.zig");
extern "c" fn realpath([*:0]const u8, [*]u8) ?[*:0]u8;
pub fn canonical(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var buf: [4096]u8 = undefined;
    if (realpath(z, &buf)) |p| return a.dupe(u8, std.mem.span(p));
    if (os.c.errno(@as(c_int, -1)) != .NOENT) return error.InvalidPath;
    if (os.statAt(os.c.AT.FDCWD, z, os.c.AT.SYMLINK_NOFOLLOW)) |st| {
        // A dangling symlink is not a missing leaf; accepting it would allow
        // a later create to follow an unchecked intermediate link.
        if (st.mode & os.c.S.IFMT == os.c.S.IFLNK) return error.InvalidPath;
    } else |err| if (err != error.FileNotFound) return error.InvalidPath;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    if (std.mem.eql(u8, parent, path)) return error.InvalidPath;
    const resolved_parent = try canonical(a, parent);
    defer a.free(resolved_parent);
    const joined = try std.fs.path.resolve(a, &.{ resolved_parent, std.fs.path.basename(path) });
    errdefer a.free(joined);
    const joined_z = try a.dupeSentinel(u8, joined, 0);
    defer a.free(joined_z);
    // Removing .. may expose an existing symlink after a missing component.
    if (realpath(joined_z, &buf)) |p| {
        const result = try a.dupe(u8, std.mem.span(p));
        a.free(joined);
        return result;
    }
    if (os.c.errno(@as(c_int, -1)) != .NOENT) return error.InvalidPath;
    return joined;
}
pub fn authorize(a: std.mem.Allocator, reg: *const @import("grants.zig").Registry, identity: @import("grants.zig").Identity, right: @import("grants.zig").Right, path: []const u8, now: i64) ![]const u8 {
    const resolved = canonical(a, path) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Denied;
    errdefer a.free(resolved);
    try reg.authorize(identity, right, .{ .kind = "path", .id = resolved }, now);
    return resolved;
}
