//! The generated `<tool> mcp` stdio adapter. It speaks
//! MCP (revision 2025-06-18, newline-delimited JSON-RPC 2.0) on stdin/stdout
//! and forwards each `tools/call` to the daemon as an ordinary proto client,
//! so daemon-side validation and grant checks apply exactly as for the CLI.
//! The tool catalog is derived from the same normalized verb model as the CLI
//! and is fixed for the adapter's lifetime. Diagnostics go to stderr only.
const std = @import("std");
const proto = @import("proto");
const runtime = @import("runtime.zig");
const s = proto.schema;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const c = std.c;

pub const protocol_version = "2025-06-18";
/// Hard per-call limits for buffered streams: MCP returns one result per call.
pub const max_stream_items = 1024;
pub const max_stream_bytes = 1024 * 1024;
/// Longest accepted JSON-RPC line; longer lines get a parse error.
pub const max_line = 4 * 1024 * 1024;
const stream_note = " Streaming: items are buffered to completion, at most 1024 items and 1 MiB of compact item JSON per call; larger streams fail with unsupported.stream_limit.";

/// Local bootstrap verbs dispatch in-process and are never MCP tools.
pub fn local(comptime name: []const u8) bool {
    return @import("shared.zig").isLocal(name);
}

/// Reversible MCP tool name: each `_` becomes `__`, each `.` becomes `_d`.
pub fn toolName(comptime wire: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        const len = wire.len + std.mem.count(u8, wire, "_") + std.mem.count(u8, wire, ".");
        if (len > 128) @compileError("cli: MCP tool name exceeds 128 bytes: " ++ wire);
        var out: [len]u8 = undefined;
        var i: usize = 0;
        for (wire) |ch| {
            out[i] = if (ch == '.' or ch == '_') '_' else ch;
            if (ch == '.' or ch == '_') {
                i += 1;
                out[i] = if (ch == '.') 'd' else '_';
            }
            i += 1;
        }
        break :blk std.fmt.comptimePrint("{s}", .{out});
    };
}

pub const Options = struct {
    /// Read end of the MCP transport (stdin for `<tool> mcp`).
    input: c.fd_t = 0,
    output: *std.Io.Writer,
    path: proto.SocketOptions = .{},
    version: []const u8 = "0.0.0",
    interrupted: ?*const std.atomic.Value(bool) = null,
};

/// Run the adapter until stdin closes or `interrupted` is set.
pub fn serve(comptime G: type, gpa: Allocator, options: Options) !void {
    var adapter: Adapter(G) = try .init(gpa, options);
    defer adapter.deinit();
    try adapter.run();
}

// ---------------------------------------------------------------- catalog

/// The `tools/list` result, built from the verb model. Allocated in `a`.
pub fn catalog(comptime G: type, a: Allocator) !Value {
    var tools = std.json.Array.init(a);
    inline for (&G.verbs) |*v| if (comptime !G.isLocal(v.name)) {
        var tool: Value = .{ .object = .empty };
        try tool.object.put(a, "name", .{ .string = comptime toolName(v.name) });
        try tool.object.put(a, "description", .{ .string = if (v.streams) v.summary ++ stream_note else v.summary });
        try tool.object.put(a, "inputSchema", try objectSchema(a, v.params));
        try tool.object.put(a, "outputSchema", try outputSchema(a, v));
        try tools.append(tool);
    };
    var result: Value = .{ .object = .empty };
    try result.object.put(a, "tools", .{ .array = tools });
    return result;
}

fn outputSchema(a: Allocator, v: *const s.Verb) !Value {
    var properties: Value = .{ .object = .empty };
    var required = std.json.Array.init(a);
    if (v.item) |item| {
        var items: Value = .{ .object = .empty };
        try items.object.put(a, "type", .{ .string = "array" });
        try items.object.put(a, "items", try typeSchema(a, item));
        try properties.object.put(a, "items", items);
        try required.append(.{ .string = "items" });
    }
    try properties.object.put(a, "result", try typeSchema(a, v.result));
    try required.append(.{ .string = "result" });
    return closedObject(a, properties, required);
}

