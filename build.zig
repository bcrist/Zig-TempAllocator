// Exported directly in case you want to use Temp_Allocator in a build script
pub const Temp_Allocator = @import("Temp_Allocator.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();

    const commit_granularity_desc = "The amount of memory committed or uncommitted at a time will always be a multiple of this (after aligning to the page size).  Defaults to 0x10000.";
    options.addOption(usize, "commit_granularity", b.option(usize, "commit_granularity", commit_granularity_desc) orelse 0x10000);

    const temp_allocator = b.addModule("Temp_Allocator", .{
        .root_source_file = b.path("Temp_Allocator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "options", .module = options.createModule() },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Temp_Allocator", .module = temp_allocator },
            },
        }),
    });
    b.installArtifact(tests);
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(tests).step);
}

const std = @import("std");
