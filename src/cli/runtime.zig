const std = @import("std");
const proto = @import("proto");
const iface = @import("iface");
const cli = @import("root.zig");
const mcp = @import("mcp.zig");
const Value = std.json.Value;

/// In-process daemon bootstrap, deliberately separate from remote handlers.
/// serve returns only after clean termination. The CLI renders {} on success.
pub const Bootstrap = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        serve: *const fn (*anyopaque, proto.SocketOptions) anyerror!void,
        serve_params: ?*const fn (*anyopaque, proto.SocketOptions, Value) anyerror!void = null,
    };
    /// Parameter-aware bootstrap; params are validated and defaults inserted.
    pub fn initWithParams(impl: anytype) Bootstrap {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        const Contract = struct { serve: *const fn (*anyopaque, proto.SocketOptions, Value) anyerror!void };
        iface.assertImplements(Contract, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .serve = legacy, .serve_params = serve };
            fn legacy(_: *anyopaque, _: proto.SocketOptions) anyerror!void {
                return error.InvalidOptions;
            }
            fn serve(ptr: *anyopaque, path: proto.SocketOptions, params: Value) anyerror!void {
                return iface.cast(T, ptr).serve(path, params);
            }
        }.vt };
    }
    pub fn init(impl: anytype) Bootstrap {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        const Contract = struct { serve: *const fn (*anyopaque, proto.SocketOptions) anyerror!void };
        iface.assertImplements(Contract, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .serve = serve };
            fn serve(ptr: *anyopaque, path: proto.SocketOptions) anyerror!void {
                return iface.cast(T, ptr).serve(path);
            }
        }.vt };
    }
};
/// Cooperative product launcher. Callbacks must use bounded regular-file I/O
/// and return promptly; the runtime cannot interrupt a blocking callback.
/// prepare validates policy/authority/config and returns null to decline, or
/// a 100..60000 ms budget measured from context.started_ms. It must not launch.
/// A product parameter check the schema cannot express returns
/// `context.reject(...)`: an `invalid_params` failure (exit 2), no launch.
/// launch is called at most once; poll observes/reaps a candidate without
/// killing a winner. Neither callback may send the user's mutation or write
/// to stdout. Product owns child lifetime, bounded diagnostics and cleanup.
pub const Startup = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const Context = struct {
        allocator: std.mem.Allocator,
        call: cli.Invocation,
        path: proto.SocketOptions,
        started_ms: i64,
        deadline_ms: i64,
        interrupted: ?*const std.atomic.Value(bool),
        /// Set by reject; owned by the runtime.
        rejection: ?*?Local.Failure = null,
        /// Report a malformed input before any launch. The code
        /// must be `invalid_params` or an `invalid_params.*` code the verb
        /// declares; data may borrow allocator. Return the result from prepare.
        pub fn reject(ctx: Context, code: []const u8, message: []const u8, data: Value) error{StartupRejected} {
            if (ctx.rejection) |slot| slot.* = .{ .code = code, .message = message, .data = data };
            return error.StartupRejected;
        }
    };
    pub const Status = enum { pending, failed };
    pub const VTable = struct {
        prepare: *const fn (*anyopaque, Context) anyerror!?u32,
        launch: *const fn (*anyopaque, Context) anyerror!void,
        poll: *const fn (*anyopaque, Context) anyerror!Status,
    };
    pub fn init(impl: anytype) Startup {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .prepare = prepare, .launch = launch, .poll = poll };
            fn prepare(ptr: *anyopaque, ctx: Context) anyerror!?u32 {
                return iface.cast(T, ptr).prepare(ctx);
            }
            fn launch(ptr: *anyopaque, ctx: Context) anyerror!void {
                return iface.cast(T, ptr).launch(ctx);
            }
            fn poll(ptr: *anyopaque, ctx: Context) anyerror!Status {
                return iface.cast(T, ptr).poll(ctx);
            }
        }.vt };
    }
};
/// Product handler interface. `commands` lists the exact wire names served;
/// init preserves that list in its return type for G.run's compile-time check.
/// Returned values may borrow Context.allocator until run returns.
pub const Local = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const Context = struct {
        allocator: std.mem.Allocator,
        name: []const u8,
        params: Value,
        path: proto.SocketOptions,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        interrupted: ?*const std.atomic.Value(bool),
    };
    pub const Failure = struct { code: []const u8, message: []const u8, data: Value = .{ .object = .empty } };
    pub const Outcome = union(enum) { result: Value, failure: Failure, status: u8 };
    pub const VTable = struct { call: *const fn (*anyopaque, Context) anyerror!Outcome };
    pub fn init(impl: anytype) struct {
        pub const commands = @typeInfo(@TypeOf(impl)).pointer.child.commands;
        handler: Local,
    } {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        return .{ .handler = .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .call = call };
            fn call(ptr: *anyopaque, ctx: Context) anyerror!Outcome {
                return iface.cast(T, ptr).call(ctx);
            }
        }.vt } };
    }
};
pub const Options = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ: ?std.process.Environ = null,
    version: []const u8 = "0.0.0",
    bootstrap: ?Bootstrap = null,
    startup: ?Startup = null,
    /// Set by the embedding program's SIGINT handler. No hidden signal-handler
    /// installation or process-global state in this library.
    interrupted: ?*const std.atomic.Value(bool) = null,
    /// MCP transport input for `<tool> mcp`; stdout is its output.
    stdin: std.c.fd_t = 0,
    /// Descriptor underlying stdout, used for interactive terminal checks.
    stdout_fd: std.c.fd_t = 1,
};

