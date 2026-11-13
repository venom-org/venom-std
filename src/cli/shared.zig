//! The standard agent-contract bundle. Remote shared verbs (`skill`, `skill.install`,
//! `doctor`) merge into every generated schema; products bind their handlers
//! with `cli.Standard`. Local verbs dispatch in-process and never reach the
//! daemon or the MCP catalog.
const std = @import("std");
const s = @import("proto").schema;

const string: s.Type = .{ .kind = .string };
const content: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "content", .summary = "Complete generated text", .type = string, .required = true },
} };

pub const skill_targets = [_][]const u8{ "claude-code", "codex", "opencode" };

const check: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "id", .summary = "Stable check identifier", .type = string, .required = true },
    .{ .name = "status", .summary = "Check outcome", .type = .{ .kind = .string, .choices = &.{ "ok", "warn", "fail" } }, .required = true },
    .{ .name = "message", .summary = "Human-readable finding", .type = string, .required = true },
    .{ .name = "fix", .summary = "Runnable POSIX shell command that repairs or rechecks", .type = string, .required = true },
} };

/// Remote shared verbs, merged into the product schema.
pub const remote = [_]s.Verb{
    .{ .name = "doctor", .summary = "Run read-only diagnostic checks; exits 1 if any check fails", .grant = .read, .params = &.{
        .{ .name = "client_schema", .summary = "Schema digest the caller was built against; a mismatch is reported as a warning", .type = string },
    }, .result = .{ .kind = .object, .fields = &.{
        .{ .name = "status", .summary = "1 if any check failed, otherwise 0", .type = .{ .kind = .integer, .min = 0, .max = 255 }, .required = true },
        .{ .name = "checks", .summary = "Check results in registration order", .type = .{ .kind = .array, .items = &check }, .required = true },
    } }, .exit = .{ .result = "status" } },
    .{ .name = "skill", .summary = "Print the generated SKILL.md for agents", .grant = .read, .result = content },
    .{ .name = "skill.install", .summary = "Install the generated SKILL.md for an agent on the daemon's host", .grant = .files, .params = &.{
        .{ .name = "target", .summary = "Skill consumer", .type = .{ .kind = .string, .choices = &skill_targets }, .required = true },
        .{ .name = "directory", .summary = "Absolute skill root overriding the target's default", .type = string },
        .{ .name = "replace", .summary = "Atomically replace a different existing SKILL.md", .type = .{ .kind = .boolean }, .default = "false" },
    }, .result = .{ .kind = .object, .fields = &.{
        .{ .name = "target", .summary = "Skill consumer", .type = string, .required = true },
        .{ .name = "path", .summary = "Absolute path of the installed SKILL.md", .type = string, .required = true },
        .{ .name = "changed", .summary = "Whether the file was written", .type = .{ .kind = .boolean }, .required = true },
    } }, .errors = &.{
        .{ .code = "conflict.skill_exists", .summary = "A different SKILL.md exists and replace is false" },
        .{ .code = "failed.skill_write", .summary = "The skill file could not be written" },
        .{ .code = "invalid_params.skill_directory", .summary = "No usable skill root: HOME is unavailable, the path is not absolute, or it traverses a symlink" },
    } },
};

