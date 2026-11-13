//! A package that depends on venom-std the way other venom repos will.
//! `zig build test` here proves every module resolves through build.zig.zon.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const venom_std = b.dependency("venom_std", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline for (.{ "iface", "proto", "cfg", "cli", "log", "secrets", "xdg", "supervisor" }) |name| {
        mod.addImport(name, venom_std.module(name));
    }

    // Products run the packaged conformance suite through this helper.
    _ = @import("venom_std").addConformance;
    _ = venom_std.path("conformance/agent_contract.py");

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Check that venom-std's modules import");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