/// Run the generated CLI; preserve typed local registration until it has been
/// checked against G's declarations, then erase the implementation pointer.
pub fn run(comptime G: type, gpa: std.mem.Allocator, argv: []const []const u8, options: anytype) !u8 {
    comptime {
        for (@typeInfo(@TypeOf(options)).@"struct".field_names) |name| {
            if (!@hasField(Options, name) and !std.mem.eql(u8, name, "local")) @compileError("cli: unknown run option '" ++ name ++ "'");
        }
        if (@hasField(@TypeOf(options), "local")) {
            const L = @TypeOf(options.local);
            for (G.local_commands) |v| {
                var count: usize = 0;
                for (L.commands) |name| {
                    if (std.mem.eql(u8, name, v.name)) count += 1;
                }
                if (count != 1) @compileError("cli: missing or duplicate local handler for '" ++ v.name ++ "'");
            }
            for (L.commands) |name| {
                if (!G.isProductLocal(name)) @compileError("cli: extra local handler '" ++ name ++ "'");
            }
        } else if (G.local_commands.len != 0) @compileError("cli: local handlers required");
    }
    var erased: Options = .{ .stdout = options.stdout, .stderr = options.stderr };
    inline for (@typeInfo(Options).@"struct".field_names) |name| {
        if (@hasField(@TypeOf(options), name)) @field(erased, name) = @field(options, name);
    }
    const handler: ?Local = if (@hasField(@TypeOf(options), "local")) options.local.handler else null;
    return runLocal(G, gpa, argv, erased, handler);
}

