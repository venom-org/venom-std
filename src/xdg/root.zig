//! xdg: XDG base directories with Venom subpaths.
//!
//! Every venom tool keeps its files under one `venom/` directory per XDG base:
//!
//! | Kind      | Base (env, then fallback)                               | venom dir             |
//! |-----------|---------------------------------------------------------|-----------------------|
//! | `config`  | `$XDG_CONFIG_HOME`, `~/.config`                         | `<base>/venom/<tool>` |
//! | `data`    | `$XDG_DATA_HOME`, `~/.local/share`                      | `<base>/venom/<tool>` |
//! | `state`   | `$XDG_STATE_HOME`, `~/.local/state`                     | `<base>/venom/<tool>` |
//! | `cache`   | `$XDG_CACHE_HOME`, `~/.cache`                           | `<base>/venom/<tool>` |
//! | `runtime` | `$XDG_RUNTIME_DIR/venom`, `${TMPDIR:-/tmp}/venom-<uid>` | flat                  |
//!
//! Following the XDG spec, an unset, empty or relative variable is ignored.
//! The runtime directory is flat (`<tool>.sock`, `<tool>.lock`, ...) because
//! the socket path is fixed as `<runtime>/<tool>.sock`.
//!
//! The environment is supplied by the caller (normally
//! `process.Init.minimal.environ`) so the module has no hidden global state
//! and does not need libc. Returned paths belong to the caller's allocator.
const std = @import("std");

pub const Kind = enum { config, data, state, cache, runtime };

pub const Options = struct {
    environ: ?std.process.Environ = null,
    /// Overrides `$HOME`. Callers with libc can pass the passwd entry when
    /// `$HOME` is unset.
    home: ?[]const u8 = null,
    /// Real user ID, used by the runtime fallback `${TMPDIR:-/tmp}/venom-<uid>`.
    uid: u32,
};

/// The XDG base directory itself (no `venom/` suffix), e.g. `~/.local/state`.
/// For `.runtime` this is already the venom runtime directory, see `venomDir`.
pub fn base(gpa: std.mem.Allocator, kind: Kind, options: Options) ![]u8 {
    if (kind == .runtime) return runtimeDir(gpa, options);
    const key: [:0]const u8, const fallback: []const u8 = switch (kind) {
        .config => .{ "XDG_CONFIG_HOME", ".config" },
        .data => .{ "XDG_DATA_HOME", ".local/share" },
        .state => .{ "XDG_STATE_HOME", ".local/state" },
        .cache => .{ "XDG_CACHE_HOME", ".cache" },
        .runtime => unreachable,
    };
    if (absolute(env(options.environ, key))) |dir| return gpa.dupe(u8, trimSlash(dir));
    const home = absolute(options.home orelse env(options.environ, "HOME")) orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), fallback });
}

/// The venom directory for `kind`. With a tool it is `<base>/venom/<tool>`;
/// without one it is the shared `<base>/venom`. The runtime directory is
/// shared by all tools, so `tool` is only validated for `.runtime`.
pub fn venomDir(gpa: std.mem.Allocator, kind: Kind, tool: ?[]const u8, options: Options) ![]u8 {
    if (tool) |t| if (!validTool(t)) return error.InvalidTool;
    const b = try base(gpa, kind, options);
    if (kind == .runtime) return b;
    defer gpa.free(b);
    if (tool) |t| return std.fmt.allocPrint(gpa, "{s}/venom/{s}", .{ b, t });
    return std.fmt.allocPrint(gpa, "{s}/venom", .{b});
}

/// `<venomDir(kind, tool)>/<name>`. `name` must be a single path component.
/// For `.runtime` the file is `<runtime>/<tool>.<name>` so tools never collide
/// in the shared directory, e.g. `path(.runtime, "venom", "status.json")` is
/// `$XDG_RUNTIME_DIR/venom/venom.status.json`.
pub fn path(gpa: std.mem.Allocator, kind: Kind, tool: []const u8, name: []const u8, options: Options) ![:0]u8 {
    if (!validName(name)) return error.InvalidName;
    const dir = try venomDir(gpa, kind, tool, options);
    defer gpa.free(dir);
    if (kind == .runtime) return std.fmt.allocPrintSentinel(gpa, "{s}/{s}.{s}", .{ dir, tool, name }, 0);
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
}

pub const SocketOptions = struct {
    socket: ?[]const u8 = null,
    environ: ?std.process.Environ = null,
    uid: u32,
};

