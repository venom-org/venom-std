//! Markdown and man documentation, and SKILL.md, all
//! rendered deterministically from the generated verb model. Verbs come in
//! wire-name order; fields, choices and examples keep declaration order.
//! Every user-supplied string is escaped for its context (Markdown, roff,
//! YAML or POSIX shell).
const std = @import("std");
const proto = @import("proto");
const manifest = @import("manifest.zig");
const s = proto.schema;
const W = *std.Io.Writer;
const Allocator = std.mem.Allocator;

// ------------------------------------------------------------------ names

pub const Name = enum { canonical, flag, page, mcp };
/// Writes a schema-validated name in one of its generated spellings:
/// canonical `pane set-title`, flag `set-title`, man page `pane-set-title`
/// or MCP `pane_dset__title`. `escape` selects roff output (`-` as `\-`).
pub fn name(w: W, text: []const u8, comptime as: Name, escape: bool) !void {
    for (text) |ch| {
        const out: []const u8 = switch (as) {
            .canonical => switch (ch) {
                '.' => " ",
                '_' => "-",
                else => &.{ch},
            },
            .flag => if (ch == '_') "-" else &.{ch},
            .page => if (ch == '.' or ch == '_') "-" else &.{ch},
            .mcp => switch (ch) {
                '_' => "__",
                '.' => "_d",
                else => &.{ch},
            },
        };
        for (out) |o| if (escape and o == '-') try w.writeAll("\\-") else try w.writeByte(o);
    }
}
pub fn canonical(w: W, text: []const u8) !void {
    return name(w, text, .canonical, false);
}
pub fn flag(w: W, text: []const u8) !void {
    return name(w, text, .flag, false);
}

/// Fail generation if two verbs map to the same man page.
pub fn checkPageNames(comptime verbs: []const s.Verb) void {
    for (verbs, 0..) |a, i| for (verbs[0..i]) |b| {
        if (a.name.len != b.name.len) continue;
        for (a.name, b.name) |x, y| {
            const nx: u8 = if (x == '.' or x == '_') '-' else x;
            const ny: u8 = if (y == '.' or y == '_') '-' else y;
            if (nx != ny) break;
        } else @compileError("cli: man page name collision between '" ++ a.name ++ "' and '" ++ b.name ++ "'");
    };
}

// --------------------------------------------------------------- escaping

pub fn markdown(w: W, text: []const u8) !void {
    for (text) |ch| {
        if (std.mem.indexOfScalar(u8, "\\`*_[]<>|~", ch) != null) try w.writeByte('\\');
        try w.writeByte(ch);
    }
}
/// Roff text: a leading `\&` neutralizes control characters at line start.
pub fn roff(w: W, text: []const u8) !void {
    try w.writeAll("\\&");
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\e"),
        '-' => try w.writeAll("\\-"),
        else => try w.writeByte(ch),
    };
}
/// POSIX shell word: bare when unambiguous, otherwise single-quoted.
pub fn shell(w: W, text: []const u8) !void {
    const safe = text.len > 0 and for (text) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "@%+=:,./_-", ch) != null)) break false;
    } else true;
    if (safe) return w.writeAll(text);
    try w.writeByte('\'');
    for (text) |ch| if (ch == '\'') try w.writeAll("'\\''") else try w.writeByte(ch);
    try w.writeByte('\'');
}
/// YAML double-quoted scalar.
pub fn yaml(w: W, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}
/// Length of a Markdown fence longer than any backtick run in `parts`.
fn fenceLen(parts: []const []const u8) usize {
    var longest: usize = 0;
    for (parts) |part| {
        var run: usize = 0;
        for (part) |ch| {
            run = if (ch == '`') run + 1 else 0;
            longest = @max(longest, run);
        }
    }
    return @max(3, longest + 1);
}
fn backticks(w: W, n: usize) !void {
    for (0..n) |_| try w.writeByte('`');
}