fn runLocal(comptime G: type, gpa: std.mem.Allocator, argv: []const []const u8, options: Options, local: ?Local) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const call = try G.parse(a, argv);
    if (call.failure) |f| return failure(a, options, call.json, f.code, f.message, if (f.param) |p| try dataParam(a, p) else null);
    if (call.help) {
        const text = try G.help(a, call.name);
        if (call.json) try line(a, options.stdout, .{ .help = text }) else try options.stdout.writeAll(text);
        return 0;
    }
    const path: proto.SocketOptions = .{ .socket = call.socket, .environ = options.environ };
    if (G.isProductLocal(call.name)) {
        if (G.isInteractive(call.name) and (std.c.isatty(options.stdin) != 1 or std.c.isatty(options.stdout_fd) != 1)) return failure(a, options, call.json, "unsupported.terminal", "command needs a terminal on stdin and stdout", .{ .object = .empty });
        const handler = local.?; // registration checked at compile time by G.run
        const outcome = handler.vtable.call(handler.ptr, .{ .allocator = a, .name = call.name, .params = call.params, .path = path, .stdout = options.stdout, .stderr = options.stderr, .interrupted = options.interrupted }) catch |err| {
            if (err == error.OutOfMemory or err == error.WriteFailed) return err;
            return failure(a, options, call.json, "internal.local", "local handler failed", .{ .object = .empty });
        };
        switch (outcome) {
            .status => |status| return if (status <= 11) status else try failure(a, options, call.json, "internal.local", "invalid local exit status", .{ .object = .empty }),
            .failure => |f| {
                var declared = proto.errors.knownCode(f.code) and std.mem.indexOfScalar(u8, f.code, '.') == null;
                for (call.verb.?.errors) |e| if (std.mem.eql(u8, f.code, e.code)) {
                    declared = true;
                };
                if (!declared) return failure(a, options, call.json, "internal.local", "undeclared local error code", .{ .object = .empty });
                return failure(a, options, call.json, f.code, f.message, f.data);
            },
            .result => |result| {
                var value = result;
                var result_path: proto.schema.Path = .{ .gpa = a };
                if (try proto.schema.validateValue(a, call.verb.?.result, &value, &result_path, false) != null) return failure(a, options, call.json, "internal.result", "local result does not match schema", .{ .object = .empty });
                if (call.json or value != .object or value.object.count() != 0) try line(a, options.stdout, value);
                return switch (call.verb.?.exit) {
                    .standard => 0,
                    .result => |field| @intCast(value.object.get(field).?.integer),
                };
            },
        }
    }
    if (std.mem.eql(u8, call.name, "serve")) {
        const b = options.bootstrap orelse return failure(a, options, call.json, "unsupported.bootstrap", "no daemon bootstrap registered", null);
        if (b.vtable.serve_params) |serve| {
            serve(b.ptr, path, call.params) catch |err| return transportFailure(G, a, options, call, path, err);
        } else {
            // Never silently discard a product extension in a legacy callback.
            if (call.params.object.count() != 0) return failure(a, options, call.json, "unsupported.bootstrap", "parameter-aware bootstrap required", null);
            const serve = b.vtable.serve;
            serve(b.ptr, path) catch |err| return transportFailure(G, a, options, call, path, err);
        }
        try line(a, options.stdout, struct {}{});
        return 0;
    }
    if (std.mem.eql(u8, call.name, "mcp")) {
        try mcp.serve(G, gpa, .{ .input = options.stdin, .output = options.stdout, .path = path, .version = options.version, .interrupted = options.interrupted });
        return 0;
    }
    if (std.mem.eql(u8, call.name, "completions")) {
        const shell = std.meta.stringToEnum(cli.completions.Shell, call.params.object.get("shell").?.string).?;
        var out: std.Io.Writer.Allocating = .init(a);
        try cli.completions.write(G, a, &out.writer, shell);
        return content(a, options, call.json, out.written());
    }
    if (std.mem.eql(u8, call.name, "docs")) return docs(G, a, call, options);
    return remote(G, gpa, a, call, path, options) catch |err| {
        if (err == error.WriteFailed or err == error.OutOfMemory) return err;
        return transportFailure(G, a, options, call, path, err);
    };
}

