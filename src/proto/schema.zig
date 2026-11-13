//! The verb model, as `proto` needs it for dispatch: verb names,
//! parameter/result/item type descriptors, streaming and grant metadata.
//! `check` validates a model; `validateParams`/`validateValue` apply it to
//! JSON. Loading a ZON manifest belongs to the `cli` generator,
//! which builds this same model; `cli.digest` computes its digest.
const std = @import("std");
const errors = @import("errors.zig");
const Value = std.json.Value;

/// Largest integer every JSON parser reads exactly (2^53 - 1).
pub const max_safe_integer: i64 = 9007199254740991;

pub const Grant = enum { none, read, write, respond, files, spawn, admin };
pub const Kind = enum { string, boolean, integer, number, null, array, object };

/// A closed type descriptor. Only the members listed for
/// a kind may be set; `check` enforces it.
pub const Type = struct {
    kind: Kind,
    /// Shared protocol records may have explicit null members (grant records).
    nullable: bool = false,
    /// string: allowed values.
    choices: ?[]const []const u8 = null,
    /// integer, number: inclusive bounds.
    min: ?f64 = null,
    max: ?f64 = null,
    /// array: element type.
    items: ?*const Type = null,
    /// array of strings, as a verb parameter: the generated CLI also takes
    /// `--name a,b`. JSON input and the wire are unaffected. Opt-in, because a
    /// comma is ordinary in other string arrays, such as a command's argv.
    comma_list: bool = false,
    /// object: members. Unknown members are rejected.
    fields: ?[]const Field = null,
};

pub const Field = struct {
    name: []const u8,
    summary: []const u8,
    type: Type,
    required: bool = false,
    /// JSON text of the default, filled in when the field is absent.
    default: ?[]const u8 = null,
};

pub const ErrorDecl = struct {
    code: []const u8,
    summary: []const u8,
    data: ?Type = null,
};

pub const Exit = union(enum) {
    standard,
    /// Name of a required top-level integer result field bounded 0–255.
    result: []const u8,
};

pub const Verb = struct {
    name: []const u8,
    summary: []const u8,
    params: []const Field = &.{},
    result: Type,
    errors: []const ErrorDecl = &.{},
    /// Required capability, enforced by Dispatcher before calling the handler.
    grant: Grant,
    streams: bool = false,
    /// Required exactly when `streams` is true.
    item: ?Type = null,
    exit: Exit = .standard,
};

pub const Schema = struct {
    format: u32 = 1,
    tool: []const u8,
    summary: []const u8,
    verbs: []const Verb,

    pub fn find(self: *const Schema, name: []const u8) ?*const Verb {
        for (self.verbs) |*verb| if (std.mem.eql(u8, verb.name, name)) return verb;
        return null;
    }
};

/// Verb names `proto` implements itself or that the protocol reserves. A schema
/// must not declare them.
pub const reserved_verbs = [_][]const u8{ "hello", "cancel", "ping", "bridge" };

/// Where `check` found a problem: the verb and, if any, the field or error.
pub const Diagnostic = struct {
    verb: []const u8 = "",
    subject: []const u8 = "",
};

/// Tool name: `^[a-z][a-z0-9-]{0,31}$`.
pub fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-')) return false;
    return true;
}

/// Verb name: `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$`.
pub fn validVerbName(name: []const u8) bool {
    return errors.validCode(name);
}

/// Validate a model's verbs and type descriptors, so the dispatcher can
/// trust it. Errors name the first problem; `diag` says where it is.
pub fn check(schema: *const Schema, diag: ?*Diagnostic) error{InvalidSchema}!void {
    var scratch: Diagnostic = .{};
    const d = diag orelse &scratch;
    d.* = .{};
    if (schema.format != 1 or !validToolName(schema.tool) or !validText(schema.summary)) return error.InvalidSchema;
    for (schema.verbs, 0..) |*verb, i| {
        d.* = .{ .verb = verb.name };
        if (!validVerbName(verb.name) or !validText(verb.summary)) return error.InvalidSchema;
        for (reserved_verbs) |r| if (std.mem.eql(u8, r, verb.name)) return error.InvalidSchema;
        for (schema.verbs[0..i]) |prev| if (std.mem.eql(u8, prev.name, verb.name)) return error.InvalidSchema;
        try checkFields(verb.params, d);
        d.subject = "result";
        try checkType(verb.result, d);
        if (verb.streams != (verb.item != null)) {
            d.subject = "item";
            return error.InvalidSchema;
        }
        if (verb.item) |item| {
            d.subject = "item";
            try checkType(item, d);
        }
        for (verb.errors, 0..) |e, j| {
            d.subject = e.code;
            if (!errors.knownCode(e.code) or std.mem.indexOfScalar(u8, e.code, '.') == null or !validText(e.summary)) return error.InvalidSchema;
            for (verb.errors[0..j]) |prev| if (std.mem.eql(u8, prev.code, e.code)) return error.InvalidSchema;
            if (e.data) |data| try checkType(data, d);
        }
        switch (verb.exit) {
            .standard => {},
            .result => |name| {
                d.subject = name;
                const fields = if (verb.result.kind == .object) verb.result.fields orelse &.{} else return error.InvalidSchema;
                const field = for (fields) |f| {
                    if (std.mem.eql(u8, f.name, name)) break f;
                } else return error.InvalidSchema;
                const t = field.type;
                if (!field.required or t.kind != .integer or (t.min orelse -1) < 0 or (t.max orelse 256) > 255) return error.InvalidSchema;
            },
        }
    }
    d.* = .{};
}

