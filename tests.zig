const std = @import("std");
const TempAllocator = @import("temp_allocator.zig");

const expectEqual = std.testing.expectEqual;

test "TempAllocator" {
    var ta = try TempAllocator.init(1024 * 1024 * 1024 * 1024); // 1 TB
    defer ta.deinit();

    try expectEqual(@as(usize, 0), ta.highWaterUsage());
    try expectEqual(@as(usize, 0), ta.committed());

    var alloc: std.mem.Allocator = ta.allocator();

    var temp = try alloc.alloc(u8, 17);
    try expectEqual(@as(usize, 17), temp.len);
    try expectEqual(@as(usize, 0x10000), ta.committed());

    temp = try alloc.alloc(u8, 300000);
    try expectEqual(@as(usize, 300000), temp.len);
    try expectEqual(@as(usize, 300017), ta.highWaterUsage());
    try expectEqual(@as(usize, 0x50000), ta.committed());

    for (temp) |*b| {
        b.* = 13;
    }

    ta.reset();
    try expectEqual(@as(usize, 0), ta.highWaterUsage());
    try expectEqual(@as(usize, 0x50000), ta.committed());

    temp = try alloc.alloc(u8, 1000);
    const snapshot = ta.snapshot();
    try expectEqual(@as(usize, 1000), snapshot);

    temp = try alloc.alloc(u8, 1000);
    try expectEqual(@as(usize, 2000), ta.highWaterUsage());
    ta.releaseToSnapshot(snapshot);
    try expectEqual(@as(usize, 1000), ta.snapshot());
    try expectEqual(@as(usize, 2000), ta.highWaterUsage());

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        // std.debug.print("{}: estimate: {}\tcommitted: {}\n", .{ i, ta.usage_estimate, ta.committed() });
        ta.reset();
    }

    try expectEqual(@as(usize, 0x30000), ta.committed());
}