fn closedObject(a: Allocator, properties: Value, required: std.json.Array) !Value {
    var out: Value = .{ .object = .empty };
    try out.object.put(a, "type", .{ .string = "object" });
    try out.object.put(a, "properties", properties);
    try out.object.put(a, "required", .{ .array = required });
    try out.object.put(a, "additionalProperties", .{ .bool = false });
    return out;
}

fn objectSchema(a: Allocator, fields: []const s.Field) error{OutOfMemory}!Value {
    var properties: Value = .{ .object = .empty };
    var required = std.json.Array.init(a);
    for (fields) |f| {
        var property = try typeSchema(a, f.type);
        try property.object.put(a, "description", .{ .string = f.summary });
        if (f.default) |d| try property.object.put(a, "default", std.json.parseFromSliceLeaky(Value, a, d, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The generator validated every default as JSON of its type.
            else => unreachable,
        });
        try properties.object.put(a, f.name, property);
        if (f.required) try required.append(.{ .string = f.name });
    }
    return closedObject(a, properties, required);
}

/// JSON Schema for a verb-schema type descriptor.
pub fn typeSchema(a: Allocator, t: s.Type) error{OutOfMemory}!Value {
    if (t.nullable) {
        var base = t;
        base.nullable = false;
        var choices = std.json.Array.init(a);
        try choices.append(try typeSchema(a, base));
        try choices.append(try typeSchema(a, .{ .kind = .null }));
        var wrapped: Value = .{ .object = .empty };
        try wrapped.object.put(a, "anyOf", .{ .array = choices });
        return wrapped;
    }
    if (t.kind == .object) return objectSchema(a, t.fields orelse &.{});
    var out: Value = .{ .object = .empty };
    try out.object.put(a, "type", .{ .string = @tagName(t.kind) });
    if (t.choices) |choices| {
        var values = std.json.Array.init(a);
        for (choices) |choice| try values.append(.{ .string = choice });
        try out.object.put(a, "enum", .{ .array = values });
    }
    if (t.min) |min| try out.object.put(a, "minimum", number(min));
    if (t.max) |max| try out.object.put(a, "maximum", number(max));
    if (t.items) |items| try out.object.put(a, "items", try typeSchema(a, items.*));
    return out;
}

fn number(x: f64) Value {
    if (@floor(x) == x and @abs(x) <= @as(f64, @floatFromInt(s.max_safe_integer))) return .{ .integer = @intFromFloat(x) };
    return .{ .float = x };
}

// ---------------------------------------------------------------- transport

/// Newline-delimited input over a pollable fd, with a bounded line length.
const Input = struct {
    fd: c.fd_t,
    buf: std.ArrayList(u8) = .empty,
    eof: bool = false,
    /// Discarding the rest of an over-long line.
    skipping: bool = false,

    const Next = union(enum) { line: []u8, overflow };

    fn deinit(self: *Input, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }

    /// Wait at most timeout_ms and read what is available.
    fn fill(self: *Input, gpa: Allocator, timeout_ms: i32) !void {
        if (self.eof) return;
        var fds = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&fds, 1, timeout_ms) <= 0) return; // timeout or EINTR
        if (fds[0].revents == 0) return;
        var chunk: [64 * 1024]u8 = undefined;
        const n = c.read(self.fd, &chunk, chunk.len);
        if (n < 0) switch (c.errno(n)) {
            .INTR, .AGAIN => return,
            else => {
                self.eof = true;
                return;
            },
        };
        if (n == 0) {
            self.eof = true;
            return;
        }
        try self.buf.appendSlice(gpa, chunk[0..@intCast(n)]);
    }

    /// The next complete line (owned by gpa). At EOF a trailing unterminated
    /// line counts as complete.
    fn next(self: *Input, gpa: Allocator) !?Next {
        while (true) {
            const newline = std.mem.indexOfScalar(u8, self.buf.items, '\n');
            if (self.skipping) {
                const end = newline orelse {
                    self.buf.clearRetainingCapacity();
                    return null;
                };
                self.consume(end + 1);
                self.skipping = false;
                continue;
            }
            const end = newline orelse {
                if (self.buf.items.len > max_line) {
                    self.buf.clearRetainingCapacity();
                    self.skipping = true;
                    return .overflow;
                }
                if (!self.eof or self.buf.items.len == 0) return null;
                const line = try self.buf.toOwnedSlice(gpa);
                return .{ .line = line };
            };
            if (end > max_line) {
                self.consume(end + 1);
                return .overflow;
            }
            const line = try gpa.dupe(u8, self.buf.items[0..end]);
            self.consume(end + 1);
            return .{ .line = line };
        }
    }

    fn consume(self: *Input, n: usize) void {
        const rest = self.buf.items.len - n;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[n..]);
        self.buf.items.len = rest;
    }
};

