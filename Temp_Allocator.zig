// This allocator utilizes a fixed chunk of virtual address space to allocate from.  The size
// of this chunk must be specified when initializing the allocator, and can't be changed without
// first `deinit`ing all the memory first.  But this maximum size may be enormous, because it
// won't be "committed" to physical memory and/or swap pages until it's actually used.
//
// If the amount of memory used decreases significantly for many `reset`s in a row, some committed
// memory may be released back to the OS, reducing the apparent memory usage without giving up the
// virtual address space reservation.
//
// When this file refers to "committed" memory, it means subtly different things on Windows vs. other OS's:
//  - On windows it means memory that has been allocated with `VirtualAlloc(..., MEM_COMMIT...)`.
//    Uncommitted memory on Windows will trigger an access violation if read or written.
//    See details here: https://docs.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualalloc
//  - On other systems, the full virtual address space reservation is `mmap`ed with `PROT_NONE` and then
//    converted to `PROT_READ | PROT_WRITE` as necessary

/// The amount of memory committed or uncommitted at a time will always be a multiple of this.
const commit_granularity = std.mem.alignForward(usize, 0x10000, std.heap.page_size_min);

/// The maximum chunk of virtual address space that may be used by the allocator.
reservation: []u8 = &[_]u8 {},
/// The number of bytes at the beginning of `reservation` which have already been allocated and/or can't be used for a new allocation.
consumed: usize = 0,
/// The number of bytes at the end of `reservation` which are not committed.
uncommitted: usize = 0,
/// If The maximum bytes used has decreased since the last time the allocator was reset,
/// this will store the maximum usage before the decrease.  It is only updated when `consumed`
/// decreases; use `high_water_usage()` to query the actual value including the current usage.
high_water: usize = 0,
/// An exponential moving average for estimating what the high water mark will be on the next reset.
usage_estimate: usize = 0,
/// The actual high water mark from the last time the allocator was reset.
prev_usage: usize = 0,

/// Using this at the same time as the interface returned by `thread_safe_allocator` is not thread safe.
pub fn allocator(self: *Temp_Allocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

/// Provides a lock free thread safe `Allocator` interface to the underlying `Temp_Allocator`
/// Using this at the same time as the interface returned by `allocator` is not thread safe.
/// Using this at the same time as methods outside this interface (e.g. snapshot, release_to_snapshot, reset) is not thread safe.
pub fn allocator_thread_safe(self: *Temp_Allocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc_thread_safe,
            .resize = resize_thread_safe,
            .remap = remap_thread_safe,
            .free = free_thread_safe,
        },
    };
}

pub fn init(max_capacity: usize) !Temp_Allocator {
    var self = Temp_Allocator {};
    try self.reserve(max_capacity);
    return self;
}

pub fn reserve(self: *Temp_Allocator, max_capacity: usize) !void {
    std.debug.assert(self.reservation.len == 0);

    switch (builtin.os.tag) {
        .windows => {
            const w = std.os.windows;
            var base_addr: ?*anyopaque = null;
            var size: usize = max_capacity;
            const status = w.ntdll.NtAllocateVirtualMemory(w.current_process, @ptrCast(&base_addr), 0, &size, .{ .RESERVE = true }, .{ .NOACCESS = true });
            if (status != w.NTSTATUS.SUCCESS) return error.OutOfMemory;
            self.reservation.ptr = @ptrCast(base_addr);
            self.reservation.len = size;
        },
        else => {
            // N.B. We use MAP_NORESERVE to prevent clogging swap, but this does mean we open up the possibility of getting segfaults later
            // when the temporary allocator's memory is written to.  But linux's default vm.overcommit_memory sysctl means that can happen
            // for pretty much any allocation.  So Zig's use of errors to try to handle allocation failures is already broken on linux.
            self.reservation = try std.posix.mmap(null, max_capacity, .{}, .{
                .TYPE = .PRIVATE,
                .ANONYMOUS = true,
                .NORESERVE = true,
            }, -1, 0);
        }
    }

    self.uncommitted = self.reservation.len;
    self.consumed = 0;
}

pub fn deinit(self: *Temp_Allocator) void {
    if (self.reservation.len > 0) {
        switch (builtin.os.tag) {
            .windows => {
                const w = std.os.windows;
                var base_addr: ?*anyopaque = self.reservation.ptr;
                var size: usize = 0;
                _ = w.ntdll.NtFreeVirtualMemory(w.current_process, @ptrCast(&base_addr), &size, .{ .RELEASE = true });
            },
            else => {
                std.posix.munmap(@alignCast(self.reservation));
            },
        }
    }
    self.reservation = &[_]u8 {};
    self.consumed = 0;
    self.uncommitted = 0;
}

pub fn available(self: *Temp_Allocator) usize {
    return self.reservation.len - self.consumed;
}

pub fn committed(self: *Temp_Allocator) usize {
    return self.reservation.len - self.uncommitted;
}

pub fn committed_available(self: *Temp_Allocator) usize {
    return self.reservation.len - self.uncommitted - self.consumed;
}