/// Socket path, in order: `--socket`, then `$<TOOL>_SOCKET`,
/// then `<runtime>/<tool>.sock`.
pub fn socketPath(gpa: std.mem.Allocator, tool: []const u8, options: SocketOptions) ![:0]u8 {
    if (!validTool(tool)) return error.InvalidTool;
    var key: [40:0]u8 = undefined;
    for (tool, 0..) |ch, i| key[i] = if (ch == '-') '_' else std.ascii.toUpper(ch);
    @memcpy(key[tool.len..][0..7], "_SOCKET");
    key[tool.len + 7] = 0;
    if (options.socket orelse env(options.environ, key[0 .. tool.len + 7 :0])) |p| {
        if (p.len == 0 or std.mem.indexOfScalar(u8, p, 0) != null) return error.InvalidPath;
        return gpa.dupeSentinel(u8, p, 0);
    }
    return path(gpa, .runtime, tool, "sock", .{ .environ = options.environ, .uid = options.uid });
}

pub fn lockPath(gpa: std.mem.Allocator, socket: []const u8) ![:0]u8 {
    return siblingPath(gpa, socket, "lock");
}

/// `<socket without .sock>.<suffix>`: files that live next to a daemon's
/// socket (lock, status) and so follow `--socket` overrides.
pub fn siblingPath(gpa: std.mem.Allocator, socket: []const u8, suffix: []const u8) ![:0]u8 {
    const stem = if (std.mem.endsWith(u8, socket, ".sock")) socket[0 .. socket.len - 5] else socket;
    return std.fmt.allocPrintSentinel(gpa, "{s}.{s}", .{ stem, suffix }, 0);
}

pub fn validTool(tool: []const u8) bool {
    if (tool.len == 0 or tool.len > 32 or tool[0] < 'a' or tool[0] > 'z') return false;
    for (tool[1..]) |ch| if (!(ch >= 'a' and ch <= 'z') and !std.ascii.isDigit(ch) and ch != '-') return false;
    return true;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn runtimeDir(gpa: std.mem.Allocator, options: Options) ![]u8 {
    if (nonempty(env(options.environ, "XDG_RUNTIME_DIR"))) |dir|
        return std.fmt.allocPrint(gpa, "{s}/venom", .{dir});
    const tmp = nonempty(env(options.environ, "TMPDIR")) orelse "/tmp";
    return std.fmt.allocPrint(gpa, "{s}/venom-{d}", .{ tmp, options.uid });
}

fn env(environ: ?std.process.Environ, key: [:0]const u8) ?[]const u8 {
    return if (environ) |e| e.getPosix(key) else null;
}
fn nonempty(value: ?[]const u8) ?[]const u8 {
    return if (value) |s| (if (s.len > 0) s else null) else null;
}
fn absolute(value: ?[]const u8) ?[]const u8 {
    const s = nonempty(value) orelse return null;
    return if (s[0] == '/' and std.mem.indexOfScalar(u8, s, 0) == null) s else null;
}
fn trimSlash(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, "/");
    return if (t.len == 0) "/" else t;
}

test "runtime paths: fallback, flag precedence, lock suffix and tool validation" {
    const a = std.testing.allocator;
    const p = try socketPath(a, "venom-echo", .{ .uid = 123 });
    defer a.free(p);
    try std.testing.expectEqualStrings("/tmp/venom-123/venom-echo.sock", p);
    const override = try socketPath(a, "venom", .{ .uid = 123, .socket = "/a/custom" });
    defer a.free(override);
    const lock = try lockPath(a, override);
    defer a.free(lock);
    try std.testing.expectEqualStrings("/a/custom.lock", lock);
    const suffixed = try lockPath(a, p);
    defer a.free(suffixed);
    try std.testing.expectEqualStrings("/tmp/venom-123/venom-echo.lock", suffixed);
    const status = try siblingPath(a, p, "status.json");
    defer a.free(status);
    try std.testing.expectEqualStrings("/tmp/venom-123/venom-echo.status.json", status);
    try std.testing.expectError(error.InvalidTool, socketPath(a, "../bad", .{ .uid = 0 }));
}

