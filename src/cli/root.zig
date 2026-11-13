//! CLI generation from a verb schema. Instantiate Generator(@import("verbs.zon"));
//! its parser/help are compiled from the same proto schema the daemon uses.
const std = @import("std");
const proto = @import("proto");
const s = proto.schema;
const Value = std.json.Value;
const cli_digest = @import("digest.zig");
pub const manifest = @import("manifest.zig");
pub const runtime = @import("runtime.zig");
pub const mcp = @import("mcp.zig");
pub const shared = @import("shared.zig");
pub const docs = @import("docs.zig");
pub const completions = @import("completions.zig");
pub const skill = @import("skill.zig");
pub const doctor = @import("doctor.zig");
pub const digest = @import("digest.zig");
pub const Bootstrap = runtime.Bootstrap;
pub const Local = runtime.Local;
pub const RunOptions = runtime.Options;

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
    param: ?[]const u8 = null,
};
pub const Invocation = struct {
    json: bool = false,
    socket: ?[]const u8 = null,
    help: bool = false,
    /// Wire name or a command group (for help).
    name: []const u8 = "",
    verb: ?*const s.Verb = null,
    params: Value = .{ .object = .empty },
    failure: ?Failure = null,
};

pub fn spelling(comptime name: []const u8) []const u8 {
    var out: [name.len]u8 = undefined;
    for (name, 0..) |ch, i| out[i] = switch (ch) {
        '.' => ' ',
        '_' => '-',
        else => ch,
    };
    return std.fmt.comptimePrint("{s}", .{out});
}
fn flagName(comptime name: []const u8) []const u8 {
    var out: [name.len]u8 = undefined;
    for (name, 0..) |ch, i| out[i] = if (ch == '_') '-' else ch;
    return std.fmt.comptimePrint("{s}", .{out});
}

const ping: s.Verb = .{ .name = "ping", .summary = "Check daemon connectivity", .result = .{ .kind = .object, .fields = &.{} }, .grant = .none };

/// Product manifests cannot override local bootstrap, protocol or shared
/// names. The standard bundle (`skill`, `skill.install`, `doctor`) and the
/// grant verbs merge into `schema`; bind the former with
/// `Standard(G)`. Local verbs (`serve`, `mcp`, `completions`, `docs`) run
/// in-process and are never sent to the daemon or listed as MCP tools.
pub fn Generator(comptime input: anytype) type {
    return FromModel(manifest.normalize(input), manifest.examples(input));
}
/// Generate from a normalized model after merging optional shared bundles
/// (e.g. `cfg.merge`). This keeps library-only fixtures independent of
/// product runtime handlers. Its docs and skill have no examples.
pub fn FromSchema(comptime input: s.Schema) type {
    return FromModel(input, &.{});
}
/// `FromSchema` with manifest examples (`manifest.examples(input)`).
pub fn FromModel(comptime input: s.Schema, comptime manifest_examples: []const manifest.Example) type {
    return WithBootstrap(input, manifest_examples, .{});
}