pub fn snapshot(self: *Temp_Allocator) usize {
    return self.consumed;
}

pub fn release_to_snapshot(self: *Temp_Allocator, snapshot_value: usize) void {
    const high_water = self.high_water_usage();
    self.high_water = high_water;
    std.debug.assert(snapshot_value <= high_water);
    self.consumed = snapshot_value;
}

pub fn high_water_usage(self: *Temp_Allocator) usize {
    return @max(self.high_water, self.snapshot());
}

pub const Reset_Params = struct {
    usage_contraction_rate: u16 = 1,
    usage_expansion_rate: u16 = 64,
    fast_usage_expansion_rate: u16 = 1024,
    // The defaults above give an impulse response "half-life" for usage_estimate as follows:
    //     ~11 cycles after an increase
    //     ~710 cycles after a decrease
    // If the initially committed range overflows two cycles in a row, it will be expanded on the second reset.
};
pub fn reset(self: *Temp_Allocator, comptime params: Reset_Params) void {
    const high_water = self.high_water_usage();
    const new_usage_estimate = self.compute_usage_estimate(high_water, params);
    var committed_bytes = self.reservation.len - self.uncommitted;
    const max_committed = std.mem.alignForward(usize, new_usage_estimate + commit_granularity, commit_granularity);

    if (committed_bytes > max_committed) {
        const to_decommit = self.reservation[max_committed..committed_bytes];
        self.uncommitted = self.reservation.len - max_committed;
        switch (builtin.os.tag) {
            .windows => {
                const w = std.os.windows;
                var base_addr: ?*anyopaque = to_decommit.ptr;
                var size: usize = to_decommit.len;
                _ = w.ntdll.NtFreeVirtualMemory(w.current_process, @ptrCast(&base_addr), &size, .{ .DECOMMIT = true });
            },
            else => {
                std.posix.madvise(@alignCast(to_decommit.ptr), to_decommit.len, std.posix.MADV.DONTNEED) catch {
                    // ignore
                };
                _ = std.posix.system.mprotect(@alignCast(@ptrCast(to_decommit.ptr)), to_decommit.len, .{});
            },
        }

        committed_bytes = self.reservation.len - self.uncommitted;
    }

    self.consumed = 0;
    self.high_water = 0;
    self.usage_estimate = new_usage_estimate;
    self.prev_usage = high_water;
}

fn compute_usage_estimate(self: *Temp_Allocator, usage: usize, comptime params: Reset_Params) usize {
    const last_usage_estimate = self.usage_estimate;
    const initial_committed_bytes = std.mem.alignForward(usize, last_usage_estimate + commit_granularity, commit_granularity);
    if (last_usage_estimate == 0) {
        return usage;
    } else if (usage > last_usage_estimate) {
        if (usage > initial_committed_bytes and self.prev_usage > initial_committed_bytes) {
            const delta = @max(usage, self.prev_usage) - last_usage_estimate;
            return last_usage_estimate + scale_usage_delta(delta, params.fast_usage_expansion_rate);
        } else {
            const avg_usage = usage / 2 + self.prev_usage / 2;
            if (avg_usage > last_usage_estimate) {
                return last_usage_estimate + scale_usage_delta(avg_usage - last_usage_estimate, params.usage_expansion_rate);
            } else {
                return last_usage_estimate;
            }
        }
    } else if (usage < last_usage_estimate) {
        return last_usage_estimate - scale_usage_delta(last_usage_estimate - usage, params.usage_contraction_rate);
    } else {
        return last_usage_estimate;
    }
}

fn scale_usage_delta(delta: usize, comptime scale: usize) usize {
    return @max(1, if (delta >= (1 << 20)) delta / 1024 * scale else delta * scale / 1024);
}

fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    const align_offset = std.mem.alignPointerOffset(self.reservation.ptr + self.consumed, alignment.toByteUnits()) orelse return null;
    const needed = n + align_offset;
    const have = self.committed_available();
    if (needed > have) {
        const len_to_commit = std.mem.alignForward(usize, needed - have, commit_granularity);
        if (len_to_commit > self.uncommitted) return null;
        if (!commit(self.reservation[self.committed()..][0..len_to_commit])) return null;
        self.uncommitted -= len_to_commit;
    }

    const result = self.reservation[self.consumed + align_offset ..][0..n];
    self.consumed += needed;
    return result.ptr;
}

fn alloc_thread_safe(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));
    const ptr_align = alignment.toByteUnits();

    var observed_consumed = @atomicLoad(usize, &self.consumed, .monotonic);
    var observed_uncommitted = @atomicLoad(usize, &self.uncommitted, .monotonic);
    while (true) {
        const align_offset = std.mem.alignPointerOffset(self.reservation.ptr + observed_consumed, ptr_align) orelse return null;
        const needed = n + align_offset;
        const have = self.reservation.len -| (observed_uncommitted + observed_consumed);
        if (needed > have) {
            const len_to_commit = std.mem.alignForward(usize, needed - have, commit_granularity);
            if (len_to_commit > observed_uncommitted) return null;
            if (!commit(self.reservation[self.reservation.len - observed_uncommitted ..][0..len_to_commit])) return null;
            const new_uncommitted = observed_uncommitted - len_to_commit;
            const found_uncommitted = @atomicRmw(usize, &self.uncommitted, .Min, new_uncommitted, .monotonic);
            observed_uncommitted = @min(new_uncommitted, found_uncommitted);
            continue;
        }

        const new_consumed = observed_consumed + needed;
        observed_consumed = @cmpxchgWeak(usize, &self.consumed, observed_consumed, new_consumed, .acquire, .monotonic) orelse {
            return self.reservation.ptr + observed_consumed + align_offset;
        };
    }
}

