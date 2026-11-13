//! The complete-schema digest advertised in the protocol's
//! `hello.schema` and compared by `doctor`.
//!
//! The digest is `sha256:` plus 64 lowercase hex digits over the canonical
//! JSON of the complete normalized manifest of a generator `G`:
//!
//! - root: `format`, `tool`, `summary`, `protocol` (versioned core metadata:
//!   `{"version":1,"transport":["cancel","hello"]}`) and `verbs`;
//! - `verbs`: every verb of the generated surface (product, shared remote,
//!   shared local bootstrap and `ping`), sorted by wire name, with all
//!   verb-schema member defaults expanded (`params`, `errors`, `examples` are
//!   always arrays; `streams`, `exit`, field `required` and error `data` are
//!   always present). Shared verbs carry `bundle`:
//!   `{"name":…,"version":1,"dispatch":"local"|"remote"}`;
//! - field `default` values and example `params`/`result` are embedded as
//!   JSON values; example params have defaults inserted, like requests;
//! - type descriptors keep only members that are set (`nullable` and
//!   `comma_list` only when true); integer bounds are integers.
//!
//! Canonical JSON: object keys sorted by UTF-8 bytes, arrays in order, no
//! whitespace or trailing newline. Strings escape only `"`, `\` and C0
//! controls (as lowercase `\u00xx`). Integral numbers print as decimal
//! integers (negative zero is 0); others use the shortest round-trip digits,
//! laid out as ECMAScript `Number.prototype.toString` does, except that a
//! positive exponent has no `+` (`1e21`, `1.5e-7`, `0.000001`).
const std = @import("std");
const proto = @import("proto");
const shared = @import("shared.zig");
const s = proto.schema;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const prefix = "sha256:";
pub const len = prefix.len + 64;
pub const Digest = [len]u8;

/// Version of the shared bundles and core protocol metadata in the digest.
pub const bundle_version = 1;
pub const protocol_version = 1;

/// Digest of canonical bytes.
pub fn ofCanonical(bytes: []const u8) Digest {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    var out: Digest = undefined;
    @memcpy(out[0..prefix.len], prefix);
    _ = std.fmt.bufPrint(out[prefix.len..], "{x}", .{&hash}) catch unreachable;
    return out;
}

/// The complete-schema digest of generator `G`.
pub fn compute(comptime G: type, gpa: Allocator) !Digest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try writeCanonical(a, &out.writer, try manifest(G, a));
    return ofCanonical(out.written());
}

/// Canonical JSON of `G`'s complete normalized manifest. Caller frees.
pub fn canonical(comptime G: type, gpa: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try writeCanonical(a, &out.writer, try manifest(G, a));
    return gpa.dupe(u8, out.written());
}

/// The complete normalized manifest of `G` as a JSON value owned by `arena`.
pub fn manifest(comptime G: type, arena: Allocator) !Value {
    var verbs: std.json.Array = .init(arena);
    for (&G.verbs) |*v| {
        var value = try verbValue(arena, v, G.examples);
        if (G.isProductLocal(v.name)) {
            try value.object.put(arena, "dispatch", .{ .string = "local" });
            try value.object.put(arena, "interactive", .{ .bool = G.isInteractive(v.name) });
        }
        try verbs.append(value);
    }
    const protocol = try object(arena, &.{
        .{ "version", .{ .integer = protocol_version } },
        .{ "transport", try strings(arena, &.{ "cancel", "hello" }) },
    });
    return object(arena, &.{
        .{ "format", .{ .integer = G.schema.format } },
        .{ "tool", .{ .string = G.schema.tool } },
        .{ "summary", .{ .string = G.schema.summary } },
        .{ "protocol", protocol },
        .{ "verbs", .{ .array = verbs } },
    });
}

const config_verbs = [_][]const u8{ "config.check", "config.get", "config.reload", "config.schema", "config.set" };

/// The shared bundle a wire name belongs to, or null for product verbs.
pub fn bundle(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "ping")) return "protocol";
    for (shared.local ++ shared.remote) |v| if (std.mem.eql(u8, v.name, name)) return "agent-contract";
    if (proto.grant_verbs.find(name) != null) return "grants";
    for (config_verbs) |c| if (std.mem.eql(u8, c, name)) return "config";
    if (std.mem.eql(u8, name, "events")) return "events";
    return null;
}

fn verbValue(a: Allocator, v: *const s.Verb, examples: anytype) !Value {
    var map: std.json.ObjectMap = .empty;
    try map.put(a, "name", .{ .string = v.name });
    try map.put(a, "summary", .{ .string = v.summary });
    try map.put(a, "params", try fieldsValue(a, v.params));
    try map.put(a, "result", try typeValue(a, v.result));
    var errors: std.json.Array = .init(a);
    for (v.errors) |e| try errors.append(try object(a, &.{
        .{ "code", .{ .string = e.code } },
        .{ "summary", .{ .string = e.summary } },
        .{ "data", try typeValue(a, e.data orelse .{ .kind = .object, .fields = &.{} }) },
    }));
    try map.put(a, "errors", .{ .array = errors });
    try map.put(a, "grant", .{ .string = @tagName(v.grant) });
    try map.put(a, "streams", .{ .bool = v.streams });
    if (v.item) |item| try map.put(a, "item", try typeValue(a, item));
    try map.put(a, "exit", switch (v.exit) {
        .standard => try object(a, &.{.{ "kind", .{ .string = "standard" } }}),
        .result => |field| try object(a, &.{ .{ "kind", .{ .string = "result" } }, .{ "field", .{ .string = field } } }),
    });
    var list: std.json.Array = .init(a);
    for (examples) |e| if (std.mem.eql(u8, e.verb, v.name)) {
        var params = try parse(a, e.params);
        // Examples are stored as declared; normalization inserts defaults.
        if (try s.validateParams(a, v.params, &params) != null) return error.InvalidExample;
        try list.append(try object(a, &.{ .{ "params", params }, .{ "result", try parse(a, e.result) } }));
    };
    try map.put(a, "examples", .{ .array = list });
    if (bundle(v.name)) |name| try map.put(a, "bundle", try object(a, &.{
        .{ "name", .{ .string = name } },
        .{ "version", .{ .integer = bundle_version } },
        .{ "dispatch", .{ .string = if (shared.isLocal(v.name)) "local" else "remote" } },
    }));
    return .{ .object = map };
}