fn remote(comptime G: type, gpa: std.mem.Allocator, a: std.mem.Allocator, call: cli.Invocation, path: proto.SocketOptions, options: Options) !u8 {
    const started_ms = nowMs();
    var used_startup = false;
    var client = proto.Client.init(gpa, .{
        .tool = G.schema.tool,
        .path = path,
        .hello = .{ .identity = .{ .name = G.schema.tool, .version = options.version }, .caps = &.{"cancel"} },
    }) catch |err| blk: {
        if (err != error.NotRunning) return err;
        const policy = G.startup_policy orelse return err;
        if (!std.mem.eql(u8, call.name, policy.verb)) return err;
        const hook = options.startup orelse return err;
        used_startup = true;
        var rejection: ?Local.Failure = null;
        break :blk start(G, gpa, a, call, path, options, hook, started_ms, &rejection) catch |e| {
            if (e != error.StartupRejected) return e;
            const f = rejection orelse return failure(a, options, call.json, "internal", "startup rejection without a failure", null);
            const class = "invalid_params";
            var declared = std.mem.eql(u8, f.code, class);
            if (std.mem.startsWith(u8, f.code, class ++ ".")) for (call.verb.?.errors) |d| if (std.mem.eql(u8, f.code, d.code)) {
                declared = true;
            };
            if (!declared) return failure(a, options, call.json, "internal", "undeclared startup rejection code", null);
            return failure(a, options, call.json, f.code, f.message, f.data);
        };
    };
    defer client.deinit();
    while (!(client.pollHello(100) catch |err| {
        if (err == error.DeniedToken) {
            var data: Value = .{ .object = .empty };
            try data.object.put(a, "reason", .{ .string = @tagName(client.token_failure orelse .invalid) });
            return failure(a, options, call.json, "denied.token", "token authentication failed", data);
        }
        return err;
    })) if (interrupted(options)) return failure(a, options, call.json, "cancelled", "interrupted", null);
    // doctor gets the compiled digest unless the caller chose one.
    var params = call.params;
    if (std.mem.eql(u8, call.name, "doctor") and params.object.get("client_schema") == null) {
        const compiled = try G.digest(gpa);
        try params.object.put(a, "client_schema", .{ .string = try a.dupe(u8, &compiled) });
    }
    if (used_startup and interrupted(options)) return error.Cancelled;
    client.request(@as(i64, 2), call.name, params) catch |err| return if (used_startup) error.StartupResult else err;
    var cancelling = false;
    var cancel_deadline: i64 = 0;
    while (true) {
        if (interrupted(options) and !cancelling) {
            if (!client.connection.hasCap("cancel")) return failure(a, options, call.json, "cancelled", "interrupted", null);
            try client.request(@as(i64, 3), "cancel", .{ .id = @as(i64, 2) });
            cancelling = true;
            cancel_deadline = nowMs() + 10_000;
        }
        if (cancelling and nowMs() >= cancel_deadline) return failure(a, options, call.json, "cancelled", "interrupted", null);
        const msg = (client.receive(100) catch |err| return if (used_startup) error.StartupResult else err) orelse continue;
        if (msg != .ndjson) return error.InvalidResponse;
        var response = try proto.Response.parse(gpa, msg.ndjson);
        defer response.deinit();
        if (response.id) |id| {
            if (id.eql(.{ .integer = 3 }) and cancelling) continue;
            if (!id.eql(.{ .integer = 2 })) return error.InvalidResponse;
        } else if (response.body != .@"error") return error.InvalidResponse;
        var response_arena = std.heap.ArenaAllocator.init(gpa);
        defer response_arena.deinit();
        if (try render(response_arena.allocator(), call.verb.?, call.json, response.body, options)) |status| return status;
    }
}
// Only a missing initial connection reaches this path. Readiness uses normal
// owner authentication and ping; the caller's mutation is sent afterwards once.
fn start(comptime G: type, gpa: std.mem.Allocator, a: std.mem.Allocator, call: cli.Invocation, path: proto.SocketOptions, options: Options, hook: Startup, started_ms: i64, rejection: *?Local.Failure) !proto.Client {
    const resolved = try selectedSocket(a, G.schema.tool, path);
    _ = try proto.os.address(resolved);
    var ctx: Startup.Context = .{ .allocator = a, .call = call, .path = .{ .socket = resolved, .environ = path.environ }, .started_ms = started_ms, .deadline_ms = started_ms + 60_000, .interrupted = options.interrupted, .rejection = rejection };
    try startupCheck(ctx);
    const budget = try hook.vtable.prepare(hook.ptr, ctx) orelse return error.NotRunning;
    if (budget < 100 or budget > 60_000) return error.StartupConfig;
    ctx.deadline_ms = started_ms + budget;
    try startupCheck(ctx);
    var failed = false;
    hook.vtable.launch(hook.ptr, ctx) catch |err| {
        if (err != error.AlreadyRunning and err != error.StartupFailed) return err;
        failed = err == error.StartupFailed;
    };
    var delay: i32 = 5;
    while (true) {
        startupCheck(ctx) catch |err| return if (err == error.StartupDeadline and failed) error.StartupFailed else err;
        failed = (try hook.vtable.poll(hook.ptr, ctx)) == .failed or failed;
        startupCheck(ctx) catch |err| return if (err == error.StartupDeadline and failed) error.StartupFailed else err;
        if (proto.Client.init(gpa, .{ .tool = G.schema.tool, .path = ctx.path, .hello = .{ .identity = .{ .name = G.schema.tool, .version = options.version }, .caps = &.{"cancel"} } })) |connected| {
            var client = connected;
            client.connection.deadline_ms = ctx.deadline_ms;
            var retained = false;
            defer if (!retained) client.deinit();
            while (!(client.pollHello(try startupWait(ctx, 100)) catch |err| return if (err == error.Timeout) error.StartupDeadline else err)) try startupCheck(ctx);
            try startupCheck(ctx);
            try client.request(@as(i64, 1), "ping", struct {}{});
            while (true) {
                const msg = try client.receive(try startupWait(ctx, 100)) orelse continue;
                if (msg != .ndjson) return error.InvalidResponse;
                var response = try proto.Response.parse(gpa, msg.ndjson);
                defer response.deinit();
                if (response.id == null or !response.id.?.eql(.{ .integer = 1 })) return error.InvalidResponse;
                if (response.body != .ok or response.body.ok != .object or response.body.ok.object.count() != 0) return error.InvalidResponse;
                try startupCheck(ctx);
                retained = true;
                return client;
            }
        } else |err| if (err != error.NotRunning) return err;
        if (nowMs() >= ctx.deadline_ms) return if (failed) error.StartupFailed else error.StartupDeadline;
        // poll without descriptors is a bounded, interruptible backoff.
        var fds: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&fds, 0, try startupWait(ctx, delay));
        delay = @min(delay * 2, 100);
    }
}
/// The selected socket as an absolute path (relative selections join the cwd).
fn selectedSocket(a: std.mem.Allocator, tool: []const u8, path: proto.SocketOptions) ![]const u8 {
    const selected = try proto.os.socketPath(a, tool, path);
    if (std.fs.path.isAbsolute(selected)) return selected;
    var cwd: [4096]u8 = undefined;
    if (std.c.getcwd(&cwd, cwd.len) == null) return error.InvalidPath;
    return std.fs.path.join(a, &.{ std.mem.sliceTo(&cwd, 0), selected });
}
fn startupCheck(ctx: Startup.Context) !void {
    if (ctx.interrupted) |flag| if (flag.load(.monotonic)) return error.Cancelled;
    if (nowMs() >= ctx.deadline_ms) return error.StartupDeadline;
}
fn startupWait(ctx: Startup.Context, max_ms: i32) !i32 {
    try startupCheck(ctx);
    return @intCast(@min(max_ms, @max(0, ctx.deadline_ms - nowMs())));
}
fn interrupted(options: Options) bool {
    return if (options.interrupted) |flag| flag.load(.monotonic) else false;
}

