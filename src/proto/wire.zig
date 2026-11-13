const std = @import("std");
const os = @import("os.zig");

pub const default_max_frame = 1024 * 1024;
pub const hard_max_frame = 16 * 1024 * 1024;
pub const Protocol = enum { sniff, ndjson, binary };
pub const Frame = struct { kind: u16, stream: u32 = 0, payload: []const u8 };
pub const Message = union(enum) { ndjson: []const u8, frame: Frame };
pub const Kind = struct {
    pub const hello = 1;
    pub const hello_ok = 2;
    pub const err = 3;
    pub const ping = 4;
    pub const pong = 5;
    pub const close = 6;
    pub const control = 0x10;
};

/// A buffered non-blocking socket. Message slices remain valid until consume()
/// or read(). All allocations and output queues are bounded by explicit limits.
pub const Connection = struct {
    gpa: std.mem.Allocator,
    fd: os.c.fd_t,
    protocol: Protocol = .sniff,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    consumed: usize = 0,
    max_frame: u32 = default_max_frame,
    output_limit: usize = 8 * 1024 * 1024,
    ready: bool = false,
    closing: bool = false,
    deadline_ms: i64,
    /// The parsed hello owns the negotiated capability strings.
    hello: ?std.json.Parsed(std.json.Value) = null,
    caps: std.ArrayList([]const u8) = .empty,
    version: i64 = 0,
    registry: ?*@import("grants.zig").Registry = null,
    identity: @import("grants.zig").Identity = .{},
    audit: ?*@import("audit.zig").Log = null,

    pub fn init(gpa: std.mem.Allocator, fd: os.c.fd_t) Connection {
        return .{ .gpa = gpa, .fd = fd, .deadline_ms = os.nowMs() + 10_000 };
    }
    pub fn deinit(self: *Connection) void {
        os.close(self.fd);
        // Requests and responses may carry credentials, so buffers are zeroed.
        std.crypto.secureZero(u8, self.input.allocatedSlice());
        std.crypto.secureZero(u8, self.output.allocatedSlice());
        self.input.deinit(self.gpa);
        self.output.deinit(self.gpa);
        self.caps.deinit(self.gpa);
        if (self.hello) |h| h.deinit();
        self.* = undefined;
    }
    pub fn hasCap(self: *const Connection, name: []const u8) bool {
        for (self.caps.items) |cap| if (std.mem.eql(u8, cap, name)) return true;
        return false;
    }
    pub fn queue(self: *Connection, bytes: []const u8) !void {
        if (self.output.items.len - self.sent + bytes.len > self.output_limit) return error.SlowReader;
        if (self.sent > 0) {
            const left = self.output.items.len - self.sent;
            std.mem.copyForwards(u8, self.output.items[0..left], self.output.items[self.sent..]);
            self.output.items.len = left;
            self.sent = 0;
        }
        try self.output.appendSlice(self.gpa, bytes);
    }
    pub fn sendMessage(self: *Connection, message: Message) !void {
        switch (message) {
            .ndjson => |line| {
                if (line.len + 1 > self.max_frame) return error.TooLarge;
                if (std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidMessage;
                if (self.protocol == .binary) return self.sendMessage(.{ .frame = .{ .kind = Kind.control, .payload = line } });
                if (self.output.items.len - self.sent + line.len + 1 > self.output_limit) return error.SlowReader;
                try self.output.ensureUnusedCapacity(self.gpa, line.len + 1);
                try self.queue(line);
                try self.queue("\n");
            },
            .frame => |f| {
                if (f.payload.len > self.max_frame) return error.TooLarge;
                if (self.protocol != .binary) return error.InvalidMessage;
                var header: [10]u8 = undefined;
                std.mem.writeInt(u16, header[0..2], f.kind, .big);
                std.mem.writeInt(u32, header[2..6], f.stream, .big);
                std.mem.writeInt(u32, header[6..10], @intCast(f.payload.len), .big);
                if (self.output.items.len - self.sent + 10 + f.payload.len > self.output_limit) return error.SlowReader;
                try self.output.ensureUnusedCapacity(self.gpa, 10 + f.payload.len);
                try self.queue(&header);
                try self.queue(f.payload);
            },
        }
    }
    pub fn flush(self: *Connection) !void {
        // One syscall per tick bounds the work done for a writable peer.
        if (self.sent < self.output.items.len) {
            const n = (try os.send(self.fd, self.output.items[self.sent..])) orelse return;
            if (n == 0) return error.Disconnected;
            self.sent += n;
        }
        if (self.sent == self.output.items.len) {
            std.crypto.secureZero(u8, self.output.items);
            self.output.clearRetainingCapacity();
            self.sent = 0;
        }
    }
    pub fn read(self: *Connection) !bool {
        self.consume();
        var buf: [8192]u8 = undefined;
        // Bound buffering to a single message plus one socket-read of lookahead.
        if (self.input.items.len >= @as(usize, self.max_frame) + 10) return error.TooLarge;
        const n = (try os.recv(self.fd, &buf)) orelse return false;
        if (n == 0) return error.EndOfStream;
        try self.input.appendSlice(self.gpa, buf[0..n]);
        return true;
    }
    pub fn consume(self: *Connection) void {
        if (self.consumed == 0) return;
        const left = self.input.items.len - self.consumed;
        std.mem.copyForwards(u8, self.input.items[0..left], self.input.items[self.consumed..]);
        // Consumed requests do not linger in spare capacity.
        std.crypto.secureZero(u8, self.input.items[left..]);
        self.input.items.len = left;
        self.consumed = 0;
    }
    pub fn next(self: *Connection) !?Message {
        self.consume();
        const bytes = self.input.items;
        if (self.protocol == .sniff) {
            if (bytes.len == 0) return null;
            switch (bytes[0]) {
                '{' => self.protocol = .ndjson,
                0xf5 => {
                    self.protocol = .binary;
                    self.consumed = 1;
                },
                else => return error.BadPreamble,
            }
            self.deadline_ms = os.nowMs() + 10_000;
            return self.next();
        }
        switch (self.protocol) {
            .ndjson => {
                const end = std.mem.indexOfScalar(u8, bytes, '\n') orelse {
                    if (bytes.len >= self.max_frame) return error.TooLarge;
                    return null;
                };
                if (end + 1 > self.max_frame) return error.TooLarge;
                self.consumed = end + 1;
                return .{ .ndjson = bytes[0..end] };
            },
            .binary => {
                if (bytes.len < 10) return null;
                const len = std.mem.readInt(u32, bytes[6..10], .big);
                if (len > self.max_frame) return error.TooLarge;
                if (bytes.len < 10 + @as(usize, len)) return null;
                self.consumed = 10 + @as(usize, len);
                return .{ .frame = .{
                    .kind = std.mem.readInt(u16, bytes[0..2], .big),
                    .stream = std.mem.readInt(u32, bytes[2..6], .big),
                    .payload = bytes[10..][0..len],
                } };
            },
            .sniff => unreachable,
        }
    }
};