const Content = struct { type: []const u8 = "text", text: []const u8 };
const Failure = struct { code: []const u8, message: []const u8, data: ?Value = null };
const Outcome = union(enum) { cancelled, failure: Failure, success: Value };

fn Adapter(comptime G: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        options: Options,
        input: Input,
        /// Lines that arrived while a call was in flight, in order.
        pending: std.ArrayList([]u8) = .empty,
        catalog_arena: std.heap.ArenaAllocator,
        tools: Value,

        fn init(gpa: Allocator, options: Options) !Self {
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const tools = try catalog(G, arena.allocator());
            return .{ .gpa = gpa, .options = options, .input = .{ .fd = options.input }, .catalog_arena = arena, .tools = tools };
        }

        fn deinit(self: *Self) void {
            for (self.pending.items) |line| self.gpa.free(line);
            self.pending.deinit(self.gpa);
            self.input.deinit(self.gpa);
            self.catalog_arena.deinit();
        }

        fn interrupted(self: *Self) bool {
            return if (self.options.interrupted) |flag| flag.load(.monotonic) else false;
        }

        fn run(self: *Self) !void {
            while (!self.interrupted()) {
                if (self.pending.items.len > 0) {
                    const line = self.pending.orderedRemove(0);
                    defer self.gpa.free(line);
                    try self.handle(line);
                    continue;
                }
                if (try self.input.next(self.gpa)) |next| switch (next) {
                    .overflow => try self.rpcError(self.gpa, .null, -32700, "message too large"),
                    .line => |line| {
                        defer self.gpa.free(line);
                        try self.handle(line);
                    },
                } else if (self.input.eof) return else try self.input.fill(self.gpa, 100);
            }
        }

        fn handle(self: *Self, line: []const u8) !void {
            if (std.mem.trim(u8, line, " \t\r").len == 0) return;
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            const message = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.rpcError(a, .null, -32700, "parse error"),
            };
            if (message != .object) return self.rpcError(a, .null, -32600, "invalid request");
            const object = message.object;
            const raw_id = object.get("id");
            const id: Value = if (raw_id) |v| switch (v) {
                .integer, .string => v,
                else => return self.rpcError(a, .null, -32600, "invalid request id"),
            } else .null;
            const version = object.get("jsonrpc");
            if (version == null or version.? != .string or !std.mem.eql(u8, version.?.string, "2.0")) return self.rpcError(a, id, -32600, "jsonrpc must be \"2.0\"");
            const method = object.get("method") orelse return; // a response to us; we send no requests
            if (method != .string) return self.rpcError(a, id, -32600, "method must be a string");
            // Notifications (initialized, cancelled outside a call) need no reply.
            if (raw_id == null) return;
            const params = object.get("params");
            if (params) |p| if (p != .object) return self.rpcError(a, id, -32602, "params must be an object");
            const name = method.string;
            if (std.mem.eql(u8, name, "initialize")) return self.reply(a, id, .{
                .protocolVersion = protocol_version,
                .capabilities = .{ .tools = .{ .listChanged = false } },
                .serverInfo = .{ .name = G.schema.tool, .version = self.options.version },
                .instructions = G.schema.summary,
            });
            if (std.mem.eql(u8, name, "ping")) return self.reply(a, id, struct {}{});
            if (std.mem.eql(u8, name, "tools/list")) return self.reply(a, id, self.tools);
            if (std.mem.eql(u8, name, "tools/call")) return self.call(a, id, params);
            return self.rpcError(a, id, -32601, "method not found");
        }

        fn call(self: *Self, a: Allocator, id: Value, params: ?Value) !void {
            const p = params orelse return self.rpcError(a, id, -32602, "missing params");
            const name = p.object.get("name") orelse return self.rpcError(a, id, -32602, "missing tool name");
            if (name != .string) return self.rpcError(a, id, -32602, "tool name must be a string");
            const verb = find(name.string) orelse return self.rpcError(a, id, -32602, "unknown tool");
            var args: Value = p.object.get("arguments") orelse .{ .object = .empty };
            if (args == .null) args = .{ .object = .empty };
            if (args != .object) return self.rpcError(a, id, -32602, "arguments must be an object");
            // JSON Schema defaults are annotations: the adapter inserts them.
            if (try s.validateParams(a, verb.params, &args)) |f| {
                var data: Value = .{ .object = .empty };
                try data.object.put(a, "param", .{ .string = f.path });
                return self.toolError(a, id, .{ .code = f.code(), .message = "parameter validation failed", .data = data });
            }
            switch (try self.dispatch(a, id, verb, args)) {
                // MCP: no response for a cancelled request.
                .cancelled => {},
                .failure => |f| try self.toolError(a, id, f),
                .success => |structured| {
                    const text = try std.json.Stringify.valueAlloc(a, structured, .{});
                    try self.reply(a, id, .{ .content = &[_]Content{.{ .text = text }}, .structuredContent = structured, .isError = false });
                },
            }
        }

        fn find(name: []const u8) ?*const s.Verb {
            inline for (&G.verbs) |*v| if (comptime !G.isLocal(v.name)) {
                if (std.mem.eql(u8, name, comptime toolName(v.name))) return v;
            };
            return null;
        }

        fn dispatch(self: *Self, a: Allocator, id: Value, verb: *const s.Verb, args: Value) !Outcome {
            var client = proto.Client.init(self.gpa, .{
                .tool = G.schema.tool,
                .path = self.options.path,
                .hello = .{ .identity = .{ .name = G.schema.tool, .version = self.options.version }, .caps = &.{"cancel"} },
            }) catch |err| return self.transport(a, err);
            defer client.deinit();
            while (!(client.pollHello(50) catch |err| {
                if (err == error.DeniedToken) {
                    var data: Value = .{ .object = .empty };
                    try data.object.put(a, "reason", .{ .string = @tagName(client.token_failure orelse .invalid) });
                    return .{ .failure = .{ .code = "denied.token", .message = "token authentication failed", .data = data } };
                }
                return self.transport(a, err);
            })) {
                if (try self.service(id)) return .cancelled;
            }
            if (verb.streams and !client.connection.hasCap("cancel")) return .{ .failure = .{ .code = "unsupported.capability", .message = "daemon did not negotiate cancel, which streaming tools require" } };
            client.request(@as(i64, 2), verb.name, args) catch |err| return self.transport(a, err);
            var items = std.json.Array.init(a);
            var item_bytes: usize = 0;
            while (true) {
                if (try self.service(id)) {
                    cancelUpstream(&client);
                    return .cancelled;
                }
                const msg = (client.receive(50) catch |err| return self.transport(a, err)) orelse continue;
                if (msg != .ndjson) return self.transport(a, error.InvalidResponse);
                // Parsed values live in the per-message arena `a`.
                const response = proto.Response.parse(a, msg.ndjson) catch |err| return self.transport(a, err);
                if (response.id) |rid| {
                    if (rid.eql(.{ .integer = 3 })) continue;
                    if (!rid.eql(.{ .integer = 2 })) return self.transport(a, error.InvalidResponse);
                } else if (response.body != .@"error") return self.transport(a, error.InvalidResponse);
                switch (response.body) {
                    .@"error" => |e| return .{ .failure = .{ .code = e.code, .message = e.message, .data = e.data } },
                    .item => |raw| {
                        const t = verb.item orelse return self.transport(a, error.InvalidResponse);
                        var value = raw;
                        const bad_item = if (std.mem.eql(u8, verb.name, "events"))
                            (try proto.events.validateItem(a, t, value)) != null
                        else
                            try invalid(a, t, &value);
                        if (bad_item) return invalidResult();
                        item_bytes += (try std.json.Stringify.valueAlloc(a, value, .{})).len;
                        try items.append(value);
                        if (items.items.len > max_stream_items or item_bytes > max_stream_bytes) {
                            cancelUpstream(&client);
                            return .{ .failure = .{ .code = "unsupported.stream_limit", .message = "stream exceeded 1024 items or 1 MiB; use the CLI's --json streaming instead" } };
                        }
                    },
                    .ok => |raw| {
                        var value = raw;
                        if (try invalid(a, verb.result, &value)) return invalidResult();
                        var structured: Value = .{ .object = .empty };
                        if (verb.streams) try structured.object.put(a, "items", .{ .array = items });
                        try structured.object.put(a, "result", value);
                        return .{ .success = structured };
                    },
                }
            }
        }

        /// Read stdin while a call is in flight. True when the caller cancelled
        /// this request or we were interrupted; everything else is queued.
        fn service(self: *Self, id: Value) !bool {
            if (self.interrupted()) return true;
            // The cancellation may already be queued behind this request.
            for (self.pending.items, 0..) |line, i| if (cancels(self.gpa, line, id)) {
                self.gpa.free(self.pending.orderedRemove(i));
                return true;
            };
            try self.input.fill(self.gpa, 0);
            while (try self.input.next(self.gpa)) |next| switch (next) {
                // A NUL line fails to parse, so the queue answers it with -32700.
                .overflow => try self.pending.append(self.gpa, try self.gpa.dupe(u8, "\x00")),
                .line => |line| {
                    if (cancels(self.gpa, line, id)) {
                        self.gpa.free(line);
                        return true;
                    }
                    try self.pending.append(self.gpa, line);
                },
            };
            // EOF is not a cancellation: finish and answer the call, then exit.
            return false;
        }

        fn reply(self: *Self, a: Allocator, id: Value, result: anytype) !void {
            try runtime.line(a, self.options.output, .{ .jsonrpc = "2.0", .id = id, .result = result });
        }

        fn rpcError(self: *Self, a: Allocator, id: Value, code: i64, message: []const u8) !void {
            try runtime.line(a, self.options.output, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
        }

        fn transport(self: *Self, a: Allocator, err: anyerror) !Outcome {
            const data = try runtime.transportData(a, G.schema.tool, self.options.path, err);
            return .{ .failure = .{ .code = runtime.transportCode(err), .message = runtime.transportMessage(err), .data = data } };
        }

        /// Execution failures are tool results, not JSON-RPC errors. The Venom
        /// error wrapper is preserved verbatim; structuredContent is omitted.
        fn toolError(self: *Self, a: Allocator, id: Value, f: Failure) !void {
            const text = try std.json.Stringify.valueAlloc(a, .{ .@"error" = f }, .{ .emit_null_optional_fields = false });
            try self.reply(a, id, .{ .content = &[_]Content{.{ .text = text }}, .isError = true });
        }
    };
}

