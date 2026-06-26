test {
    var ta: Temp_Allocator = try .init(1024 * 1024 * 1024 * 1024); // 1 TB
    defer ta.deinit();

    try expectEqual(@as(usize, 0), ta.high_water_usage());
    try expectEqual(@as(usize, 0), ta.committed());

    var alloc: std.mem.Allocator = ta.allocator();

    var temp = try alloc.alloc(u8, 17);
    try expectEqual(@as(usize, 17), temp.len);
    try expectEqual(@as(usize, 0x10000), ta.committed());

    temp = try alloc.alloc(u8, 300000);
    try expectEqual(@as(usize, 300000), temp.len);
    try expectEqual(@as(usize, 300017), ta.high_water_usage());
    try expectEqual(@as(usize, 0x50000), ta.committed());

    for (temp) |*b| {
        b.* = 13;
    }

    ta.reset(.{});
    try expectEqual(@as(usize, 0), ta.high_water_usage());
    try expectEqual(@as(usize, 0x50000), ta.committed());

    temp = try alloc.alloc(u8, 1000);
    const snapshot = ta.snapshot();
    try expectEqual(@as(usize, 1000), snapshot);

    temp = try alloc.alloc(u8, 1000);
    try expectEqual(@as(usize, 2000), ta.high_water_usage());
    ta.release_to_snapshot(snapshot);
    try expectEqual(@as(usize, 1000), ta.snapshot());
    try expectEqual(@as(usize, 2000), ta.high_water_usage());

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        // std.debug.print("{}: estimate: {}\tcommitted: {}\n", .{ i, ta.usage_estimate, ta.committed() });
        ta.reset(.{});
    }

    try expectEqual(@as(usize, 0x30000), ta.committed());
}

test "concurrent usage" {
    const num_threads = 100;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .limited(num_threads) });
    defer threaded.deinit();

    var ta: Temp_Allocator = try .init(1024 * 1024 * 1024 * 1024); // 1 TB
    defer ta.deinit();

    var group: std.Io.Group = .init;

    var latch: std.atomic.Value(u32) = .init(0);

    for (0..num_threads) |n| {
        try group.concurrent(threaded.io(), concurrent_temp_allocator_func, .{ n, ta.allocator_thread_safe(), &latch });
    }

    latch.store(1, .monotonic);

    try group.await(threaded.io());

    // std.log.err("high water: {B}", .{ ta.high_water_usage() });
}

fn concurrent_temp_allocator_func(n: usize, alloc: std.mem.Allocator, latch: *std.atomic.Value(u32)) void {
    while (latch.load(.monotonic) == 0) {}

    concurrent_temp_allocator_impl(alloc) catch |err| {
        std.log.err("thread {}: {t}", .{ n, err });
        if (@errorReturnTrace()) |ert| std.debug.dumpErrorReturnTrace(ert);
    };
}

fn concurrent_temp_allocator_impl(alloc: std.mem.Allocator) !void {
    const p1 = try alloc.alloc(u8, 1);
    defer alloc.free(p1);

    const p2 = try alloc.alloc(u8, 2);
    defer alloc.free(p2);

    const p3 = try alloc.alloc(u64, 1);
    defer alloc.free(p3);

    var p4 = try alloc.alloc(u8, 3);
    defer alloc.free(p4);

    if (alloc.resize(p4, 1)) {
        p4.len = 1;
    } else return error.ResizeShrinkFailed;

    for (0..1000) |n| {
        const p9 = try alloc.alloc(u32, n);
        defer alloc.free(p9);

        const p5 = try alloc.alloc(u8, 1);
        defer alloc.free(p5);

        const p6 = try alloc.alloc(u8, 1);
        defer alloc.free(p6);

        const p7 = try alloc.alloc(u8, 1);
        defer alloc.free(p7);

        const p8 = try alloc.alloc(u8, 1);
        defer alloc.free(p8);
    }
}

const expectEqual = std.testing.expectEqual;
const Temp_Allocator = @import("Temp_Allocator");
const std = @import("std");
