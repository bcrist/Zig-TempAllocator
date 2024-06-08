const std = @import("std");

// Exported directly in case you want to use TempAllocator in a build script
pub const Temp_Allocator = @import("Temp_Allocator.zig");

pub fn build(b: *std.Build) void {
    const temp_allocator = b.addModule("Temp_Allocator", .{
        .root_source_file = b.path("Temp_Allocator.zig"),
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("tests.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    tests.root_module.addImport("Temp_Allocator", temp_allocator);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
