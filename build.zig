const std = @import("std");

/// Modules exposed to dependents. Each one is importable on its own:
/// `dep.module("proto")`, `dep.module("cfg")`, and so on.
pub const modules = [_][]const u8{
    "iface",
    "proto",
    "cfg",
    "cli",
    "log",
    "secrets",
    "xdg",
    "supervisor",
};

/// Options for `addConformance`.
pub const ConformanceOptions = struct {
    /// venom-std's `conformance/agent_contract.py`, e.g.
    /// `b.dependency("venom_std", .{}).path("conformance/agent_contract.py")`.
    suite: std.Build.LazyPath,
    /// The product binary (daemon and CLI in one).
    exe: *std.Build.Step.Compile,
    /// The product's JSON profile (see the suite's docstring).
    profile: std.Build.LazyPath,
};

/// Run the agent-contract conformance suite against a
/// product binary. Products call it from their build.zig:
///
///     const check = @import("venom_std").addConformance(b, .{ ... });
///     b.step("test-conformance", "...").dependOn(&check.step);
///
/// Needs `python3` on PATH. The run fails unless every checklist item passes.
pub fn addConformance(b: *std.Build, options: ConformanceOptions) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(options.suite);
    run.addArtifactArg(options.exe);
    run.addFileArg(options.profile);
    run.setName(b.fmt("conformance {s}", .{options.exe.name}));
    run.has_side_effects = true;
    run.expectExitCode(0);
    return run;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all tests (unit, leak canary, consumer)");
    const unit_step = b.step("test-unit", "Run every module's unit tests");
    test_step.dependOn(unit_step);

    inline for (modules) |name| {
        const root = if (comptime std.mem.eql(u8, name, "iface"))
            "src/iface.zig"
        else
            "src/" ++ name ++ "/root.zig";

        const mod = b.addModule(name, .{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        if (!std.mem.eql(u8, name, "iface")) {
            mod.addImport("iface", b.modules.get("iface").?);
        }

        if (std.mem.eql(u8, name, "proto") or std.mem.eql(u8, name, "secrets") or std.mem.eql(u8, name, "log") or std.mem.eql(u8, name, "supervisor")) mod.link_libc = true;

        const tests = b.addTest(.{ .name = name, .root_module = mod });
        unit_step.dependOn(&b.addRunArtifact(tests).step);
    }

    b.modules.get("proto").?.addImport("xdg", b.modules.get("xdg").?);
    b.modules.get("cli").?.addImport("proto", b.modules.get("proto").?);
    b.modules.get("cfg").?.addImport("proto", b.modules.get("proto").?);
    b.modules.get("cfg").?.addImport("secrets", b.modules.get("secrets").?);
    b.modules.get("secrets").?.addImport("proto", b.modules.get("proto").?);
    b.modules.get("secrets").?.addImport("cli", b.modules.get("cli").?);
    b.modules.get("supervisor").?.addImport("log", b.modules.get("log").?);

    const echo = b.addExecutable(.{
        .name = "venom-echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/echo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = b.modules.get("cli").? },
                .{ .name = "proto", .module = b.modules.get("proto").? },
                .{ .name = "cfg", .module = b.modules.get("cfg").? },
                .{ .name = "log", .module = b.modules.get("log").? },
                .{ .name = "supervisor", .module = b.modules.get("supervisor").? },
                .{ .name = "xdg", .module = b.modules.get("xdg").? },
            },
        }),
    });
    b.installArtifact(echo);
    // venom-echo's own handlers (counter, sleep) against the real dispatcher.
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "venom-echo", .root_module = echo.root_module })).step);
    const cli_step = b.step("test-cli", "Exercise generated CLI over a real socket and reject invalid manifests");
    const cli_test = b.addSystemCommand(&.{"python3"});
    cli_test.addFileArg(b.path("test/cli/integration.py"));
    cli_test.addArtifactArg(echo);
    cli_test.addArg(b.graph.zig_exe);
    const cli_fixture = b.addExecutable(.{
        .name = "test-cli-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cli/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cli", .module = b.modules.get("cli").? }},
        }),
    });
    cli_test.addArtifactArg(cli_fixture);
    cli_test.has_side_effects = true;
    cli_test.expectExitCode(0);
    cli_step.dependOn(&cli_test.step);
    test_step.dependOn(cli_step);
    const cfg_test = b.addSystemCommand(&.{"python3"});
    cfg_test.addFileArg(b.path("test/cfg/integration.py"));
    cfg_test.addArtifactArg(echo);
    cfg_test.has_side_effects = true;
    cfg_test.expectExitCode(0);
    b.step("test-cfg", "Exercise typed config CLI/MCP round-trips over a real daemon").dependOn(&cfg_test.step);
    test_step.dependOn(&cfg_test.step);

    // Agent-contract conformance: the packaged suite against venom-echo.
    const conformance = addConformance(b, .{ .suite = b.path("conformance/agent_contract.py"), .exe = echo, .profile = b.path("conformance/venom-echo.json") });
    b.step("test-conformance", "Run the agent-contract conformance suite against venom-echo").dependOn(&conformance.step);
    test_step.dependOn(&conformance.step);
    // Products can exercise all stream checks using events alone.
    const event_conformance = addConformance(b, .{ .suite = b.path("conformance/agent_contract.py"), .exe = echo, .profile = b.path("conformance/venom-echo-events.json") });
    const event_step = b.step("test-conformance-events", "Exercise event-only conformance profiles and reject broken streams");
    event_step.dependOn(&event_conformance.step);
    const event_canaries = b.addSystemCommand(&.{"python3"});
    event_canaries.addFileArg(b.path("test/conformance/events.py"));
    event_canaries.addFileArg(b.path("conformance/agent_contract.py"));
    event_canaries.addArtifactArg(echo);
    event_canaries.addFileArg(b.path("conformance/venom-echo-events.json"));
    event_canaries.has_side_effects = true;
    event_canaries.expectExitCode(0);
    event_step.dependOn(&event_canaries.step);
    test_step.dependOn(event_step);
    const generation_canaries = b.addSystemCommand(&.{"python3"});
    generation_canaries.addFileArg(b.path("test/conformance/generation.py"));
    generation_canaries.addFileArg(b.path("conformance/agent_contract.py"));
    generation_canaries.has_side_effects = true;
    generation_canaries.expectExitCode(0);
    b.step("test-conformance-generation", "Check local and remote generation agreement canaries").dependOn(&generation_canaries.step);
    test_step.dependOn(&generation_canaries.step);
    // The suite isolates HOME, TMPDIR and every XDG dir, runtime included.
    const isolation = b.addSystemCommand(&.{"python3"});
    isolation.addFileArg(b.path("test/conformance/isolation.py"));
    isolation.addFileArg(b.path("conformance/agent_contract.py"));
    isolation.addArtifactArg(echo);
    isolation.addFileArg(b.path("conformance/venom-echo.json"));
    isolation.has_side_effects = true;
    isolation.expectExitCode(0);
    b.step("test-conformance-isolation", "Check that the conformance suite never reaches the caller's real dirs").dependOn(&isolation.step);
    test_step.dependOn(&isolation.step);
    // Canary: the suite must fail a profile whose "mutation" is read-only.
    const canary_conf = b.addSystemCommand(&.{"python3"});
    canary_conf.addFileArg(b.path("conformance/agent_contract.py"));
    canary_conf.addArtifactArg(echo);
    canary_conf.addFileArg(b.path("test/conformance/read-only-mutation.json"));
    canary_conf.setName("conformance canary");
    canary_conf.has_side_effects = true;
    canary_conf.expectStdOutMatch("not ok grants");
    canary_conf.expectExitCode(1);
    b.step("test-conformance-canary", "Check that the conformance suite fails a nonconforming profile").dependOn(&canary_conf.step);
    test_step.dependOn(&canary_conf.step);

    // Leak canary: a test that leaks must fail. This guards the guarantee that
    // `std.testing.allocator` turns leaks into test failures.
    const canary_step = b.step("test-leak-canary", "Check that a leaking test fails");
    const canary = b.addSystemCommand(&.{ b.graph.zig_exe, "test" });
    canary.addFileArg(b.path("test/leak/leak.zig"));
    // Match the leak report specifically (not just any failure); capturing
    // stderr also keeps the expected failure out of the build output.
    canary.expectStdErrMatch("1 tests leaked memory");
    canary.expectExitCode(1);
    canary.has_side_effects = true;
    canary_step.dependOn(&canary.step);
    test_step.dependOn(canary_step);

    // Consumer smoke test: a separate package that depends on venom-std
    // through its build.zig.zon, the same way other venom repos will.
    const consumer_step = b.step("test-consumer", "Build a package that depends on venom-std");
    const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    consumer.setCwd(b.path("test/consumer"));
    consumer.has_side_effects = true;
    consumer.expectExitCode(0);
    consumer_step.dependOn(&consumer.step);
    test_step.dependOn(consumer_step);
}