/// Compact type description, e.g. `object { text: string (required) }`.
/// Field names are schema-validated identifiers; enum choices go through
/// `escape`, so the result is safe in the caller's context.
pub fn typeText(w: W, t: s.Type, escape: *const fn (W, []const u8) anyerror!void) anyerror!void {
    switch (t.kind) {
        .object => {
            const fields = t.fields orelse &.{};
            if (fields.len == 0) try w.writeAll("object {}") else {
                try w.writeAll("object { ");
                for (fields, 0..) |f, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{s}: ", .{f.name});
                    try typeText(w, f.type, escape);
                    if (f.required) try w.writeAll(" (required)");
                }
                try w.writeAll(" }");
            }
        },
        .array => {
            try w.writeAll("array of ");
            try typeText(w, t.items.?.*, escape);
            if (t.comma_list) try w.writeAll(" (JSON, or comma-separated: a,b)");
        },
        else => {
            try w.writeAll(@tagName(t.kind));
            if (t.choices) |choices| {
                try w.writeAll(" (one of: ");
                for (choices, 0..) |c, i| {
                    if (i > 0) try w.writeAll(", ");
                    try escape(w, c);
                }
                try w.writeAll(")");
            }
            if (t.min != null or t.max != null) {
                try w.writeAll(" [");
                if (t.min) |m| try w.print("{d}", .{m});
                try w.writeAll("..");
                if (t.max) |m| try w.print("{d}", .{m});
                try w.writeAll("]");
            }
        },
    }
    if (t.nullable) try w.writeAll(" or null");
}

/// `<tool> pane set-title --title 'x' --json`, shell-quoted.
fn exampleCommand(w: W, tool: []const u8, e: manifest.Example) !void {
    try w.print("{s} ", .{tool});
    try canonical(w, e.verb);
    for (e.args) |arg| {
        try w.writeAll(" ");
        // Dash-leading values must use '=', or they would parse as flags.
        try w.print("--{s}{s}", .{ arg.flag, if (arg.equals) "=" else " " });
        try shell(w, arg.value);
    }
    try w.writeAll(" --json");
}

const exit_table = [_]struct { []const u8, u8 }{
    .{ "success", 0 },     .{ "failed (and unknown classes)", 1 }, .{ "invalid_params (and CLI usage)", 2 },
    .{ "not_found", 3 },   .{ "denied", 4 },                       .{ "conflict", 5 },
    .{ "unavailable", 6 }, .{ "timeout", 7 },                      .{ "cancelled", 8 },
    .{ "protocol", 9 },    .{ "unsupported", 10 },                 .{ "internal", 11 },
};

// --------------------------------------------------------------- Markdown

fn heading(w: W, level: usize) !void {
    for (0..level) |_| try w.writeByte('#');
    try w.writeByte(' ');
}

/// One verb's reference section. Shared by `docs` and `skill`.
fn verbMarkdown(comptime G: type, w: W, tool: []const u8, v: s.Verb, examples: []const manifest.Example, level: usize) !void {
    try heading(w, level);
    try w.print("`{s} ", .{tool});
    try canonical(w, v.name);
    try w.writeAll("`\n\n");
    try markdown(w, v.summary);
    try w.print("\n\n- Wire name: `{s}`\n- MCP tool: ", .{v.name});
    if (G.isLocal(v.name)) try w.writeAll("none (local command)") else {
        try w.writeAll("`");
        try name(w, v.name, .mcp, false);
        try w.writeAll("`");
    }
    try w.print("\n- Grant: `{s}`\n", .{@tagName(v.grant)});
    switch (v.exit) {
        .standard => try w.writeAll("- Exit status: standard error mapping\n"),
        .result => |field| try w.print("- Exit status: on success, `result.{s}`; errors use the standard mapping\n", .{field}),
    }
    if (G.isInteractive(v.name)) try w.writeAll("- Interactive: needs a terminal on stdin and stdout\n");
    if (v.streams) try w.writeAll("- Streams: `--json` prints one item per line and suppresses the final success summary; MCP buffers at most 1024 items and 1 MiB per call (else `unsupported.stream_limit`)\n");
    try w.writeAll("\n");
    if (v.params.len > 0) {
        try w.writeAll("| Flag | Type | Required | Default | Description |\n|---|---|---|---|---|\n");
        for (v.params) |p| {
            try w.writeAll("| `--");
            try flag(w, p.name);
            try w.writeAll("` | ");
            try typeText(w, p.type, markdown);
            try w.print(" | {s} | ", .{if (p.required) "yes" else "no"});
            if (p.default) |d| try markdown(w, d);
            try w.writeAll(" | ");
            try markdown(w, p.summary);
            try w.writeAll(" |\n");
        }
        try w.writeAll("\n");
    } else try w.writeAll("No parameters.\n\n");
    try w.writeAll("Result: ");
    try typeText(w, v.result, markdown);
    try w.writeAll("\n\n");
    if (v.item) |item| {
        try w.writeAll("Stream item: ");
        try typeText(w, item, markdown);
        try w.writeAll("\n\n");
    }
    if (v.errors.len > 0) {
        try w.writeAll("| Error | Exit | Meaning |\n|---|---|---|\n");
        for (v.errors) |e| {
            try w.print("| `{s}` | {d} | ", .{ e.code, proto.errors.exitCode(e.code) });
            try markdown(w, e.summary);
            try w.writeAll(" |\n");
        }
        try w.writeAll("\n");
    }
    for (examples) |e| if (std.mem.eql(u8, e.verb, v.name)) {
        var n = fenceLen(&.{e.result});
        for (e.args) |arg| n = @max(n, fenceLen(&.{arg.value}));
        try backticks(w, n);
        try w.writeAll("bash\n");
        try exampleCommand(w, tool, e);
        try w.print("\n# => {s}\n", .{e.result});
        try backticks(w, n);
        try w.writeAll("\n\n");
    };
}