/// Compiled bootstrap extension, separate from the closed format-1 manifest.
/// `serve_params` uses manifest parameter records (including native defaults).
/// `startup` is an optional shared.StartupPolicy keyed to a product verb.
/// `local` holds product-local commands, served by Local.init at run time.
pub fn WithBootstrap(comptime input: s.Schema, comptime manifest_examples: []const manifest.Example, comptime extension: anytype) type {
    @setEvalBranchQuota(2_000_000);
    for (@typeInfo(@TypeOf(extension)).@"struct".field_names) |name| {
        if (!std.mem.eql(u8, name, "serve_params") and !std.mem.eql(u8, name, "startup") and !std.mem.eql(u8, name, "local")) @compileError("cli: unknown bootstrap extension member '" ++ name ++ "'");
    }
    const policy: ?shared.StartupPolicy = if (@hasField(@TypeOf(extension), "startup")) .{ .verb = extension.startup.verb, .summary = extension.startup.summary } else null;
    const model = proto.grant_verbs.merge(shared.merge(shared.withPolicy(input, policy)));
    const records = if (@hasField(@TypeOf(extension), "local")) extension.local else .{};
    const product = manifest.normalizeLocal(.{ .format = 1, .tool = input.tool, .summary = input.summary, .verbs = records });
    for (product.verbs) |v| {
        if (shared.reserved(v.name) or std.mem.eql(u8, v.name, "ping") or std.mem.startsWith(u8, v.name, "ping.")) @compileError("cli: reserved local command name");
        for (model.verbs ++ shared.local) |remote| {
            if (pathCollision(v.name, remote.name)) @compileError("cli: local command collides with verb '" ++ remote.name ++ "'");
        }
        for (product.verbs) |other| {
            if (!std.mem.eql(u8, v.name, other.name) and pathCollision(v.name, other.name)) @compileError("cli: local command path collision");
        }
    }
    const locals = manifest.normalize(.{ .format = 1, .tool = input.tool, .summary = input.summary, .verbs = .{.{
        .name = "serve",
        .summary = "Start the daemon",
        .grant = .none,
        .params = if (@hasField(@TypeOf(extension), "serve_params")) extension.serve_params else .{},
        .result = .{ .kind = .object, .fields = .{} },
    }} });
    const local = blk: {
        var out = shared.local;
        for (&out) |*v| if (std.mem.eql(u8, v.name, "serve")) {
            v.params = locals.verbs[0].params;
            if (policy != null) v.errors = &shared.startup_errors;
        };
        break :blk out ++ product.verbs[0..product.verbs.len].*;
    };
    // Shared names are reserved, so product pages cannot collide with them.
    docs.checkPageNames(&(model.verbs[0..model.verbs.len].* ++ local ++ [_]s.Verb{ping}));
    for (model.verbs ++ local) |v| {
        _ = mcp.toolName(v.name); // fails generation for names over 128 bytes
        for (v.params) |p| for ([_][]const u8{ "json", "socket", "help", "timeout" }) |global| {
            if (std.mem.eql(u8, p.name, global)) @compileError("cli: parameter collides with global flag '" ++ global ++ "'");
        };
    }
    return struct {
        pub const schema = model;
        pub const startup_policy = policy;
        /// Manifest examples, for docs and skill generation.
        pub const examples = manifest_examples ++ manifest.examples(.{ .verbs = records });
        pub const local_commands = product.verbs;
        pub fn isProductLocal(name: []const u8) bool {
            for (local_commands) |v| if (std.mem.eql(u8, v.name, name)) return true;
            return false;
        }
        pub fn isLocal(name: []const u8) bool {
            return shared.isLocal(name) or isProductLocal(name);
        }
        pub fn isInteractive(name: []const u8) bool {
            inline for (records) |record| {
                if (std.mem.eql(u8, record.name, name)) return if (@hasField(@TypeOf(record), "interactive")) record.interactive else false;
            }
            return false;
        }
        pub const verbs = blk: {
            @setEvalBranchQuota(2_000_000);
            const extra = local ++ [_]s.Verb{ping};
            var all: [model.verbs.len + extra.len]s.Verb = undefined;
            @memcpy(all[0..model.verbs.len], model.verbs);
            @memcpy(all[model.verbs.len..], &extra);
            std.mem.sort(s.Verb, &all, {}, struct {
                fn less(_: void, a: s.Verb, b: s.Verb) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.less);
            break :blk all;
        };

        /// All allocations belong to `arena`; argv omits argv[0]. Errors are
        /// values so --json survives usage failures. Only OOM is a Zig error.
        pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) !Invocation {
            @setEvalBranchQuota(200_000);
            var call: Invocation = .{};
            // Dash-leading values must use '=', so this cannot mistake a
            // valid parameter value for the global switch.
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "--")) break;
                if (std.mem.eql(u8, arg, "--json")) call.json = true;
            }
            const Raw = struct { name: []const u8, value: []const u8, equals: bool };
            var flags: std.ArrayList(Raw) = .empty;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            var path: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < argv.len) : (i += 1) {
                const arg = argv[i];
                if (std.mem.eql(u8, arg, "--")) {
                    if (i + 1 != argv.len) return bad(call, "invalid_params.usage", "positional arguments are not supported", null);
                    break;
                }
                if (std.mem.startsWith(u8, arg, "--")) {
                    const split = std.mem.indexOfScalar(u8, arg, '=');
                    const name = arg[2 .. split orelse arg.len];
                    if (seen.contains(name)) return bad(call, "invalid_params.usage", "repeated option", name);
                    try seen.put(arena, name, {});
                    if (std.mem.eql(u8, name, "json") or std.mem.eql(u8, name, "help")) {
                        if (split != null) return bad(call, "invalid_params.usage", "switch does not take a value", name);
                        if (std.mem.eql(u8, name, "help")) call.help = true;
                        continue;
                    }
                    const text = if (split) |eq| arg[eq + 1 ..] else blk: {
                        if (i + 1 == argv.len or std.mem.startsWith(u8, argv[i + 1], "-")) return bad(call, "invalid_params.usage", "option needs a value; use '=' for values starting with '-'", name);
                        i += 1;
                        break :blk argv[i];
                    };
                    if (std.mem.eql(u8, name, "socket")) {
                        call.socket = text;
                        continue;
                    }
                    try flags.append(arena, .{ .name = name, .value = text, .equals = split != null });
                    continue;
                }
                if (arg.len == 0 or arg[0] == '-') return bad(call, "invalid_params.usage", "unknown command or option", null);
                if (path.items.len > 0) try path.append(arena, ' ');
                try path.appendSlice(arena, arg);
                // Every token must select a child, not bypass an unknown group.
                var found = false;
                inline for (verbs) |v| {
                    const canonical = comptime spelling(v.name);
                    if (std.mem.eql(u8, path.items, canonical) or (std.mem.startsWith(u8, canonical, path.items) and canonical[path.items.len] == ' ')) found = true;
                    if (std.mem.eql(u8, path.items, v.name)) {
                        path.items.len = 0;
                        try path.appendSlice(arena, canonical);
                        found = true;
                    }
                }
                if (!found) return bad(call, "invalid_params.usage", "unknown command", null);
            }
            call.name = path.items;
            inline for (&verbs) |*v| if (std.mem.eql(u8, call.name, comptime spelling(v.name))) {
                call.verb = v;
                call.name = v.name;
            };
            if (call.verb == null) {
                if (flags.items.len != 0 or (!call.help and path.items.len != 0)) return bad(call, "invalid_params.usage", "select a command", null);
                call.help = true;
                return call;
            }
            for (flags.items) |f| {
                var field: ?s.Field = null;
                inline for (verbs) |v| {
                    if (std.mem.eql(u8, call.name, v.name)) inline for (v.params) |p| {
                        if (std.mem.eql(u8, f.name, comptime flagName(p.name))) field = p;
                    };
                }
                const p = field orelse return bad(call, "invalid_params.unknown", "unknown option", f.name);
                if (p.type.kind == .boolean and !f.equals) return bad(call, "invalid_params.type", "booleans require --name=true or --name=false", p.name);
                const value: Value = if (p.type.kind == .string) blk: {
                    if (!std.unicode.utf8ValidateSlice(f.value)) return bad(call, "invalid_params.type", "expected UTF-8 text", p.name);
                    break :blk .{ .string = f.value };
                } else if (p.type.kind == .integer) blk: {
                    if (!decimal(f.value)) return bad(call, "invalid_params.type", "expected a signed decimal integer", p.name);
                    const integer = std.fmt.parseInt(i64, f.value, 10) catch return bad(call, "invalid_params.range", "integer out of range", p.name);
                    break :blk .{ .integer = integer };
                } else if (commaSeparated(p.type, f.value)) blk: {
                    if (!std.unicode.utf8ValidateSlice(f.value)) return bad(call, "invalid_params.type", "expected UTF-8 text", p.name);
                    var items: std.json.Array = .init(arena);
                    var parts = std.mem.splitScalar(u8, f.value, ',');
                    while (parts.next()) |part| {
                        if (part.len == 0) return bad(call, "invalid_params.type", "empty item in a comma-separated list; use a JSON array for empty strings", p.name);
                        try items.append(.{ .string = part });
                    }
                    break :blk .{ .array = items };
                } else blk: {
                    break :blk std.json.parseFromSliceLeaky(Value, arena, f.value, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return bad(call, "invalid_params.type", "invalid option value", p.name),
                    };
                };
                try call.params.object.put(arena, p.name, value);
            }
            if (!call.help) if (try s.validateParams(arena, call.verb.?.params, &call.params)) |f| return bad(call, f.code(), "parameter validation failed", f.path);
            return call;
        }

        pub fn help(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
            @setEvalBranchQuota(200_000);
            var out: std.Io.Writer.Allocating = .init(arena);
            const w = &out.writer;
            try w.print("{s} — {s}\nUsage: {s} <command> [options]\n\n", .{ schema.tool, schema.summary, schema.tool });
            inline for (verbs) |v| {
                const canonical = comptime spelling(v.name);
                if (name.len == 0 or std.mem.eql(u8, name, v.name) or std.mem.eql(u8, name, canonical) or (std.mem.startsWith(u8, canonical, name) and canonical[name.len] == ' ')) {
                    try w.print("{s}  {s}\n  wire: {s}; grant: {s}\n", .{ canonical, v.summary, v.name, @tagName(v.grant) });
                    inline for (v.params) |p| {
                        try w.print("  --{s} <{s}>  {s}{s}", .{ comptime flagName(p.name), @tagName(p.type.kind), p.summary, if (p.required) " (required)" else "" });
                        if (p.default) |d| try w.print("; default: {s}", .{d});
                        if (p.type.comma_list) try w.writeAll("; JSON, or comma-separated: a,b");
                        if (p.type.choices) |choices| {
                            try w.writeAll("; choices:");
                            for (choices) |c| try w.print(" {s}", .{c});
                        }
                        try w.writeAll("\n");
                    }
                    if (v.streams) try w.writeAll("  Streams NDJSON items; final success summary is suppressed.\n");
                    switch (v.exit) {
                        .standard => {},
                        .result => |field| try w.print("  Success exit status: result.{s}\n", .{field}),
                    }
                    try w.writeAll("\n");
                }
            }
            try w.writeAll("Global options: --json  --socket <path>  --help\nDotted wire aliases are accepted. Values starting with '-' require '='.\nBooleans require '=true' or '=false'; arrays/objects take JSON. Flags cannot repeat.\n");
            return out.toOwnedSlice();
        }

        /// Complete-schema digest, for `hello.schema`
        /// (`proto.Server` hello options) and `Standard` options.
        pub fn digest(gpa: std.mem.Allocator) !cli_digest.Digest {
            return cli_digest.compute(@This(), gpa);
        }

        /// RunOptions fields plus a typed `.local = Local.init(&impl)` when
        /// local commands are declared. Missing/extra handler names fail builds.
        pub fn run(gpa: std.mem.Allocator, argv: []const []const u8, options: anytype) !u8 {
            return runtime.run(@This(), gpa, argv, options);
        }
    };
}

