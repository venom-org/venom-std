//! The single shared declaration bundle, including refinement error data.
const std = @import("std");
const s = @import("proto").schema;
const string: s.Type = .{ .kind = .string };
const boolean: s.Type = .{ .kind = .boolean };
const data: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "param", .summary = "Parameter name", .type = string, .required = true },
    .{ .name = "key", .summary = "Dotted config field path, empty for root", .type = string, .required = true },
    .{ .name = "source", .summary = "Config file that failed, when one did: defaults, user or a product-named overlay (e.g. workspace, repo)", .type = string },
    .{ .name = "path", .summary = "Path of the failing overlay file", .type = string },
} };
const activation_data: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "reason", .summary = "Redacted cleanup failure category", .type = .{ .kind = .string, .choices = &.{ "io", "unsafe_store", "limit", "other" } }, .required = true },
    .{ .name = "partial", .summary = "Effects may have completed and are not rolled back", .type = boolean, .required = true },
} };
const errors = &[_]s.ErrorDecl{
    .{ .code = "invalid_params.config_zon", .summary = "Malformed or incorrectly typed data-only ZON", .data = data },
    .{ .code = "invalid_params.config_key", .summary = "Unknown or invalid dotted object key", .data = data },
    .{ .code = "invalid_params.config_value", .summary = "Whole configuration validation failed", .data = data },
    .{ .code = "invalid_params.config_secret", .summary = "Secret fields in ZON must be references", .data = data },
    .{ .code = "failed.config_activation", .summary = "Pre-activation cleanup failed; active config preserved", .data = activation_data },
    .{ .code = "failed.config_io", .summary = "Cannot read or atomically replace config, or the file is read-only", .data = data },
    .{ .code = "failed.config_edit", .summary = "Cannot edit this key in the file's text; the file is unchanged", .data = data },
    .{ .code = "failed.config_secret_store", .summary = "Secret store unavailable or failed", .data = data },
};
const content: s.Type = .{ .kind = .object, .fields = &.{.{ .name = "content", .summary = "Serialized content", .type = string, .required = true }} };
/// builtin, defaults, user, or the name of one of the product's overlays.
const source: s.Type = string;
const lookup: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "content", .summary = "Redacted effective ZON value", .type = string, .required = true },
    .{ .name = "source", .summary = "Highest layer supplying the key: builtin, defaults (defaults.zon), user (config.zon) or an overlay name (e.g. workspace, repo)", .type = source, .required = true },
    .{ .name = "path", .summary = "File of the overlay named by source", .type = string },
    .{ .name = "sources", .summary = "Source of every value under the key", .type = .{ .kind = .array, .items = &.{ .kind = .object, .fields = &.{
        .{ .name = "key", .summary = "Dotted value path", .type = string, .required = true },
        .{ .name = "source", .summary = "builtin, defaults, user or an overlay name", .type = source, .required = true },
        .{ .name = "path", .summary = "File of the overlay named by source", .type = string },
    } } }, .required = true },
} };
const change: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "changed", .summary = "Persisted bytes or active snapshot changed", .type = boolean, .required = true },
    .{ .name = "restart_required", .summary = "Restart-only settings differ", .type = boolean, .required = true },
} };
pub const verbs = [_]s.Verb{
    .{ .name = "config.get", .summary = "Read redacted effective ZON (builtin < defaults.zon < config.zon < overlays) and each value's source", .grant = .read, .params = &.{.{ .name = "key", .summary = "Dotted field path; empty reads all", .type = string, .default = "\"\"" }}, .result = lookup, .errors = errors },
    .{ .name = "config.set", .summary = "Validate and atomically persist a ZON value to the product's config file (the user file unless it picks an overlay) without reloading", .grant = .admin, .params = &.{
        .{ .name = "key", .summary = "Dotted object field path; map entry names may be quoted (a.\"b.c\".d)", .type = string, .required = true },
        .{ .name = "value", .summary = "One data-only ZON value", .type = string, .required = true },
    }, .result = change, .errors = errors },
    .{ .name = "config.check", .summary = "Validate defaults.zon, config.zon and overlays without changing active state", .grant = .read, .result = .{ .kind = .object, .fields = &.{.{ .name = "valid", .summary = "Configuration is valid", .type = boolean, .required = true }} }, .errors = errors },
    .{ .name = "config.reload", .summary = "Apply validated hot settings; preserve restart-only values", .grant = .admin, .result = change, .errors = errors },
    .{ .name = "config.schema", .summary = "Describe JSON-equivalent config types and field policies", .grant = .read, .result = content, .errors = errors },
};
pub fn merge(comptime model: s.Schema) s.Schema {
    return mergeWith(model, .{});
}
/// A product validation code for the shared config verbs, e.g.
/// `invalid_params.key_conflict`. Its data is the shared config
/// error data (`param`, `key`, `source`, `path`), like `config_value`.
pub const ErrorCode = struct { code: []const u8, summary: []const u8 };
pub const MergeOptions = struct {
    /// Extra `invalid_params.*` codes that a product's `validate` or
    /// `validate_layer` hook may return (`cfg.Validation.code`). They are
    /// declared on `config.get`, `config.set`, `config.check` and
    /// `config.reload`, the verbs that validate the configuration.
    errors: []const ErrorCode = &.{},
    /// Extra params on `config.get` and `config.set`, e.g. venom's
    /// `--workspace` and `--repo`, after the shared ones. They must be optional
    /// with no default: absent means the store's own scope. The shared handler
    /// ignores them, so the product must route these two verbs to its own
    /// handler (see `Store.bindings`) and call the store when none is given.
    scope_params: []const s.Field = &.{},
    /// What those params can fail with, on `config.get` and `config.set` only,
    /// after every other error. Each brings its own data.
    scope_errors: []const s.ErrorDecl = &.{},
};
/// `merge` plus product-declared validation codes and scope params. With no
/// options the result (and so the schema digest) equals `merge(model)`.
pub fn mergeWith(comptime model: s.Schema, comptime options: MergeOptions) s.Schema {
    for (model.verbs) |v| for (verbs) |shared| if (std.mem.eql(u8, v.name, shared.name)) @compileError("product cannot override shared config verbs");
    if (options.errors.len == 0 and options.scope_params.len == 0 and options.scope_errors.len == 0) {
        const all = model.verbs[0..model.verbs.len].* ++ verbs;
        return .{ .format = model.format, .tool = model.tool, .summary = model.summary, .verbs = &all };
    }
    var extra: [options.errors.len]s.ErrorDecl = undefined;
    for (options.errors, &extra, 0..) |e, *out, i| {
        if (!std.mem.startsWith(u8, e.code, "invalid_params.")) @compileError("cfg: product config error '" ++ e.code ++ "' must be in the invalid_params class");
        for (errors) |shared| if (std.mem.eql(u8, shared.code, e.code)) @compileError("cfg: product config error '" ++ e.code ++ "' is already a shared config error");
        for (options.errors[0..i]) |prev| if (std.mem.eql(u8, prev.code, e.code)) @compileError("cfg: duplicate product config error '" ++ e.code ++ "'");
        out.* = .{ .code = e.code, .summary = e.summary, .data = data };
    }
    const validating = errors.* ++ extra;
    for (options.scope_errors, 0..) |e, i| {
        for (validating) |other| if (std.mem.eql(u8, other.code, e.code)) @compileError("cfg: scope error '" ++ e.code ++ "' is already a config error");
        for (options.scope_errors[0..i]) |prev| if (std.mem.eql(u8, prev.code, e.code)) @compileError("cfg: duplicate scope error '" ++ e.code ++ "'");
    }
    for (options.scope_params, 0..) |p, i| {
        if (p.required or p.default != null) @compileError("cfg: scope param '" ++ p.name ++ "' must be optional with no default");
        if (std.mem.eql(u8, p.name, "key") or std.mem.eql(u8, p.name, "value")) @compileError("cfg: scope param '" ++ p.name ++ "' is a shared config param");
        for (options.scope_params[0..i]) |prev| if (std.mem.eql(u8, prev.name, p.name)) @compileError("cfg: duplicate scope param '" ++ p.name ++ "'");
    }
    const scoped = validating ++ options.scope_errors[0..options.scope_errors.len].*;
    var shared = verbs;
    for (&shared) |*v| {
        if (std.mem.eql(u8, v.name, "config.schema")) continue;
        if (std.mem.eql(u8, v.name, "config.get") or std.mem.eql(u8, v.name, "config.set")) {
            const params = v.params[0..v.params.len].* ++ options.scope_params[0..options.scope_params.len].*;
            v.params = &params;
            v.errors = &scoped;
        } else v.errors = &validating;
    }
    const merged = shared;
    const all = model.verbs[0..model.verbs.len].* ++ merged;
    return .{ .format = model.format, .tool = model.tool, .summary = model.summary, .verbs = &all };
}
