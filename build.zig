const std = @import("std");

pub fn build(b: *std.Build) void {
    const temp_allocator = b.addModule("TempAllocator", .{
        .source_file = .{ .path = "TempAllocator.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "tests.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    tests.addModule("TempAllocator", temp_allocator);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
