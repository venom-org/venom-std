//! Build-time ZON normalization. @import("verbs.zon") is static data; no
//! runtime file loading or executable schema expressions are involved.
const std = @import("std");
const s = @import("proto").schema;

fn closed(comptime value: anytype, comptime allowed: []const []const u8) void {
    for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        for (allowed) |a| {
            if (std.mem.eql(u8, name, a)) break;
        } else @compileError("cli: unknown manifest member '" ++ name ++ "'");
    }
}

pub fn json(comptime value: anytype) []const u8 {
    // Fixed storage works during compilation and imposes no runtime allocation.
    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    std.json.Stringify.value(value, .{}, &w) catch @compileError("cli: manifest value exceeds 64 KiB");
    return std.fmt.comptimePrint("{s}", .{w.buffered()});
}

/// `nullable_ok` is false under `params`: CLI flags have no
/// unambiguous spelling for "string or null", so parameters stay non-null.
fn fields(comptime input: anytype, comptime nullable_ok: bool) []const s.Field {
    var out: [input.len]s.Field = undefined;
    for (input, 0..) |f, i| {
        closed(f, &.{ "name", "summary", "type", "required", "default" });
        if (@hasField(@TypeOf(f), "default")) {
            if (@hasField(@TypeOf(f), "required") and f.required) @compileError("cli: required field has a default");
            validateStatic(descriptor(f.type, nullable_ok), f.default, true);
        }
        out[i] = .{
            .name = f.name,
            .summary = f.summary,
            .type = descriptor(f.type, nullable_ok),
            .required = if (@hasField(@TypeOf(f), "required")) f.required else false,
            .default = if (@hasField(@TypeOf(f), "default")) jsonValue(descriptor(f.type, nullable_ok), f.default) else null,
        };
    }
    const result = out;
    return &result;
}

/// A ZON type descriptor. Any kind may set `nullable = true` ("<kind> or
/// null", as in the shared grant records) where `nullable_ok`: results, stream
/// items and error data, at any depth.
fn descriptor(comptime t: anytype, comptime nullable_ok: bool) s.Type {
    const kind: s.Kind = t.kind;
    closed(t, switch (kind) {
        .string => &.{ "kind", "nullable", "choices" },
        .integer, .number => &.{ "kind", "nullable", "min", "max" },
        .array => &.{ "kind", "nullable", "items", "comma_list" },
        .object => &.{ "kind", "nullable", "fields" },
        else => &.{ "kind", "nullable" },
    });
    const nullable: bool = if (@hasField(@TypeOf(t), "nullable")) t.nullable else false;
    if (nullable and !nullable_ok) @compileError("cli: nullable is not allowed in params");
    const comma_list: bool = if (@hasField(@TypeOf(t), "comma_list")) t.comma_list else false;
    if (comma_list and nullable_ok) @compileError("cli: comma_list is only allowed on params");
    if (comma_list and t.items.kind != .string) @compileError("cli: comma_list needs an array of strings");
    if (kind == .array and @hasField(@TypeOf(t.items), "comma_list")) @compileError("cli: comma_list is only allowed on a top-level param");
    if (kind == .object) for (t.fields) |f| if (@hasField(@TypeOf(f.type), "comma_list")) @compileError("cli: comma_list is only allowed on a top-level param");
    return .{
        .kind = kind,
        .nullable = nullable,
        .choices = if (@hasField(@TypeOf(t), "choices")) blk: {
            var choices: [t.choices.len][]const u8 = undefined;
            for (t.choices, 0..) |c, i| choices[i] = c;
            const result = choices;
            break :blk &result;
        } else null,
        .min = if (@hasField(@TypeOf(t), "min")) t.min else null,
        .max = if (@hasField(@TypeOf(t), "max")) t.max else null,
        .items = if (kind == .array) &descriptor(t.items, nullable_ok) else null,
        .comma_list = comma_list,
        .fields = if (kind == .object) fields(t.fields, nullable_ok) else null,
    };
}

pub fn normalize(comptime input: anytype) s.Schema {
    return normalizeMode(input, false);
}

/// Compiled records for product-local commands; format 1 remains closed.
pub fn normalizeLocal(comptime input: anytype) s.Schema {
    return normalizeMode(input, true);
}

