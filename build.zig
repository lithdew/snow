const std = @import("std");

const pkgs = struct {
    const pike = std.build.Pkg{
        .name = "pike",
        .path = "pike/pike.zig",
    };
};

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const test_runner = b.addTest("test.zig");
    test_runner.setBuildMode(mode);
    test_runner.setTarget(target);
    test_runner.addPackage(pkgs.pike);

    const test_step = b.step("test", "Runs the test suite.");
    test_step.dependOn(&test_runner.step);
}
