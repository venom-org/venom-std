//! Client credential selection. Informational *_PRINCIPAL and pane environment
//! variables are deliberately never read. Only explicit @owner reads the file.
const std = @import("std");
const os = @import("os.zig");
const c = os.c;
pub fn fromEnvironment(gpa: std.mem.Allocator, tool: []const u8, options: os.SocketOptions) !?[]u8 {
    const env = options.environ orelse return null;
    var key: [40:0]u8 = undefined;
    if (!@import("xdg").validTool(tool)) return error.InvalidTool;
    for (tool, 0..) |ch, i| key[i] = if (ch == '-') '_' else std.ascii.toUpper(ch);
    @memcpy(key[tool.len..][0..6], "_TOKEN");
    key[tool.len + 6] = 0;
    const value = env.getPosix(key[0 .. tool.len + 6 :0]) orelse return null;
    if (!std.mem.eql(u8, value, "@owner")) return try gpa.dupe(u8, value);
    const socket = try os.socketPath(gpa, tool, options);
    defer gpa.free(socket);
    const base = if (std.mem.endsWith(u8, socket, ".sock")) socket[0 .. socket.len - 5] else socket;
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}.owner", .{base}, 0);
    defer gpa.free(path);
    const dir = try os.runtimeDir(gpa, path, false);
    defer os.close(dir);
    const name = path[path.len - std.fs.path.basename(path).len .. :0];
    const st = try os.statAt(dir, name, c.AT.SYMLINK_NOFOLLOW);
    if (st.mode & c.S.IFMT != c.S.IFREG or st.uid != c.getuid() or st.mode & 0o777 != 0o600 or st.nlink != 1) return error.InsecurePath;
    const fd = c.openat(dir, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) return error.InvalidOwnerFile;
    defer os.close(fd);
    var buf: [256]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0 or n == buf.len) return error.InvalidOwnerFile;
    return try gpa.dupe(u8, std.mem.trimEnd(u8, buf[0..@intCast(n)], "\r\n"));
}