fn conventions(w: W, tool: []const u8) !void {
    try w.print(
        \\- Subcommands are space-separated (`{0s} grant issue`); the exact dotted wire name is also accepted (`{0s} grant.issue`).
        \\- Every parameter is a named flag: `--name value` or `--name=value`. Values starting with `-` must use `=`. Booleans need `=true` or `=false`; arrays and objects take one JSON value. Flags cannot repeat and there are no positional arguments.
        \\- Global options: `--json`, `--socket <path>`, `--help`. With `--json`, stdout holds only the result or `{{"error":...}}`; diagnostics go to stderr.
        \\- Streaming commands with `--json` print one JSON item per line; the final success summary is validated (and sets the exit status) but not printed.
        \\- Match `error.code` and the exit status, never English messages.
        \\
        \\| Error class | Exit |
        \\|---|---|
        \\
    , .{tool});
    for (exit_table) |row| try w.print("| {s} | {d} |\n", .{ row[0], row[1] });
    try w.writeAll("\n");
}

pub fn writeMarkdown(comptime G: type, w: W) !void {
    const tool = G.schema.tool;
    try w.print("# {s}\n\n", .{tool});
    try markdown(w, G.schema.summary);
    try w.writeAll("\n\n## Conventions\n\n");
    try conventions(w, tool);
    try w.writeAll("## Commands\n\n");
    for (G.verbs) |v| try verbMarkdown(G, w, tool, v, G.examples, 3);
}

// ------------------------------------------------------------------- SKILL