/// Local verbs: bootstrap (`serve`, `mcp`) and offline generators.
pub const local = [_]s.Verb{
    .{ .name = "completions", .summary = "Print shell completions generated from the verb schema", .grant = .none, .params = &.{
        .{ .name = "shell", .summary = "Target shell", .type = .{ .kind = .string, .choices = &.{ "bash", "zsh", "fish" } }, .required = true },
    }, .result = content },
    .{ .name = "docs", .summary = "Print Markdown or man documentation, or write it to a directory", .grant = .none, .params = &.{
        .{ .name = "format", .summary = "Output format", .type = .{ .kind = .string, .choices = &.{ "markdown", "man" } }, .default = "\"markdown\"" },
        .{ .name = "directory", .summary = "Write one file per page into this existing directory instead of printing", .type = string },
    }, .result = .{ .kind = .object, .fields = &.{
        .{ .name = "content", .summary = "Generated text, when printing", .type = string },
        .{ .name = "files", .summary = "Written files, when a directory is given", .type = .{ .kind = .array, .items = &string } },
    } } },
    .{ .name = "mcp", .summary = "Serve the verbs as an MCP stdio server (JSON-RPC on stdin/stdout)", .result = .{ .kind = .object, .fields = &.{} }, .grant = .none },
    .{ .name = "serve", .summary = "Start the daemon", .result = .{ .kind = .object, .fields = &.{} }, .grant = .none },
};

pub fn isLocal(name: []const u8) bool {
    for (local) |v| if (std.mem.eql(u8, v.name, name)) return true;
    return false;
}

/// Shared names a product may not declare (or nest under).
pub fn reserved(name: []const u8) bool {
    for (local ++ remote) |v| {
        if (std.mem.eql(u8, v.name, name)) return true;
        if (name.len > v.name.len and std.mem.startsWith(u8, name, v.name) and name[v.name.len] == '.' and isLocal(v.name)) return true;
    }
    return false;
}

pub fn merge(comptime model: s.Schema) s.Schema {
    for (model.verbs) |v| if (reserved(v.name)) @compileError("cli: reserved bootstrap or shared verb name '" ++ v.name ++ "'");
    const all = model.verbs[0..model.verbs.len].* ++ remote;
    return .{ .format = model.format, .tool = model.tool, .summary = model.summary, .verbs = &all };
}

/// Local CLI policy only. The normalized declaration is the eligibility key;
/// its summary carries the same policy into help, docs, skill and digest.
pub const StartupPolicy = struct { verb: []const u8, summary: []const u8 };
pub const startup_errors = [_]s.ErrorDecl{
    .{ .code = "invalid_params.startup_config", .summary = "Invalid startup configuration", .data = .{ .kind = .object, .fields = &.{} } },
    .{ .code = "denied.startup_context", .summary = "Managed context cannot bootstrap owner authority", .data = .{ .kind = .object, .fields = &.{} } },
    .{ .code = "unavailable.startup_failed", .summary = "Daemon launch or initialization failed", .data = .{ .kind = .object, .fields = &.{} } },
    .{ .code = "unavailable.startup_deadline", .summary = "Daemon did not become ready within the startup budget", .data = .{ .kind = .object, .fields = &.{} } },
    .{ .code = "unavailable.startup_result", .summary = "Mutation outcome is unknown; inspect state before retrying", .data = .{ .kind = .object, .fields = &.{} } },
};
pub fn withPolicy(comptime model: s.Schema, comptime policy: ?StartupPolicy) s.Schema {
    const p = policy orelse return model;
    if (reserved(p.verb) or p.summary.len == 0) @compileError("cli: startup policy requires a product verb and summary");
    if (!std.unicode.utf8ValidateSlice(p.summary)) @compileError("cli: invalid startup policy summary");
    for (p.summary) |ch| if (ch < 0x20 or ch == 0x7f) @compileError("cli: invalid startup policy summary");
    var verbs = model.verbs[0..model.verbs.len].*;
    var found = false;
    for (&verbs) |*v| if (std.mem.eql(u8, v.name, p.verb)) {
        found = true;
        v.summary = v.summary ++ " " ++ p.summary;
        for (v.errors) |existing| for (startup_errors) |extra| {
            if (std.mem.eql(u8, existing.code, extra.code)) @compileError("cli: duplicate startup error declaration");
        };
        const errors = v.errors[0..v.errors.len].* ++ startup_errors;
        v.errors = &errors;
    };
    if (!found) @compileError("cli: startup policy verb is absent from schema");
    const result = verbs;
    var out = model;
    out.verbs = &result;
    return out;
}
