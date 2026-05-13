const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("mustache", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // demo executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("mustache", lib_mod);
    const exe = b.addExecutable(.{
        .name = "mustache-demo",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    // unit tests
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // spec conformance runner
    const spec_mod = b.createModule(.{
        .root_source_file = b.path("tests/spec_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_mod.addImport("mustache", lib_mod);
    const spec_exe = b.addExecutable(.{
        .name = "mustache-spec",
        .root_module = spec_mod,
    });
    const run_spec = b.addRunArtifact(spec_exe);
    run_spec.step.dependOn(b.getInstallStep());
    const spec_step = b.step("spec", "Run the Mustache spec conformance suite");
    spec_step.dependOn(&run_spec.step);
}