fn normalizeMode(comptime input: anytype, comptime local: bool) s.Schema {
    @setEvalBranchQuota(2_000_000);
    closed(input, &.{ "format", "tool", "summary", "verbs" });
    var verbs: [input.verbs.len]s.Verb = undefined;
    for (input.verbs, 0..) |v, i| {
        if (local) {
            closed(v, &.{ "name", "summary", "params", "result", "errors", "grant", "exit", "examples", "interactive" });
            if (@hasField(@TypeOf(v), "grant") and v.grant != .none) @compileError("cli: local grant must be none");
            if (@hasField(@TypeOf(v), "interactive")) {
                const interactive: bool = v.interactive;
                _ = interactive;
            }
        } else closed(v, &.{ "name", "summary", "params", "result", "errors", "grant", "streams", "item", "exit", "examples" });
        verbs[i] = .{
            .name = v.name,
            .summary = v.summary,
            .params = if (@hasField(@TypeOf(v), "params")) fields(v.params, false) else &.{},
            .result = descriptor(v.result, true),
            .grant = if (local) .none else v.grant,
            .streams = if (@hasField(@TypeOf(v), "streams")) v.streams else false,
            .item = if (@hasField(@TypeOf(v), "item")) descriptor(v.item, true) else null,
            .exit = if (@hasField(@TypeOf(v), "exit")) blk: {
                if (v.exit.kind == .standard) {
                    closed(v.exit, &.{"kind"});
                    break :blk .standard;
                }
                if (v.exit.kind != .result) @compileError("cli: invalid exit kind");
                closed(v.exit, &.{ "kind", "field" });
                break :blk .{ .result = v.exit.field };
            } else .standard,
            .errors = if (@hasField(@TypeOf(v), "errors")) blk: {
                var errors: [v.errors.len]s.ErrorDecl = undefined;
                for (v.errors, 0..) |e, j| {
                    closed(e, &.{ "code", "summary", "data" });
                    errors[j] = .{ .code = e.code, .summary = e.summary, .data = if (@hasField(@TypeOf(e), "data")) descriptor(e.data, true) else .{ .kind = .object, .fields = &.{} } };
                }
                const result = errors;
                break :blk &result;
            } else &.{},
        };
    }
    // Stable help and future artifact generators use wire-name order.
    std.mem.sort(s.Verb, &verbs, {}, struct {
        fn less(_: void, a: s.Verb, b: s.Verb) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    const result = verbs;
    const schema: s.Schema = .{ .format = input.format, .tool = input.tool, .summary = input.summary, .verbs = &result };
    // proto validates structure; defaults are checked directly as static ZON
    // values because Zig runtime allocators cannot be evaluated at comptime.
    var checked = result;
    for (&checked) |*v| {
        v.params = withoutDefaults(v.params);
        v.result = typeWithoutDefaults(v.result);
        if (v.item) |item| v.item = typeWithoutDefaults(item);
        var errors: [v.errors.len]s.ErrorDecl = undefined;
        for (v.errors, 0..) |e, i| {
            errors[i] = e;
            if (e.data) |data| errors[i].data = typeWithoutDefaults(data);
        }
        const es = errors;
        v.errors = &es;
    }
    var check_schema = schema;
    check_schema.verbs = &checked;
    s.check(&check_schema, null) catch @compileError("cli: invalid verb schema");
    if (@hasField(@TypeOf(input), "verbs")) for (input.verbs) |v| {
        if (@hasField(@TypeOf(v), "examples")) for (v.examples) |example| {
            closed(example, &.{ "params", "result" });
            const verb = schema.find(v.name).?;
            validateExample(verb, example);
        };
    };
    return schema;
}

fn validateExample(comptime verb: *const s.Verb, comptime example: anytype) void {
    validateStatic(.{ .kind = .object, .fields = verb.params }, example.params, true);
    validateStatic(verb.result, example.result, false);
}
fn withoutDefaults(comptime fs: []const s.Field) []const s.Field {
    var out: [fs.len]s.Field = undefined;
    for (fs, 0..) |f, i| {
        out[i] = f;
        out[i].default = null;
        out[i].type = typeWithoutDefaults(f.type);
    }
    const result = out;
    return &result;
}
fn typeWithoutDefaults(comptime t: s.Type) s.Type {
    var result = t;
    if (t.fields) |fs| result.fields = withoutDefaults(fs);
    if (t.items) |item| result.items = &typeWithoutDefaults(item.*);
    return result;
}
/// Validate static values without coercion or runtime allocation.
fn validateStatic(comptime t: s.Type, comptime v: anytype, comptime defaults: bool) void {
    const info = @typeInfo(@TypeOf(v));
    if (t.nullable and info == .null) return;
    switch (t.kind) {
        .null => if (info != .null) @compileError("cli: expected null"),
        .boolean => if (info != .bool) @compileError("cli: expected boolean"),
        .string => {
            const text: []const u8 = v;
            if (!std.unicode.utf8ValidateSlice(text)) @compileError("cli: invalid UTF-8");
            if (t.choices) |choices| {
                for (choices) |c| {
                    if (std.mem.eql(u8, text, c)) break;
                } else @compileError("cli: invalid enum value");
            }
        },
        .integer, .number => {
            if (info != .comptime_int and info != .int and info != .comptime_float and info != .float) @compileError("cli: expected number");
            if (t.kind == .integer and info != .comptime_int and info != .int) @compileError("cli: expected integer");
            const number: f64 = if (info == .comptime_int or info == .int) @floatFromInt(v) else v;
            if (!std.math.isFinite(number) or (t.min != null and number < t.min.?) or (t.max != null and number > t.max.?) or ((info == .comptime_int or info == .int) and @abs(number) > s.max_safe_integer)) @compileError("cli: number out of range");
        },
        .array => {
            if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("cli: expected array tuple");
            for (v) |item| validateStatic(t.items.?.*, item, defaults);
        },
        .object => {
            if (info != .@"struct") @compileError("cli: expected object");
            closed(v, blk: {
                var names: [t.fields.?.len][]const u8 = undefined;
                for (t.fields.?, 0..) |f, i| names[i] = f.name;
                const names_result = names;
                break :blk &names_result;
            });
            for (t.fields.?) |f| {
                if (@hasField(@TypeOf(v), f.name)) validateStatic(f.type, @field(v, f.name), defaults) else if (f.required) @compileError("cli: missing required field '" ++ f.name ++ "'");
            }
        },
    }
}

// Empty .{} is JSON [] to Zig, but is an object when its schema says so.
// Walk compound defaults with the descriptor, preserving explicit null/absence.
fn jsonValue(comptime t: s.Type, comptime value: anytype) []const u8 {
    if (@typeInfo(@TypeOf(value)) == .null) return "null";
    if (t.kind == .object) {
        var text: []const u8 = "{";
        var first = true;
        for (t.fields.?) |f| if (@hasField(@TypeOf(value), f.name)) {
            text = text ++ (if (first) "" else ",") ++ json(f.name) ++ ":" ++ jsonValue(f.type, @field(value, f.name));
            first = false;
        };
        return text ++ "}";
    }
    if (t.kind == .array) {
        var text: []const u8 = "[";
        for (value, 0..) |item, i| text = text ++ (if (i == 0) "" else ",") ++ jsonValue(t.items.?.*, item);
        return text ++ "]";
    }
    return json(value);
}

/// One `--flag value` pair of a generated example, in declaration order.
/// `value` is the raw text for strings and compact JSON otherwise. `equals`
/// marks values that must be attached as `--flag=value` (booleans and
/// dash-leading values, which would otherwise parse as flags).
pub const Arg = struct { flag: []const u8, value: []const u8, equals: bool };
/// A manifest example, kept for docs, skill and digest generation.
/// `params` and `result` are compact JSON in declaration order,
/// before default insertion.
pub const Example = struct { verb: []const u8, args: []const Arg, result: []const u8, params: []const u8 = "{}" };

/// Examples in verb wire-name order, then declaration order. Inputs were
/// already validated by `normalize`.
pub fn examples(comptime input: anytype) []const Example {
    // Local examples are evaluated lazily in the generated type, outside
    // WithBootstrap's quota. Give serialization its own compilation budget.
    @setEvalBranchQuota(2_000_000);
    var out: []const Example = &.{};
    for (input.verbs) |v| if (@hasField(@TypeOf(v), "examples")) for (v.examples) |e| {
        const params = if (@hasField(@TypeOf(v), "params")) fields(v.params, false) else &.{};
        var args: []const Arg = &.{};
        for (@typeInfo(@TypeOf(e.params)).@"struct".field_names) |name| {
            const f = for (params) |p| {
                if (std.mem.eql(u8, p.name, name)) break p;
            } else unreachable;
            const value = @field(e.params, name);
            const text: []const u8 = if (f.type.kind == .string) std.fmt.comptimePrint("{s}", .{value}) else jsonValue(f.type, value);
            args = args ++ &[_]Arg{.{ .flag = flag(name), .value = text, .equals = f.type.kind == .boolean or (text.len > 0 and text[0] == '-') }};
        }
        out = out ++ &[_]Example{.{ .verb = v.name, .args = args, .result = jsonValue(descriptor(v.result, true), e.result), .params = jsonValue(.{ .kind = .object, .fields = params }, e.params) }};
    };
    // Insertion sort is stable, preserving declaration order per verb.
    var sorted = out[0..out.len].*;
    for (0..sorted.len) |i| {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, sorted[j].verb, sorted[j - 1].verb)) : (j -= 1) {
            std.mem.swap(Example, &sorted[j], &sorted[j - 1]);
        }
    }
    const result = sorted;
    return &result;
}
fn flag(comptime name: []const u8) []const u8 {
    var out: [name.len]u8 = undefined;
    for (name, 0..) |ch, i| out[i] = if (ch == '_') '-' else ch;
    return std.fmt.comptimePrint("{s}", .{out});
}