fn commit(to_commit: []u8) bool {
    switch (builtin.os.tag) {
        .windows => {
            const w = std.os.windows;
            var base_addr: ?*anyopaque = to_commit.ptr;
            var size: usize = to_commit.len;
            const status = w.ntdll.NtAllocateVirtualMemory(w.current_process, @ptrCast(&base_addr), 0, &size, .{ .COMMIT = true }, .{ .READWRITE = true });
            switch (status) {
                w.NTSTATUS.SUCCESS, w.NTSTATUS.ALREADY_COMMITTED => {},
                else => return false,
            }
            std.debug.assert(base_addr == @as(?*anyopaque, to_commit.ptr));
            std.debug.assert(size == to_commit.len);
        },
        else => {
            const status = std.posix.system.mprotect(@alignCast(@ptrCast(to_commit.ptr)), to_commit.len, .{ .READ = true, .WRITE = true });
            if (status != 0) return false;
        },
    }
    return true;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    // "`alignment` must equal the same value that was passed as the `alignment` parameter to the original `alloc` call."
    //   - std.mem.Allocator VTable
    //if (std.mem.alignPointerOffset(memory.ptr, alignment.toByteUnits()) != 0) return false;

    const is_last_alloc = memory.ptr + memory.len == self.reservation.ptr + self.consumed;

    if (new_len <= memory.len) {
        if (is_last_alloc) {
            const high_water = self.high_water_usage();
            self.consumed = self.consumed - (memory.len - new_len);
            self.high_water = high_water;
        }
        return true;
    }

    if (!is_last_alloc) return false;

    self.consumed -= memory.len;
    const result = alloc(ctx, new_len, alignment, ret_addr) orelse {
        self.consumed += memory.len;
        return false;
    };
    std.debug.assert(result == memory.ptr);
    return true;
}

fn resize_thread_safe(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = alignment;
    _ = ret_addr;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    const observed_consumed = @atomicLoad(usize, &self.consumed, .monotonic);
    const is_last_alloc = memory.ptr + memory.len == self.reservation.ptr + observed_consumed;

    if (new_len <= memory.len) {
        if (is_last_alloc) {
            const new_consumed = observed_consumed - (memory.len - new_len);
            if (@cmpxchgStrong(usize, &self.consumed, observed_consumed, new_consumed, .release, .monotonic) == null) {
                _ = @atomicRmw(usize, &self.high_water, .Max, observed_consumed, .monotonic);
            }
        }
        return true;
    }

    if (!is_last_alloc) return false;

    var observed_uncommitted = @atomicLoad(usize, &self.uncommitted, .monotonic);
    while (true) {
        const needed = new_len - memory.len;
        const have = self.reservation.len -| (observed_uncommitted + observed_consumed);
        if (needed > have) {
            const len_to_commit = std.mem.alignForward(usize, needed - have, commit_granularity);
            if (len_to_commit > observed_uncommitted) return false;
            if (!commit(self.reservation[self.reservation.len - observed_uncommitted ..][0..len_to_commit])) return false;
            const new_uncommitted = observed_uncommitted - len_to_commit;
            const found_uncommitted = @atomicRmw(usize, &self.uncommitted, .Min, new_uncommitted, .monotonic);
            observed_uncommitted = @min(new_uncommitted, found_uncommitted);
            continue;
        }

        const new_consumed = observed_consumed + needed;
        return @cmpxchgWeak(usize, &self.consumed, observed_consumed, new_consumed, .acquire, .monotonic) == null;
    }
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn remap_thread_safe(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize_thread_safe(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    const is_last_alloc = memory.ptr + memory.len == self.reservation.ptr + self.consumed;
    if (is_last_alloc) {
        const high_water = self.high_water_usage();
        self.consumed -= memory.len;
        self.high_water = high_water;
    }
}

fn free_thread_safe(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    const observed_consumed = @atomicLoad(usize, &self.consumed, .monotonic);
    const is_last_alloc = memory.ptr + memory.len == self.reservation.ptr + observed_consumed;
    if (!is_last_alloc) return;

    const new_consumed = observed_consumed - memory.len;
    if (@cmpxchgStrong(usize, &self.consumed, observed_consumed, new_consumed, .release, .monotonic) == null) {
        _ = @atomicRmw(usize, &self.high_water, .Max, observed_consumed, .monotonic);
    }
}

const Temp_Allocator = @This();
const builtin = @import("builtin");
const std = @import("std");
