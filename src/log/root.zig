//! log: structured logging to stderr and a file in the state directory.
//!
//! A record is a level, a message and a struct of fields:
//!
//! ```zig
//! logger.info("listening", .{ .socket = path, .pid = pid });
//! ```
//!
//! Each sink renders it as human-readable text
//! (`2026-11-06T21:44:22.123Z INFO  listening socket=/run/... pid=42`) or as
//! one compact JSON object per line
//! (`{"ts":"...","level":"info","source":"venom-echo","msg":"listening","socket":"/run/...","pid":42}`).
//!
//! Levels come from `Config`, a plain struct that decodes from ZON so it can
//! sit inside a tool's config; `setConfig` applies a reloaded config at run
//! time. A logger is safe to share between threads. Records are formatted into
//! a fixed buffer (no allocation on the logging path) and appended to the file
//! with a single `write`, so concurrent writers never interleave lines.
const std = @import("std");
const c = std.c;

pub const Level = enum(u8) {
    err,
    warn,
    info,
    debug,

    /// `error`, `warn`, `info` or `debug` (also `err`/`warning`).
    pub fn parse(text: []const u8) ?Level {
        const names = .{ .{ "error", Level.err }, .{ "err", Level.err }, .{ "warn", Level.warn }, .{ "warning", Level.warn }, .{ "info", Level.info }, .{ "debug", Level.debug } };
        inline for (names) |n| if (std.ascii.eqlIgnoreCase(text, n[0])) return n[1];
        return null;
    }

    pub fn name(level: Level) []const u8 {
        return switch (level) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
        };
    }

    fn label(level: Level) []const u8 {
        return switch (level) {
            .err => "ERROR",
            .warn => "WARN ",
            .info => "INFO ",
            .debug => "DEBUG",
        };
    }

    fn enabled(level: Level, threshold: Level) bool {
        return @backingInt(level) <= @backingInt(threshold);
    }
};

pub const Format = enum(u8) { text, json };

/// The `log` section of a tool's config.
pub const Config = struct {
    /// Records less severe than this are dropped from every sink.
    level: Level = .info,
    /// Stderr is for humans, so by default it only shows problems.
    stderr_level: Level = .warn,
    stderr_format: Format = .text,
    file_format: Format = .json,
};

/// Longest rendered record; longer records are cut and end with `…`.
pub const max_record = 8192;

pub const Options = struct {
    /// Value of the `source` field, normally the tool name.
    source: []const u8,
    config: Config = .{},
    /// Human sink. Writes are serialized by the logger and flushed per record.
    stderr: ?*std.Io.Writer = null,
    /// Append-only file sink, see `openFile`. The logger closes it.
    file: ?c.fd_t = null,
    /// Wall clock in milliseconds since the epoch. Tests pin it.
    clock: *const fn () i64 = realtimeMs,
};