/// SKILL.md. Credential-free and deterministic;
/// `notes` is hand-written Markdown appended verbatim.
pub fn writeSkill(comptime G: type, w: W, notes: []const u8) !void {
    const tool = G.schema.tool;
    try w.print("---\nname: {s}\ndescription: ", .{tool});
    try yaml(w, G.schema.summary);
    try w.print("\n---\n\n# {s}\n\n", .{tool});
    try markdown(w, G.schema.summary);
    try w.print(
        \\
        \\
        \\## How to use it
        \\
        \\- Run `{0s} <command> --json` and parse stdout. Run `{0s} --help` or `{0s} <command> --help` for usage.
        \\- **Read-only by default.** Callers without an issued grant hold only `read` rights. Commands that need `write`, `respond`, `files`, `spawn` or `admin` fail with a `denied.*` error (exit 4). Ask the user for a grant; never try to obtain rights yourself.
        \\- Streams: the CLI prints NDJSON items for as long as the stream runs. Through MCP, a stream call buffers at most 1024 items and 1 MiB of item JSON and otherwise fails with `unsupported.stream_limit`; use the CLI for unbounded streams such as `events`.
        \\- Run `{0s} doctor --json` when something fails; each failing check carries a `fix` command to run.
        \\- The examples below are illustrative and were never executed.
        \\
    , .{tool});
    try conventions(w, tool);
    try w.writeAll("## Commands\n\n| Command | Grant | Summary |\n|---|---|---|\n");
    for (G.verbs) |v| {
        if (G.isProductLocal(v.name)) continue;
        try w.print("| `{s} ", .{tool});
        try canonical(w, v.name);
        try w.print("` | `{s}` | ", .{@tagName(v.grant)});
        try markdown(w, v.summary);
        try w.writeAll(" |\n");
    }
    try w.writeAll("\n## Reference\n\n");
    for (G.verbs) |v| {
        if (!G.isProductLocal(v.name)) try verbMarkdown(G, w, tool, v, G.examples, 3);
    }
    var local_heading = false;
    for (G.verbs) |v| {
        if (!G.isProductLocal(v.name) or G.isInteractive(v.name)) continue;
        if (!local_heading) {
            try w.writeAll("## Local commands\n\n");
            local_heading = true;
        }
        try verbMarkdown(G, w, tool, v, G.examples, 3);
    }
    if (notes.len > 0) {
        try w.writeAll("## Notes\n\n");
        try w.writeAll(notes);
        if (notes[notes.len - 1] != '\n') try w.writeAll("\n");
    }
}

// --------------------------------------------------------------------- man

pub const Page = struct { name: []const u8, content: []const u8 };

fn th(w: W, tool: []const u8, verb: ?[]const u8) !void {
    try w.writeAll(".TH \"");
    for (tool) |ch| try w.writeByte(std.ascii.toUpper(ch));
    if (verb) |v| {
        try w.writeByte('-');
        for (v) |ch| try w.writeByte(if (ch == '.' or ch == '_') '-' else std.ascii.toUpper(ch));
    }
    try w.writeAll("\" \"1\" \"\" \"\" \"Venom Manual\"\n");
}
/// Roff text for a generated name (prefixed with `\&` like `roff`).
fn roffName(w: W, text: []const u8, comptime as: Name) !void {
    try w.writeAll("\\&");
    try name(w, text, as, true);
}

fn verbRoff(comptime G: type, w: W, tool: []const u8, v: s.Verb, examples: []const manifest.Example) !void {
    try w.writeAll(".TP\n.B ");
    try roff(w, tool);
    try w.writeAll(" ");
    try roffName(w, v.name, .canonical);
    try w.writeAll("\n");
    try roff(w, v.summary);
    try w.writeAll("\n.br\nWire name: ");
    try roff(w, v.name);
    try w.writeAll("; MCP tool: ");
    if (G.isLocal(v.name)) try w.writeAll("none (local command)") else try roffName(w, v.name, .mcp);
    try w.print("; grant: {s}.\n", .{@tagName(v.grant)});
    if (G.isInteractive(v.name)) try w.writeAll(".br\nInteractive: needs a terminal on stdin and stdout\n");
    switch (v.exit) {
        .standard => {},
        .result => |field| try w.print(".br\nOn success the exit status is result.{s}.\n", .{field}),
    }
    if (v.streams) try w.writeAll(".br\nStreams: \\-\\-json prints one item per line and suppresses the final success summary.\n");
    try w.writeAll(".RS\n");
    for (v.params) |p| {
        try w.writeAll(".TP\n.B \\-\\-");
        try roffName(w, p.name, .flag);
        try w.writeAll("\n");
        try roff(w, p.summary);
        try w.writeAll(". Type: ");
        try typeText(w, p.type, roff);
        if (p.required) try w.writeAll("; required");
        if (p.default) |d| {
            try w.writeAll("; default: ");
            try roff(w, d);
        }
        try w.writeAll(".\n");
    }
    if (v.params.len == 0) try w.writeAll("No parameters.\n");
    try w.writeAll(".PP\nResult: ");
    try typeText(w, v.result, roff);
    try w.writeAll(".\n");
    if (v.item) |item| {
        try w.writeAll(".PP\nStream item: ");
        try typeText(w, item, roff);
        try w.writeAll(".\n");
    }
    for (v.errors) |e| {
        try w.writeAll(".PP\nError ");
        try roff(w, e.code);
        try w.print(" (exit {d}): ", .{proto.errors.exitCode(e.code)});
        try roff(w, e.summary);
        try w.writeAll(".\n");
    }
    for (examples) |e| if (std.mem.eql(u8, e.verb, v.name)) {
        // Example text is shell-quoted first, then escaped for roff.
        try w.writeAll(".PP\nExample:\n.nf\n\\&");
        try roff(w, tool);
        try w.writeAll(" ");
        try name(w, e.verb, .canonical, true);
        for (e.args) |arg| {
            try w.writeAll(" \\-\\-");
            try name(w, arg.flag, .flag, true);
            try w.writeAll(if (arg.equals) "=" else " ");
            var quoted: [4096]u8 = undefined;
            var q = std.Io.Writer.fixed(&quoted);
            shell(&q, arg.value) catch return error.ExampleTooLong;
            try roff(w, q.buffered());
        }
        try w.writeAll(" \\-\\-json\n");
        try roff(w, e.result);
        try w.writeAll("\n.fi\n");
    };
    try w.writeAll(".RE\n");
}

