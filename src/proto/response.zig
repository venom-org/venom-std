//! Client side of the wire protocol: decode a server message (`item`, `ok` or
//! `error`) and map errors to CLI exit codes.
const std = @import("std");
const errors = @import("errors.zig");
const Id = @import("dispatch.zig").Id;
const Value = std.json.Value;

pub const Response = struct {
    parsed: std.json.Parsed(Value),
    /// Null only for errors about a message whose id could not be read.
    id: ?Id,
    body: Body,

    pub const Body = union(enum) {
        item: Value,
        ok: Value,
        @"error": Error,
    };

    pub const Error = struct {
        code: []const u8,
        message: []const u8,
        data: ?Value,

        pub fn exitCode(self: Error) u8 {
            return errors.exitCode(self.code);
        }
    };

    /// Parse one line. Unknown members are ignored, for forward compatibility; a message
    /// that is not exactly one of item/ok/error is error.InvalidResponse.
    pub fn parse(gpa: std.mem.Allocator, line: []const u8) !Response {
        const parsed = std.json.parseFromSlice(Value, gpa, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const object = parsed.value.object;
        const raw_id = object.get("id") orelse return error.InvalidResponse;
        const id: ?Id = if (raw_id == .null) null else Id.fromValue(raw_id) orelse return error.InvalidResponse;
        var body: ?Body = null;
        var kinds: usize = 0;
        if (object.get("item")) |v| {
            kinds += 1;
            body = .{ .item = v };
        }
        if (object.get("ok")) |v| {
            kinds += 1;
            body = .{ .ok = v };
        }
        if (object.get("error")) |e| {
            kinds += 1;
            if (e != .object) return error.InvalidResponse;
            const code = e.object.get("code") orelse return error.InvalidResponse;
            const message = e.object.get("message") orelse return error.InvalidResponse;
            if (code != .string or message != .string) return error.InvalidResponse;
            body = .{ .@"error" = .{ .code = code.string, .message = message.string, .data = e.object.get("data") } };
        }
        if (kinds != 1) return error.InvalidResponse;
        if (id == null and body.? != .@"error") return error.InvalidResponse;
        return .{ .parsed = parsed, .id = id, .body = body.? };
    }

    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    /// True for the final message of a request (`ok` or `error`).
    pub fn final(self: Response) bool {
        return self.body != .item;
    }

    /// CLI exit code: 0 for `ok`, the class code for `error`.
    pub fn exitCode(self: Response) u8 {
        return switch (self.body) {
            .@"error" => |e| e.exitCode(),
            else => 0,
        };
    }
};

const testing = std.testing;

test "response: decode item, ok and error with exit codes" {
    var ok = try Response.parse(testing.allocator, "{\"id\":2,\"ok\":{\"text\":\"hi\"},\"extra\":1}");
    defer ok.deinit();
    try testing.expectEqual(@as(i64, 2), ok.id.?.integer);
    try testing.expectEqualStrings("hi", ok.body.ok.object.get("text").?.string);
    try testing.expect(ok.final());
    try testing.expectEqual(@as(u8, 0), ok.exitCode());

    var item = try Response.parse(testing.allocator, "{\"id\":\"s\",\"item\":null}");
    defer item.deinit();
    try testing.expectEqualStrings("s", item.id.?.string);
    try testing.expect(!item.final());

    var err = try Response.parse(testing.allocator, "{\"id\":3,\"error\":{\"code\":\"invalid_params.missing\",\"message\":\"m\",\"data\":{\"param\":\"text\"}}}");
    defer err.deinit();
    try testing.expectEqual(@as(u8, 2), err.exitCode());
    try testing.expectEqualStrings("text", err.body.@"error".data.?.object.get("param").?.string);

    var unknown = try Response.parse(testing.allocator, "{\"id\":null,\"error\":{\"code\":\"novel.thing\",\"message\":\"m\"}}");
    defer unknown.deinit();
    try testing.expectEqual(@as(u8, 1), unknown.exitCode());

    for ([_][]const u8{
        "[]",
        "{\"ok\":1}",
        "{\"id\":1}",
        "{\"id\":1,\"ok\":1,\"error\":{\"code\":\"x\",\"message\":\"m\"}}",
        "{\"id\":null,\"ok\":1}",
        "{\"id\":1,\"error\":{\"code\":1,\"message\":\"m\"}}",
        "{\"id\":1.5,\"ok\":1}",
        "not json",
    }) |line| try testing.expectError(error.InvalidResponse, Response.parse(testing.allocator, line));
}