fn fieldsValue(a: Allocator, fields: []const s.Field) error{ OutOfMemory, InvalidDefault }!Value {
    var array: std.json.Array = .init(a);
    for (fields) |f| {
        var map: std.json.ObjectMap = .empty;
        try map.put(a, "name", .{ .string = f.name });
        try map.put(a, "summary", .{ .string = f.summary });
        try map.put(a, "type", try typeValue(a, f.type));
        try map.put(a, "required", .{ .bool = f.required });
        if (f.default) |text| try map.put(a, "default", parse(a, text) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidDefault);
        try array.append(.{ .object = map });
    }
    return .{ .array = array };
}

fn typeValue(a: Allocator, t: s.Type) error{ OutOfMemory, InvalidDefault }!Value {
    var map: std.json.ObjectMap = .empty;
    try map.put(a, "kind", .{ .string = @tagName(t.kind) });
    if (t.nullable) try map.put(a, "nullable", .{ .bool = true });
    if (t.choices) |choices| try map.put(a, "choices", try strings(a, choices));
    for ([_]struct { []const u8, ?f64 }{ .{ "min", t.min }, .{ "max", t.max } }) |bound| if (bound[1]) |b| {
        // `check` keeps integer bounds integral and within ±2^53.
        try map.put(a, bound[0], if (t.kind == .integer) .{ .integer = @intFromFloat(b) } else .{ .float = b });
    };
    if (t.items) |items| try map.put(a, "items", try typeValue(a, items.*));
    if (t.comma_list) try map.put(a, "comma_list", .{ .bool = true });
    if (t.fields) |fields| try map.put(a, "fields", try fieldsValue(a, fields));
    return .{ .object = map };
}

fn object(a: Allocator, members: []const struct { []const u8, Value }) !Value {
    var map: std.json.ObjectMap = .empty;
    for (members) |m| try map.put(a, m[0], m[1]);
    return .{ .object = map };
}
fn strings(a: Allocator, items: []const []const u8) !Value {
    var array: std.json.Array = .init(a);
    for (items) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}
fn parse(a: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}

/// Write `value` as canonical JSON (sorted keys, no whitespace). `scratch` holds key orderings.
pub fn writeCanonical(scratch: Allocator, w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try writeNumber(w, f),
        .number_string => |text| try writeNumber(w, std.fmt.parseFloat(f64, text) catch return error.InvalidNumber),
        .string => |text| try writeString(w, text),
        .array => |array| {
            try w.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try w.writeByte(',');
                try writeCanonical(scratch, w, item);
            }
            try w.writeByte(']');
        },
        .object => |map| {
            const keys = try scratch.dupe([]const u8, map.keys());
            defer scratch.free(keys);
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.less);
            try w.writeByte('{');
            for (keys, 0..) |key, i| {
                if (i != 0) try w.writeByte(',');
                try writeString(w, key);
                try w.writeByte(':');
                try writeCanonical(scratch, w, map.get(key).?);
            }
            try w.writeByte('}');
        },
    }
}

/// Escape only `"`, `\` and C0 controls (lowercase `\u00xx`).
pub fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch != '"' and ch != '\\' and ch >= 0x20) continue;
        try w.writeAll(text[start..i]);
        if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.print("\\{c}", .{ch});
        start = i + 1;
    }
    try w.writeAll(text[start..]);
    try w.writeByte('"');
}

/// Shortest round-trip decimal, ECMAScript layout, no exponent `+`.
pub fn writeNumber(w: *std.Io.Writer, x: f64) !void {
    if (!std.math.isFinite(x)) return error.InvalidNumber;
    if (x == 0) return w.writeAll("0");
    var buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&buf, "{e}", .{@abs(x)}) catch unreachable;
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    var digits_buf: [32]u8 = undefined;
    var k: usize = 0;
    for (sci[0..e_at]) |ch| if (ch != '.') {
        digits_buf[k] = ch;
        k += 1;
    };
    // Ryu output has no trailing zeros in the mantissa except a lone "0".
    while (k > 1 and digits_buf[k - 1] == '0') k -= 1;
    const digits = digits_buf[0..k];
    const n: i32 = (std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable) + 1;
    if (x < 0) try w.writeByte('-');
    const kk: i32 = @intCast(k);
    if (kk <= n and n <= 21) {
        try w.writeAll(digits);
        try w.splatByteAll('0', @intCast(n - kk));
    } else if (0 < n and n <= 21) {
        try w.writeAll(digits[0..@intCast(n)]);
        try w.writeByte('.');
        try w.writeAll(digits[@intCast(n)..]);
    } else if (-6 < n and n <= 0) {
        try w.writeAll("0.");
        try w.splatByteAll('0', @intCast(-n));
        try w.writeAll(digits);
    } else {
        try w.writeByte(digits[0]);
        if (k > 1) {
            try w.writeByte('.');
            try w.writeAll(digits[1..]);
        }
        try w.print("e{d}", .{n - 1});
    }
}