/// Handlers for the standard remote bundle. Keep at a stable address and
/// pass `bindings()` to `proto.Dispatcher.init` with the product's own.
pub fn Standard(comptime G: type) type {
    return struct {
        show: skill.Show(G) = .{},
        install: skill.Install(G) = .{},
        doctor: doctor.Doctor = .{ .tool = G.schema.tool },

        pub const Options = struct {
            /// Hand-written SKILL.md notes (Markdown, no credentials).
            notes: []const u8 = "",
            /// The daemon user's absolute `$HOME`, for default skill roots.
            home: ?[]const u8 = null,
            checks: []const doctor.Check = &.{},
            /// The digest the daemon advertises in `hello.schema`
            /// (`G.digest`); doctor compares it with `client_schema`.
            schema: ?[]const u8 = null,
        };
        pub fn init(options: Options) @This() {
            return .{
                .show = .{ .notes = options.notes },
                .install = .{ .notes = options.notes, .home = options.home },
                .doctor = .{ .tool = G.schema.tool, .checks = options.checks, .schema = options.schema },
            };
        }
        pub fn bindings(self: *@This()) [3]proto.Binding {
            return .{
                .{ .verb = "doctor", .handler = proto.VerbHandler.init(&self.doctor) },
                .{ .verb = "skill", .handler = proto.VerbHandler.init(&self.show) },
                .{ .verb = "skill.install", .handler = proto.VerbHandler.init(&self.install) },
            };
        }
    };
}

fn bad(call: Invocation, code: []const u8, message: []const u8, param: ?[]const u8) Invocation {
    var result = call;
    result.failure = .{ .code = code, .message = message, .param = param };
    return result;
}
/// Whether a flag value for `t` is a comma-separated list rather than JSON: `t`
/// opted in with `comma_list` and the value can't be meant as JSON. A leading
/// `[` stays JSON, so a malformed array fails instead of becoming odd items.
fn commaSeparated(t: s.Type, value: []const u8) bool {
    if (!t.comma_list) return false;
    return !std.mem.startsWith(u8, std.mem.trimStart(u8, value, " \t\r\n"), "[");
}

fn decimal(text: []const u8) bool {
    const digits = if (std.mem.startsWith(u8, text, "-") or std.mem.startsWith(u8, text, "+")) text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn pathCollision(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or (a.len > b.len and std.mem.startsWith(u8, a, b) and a[b.len] == '.') or (b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '.');
}

test {
    _ = @import("tests.zig");
    _ = @import("bootstrap_tests.zig");
    _ = @import("local_tests.zig");
}