fn overview(comptime G: type, w: W, full: bool) !void {
    const tool = G.schema.tool;
    try th(w, tool, null);
    try w.writeAll(".SH NAME\n");
    try roff(w, tool);
    try w.writeAll(" \\- ");
    try roff(w, G.schema.summary);
    try w.writeAll("\n.SH SYNOPSIS\n.B ");
    try roff(w, tool);
    try w.writeAll("\n<command> [\\-\\-json] [\\-\\-socket path] [\\-\\-help] [options]\n.SH DESCRIPTION\n");
    try w.writeAll("Subcommands are space\\-separated; the dotted wire name is also accepted. Every parameter is a named flag. Values starting with \\- must use =. Booleans need =true or =false; arrays and objects take one JSON value. With \\-\\-json, stdout holds only the result or the error wrapper.\n");
    try w.writeAll(".SH COMMANDS\n");
    for (G.verbs) |v| {
        if (full) try verbRoff(G, w, tool, v, G.examples) else {
            try w.writeAll(".TP\n.BR ");
            try roff(w, tool);
            try w.writeAll("\\-");
            try name(w, v.name, .page, true);
            try w.writeAll(" (1)\n");
            try roff(w, v.summary);
            try w.writeAll("\n");
        }
    }
    try w.writeAll(".SH EXIT STATUS\n");
    for (exit_table) |row| {
        try w.print(".TP\n{d}\n", .{row[1]});
        try roff(w, row[0]);
        try w.writeAll("\n");
    }
}

/// Every man page: `<tool>.1`, then `<tool>-<verb>.1` per verb. Allocated
/// in `a` (use an arena).
pub fn manPages(comptime G: type, a: Allocator) ![]Page {
    const tool = G.schema.tool;
    var pages: std.ArrayList(Page) = .empty;
    var out: std.Io.Writer.Allocating = .init(a);
    try overview(G, &out.writer, false);
    try pages.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.1", .{tool}), .content = try out.toOwnedSlice() });
    for (G.verbs) |v| {
        var file: std.Io.Writer.Allocating = .init(a);
        try file.writer.print("{s}-", .{tool});
        try name(&file.writer, v.name, .page, false);
        try file.writer.writeAll(".1");
        var body: std.Io.Writer.Allocating = .init(a);
        const w = &body.writer;
        try th(w, tool, v.name);
        try w.writeAll(".SH NAME\n");
        try roff(w, tool);
        try w.writeAll("\\-");
        try name(w, v.name, .page, true);
        try w.writeAll(" \\- ");
        try roff(w, v.summary);
        try w.writeAll("\n.SH COMMAND\n");
        try verbRoff(G, w, tool, v, G.examples);
        try w.writeAll(".SH SEE ALSO\n.BR ");
        try roff(w, tool);
        try w.writeAll(" (1)\n");
        try pages.append(a, .{ .name = try file.toOwnedSlice(), .content = try body.toOwnedSlice() });
    }
    return pages.toOwnedSlice(a);
}

/// The single printable man page: the overview with every verb inline.
pub fn writeMan(comptime G: type, w: W) !void {
    try overview(G, w, true);
}
