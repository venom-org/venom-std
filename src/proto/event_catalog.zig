//! The event publisher catalog. Closed payload shapes enforce required and
//! forbidden fields; products may extend Log.catalog with their own additions.
const s = @import("schema.zig");
const str: s.Type = .{ .kind = .string };
const boolean: s.Type = .{ .kind = .boolean };
const exit: s.Type = .{ .kind = .integer, .min = 0, .max = 255 };
fn f(comptime name: []const u8, comptime t: s.Type, comptime required: bool) s.Field {
    return .{ .name = name, .summary = name, .type = t, .required = required };
}
const pane = f("pane", str, true);
const command = f("command", str, true);
const reason = f("reason", str, true);
const code = f("exit_code", exit, false);
const records: s.Type = .{ .kind = .array, .items = &.{ .kind = .object, .fields = &.{
    f("id", str, true),                                                f("state", .{ .kind = .string, .choices = &.{ "idle", "working", "done", "blocked", "error" } }, true),
    f("kind", str, false),                                             f("app", str, false),
    f("title", str, false),                                            f("msg", str, false),
    f("progress", .{ .kind = .integer, .min = 0, .max = 100 }, false),
} } };
pub const Entry = struct { name: []const u8, resource_kind: []const u8, fields: []const s.Field };
pub const entries = [_]Entry{
    .{ .name = "config.changed", .resource_kind = "config", .fields = &.{f("restart_required", boolean, true)} },
    .{ .name = "config.reloaded", .resource_kind = "config", .fields = &.{f("restart_required", boolean, true)} },
    .{ .name = "pane.created", .resource_kind = "pane", .fields = &.{ pane, f("session", str, true) } },
    .{ .name = "pane.title_changed", .resource_kind = "pane", .fields = &.{ pane, f("title", str, true) } },
    .{ .name = "pane.exited", .resource_kind = "pane", .fields = &.{ pane, code } },
    .{ .name = "pane.removed", .resource_kind = "pane", .fields = &.{pane} },
    .{ .name = "program.status_changed", .resource_kind = "pane", .fields = &.{ pane, reason, f("records", records, true) } },
    // The shell's untrusted command line from OSC 133 C.
    .{ .name = "command.started", .resource_kind = "pane", .fields = &.{ pane, command, f("cmdline", str, false) } },
    .{ .name = "command.finished", .resource_kind = "pane", .fields = &.{ pane, command, reason, code } },
};
