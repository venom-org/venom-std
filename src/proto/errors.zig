//! Error codes, classes and their stable CLI exit codes.
const std = @import("std");

/// Error classes. The integer value is the CLI exit code and is
/// part of the public contract: never renumber. 12–63 are reserved.
pub const Class = enum(u8) {
    failed = 1,
    invalid_params = 2,
    not_found = 3,
    denied = 4,
    conflict = 5,
    unavailable = 6,
    timeout = 7,
    cancelled = 8,
    protocol = 9,
    unsupported = 10,
    internal = 11,

    pub fn exitCode(self: Class) u8 {
        return @backingInt(self);
    }
};

/// The class of `code`: the part before the first `.`. Unknown classes are
/// `failed`, as clients must treat them.
pub fn class(code: []const u8) Class {
    const head = code[0 .. std.mem.indexOfScalar(u8, code, '.') orelse code.len];
    return std.meta.stringToEnum(Class, head) orelse .failed;
}

/// CLI exit code for an error code. Success is 0.
pub fn exitCode(code: []const u8) u8 {
    return class(code).exitCode();
}

/// True if `code` is `<class>` or `<class>.<detail>…`, every component
/// matching `[a-z][a-z0-9_]*`. The class itself may be unknown.
pub fn validCode(code: []const u8) bool {
    var parts = std.mem.splitScalar(u8, code, '.');
    while (parts.next()) |part| if (!validName(part)) return false;
    return true;
}

/// True if `code` is valid and its class is one of the fixed classes; what a
/// daemon may emit.
pub fn knownCode(code: []const u8) bool {
    const head = code[0 .. std.mem.indexOfScalar(u8, code, '.') orelse code.len];
    return validCode(code) and std.meta.stringToEnum(Class, head) != null;
}

/// `[a-z][a-z0-9_]*`
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

/// One-line English text for the errors `proto` itself emits. Not stable.
pub fn defaultMessage(code: []const u8) []const u8 {
    const table = .{
        .{ "protocol.parse", "line is not a JSON object" },
        .{ "protocol.invalid_request", "request needs an integer or short string 'id' and a string 'verb'" },
        .{ "protocol.duplicate_id", "a request with this id is already in flight" },
        .{ "protocol.too_large", "message exceeds max_frame" },
        .{ "protocol.bad_preamble", "first byte must be '{' (NDJSON) or 0xF5 (binary)" },
        .{ "protocol.bad_frame", "invalid frame" },
        .{ "protocol.hello_required", "HELLO must be the first frame" },
        .{ "protocol.hello_order", "hello must be the first request and is allowed once" },
        .{ "protocol.version_mismatch", "no common protocol version" },
        .{ "invalid_params.hello", "invalid hello params" },
        .{ "unsupported.verb", "unknown verb" },
        .{ "unsupported.capability", "capability not negotiated" },
        .{ "cancelled", "cancelled by client" },
        .{ "internal.result", "handler result does not match the verb schema" },
    };
    inline for (table) |entry| if (std.mem.eql(u8, entry[0], code)) return entry[1];
    return code;
}

test "exit codes follow the error class and unknown classes are failed" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 2), exitCode("invalid_params.missing"));
    try t.expectEqual(@as(u8, 3), exitCode("not_found.pane"));
    try t.expectEqual(@as(u8, 4), exitCode("denied"));
    try t.expectEqual(@as(u8, 5), exitCode("conflict.already_running"));
    try t.expectEqual(@as(u8, 6), exitCode("unavailable.not_running"));
    try t.expectEqual(@as(u8, 7), exitCode("timeout"));
    try t.expectEqual(@as(u8, 8), exitCode("cancelled"));
    try t.expectEqual(@as(u8, 9), exitCode("protocol.parse"));
    try t.expectEqual(@as(u8, 10), exitCode("unsupported.verb"));
    try t.expectEqual(@as(u8, 11), exitCode("internal"));
    try t.expectEqual(@as(u8, 1), exitCode("failed.launch"));
    try t.expectEqual(@as(u8, 1), exitCode("brand_new_class.detail"));
    try t.expectEqual(@as(u8, 1), exitCode(""));
    try t.expectEqual(@as(u8, 1), exitCode("not_foundx"));
}

test "code syntax" {
    const t = std.testing;
    try t.expect(validCode("conflict.echo_busy"));
    try t.expect(validCode("future_class"));
    try t.expect(!knownCode("future_class"));
    try t.expect(knownCode("not_found.request"));
    try t.expect(!validCode("Not_found"));
    try t.expect(!validCode("not_found."));
    try t.expect(!validCode(".x"));
    try t.expect(!validCode("a.9b"));
    try t.expect(!validCode(""));
}
