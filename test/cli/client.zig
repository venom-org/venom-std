//! Transport fixture: generated CLI without product handler code.
const std = @import("std");
const cli = @import("cli");
const manifest = .{ .format = 1, .tool = "test-cli", .summary = "Transport fixture", .verbs = .{
    .{ .name = "watch", .summary = "Watch", .grant = .read, .streams = true, .item = .{ .kind = .string }, .result = .{ .kind = .null } },
    .{ .name = "report", .summary = "Report", .grant = .read, .result = .{ .kind = .object, .fields = .{
        .{ .name = "status", .summary = "Exit status", .type = .{ .kind = .integer, .min = 0, .max = 255 }, .required = true },
    } }, .exit = .{ .kind = .result, .field = "status" } },
} };
const App = cli.WithBootstrap(cli.manifest.normalize(manifest), &.{}, .{ .startup = .{ .verb = "report", .summary = "Fixture local startup policy" }, .local = .{
    .{ .name = "attach", .summary = "Interactive fixture", .interactive = true, .result = .{ .kind = .object, .fields = .{} } },
    .{ .name = "inspect", .summary = "Offline fixture", .params = .{.{ .name = "name", .summary = "Name", .type = .{ .kind = .string }, .default = "default" }}, .result = .{ .kind = .string }, .errors = .{.{ .code = "not_found.target", .summary = "Target missing" }} },
} });
var interrupted: std.atomic.Value(bool) = .init(false);
fn interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .monotonic);
}
const Launcher = struct {
    mode: ?[]const u8,
    marker: ?[]const u8,
    pub fn prepare(self: *@This(), _: cli.runtime.Startup.Context) anyerror!?u32 {
        return if (self.mode != null) 300 else null;
    }
    pub fn launch(self: *@This(), ctx: cli.runtime.Startup.Context) anyerror!void {
        if (self.marker) |path| {
            const z = try ctx.allocator.dupeSentinel(u8, path, 0);
            const fd = std.c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
            if (fd < 0) return error.StartupFailed;
            _ = std.c.close(fd);
        }
        if (self.mode) |mode| {
            if (std.mem.eql(u8, mode, "race")) return error.AlreadyRunning;
            if (std.mem.eql(u8, mode, "failed-winner")) return error.StartupFailed;
        }
    }
    pub fn poll(_: *@This(), _: cli.runtime.Startup.Context) anyerror!cli.runtime.Startup.Status {
        return .pending;
    }
};
const Presentation = struct {
    pub const commands = .{ "attach", "inspect" };
    pub fn call(_: *@This(), ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
        if (std.mem.eql(u8, ctx.name, "attach")) return .{ .result = .{ .object = .empty } };
        const name = ctx.params.object.get("name").?.string;
        if (std.mem.eql(u8, name, "missing")) return .{ .failure = .{ .code = "not_found.target", .message = "target missing" } };
        return .{ .result = .{ .string = name } };
    }
};
pub fn main(init: std.process.Init) !void {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = interrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var launcher: Launcher = .{ .mode = init.environ_map.get("TEST_STARTUP"), .marker = init.environ_map.get("TEST_STARTUP_MARKER") };
    var presentation: Presentation = .{};
    const status = try App.run(init.gpa, argv[1..], .{ .stdout = &out.interface, .stderr = &err.interface, .interrupted = &interrupted, .startup = cli.runtime.Startup.init(&launcher), .local = cli.Local.init(&presentation) });
    try out.interface.flush();
    try err.interface.flush();
    if (status != 0) std.process.exit(status);
}