fn validText(text: []const u8) bool {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

fn checkFields(fields: []const Field, d: *Diagnostic) error{InvalidSchema}!void {
    for (fields, 0..) |field, i| {
        d.subject = field.name;
        if (!errors.validName(field.name) or !validText(field.summary)) return error.InvalidSchema;
        for (fields[0..i]) |prev| if (std.mem.eql(u8, prev.name, field.name)) return error.InvalidSchema;
        try checkType(field.type, d);
        d.subject = field.name;
        if (field.default) |text| {
            if (field.required) return error.InvalidSchema;
            // The default must itself be a valid value of the field's type.
            var buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const arena = fba.allocator();
            var value = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return error.InvalidSchema;
            var path: Path = .{ .gpa = arena };
            const failure = validateValue(arena, field.type, &value, &path, true) catch return error.InvalidSchema;
            if (failure != null) return error.InvalidSchema;
        }
    }
}

fn checkType(t: Type, d: *Diagnostic) error{InvalidSchema}!void {
    const bounded = t.kind == .integer or t.kind == .number;
    if (t.choices != null and t.kind != .string) return error.InvalidSchema;
    if ((t.min != null or t.max != null) and !bounded) return error.InvalidSchema;
    if ((t.items != null) != (t.kind == .array)) return error.InvalidSchema;
    if ((t.fields != null) != (t.kind == .object)) return error.InvalidSchema;
    if (t.comma_list and (t.kind != .array or t.items.?.kind != .string)) return error.InvalidSchema;
    if (t.choices) |choices| {
        if (choices.len == 0) return error.InvalidSchema;
        for (choices, 0..) |choice, i| {
            if (!std.unicode.utf8ValidateSlice(choice)) return error.InvalidSchema;
            for (choices[0..i]) |prev| if (std.mem.eql(u8, prev, choice)) return error.InvalidSchema;
        }
    }
    for ([_]?f64{ t.min, t.max }) |bound| if (bound) |b| {
        if (!std.math.isFinite(b)) return error.InvalidSchema;
        if (t.kind == .integer and (b != @trunc(b) or @abs(b) > @as(f64, @floatFromInt(max_safe_integer)))) return error.InvalidSchema;
    };
    if (t.min != null and t.max != null and t.min.? > t.max.?) return error.InvalidSchema;
    if (t.items) |items| try checkType(items.*, d);
    if (t.fields) |fields| try checkFields(fields, d);
}

/// A dotted parameter path (`a.0.b`), built while validating.
pub const Path = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn push(self: *Path, part: []const u8) !usize {
        const mark = self.bytes.items.len;
        if (mark > 0) try self.bytes.append(self.gpa, '.');
        try self.bytes.appendSlice(self.gpa, part);
        return mark;
    }
    fn pushIndex(self: *Path, index: usize) !usize {
        var buf: [20]u8 = undefined;
        return self.push(std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable);
    }
    fn pop(self: *Path, mark: usize) void {
        self.bytes.items.len = mark;
    }
};

/// Why a value failed validation. `detail` completes `invalid_params.<detail>`
/// (or is reported as `internal.result` for results). `path` is owned by the
/// allocator passed to the validator.
pub const Failure = struct {
    detail: Detail,
    path: []const u8,

    pub const Detail = enum { unknown, missing, type, @"enum", range };

    pub fn code(self: Failure) []const u8 {
        return switch (self.detail) {
            inline else => |tag| "invalid_params." ++ @tagName(tag),
        };
    }
};

/// Validate a request's `params` object against a verb's fields, inserting
/// defaults for absent fields (allocated in `arena`). Null means valid.
pub fn validateParams(arena: std.mem.Allocator, fields: []const Field, params: *Value) !?Failure {
    var path: Path = .{ .gpa = arena };
    return validateObject(arena, fields, params, &path, true);
}

