const std = @import("std");

// Exported directly in case you want to use Temp_Allocator in a build script
pub const Temp_Allocator = @import("Temp_Allocator.zig");

pub fn build(b: *std.Build) void {
    const temp_allocator = b.addModule("Temp_Allocator", .{
        .root_source_file = b.path("Temp_Allocator.zig"),
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .imports = &.{
                .{ .name = "Temp_Allocator", .module = temp_allocator },
            },
        }),
    });
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(tests).step);
}