pub const Logger = struct {
    source: []const u8,
    stderr: ?*std.Io.Writer,
    file: ?c.fd_t,
    clock: *const fn () i64,
    level: std.atomic.Value(Level),
    stderr_level: std.atomic.Value(Level),
    stderr_format: std.atomic.Value(Format),
    file_format: std.atomic.Value(Format),
    mutex: c.pthread_mutex_t = .{},

    pub fn init(options: Options) Logger {
        return .{
            .source = options.source,
            .stderr = options.stderr,
            .file = options.file,
            .clock = options.clock,
            .level = .init(options.config.level),
            .stderr_level = .init(options.config.stderr_level),
            .stderr_format = .init(options.config.stderr_format),
            .file_format = .init(options.config.file_format),
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |fd| _ = c.close(fd);
        self.file = null;
    }

    /// Applies a reloaded config. Safe while other threads log.
    pub fn setConfig(self: *Logger, config: Config) void {
        self.level.store(config.level, .release);
        self.stderr_level.store(config.stderr_level, .release);
        self.stderr_format.store(config.stderr_format, .release);
        self.file_format.store(config.file_format, .release);
    }

    pub fn enabled(self: *const Logger, level: Level) bool {
        return level.enabled(self.level.load(.acquire));
    }

    pub fn err(self: *Logger, msg: []const u8, fields: anytype) void {
        self.log(.err, msg, fields);
    }
    pub fn warn(self: *Logger, msg: []const u8, fields: anytype) void {
        self.log(.warn, msg, fields);
    }
    pub fn info(self: *Logger, msg: []const u8, fields: anytype) void {
        self.log(.info, msg, fields);
    }
    pub fn debug(self: *Logger, msg: []const u8, fields: anytype) void {
        self.log(.debug, msg, fields);
    }

    /// Logging never fails: a sink that cannot be written is skipped.
    pub fn log(self: *Logger, level: Level, msg: []const u8, fields: anytype) void {
        if (!self.enabled(level)) return;
        const to_stderr = self.stderr != null and level.enabled(self.stderr_level.load(.acquire));
        if (!to_stderr and self.file == null) return;
        const ts = self.clock();
        var buf: [max_record]u8 = undefined;
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (to_stderr) {
            const line = render(&buf, self.stderr_format.load(.acquire), ts, level, self.source, msg, fields);
            const w = self.stderr.?;
            w.writeAll(line) catch {};
            w.flush() catch {};
        }
        if (self.file) |fd| {
            const line = render(&buf, self.file_format.load(.acquire), ts, level, self.source, msg, fields);
            writeAll(fd, line);
        }
    }
};

/// Opens (creating, mode 0600) `path` for appending without following a
/// symlink at the leaf. Missing parent directories are created with mode 0700.
pub fn openFile(gpa: std.mem.Allocator, path: []const u8) !c.fd_t {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    try makeDirs(gpa, std.fs.path.dirname(path) orelse return error.InvalidPath);
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    const fd = c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

/// `mkdir -p` with mode 0700 for components that do not exist yet.
pub fn makeDirs(gpa: std.mem.Allocator, dir: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(z);
    var i: usize = 1;
    while (i <= z.len) : (i += 1) {
        if (i != z.len and z[i] != '/') continue;
        const saved = z[i];
        z[i] = 0;
        defer z[i] = saved;
        if (c.mkdir(z[0..i :0], 0o700) != 0 and c.errno(@as(c_int, -1)) != .EXIST) return error.MakeDirFailed;
    }
}

pub fn realtimeMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn writeAll(fd: c.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return;
        }
        if (n == 0) return;
        rest = rest[@intCast(n)..];
    }
}

/// Renders one record, newline included, into `buf`. A record that does not
/// fit is cut and ends with `…\n`.
pub fn render(buf: []u8, format: Format, ts_ms: i64, level: Level, source: []const u8, msg: []const u8, fields: anytype) []const u8 {
    std.debug.assert(buf.len >= 16);
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 4]);
    const ok = switch (format) {
        .text => renderText(&w, ts_ms, level, msg, fields),
        .json => renderJson(&w, ts_ms, level, source, msg, fields),
    };
    if (ok) |_| {
        buf[w.end] = '\n';
        return buf[0 .. w.end + 1];
    } else |_| {
        const tail = "…\n";
        @memcpy(buf[w.end..][0..tail.len], tail);
        return buf[0 .. w.end + tail.len];
    }
}

fn renderText(w: *std.Io.Writer, ts_ms: i64, level: Level, msg: []const u8, fields: anytype) !void {
    try timestamp(w, ts_ms);
    try w.print(" {s} ", .{level.label()});
    try textString(w, msg, false);
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |key| {
        try w.writeAll(" " ++ key ++ "=");
        try textValue(w, @field(fields, key));
    }
}

fn renderJson(w: *std.Io.Writer, ts_ms: i64, level: Level, source: []const u8, msg: []const u8, fields: anytype) !void {
    try w.writeAll("{\"ts\":\"");
    try timestamp(w, ts_ms);
    try w.print("\",\"level\":\"{s}\",\"source\":", .{level.name()});
    try std.json.Stringify.encodeJsonString(source, .{}, w);
    try w.writeAll(",\"msg\":");
    try std.json.Stringify.encodeJsonString(msg, .{}, w);
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |key| {
        comptime for (.{ "ts", "level", "source", "msg" }) |reserved| {
            if (std.mem.eql(u8, key, reserved)) @compileError("log: field name '" ++ key ++ "' is reserved");
        };
        try w.writeAll(",");
        try std.json.Stringify.encodeJsonString(key, .{}, w);
        try w.writeAll(":");
        try jsonValue(w, @field(fields, key));
    }
    try w.writeAll("}");
}

