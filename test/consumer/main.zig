const std = @import("std");
const iface = @import("iface");

test "consumer: every venom-std module imports on its own" {
    _ = @import("proto");
    _ = @import("cfg");
    _ = @import("cli");
    _ = @import("log");
    _ = @import("secrets");
    _ = @import("xdg");
    _ = @import("supervisor");
}

const Counter = struct {
    n: u32 = 0,
    pub fn bump(self: *Counter) void {
        self.n += 1;
    }
};

test "consumer: iface helper works from a dependent package" {
    const VTable = struct { bump: *const fn (*anyopaque) void };
    comptime iface.assertImplements(VTable, Counter);
    var c: Counter = .{};
    iface.cast(Counter, &c).bump();
    try std.testing.expectEqual(@as(u32, 1), c.n);
}

test "consumer: CLI generator carries its protocol dependency" {
    const cli = @import("cli");
    const App = cli.Generator(.{ .format = 1, .tool = "consumer", .summary = "Consumer", .verbs = .{} });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectEqual(@as(u8, 0), try App.run(std.testing.allocator, &.{ "--help", "--json" }, .{ .stdout = &out.writer, .stderr = &err.writer }));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "consumer") != null);
}