/// Validate one value. With `fill_defaults`, absent fields with defaults are
/// inserted (request params); without, defaults are ignored (results).
pub fn validateValue(arena: std.mem.Allocator, t: Type, value: *Value, path: *Path, fill_defaults: bool) error{OutOfMemory}!?Failure {
    if (t.nullable and value.* == .null) return null;
    const ok = switch (t.kind) {
        .null => value.* == .null,
        .boolean => value.* == .bool,
        .string => value.* == .string,
        .array => value.* == .array,
        .object => value.* == .object,
        .integer => switch (value.*) {
            .integer => true,
            // Integers outside i64 arrive as digit strings: right type, out of range.
            .number_string => |s| std.mem.indexOfAny(u8, s, ".eE") == null,
            else => false,
        },
        .number => value.* == .integer or value.* == .float or value.* == .number_string,
    };
    if (!ok) return try fail(arena, .type, path);
    switch (value.*) {
        .string => |s| if (t.choices) |choices| {
            for (choices) |choice| {
                if (std.mem.eql(u8, choice, s)) break;
            } else return try fail(arena, .@"enum", path);
        },
        .integer => |i| if (@abs(i) > max_safe_integer or !inBounds(t, @floatFromInt(i))) return try fail(arena, .range, path),
        .float => |f| if (!std.math.isFinite(f) or !inBounds(t, f)) return try fail(arena, .range, path),
        .number_string => return try fail(arena, .range, path),
        .array => |array| {
            for (array.items, 0..) |*item, i| {
                const mark = try path.pushIndex(i);
                if (try validateValue(arena, t.items.?.*, item, path, fill_defaults)) |f| return f;
                path.pop(mark);
            }
        },
        .object => return validateObject(arena, t.fields.?, value, path, fill_defaults),
        else => {},
    }
    return null;
}

fn inBounds(t: Type, x: f64) bool {
    return (t.min == null or x >= t.min.?) and (t.max == null or x <= t.max.?);
}

fn validateObject(arena: std.mem.Allocator, fields: []const Field, value: *Value, path: *Path, fill_defaults: bool) error{OutOfMemory}!?Failure {
    if (value.* != .object) return try fail(arena, .type, path);
    const object = &value.object;
    for (object.keys()) |key| {
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, key)) break;
        } else {
            const mark = try path.push(key);
            defer path.pop(mark);
            return try fail(arena, .unknown, path);
        }
    }
    for (fields) |field| {
        const mark = try path.push(field.name);
        defer path.pop(mark);
        if (object.getPtr(field.name)) |member| {
            if (try validateValue(arena, field.type, member, path, fill_defaults)) |f| return f;
        } else if (field.required) {
            return try fail(arena, .missing, path);
        } else if (fill_defaults) if (field.default) |text| {
            // `check` proved the default parses and validates.
            var default = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            _ = try validateValue(arena, field.type, &default, path, true);
            try object.put(arena, field.name, default);
        };
    }
    return null;
}

fn fail(arena: std.mem.Allocator, detail: Failure.Detail, path: *Path) error{OutOfMemory}!Failure {
    return .{ .detail = detail, .path = try arena.dupe(u8, path.bytes.items) };
}

const testing = std.testing;
const echo_schema: Schema = .{
    .tool = "venom-echo",
    .summary = "A toy daemon",
    .verbs = &.{.{
        .name = "echo",
        .summary = "Return the supplied text",
        .params = &.{
            .{ .name = "text", .summary = "Text", .type = .{ .kind = .string }, .required = true },
            .{ .name = "style", .summary = "Casing", .type = .{ .kind = .string, .choices = &.{ "plain", "upper" } }, .default = "\"plain\"" },
            .{ .name = "repeat", .summary = "Count", .type = .{ .kind = .integer, .min = 1, .max = 10 } },
            .{ .name = "tags", .summary = "Tags", .type = .{ .kind = .array, .items = &.{ .kind = .object, .fields = &.{
                .{ .name = "k", .summary = "Key", .type = .{ .kind = .string }, .required = true },
                .{ .name = "w", .summary = "Weight", .type = .{ .kind = .number, .min = 0 }, .default = "1.5" },
            } } } },
        },
        .result = .{ .kind = .object, .fields = &.{.{ .name = "text", .summary = "Text", .type = .{ .kind = .string }, .required = true }} },
        .grant = .read,
    }},
};

fn expectFailure(params: []const u8, code: ?[]const u8, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var value = try std.json.parseFromSliceLeaky(Value, arena, params, .{});
    const failure = try validateParams(arena, echo_schema.verbs[0].params, &value);
    if (code) |c| {
        try testing.expect(failure != null);
        try testing.expectEqualStrings(c, failure.?.code());
        try testing.expectEqualStrings(path, failure.?.path);
    } else try testing.expect(failure == null);
}