fn timestamp(w: *std.Io.Writer, ms: i64) !void {
    const clamped: u64 = @intCast(@max(0, ms));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = clamped / 1000 };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,              @backingInt(md.month),   md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        clamped % 1000,
    });
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn textValue(w: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    if (comptime isString(T)) return textString(w, value, true);
    switch (@typeInfo(T)) {
        .optional => return if (value) |v| textValue(w, v) else w.writeAll("null"),
        .@"enum", .enum_literal => return w.writeAll(@tagName(value)),
        .error_set => return w.writeAll(@errorName(value)),
        .bool => return w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int, .float, .comptime_float => return w.print("{d}", .{value}),
        else => {
            var buf: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{any}", .{value}) catch buf[0..];
            return textString(w, s, true);
        },
    }
}

/// Field values are quoted (JSON-style escapes) when they contain spaces,
/// quotes, `=` or control bytes; the message is escaped but never quoted.
fn textString(w: *std.Io.Writer, s: []const u8, quote_if_needed: bool) !void {
    const needs = s.len == 0 or for (s) |ch| {
        if (ch <= ' ' or ch == '"' or ch == '=' or ch == '\\' or ch == 0x7f) break true;
    } else false;
    if (quote_if_needed and needs) return std.json.Stringify.encodeJsonString(s, .{}, w);
    for (s) |ch| {
        if (ch == '\n') try w.writeAll("\\n") else if (ch < ' ' or ch == 0x7f) try w.print("\\x{x:0>2}", .{ch}) else try w.writeByte(ch);
    }
}

fn jsonValue(w: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    if (comptime isString(T)) return std.json.Stringify.encodeJsonString(value, .{}, w);
    switch (@typeInfo(T)) {
        .optional => return if (value) |v| jsonValue(w, v) else w.writeAll("null"),
        .@"enum", .enum_literal => return std.json.Stringify.encodeJsonString(@tagName(value), .{}, w),
        .error_set => return std.json.Stringify.encodeJsonString(@errorName(value), .{}, w),
        .bool => return w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => return w.print("{d}", .{value}),
        .float, .comptime_float => {
            if (std.math.isFinite(@as(f64, value))) return w.print("{d}", .{value});
            return w.writeAll("null");
        },
        else => {
            var buf: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{any}", .{value}) catch buf[0..];
            return std.json.Stringify.encodeJsonString(s, .{}, w);
        },
    }
}

fn fixedClock() i64 {
    return 1_762_465_462_123; // 2025-11-06T21:44:22.123Z
}

test "log: text and json rendering" {
    var buf: [max_record]u8 = undefined;
    const text = render(&buf, .text, fixedClock(), .info, "venom-echo", "listening", .{ .socket = "/run/a b.sock", .pid = @as(u32, 42), .ok = true, .mode = .fast, .why = error.Timeout, .none = @as(?u8, null) });
    try std.testing.expectEqualStrings("2025-11-06T21:44:22.123Z INFO  listening socket=\"/run/a b.sock\" pid=42 ok=true mode=fast why=Timeout none=null\n", text);
    const json = render(&buf, .json, fixedClock(), .warn, "venom-echo", "say \"hi\"\n", .{ .n = 1.5, .s = "x" });
    try std.testing.expectEqualStrings("{\"ts\":\"2025-11-06T21:44:22.123Z\",\"level\":\"warn\",\"source\":\"venom-echo\",\"msg\":\"say \\\"hi\\\"\\n\",\"n\":1.5,\"s\":\"x\"}\n", json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\n", parsed.value.object.get("msg").?.string);
    const escaped = render(&buf, .text, 0, .err, "t", "line\nbreak", .{});
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z ERROR line\\nbreak\n", escaped);
}

test "log: oversized records are cut, not dropped" {
    var buf: [64]u8 = undefined;
    const long: [200]u8 = @splat('x');
    const line = render(&buf, .text, 0, .info, "t", &long, .{});
    try std.testing.expect(line.len <= buf.len);
    try std.testing.expect(std.mem.endsWith(u8, line, "…\n"));
}

test "log: levels filter per sink and reload at run time" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var logger = Logger.init(.{ .source = "t", .stderr = &out.writer, .clock = fixedClock, .config = .{ .level = .info, .stderr_level = .warn } });
    defer logger.deinit();
    logger.info("quiet", .{});
    logger.warn("loud", .{ .n = 1 });
    logger.debug("dropped", .{});
    try std.testing.expectEqualStrings("2025-11-06T21:44:22.123Z WARN  loud n=1\n", out.written());
    out.clearRetainingCapacity();
    logger.setConfig(.{ .level = .debug, .stderr_level = .debug, .stderr_format = .json });
    try std.testing.expect(logger.enabled(.debug));
    logger.debug("now", .{});
    try std.testing.expectEqualStrings("{\"ts\":\"2025-11-06T21:44:22.123Z\",\"level\":\"debug\",\"source\":\"t\",\"msg\":\"now\"}\n", out.written());
}