test "runtime paths honor tool env, XDG, TMPDIR and empty runtime fallback" {
    const a = std.testing.allocator;
    const cases = .{
        .{ &[_:null]?[*:0]const u8{ "VENOM_ECHO_SOCKET=/override.sock", "XDG_RUNTIME_DIR=/run/u" }, "/override.sock" },
        .{ &[_:null]?[*:0]const u8{"XDG_RUNTIME_DIR=/run/u"}, "/run/u/venom/venom-echo.sock" },
        .{ &[_:null]?[*:0]const u8{ "XDG_RUNTIME_DIR=", "TMPDIR=/custom-tmp" }, "/custom-tmp/venom-42/venom-echo.sock" },
        .{ &[_:null]?[*:0]const u8{"TMPDIR="}, "/tmp/venom-42/venom-echo.sock" },
    };
    inline for (cases) |case| {
        const environ: std.process.Environ = .{ .block = .{ .slice = case[0] } };
        const p = try socketPath(a, "venom-echo", .{ .environ = environ, .uid = 42 });
        defer a.free(p);
        try std.testing.expectEqualStrings(case[1], p);
        const flag = try socketPath(a, "venom-echo", .{ .socket = "/flag.sock", .environ = environ, .uid = 42 });
        defer a.free(flag);
        try std.testing.expectEqualStrings("/flag.sock", flag);
    }
}

test "xdg: env bases win, HOME fallbacks otherwise" {
    const a = std.testing.allocator;
    const set: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "HOME=/home/u", "XDG_CONFIG_HOME=/cfg/", "XDG_DATA_HOME=/data", "XDG_STATE_HOME=/st", "XDG_CACHE_HOME=/c", "XDG_RUNTIME_DIR=/run/u" } } };
    const unset: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"HOME=/home/u/"} } };
    const cases = .{
        .{ Kind.config, "/cfg/venom/venom-echo", "/home/u/.config/venom/venom-echo" },
        .{ Kind.data, "/data/venom/venom-echo", "/home/u/.local/share/venom/venom-echo" },
        .{ Kind.state, "/st/venom/venom-echo", "/home/u/.local/state/venom/venom-echo" },
        .{ Kind.cache, "/c/venom/venom-echo", "/home/u/.cache/venom/venom-echo" },
        .{ Kind.runtime, "/run/u/venom", "/tmp/venom-7" },
    };
    inline for (cases) |case| {
        const with = try venomDir(a, case[0], "venom-echo", .{ .environ = set, .uid = 7 });
        defer a.free(with);
        try std.testing.expectEqualStrings(case[1], with);
        const without = try venomDir(a, case[0], "venom-echo", .{ .environ = unset, .uid = 7 });
        defer a.free(without);
        try std.testing.expectEqualStrings(case[2], without);
    }
    const shared = try venomDir(a, .config, null, .{ .environ = set, .uid = 7 });
    defer a.free(shared);
    try std.testing.expectEqualStrings("/cfg/venom", shared);
}

test "xdg: empty or relative variables are ignored; home override and errors" {
    const a = std.testing.allocator;
    const rel: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "HOME=/h", "XDG_STATE_HOME=relative/dir", "XDG_CONFIG_HOME=" } } };
    const st = try venomDir(a, .state, "venom", .{ .environ = rel, .uid = 0 });
    defer a.free(st);
    try std.testing.expectEqualStrings("/h/.local/state/venom/venom", st);
    const cfg = try base(a, .config, .{ .environ = rel, .home = "/pw", .uid = 0 });
    defer a.free(cfg);
    try std.testing.expectEqualStrings("/pw/.config", cfg);
    const relhome: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"HOME=rel"} } };
    try std.testing.expectError(error.NoHome, base(a, .data, .{ .uid = 0 }));
    try std.testing.expectError(error.NoHome, base(a, .data, .{ .environ = relhome, .uid = 0 }));
    try std.testing.expectError(error.InvalidTool, venomDir(a, .data, "Bad", .{ .home = "/h", .uid = 0 }));
}

test "xdg: file paths inside venom dirs" {
    const a = std.testing.allocator;
    const e: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "HOME=/h", "XDG_RUNTIME_DIR=/run/u" } } };
    const log = try path(a, .state, "venom-echo", "venom-echo.log", .{ .environ = e, .uid = 0 });
    defer a.free(log);
    try std.testing.expectEqualStrings("/h/.local/state/venom/venom-echo/venom-echo.log", log);
    const status = try path(a, .runtime, "venom-echo", "status.json", .{ .environ = e, .uid = 0 });
    defer a.free(status);
    try std.testing.expectEqualStrings("/run/u/venom/venom-echo.status.json", status);
    inline for (.{ "", ".", "..", "a/b" }) |bad|
        try std.testing.expectError(error.InvalidName, path(a, .state, "venom", bad, .{ .environ = e, .uid = 0 }));
}
