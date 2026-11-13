const std = @import("std");
const wire = @import("wire.zig");
const errors = @import("errors.zig");
const Connection = wire.Connection;
pub const Identity = struct { name: []const u8, version: []const u8 };
pub const Options = struct {
    identity: Identity,
    versions: []const i64 = &.{1},
    caps: []const []const u8 = &.{},
    max_frame: u32 = wire.default_max_frame,
    schema: ?[]const u8 = null,
};
pub fn validate(options: Options) !void {
    if (options.max_frame < 4096 or options.max_frame > wire.hard_max_frame or options.versions.len == 0) return error.InvalidOptions;
    for (options.versions) |v| if (v < 1 or v > 9007199254740991) return error.InvalidOptions;
}
pub fn encode(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}
pub fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
pub fn validId(id: std.json.Value) bool {
    return switch (id) {
        .integer => |i| i >= -9007199254740991 and i <= 9007199254740991,
        .string => |s| s.len <= 64,
        else => false,
    };
}
pub fn sendError(conn: *Connection, id: std.json.Value, code: []const u8, data: anytype) !void {
    const err = .{ .code = code, .message = errors.defaultMessage(code), .data = data };
    const bytes = if (conn.protocol == .binary)
        try encode(conn.gpa, err)
    else
        try encode(conn.gpa, .{ .id = id, .@"error" = err });
    defer conn.gpa.free(bytes);
    if (conn.protocol == .binary) {
        try conn.sendMessage(.{ .frame = .{ .kind = wire.Kind.err, .payload = bytes } });
    } else {
        // Rejected preambles receive NDJSON even though protocol is still sniff.
        try conn.sendMessage(.{ .ndjson = bytes });
    }
}

/// Negotiate into conn, keeping ownership of parsed hello for capability slices.
pub fn negotiate(conn: *Connection, params: std.json.Value, options: Options) !void {
    const versions = field(params, "proto") orelse return error.InvalidHello;
    if (versions != .array or versions.array.items.len == 0) return error.InvalidHello;
    var chosen: i64 = 0;
    for (versions.array.items) |v| {
        if (v != .integer or v.integer < 1 or v.integer > 9007199254740991) return error.InvalidHello;
        for (options.versions) |supported| if (v.integer == supported) {
            chosen = @max(chosen, supported);
        };
    }
    const max = field(params, "max_frame") orelse std.json.Value{ .integer = wire.default_max_frame };
    if (max != .integer or max.integer < 4096 or max.integer > wire.hard_max_frame) return error.InvalidHello;
    if (field(params, "caps")) |caps| {
        if (caps != .array) return error.InvalidHello;
        for (caps.array.items) |cap| if (cap != .string) return error.InvalidHello;
    }
    if (chosen == 0) return error.VersionMismatch;
    if (field(params, "caps")) |caps| {
        try conn.caps.ensureUnusedCapacity(conn.gpa, caps.array.items.len);
        for (caps.array.items) |cap| {
            for (options.caps) |supported| {
                if (std.mem.eql(u8, cap.string, supported) and !conn.hasCap(supported))
                    conn.caps.appendAssumeCapacity(cap.string);
            }
        }
    }
    conn.version = chosen;
    conn.max_frame = @min(options.max_frame, @as(u32, @intCast(max.integer)));
}
pub fn result(conn: *Connection, options: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(conn.gpa);
    defer arena.deinit();
    const principal = if (conn.registry) |r| try @import("grant_verbs.zig").principalValue(arena.allocator(), r, conn.identity, conn.identity.principal) else null;
    return encode(conn.gpa, .{ .proto = conn.version, .server = options.identity, .caps = conn.caps.items, .max_frame = conn.max_frame, .schema = options.schema, .principal = principal });
}