test "log: Level.parse and Config from ZON" {
    try std.testing.expectEqual(Level.err, Level.parse("ERROR").?);
    try std.testing.expectEqual(Level.warn, Level.parse("warning").?);
    try std.testing.expectEqual(@as(?Level, null), Level.parse("loud"));
    var diag: std.zon.parse.Diagnostics = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const config = try std.zon.parse.fromSlice(Config, .{ .gpa = std.testing.allocator, .arena = arena.allocator(), .source = ".{ .level = .debug, .file_format = .text }", .diagnostics = &diag });
    try std.testing.expectEqual(Config{ .level = .debug, .file_format = .text }, config);
}

test "log: file sink creates 0700 dirs and a 0600 append-only file" {
    const a = std.testing.allocator;
    var template = "/tmp/venom-log-test-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    defer {
        const cmd = std.fmt.allocPrintSentinel(a, "{s}/state/venom/t/t.log", .{dir}, 0) catch unreachable;
        defer a.free(cmd);
        _ = c.unlink(cmd);
        inline for (.{ "/state/venom/t", "/state/venom", "/state", "" }) |suffix| {
            const p = std.fmt.allocPrintSentinel(a, "{s}" ++ suffix, .{dir}, 0) catch unreachable;
            defer a.free(p);
            _ = c.rmdir(p);
        }
    }
    const path = try std.fmt.allocPrint(a, "{s}/state/venom/t/t.log", .{dir});
    defer a.free(path);
    for (0..2) |round| {
        var logger = Logger.init(.{ .source = "t", .file = try openFile(a, path), .clock = fixedClock });
        defer logger.deinit();
        logger.info("hello", .{ .round = round });
        logger.debug("dropped", .{});
    }
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    var content: [512]u8 = undefined;
    const n = c.read(fd, &content, content.len);
    try std.testing.expectEqualStrings(
        "{\"ts\":\"2025-11-06T21:44:22.123Z\",\"level\":\"info\",\"source\":\"t\",\"msg\":\"hello\",\"round\":0}\n" ++
            "{\"ts\":\"2025-11-06T21:44:22.123Z\",\"level\":\"info\",\"source\":\"t\",\"msg\":\"hello\",\"round\":1}\n",
        content[0..@intCast(n)],
    );
    if (@import("builtin").os.tag == .linux) {
        var st: std.os.linux.Statx = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.statx(c.AT.FDCWD, z, 0, .{ .MODE = true }, &st));
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, st.mode) & 0o777);
    }
    try std.testing.expectError(error.InvalidPath, openFile(a, "relative.log"));
}

test "log: concurrent writers never interleave lines" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var logger = Logger.init(.{ .source = "t", .stderr = &out.writer, .clock = fixedClock, .config = .{ .stderr_level = .info } });
    const Worker = struct {
        fn run(l: *Logger, id: usize) void {
            for (0..200) |i| l.info("tick", .{ .worker = id, .i = i });
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &logger, id });
    for (threads) |t| t.join();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) try std.testing.expect(std.mem.startsWith(u8, line, "2025-11-06T21:44:22.123Z INFO  tick worker="));
    try std.testing.expectEqual(@as(usize, 800), count);
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