fn content(a: std.mem.Allocator, options: Options, json: bool, text: []const u8) !u8 {
    if (json) try line(a, options.stdout, .{ .content = text }) else try options.stdout.writeAll(text);
    try options.stdout.flush();
    return 0;
}

/// Local `docs`: print one document, or write every page into a directory.
fn docs(comptime G: type, a: std.mem.Allocator, call: cli.Invocation, options: Options) !u8 {
    const man = std.mem.eql(u8, call.params.object.get("format").?.string, "man");
    const directory = if (call.params.object.get("directory")) |d| d.string else {
        var out: std.Io.Writer.Allocating = .init(a);
        if (man) try cli.docs.writeMan(G, &out.writer) else try cli.docs.writeMarkdown(G, &out.writer);
        return content(a, options, call.json, out.written());
    };
    const pages: []const cli.docs.Page = if (man) try cli.docs.manPages(G, a) else blk: {
        var out: std.Io.Writer.Allocating = .init(a);
        try cli.docs.writeMarkdown(G, &out.writer);
        break :blk &.{.{ .name = try std.fmt.allocPrint(a, "{s}.md", .{G.schema.tool}), .content = out.written() }};
    };
    const dir_z = try a.dupeSentinel(u8, directory, 0);
    const dfd = std.c.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dfd < 0) return failure(a, options, call.json, "invalid_params.directory", "directory does not exist or is not a directory", try dataParam(a, "directory"));
    defer _ = std.c.close(dfd);
    var files: std.ArrayList([]const u8) = .empty;
    for (pages) |page| {
        const path = try std.fs.path.join(a, &.{ directory, page.name });
        writeFile(dfd, try a.dupeSentinel(u8, page.name, 0), page.content) catch {
            var data: Value = .{ .object = .empty };
            try data.object.put(a, "path", .{ .string = path });
            return failure(a, options, call.json, "failed.docs_write", "could not write documentation file", data);
        };
        try files.append(a, path);
    }
    if (call.json) try line(a, options.stdout, .{ .files = files.items }) else for (files.items) |f| try options.stdout.print("{s}\n", .{f});
    try options.stdout.flush();
    return 0;
}
fn writeFile(dfd: std.c.fd_t, name: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.openat(dfd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Human rendering of the standard bundle's results:
/// `skill` prints only its content; `doctor` lists statuses and fixes.
fn human(writer: *std.Io.Writer, verb: []const u8, value: Value) !bool {
    if (std.mem.eql(u8, verb, "skill")) {
        try writer.writeAll(value.object.get("content").?.string);
        return true;
    }
    if (std.mem.eql(u8, verb, "doctor")) {
        for (value.object.get("checks").?.array.items) |check| {
            const o = check.object;
            try writer.print("[{s}] {s}: {s}\n      fix: {s}\n", .{ o.get("status").?.string, o.get("id").?.string, o.get("message").?.string, o.get("fix").?.string });
        }
        return true;
    }
    return false;
}

/// Validate even a daemon's successful payloads, including suppressed stream
/// finals, before reporting success or applying result exit passthrough.
pub fn render(a: std.mem.Allocator, verb: *const proto.schema.Verb, json: bool, body: proto.Response.Body, options: Options) !?u8 {
    switch (body) {
        .@"error" => |e| return try failure(a, options, json, e.code, e.message, e.data),
        .item, .ok => |v| {
            if (body == .item and !verb.streams) return error.InvalidResponse;
            const t = if (body == .item) verb.item.? else verb.result;
            var value = v;
            var path: proto.schema.Path = .{ .gpa = a };
            const invalid = if (body == .item and std.mem.eql(u8, verb.name, "events"))
                try proto.events.validateItem(a, t, value)
            else
                try proto.schema.validateValue(a, t, &value, &path, false);
            if (invalid != null) return try failure(a, options, json, "internal.result", "daemon result does not match schema", null);
            if (body == .item or !verb.streams) {
                if (json or !try human(options.stdout, verb.name, value)) try line(a, options.stdout, value) else try options.stdout.flush();
            }
            if (body == .item) return null;
            return switch (verb.exit) {
                .standard => 0,
                .result => |field| @intCast(value.object.get(field).?.integer),
            };
        },
    }
}

pub fn line(a: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
    defer a.free(bytes);
    try writer.writeAll(bytes);
    try writer.writeByte('\n');
    try writer.flush();
}
fn dataParam(a: std.mem.Allocator, param: []const u8) !Value {
    var value: Value = .{ .object = .empty };
    try value.object.put(a, "param", .{ .string = param });
    return value;
}
fn failure(a: std.mem.Allocator, options: Options, json: bool, code: []const u8, message: []const u8, data: ?Value) !u8 {
    if (json) try line(a, options.stdout, .{ .@"error" = .{ .code = code, .message = message, .data = data } }) else try options.stderr.print("{s}\n", .{message});
    return proto.errors.exitCode(code);
}
/// Stable error code for a client transport failure (shared with MCP).
pub fn transportCode(err: anyerror) []const u8 {
    return switch (err) {
        error.StartupConfig => "invalid_params.startup_config",
        error.StartupContext => "denied.startup_context",
        error.StartupFailed => "unavailable.startup_failed",
        error.StartupDeadline => "unavailable.startup_deadline",
        error.StartupResult => "unavailable.startup_result",
        error.Cancelled => "cancelled",
        error.DeniedToken => "denied.token",
        error.InsecurePath => "denied.insecure_path",
        error.AlreadyRunning => "conflict.already_running",
        error.NotASocket => "conflict.not_a_socket",
        error.NotRunning, error.ConnectFailed, error.WouldBlock, error.Disconnected => "unavailable.not_running",
        error.PathTooLong => "unavailable.path_too_long",
        error.InvalidPath, error.InvalidToolName => "invalid_params.socket",
        error.VersionMismatch => "protocol.version_mismatch",
        error.InvalidResponse, error.InvalidHello, error.BadFrame, error.BadPreamble => "protocol.invalid_response",
        error.TooLarge => "protocol.too_large",
        error.Timeout => "timeout",
        error.OutOfMemory => "internal",
        else => "failed",
    };
}
/// Message for a client transport failure (shared with MCP).
pub fn transportMessage(err: anyerror) []const u8 {
    return if (std.mem.eql(u8, transportCode(err), not_running)) "No daemon at the selected socket" else @errorName(err);
}
/// Data for a client transport failure (shared with MCP):
/// `unavailable.not_running` names the absolute selected socket
/// (never a token or environment); startup errors carry empty data.
pub fn transportData(a: std.mem.Allocator, tool: []const u8, path: proto.SocketOptions, err: anyerror) !?Value {
    const code = transportCode(err);
    if (std.mem.eql(u8, code, not_running)) {
        var d: Value = .{ .object = .empty };
        const socket = selectedSocket(a, tool, path) catch |e| return if (e == error.OutOfMemory) e else d;
        try d.object.put(a, "socket", .{ .string = socket });
        return d;
    }
    return if (std.mem.indexOf(u8, code, "startup_") != null) .{ .object = .empty } else null;
}
const not_running = "unavailable.not_running";
fn transportFailure(comptime G: type, a: std.mem.Allocator, options: Options, call: cli.Invocation, path: proto.SocketOptions, err: anyerror) !u8 {
    const code = transportCode(err);
    var data = try transportData(a, G.schema.tool, path, err);
    // A failed doctor connection is still a transport error, with a runnable
    // fix rather than a fabricated doctor report. A missing
    // daemon is fixed by starting it; other path errors get a diagnostic.
    if (std.mem.eql(u8, call.name, "doctor")) {
        if (data == null) data = .{ .object = .empty };
        const fix = if (std.mem.eql(u8, code, not_running))
            try std.fmt.allocPrint(a, "{s} serve", .{G.schema.tool})
        else
            "ls -ld -- \"${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}\"";
        try data.?.object.put(a, "fix", .{ .string = fix });
    }
    return failure(a, options, call.json, code, transportMessage(err), data);
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
