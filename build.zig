const std = @import("std");
const deps = @import("deps.zig");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const test_runner = b.addTest("test.zig");
    test_runner.use_stage1 = true;
    test_runner.setBuildMode(mode);
    test_runner.setTarget(target);
    deps.addAllTo(test_runner);

    const test_step = b.step("test", "Runs the test suite.");
    test_step.dependOn(&test_runner.step);
}