fn invalid(a: Allocator, t: s.Type, value: *Value) !bool {
    var path: s.Path = .{ .gpa = a };
    return try s.validateValue(a, t, value, &path, false) != null;
}

fn invalidResult() Outcome {
    return .{ .failure = .{ .code = "internal.result", .message = "daemon result does not match schema" } };
}

/// Is `line` a `notifications/cancelled` for request `id`?
fn cancels(gpa: Allocator, line: []const u8, id: Value) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const message = std.json.parseFromSliceLeaky(Value, arena.allocator(), line, .{}) catch return false;
    if (message != .object) return false;
    const method = message.object.get("method") orelse return false;
    if (method != .string or !std.mem.eql(u8, method.string, "notifications/cancelled")) return false;
    const params = message.object.get("params") orelse return false;
    if (params != .object) return false;
    const request = params.object.get("requestId") orelse return false;
    return switch (request) {
        .integer => |n| id == .integer and id.integer == n,
        .string => |text| id == .string and std.mem.eql(u8, id.string, text),
        else => false,
    };
}

/// Best effort: ask the daemon to cancel request 2 and wait briefly for it to
/// finish. The connection closes afterwards either way.
fn cancelUpstream(client: *proto.Client) void {
    if (!client.connection.hasCap("cancel")) return;
    client.request(@as(i64, 3), "cancel", .{ .id = @as(i64, 2) }) catch return;
    var turns: usize = 0;
    while (turns < 20) : (turns += 1) {
        const msg = (client.receive(50) catch return) orelse continue;
        if (msg != .ndjson) return;
        var response = proto.Response.parse(client.connection.gpa, msg.ndjson) catch return;
        defer response.deinit();
        if (response.body != .item and response.id != null and response.id.?.eql(.{ .integer = 2 })) return;
    }
}