test "schema: params validation codes and dotted paths" {
    try check(&echo_schema, null);
    try expectFailure("{\"text\":\"hi\"}", null, "");
    try expectFailure("{}", "invalid_params.missing", "text");
    try expectFailure("{\"text\":1}", "invalid_params.type", "text");
    try expectFailure("{\"text\":\"hi\",\"x\":1}", "invalid_params.unknown", "x");
    try expectFailure("{\"text\":\"hi\",\"style\":\"loud\"}", "invalid_params.enum", "style");
    try expectFailure("{\"text\":\"hi\",\"repeat\":11}", "invalid_params.range", "repeat");
    try expectFailure("{\"text\":\"hi\",\"repeat\":2.0}", "invalid_params.type", "repeat");
    try expectFailure("{\"text\":\"hi\",\"repeat\":\"2\"}", "invalid_params.type", "repeat");
    try expectFailure("{\"text\":\"hi\",\"repeat\":99999999999999999999}", "invalid_params.range", "repeat");
    try expectFailure("{\"text\":\"hi\",\"repeat\":null}", "invalid_params.type", "repeat");
    try expectFailure("{\"text\":\"hi\",\"tags\":[{\"k\":\"a\"},{\"k\":\"b\",\"w\":-1}]}", "invalid_params.range", "tags.1.w");
    try expectFailure("{\"text\":\"hi\",\"tags\":[{\"k\":\"a\",\"z\":0}]}", "invalid_params.unknown", "tags.0.z");
    try expectFailure("{\"text\":\"hi\",\"tags\":[{}]}", "invalid_params.missing", "tags.0.k");
    try expectFailure("{\"text\":\"hi\",\"tags\":{}}", "invalid_params.type", "tags");
}

test "schema: defaults fill only absent fields, recursively" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var value = try std.json.parseFromSliceLeaky(Value, arena, "{\"text\":\"hi\",\"tags\":[{\"k\":\"a\"}]}", .{});
    try testing.expect(try validateParams(arena, echo_schema.verbs[0].params, &value) == null);
    try testing.expectEqualStrings("plain", value.object.get("style").?.string);
    try testing.expect(value.object.get("repeat") == null);
    try testing.expectEqual(@as(f64, 1.5), value.object.get("tags").?.array.items[0].object.get("w").?.float);
}

test "schema: check rejects invalid models and names the culprit" {
    const result: Type = .{ .kind = .null };
    const bad = [_]Schema{
        .{ .format = 2, .tool = "t", .summary = "s", .verbs = &.{} },
        .{ .tool = "Bad", .summary = "s", .verbs = &.{} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "ping", .summary = "s", .result = result, .grant = .none }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a-b", .summary = "s", .result = result, .grant = .none }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{ .{ .name = "a", .summary = "s", .result = result, .grant = .none }, .{ .name = "a", .summary = "s", .result = result, .grant = .none } } },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .streams = true }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .item = result }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = .{ .kind = .string, .min = 1 }, .grant = .none }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = .{ .kind = .integer, .min = 2, .max = 1 }, .grant = .none }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = .{ .kind = .array }, .grant = .none }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = .{ .kind = .string, .choices = &.{ "x", "x" } }, .grant = .none }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .errors = &.{.{ .code = "conflict", .summary = "s" }} }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .errors = &.{.{ .code = "oops.x", .summary = "s" }} }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .exit = .{ .result = "status" } }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .params = &.{.{ .name = "p", .summary = "s", .type = .{ .kind = .integer }, .default = "\"x\"" }} }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .params = &.{.{ .name = "p", .summary = "s", .type = .{ .kind = .integer }, .default = "1", .required = true }} }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = .{ .kind = .string, .comma_list = true }, .grant = .none }} },
        .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = .{ .kind = .array, .items = &.{ .kind = .integer }, .comma_list = true }, .grant = .none }} },
        .{ .tool = "t", .summary = "line\nbreak", .verbs = &.{} },
    };
    for (bad) |s| try testing.expectError(error.InvalidSchema, check(&s, null));
    var diag: Diagnostic = .{};
    const s: Schema = .{ .tool = "t", .summary = "s", .verbs = &.{.{ .name = "a", .summary = "s", .result = result, .grant = .none, .params = &.{.{ .name = "level", .summary = "s", .type = .{ .kind = .integer, .max = 1e300 } }} }} };
    try testing.expectError(error.InvalidSchema, check(&s, &diag));
    try testing.expectEqualStrings("a", diag.verb);
    try testing.expectEqualStrings("level", diag.subject);
    const status: Schema = .{ .tool = "t", .summary = "s", .verbs = &.{.{
        .name = "run",
        .summary = "s",
        .result = .{ .kind = .object, .fields = &.{.{ .name = "status", .summary = "s", .type = .{ .kind = .integer, .min = 0, .max = 255 }, .required = true }} },
        .grant = .spawn,
        .exit = .{ .result = "status" },
    }} };
    try check(&status, null);
}
