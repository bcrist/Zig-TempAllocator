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
//  - On other systems, the full virtual address space reservation can be read or written at any time, but
//    pages won't be assigned until they're written to for the first time.  "Committed" on these systems means
//    pages where that may be the case.

/// The amount of memory committed or uncommitted at a time will always be a multiple of this.
const commit_granularity = std.mem.alignForward(usize, 0x10000, std.mem.page_size);

/// Memory that has been committed, but not yet used for an allocation.
/// The allocator attempts to fulfill requests from this first.
available: []u8 = &[_]u8 {},
/// The maximum chunk of virtual address space that may be used by the allocator.
reservation: []align(std.mem.page_size) u8 = &[_]u8 {},
/// The number of bytes at the end of `reservation` which are not committed.
uncommitted: usize = 0,
/// If The maximum bytes used has decreased since the last time the allocator was reset,
/// this will store the maximum usage before the decrease.  It is only updated when
/// `available.len + uncommitted` increases; use `high_water_usage()` to query the actual
/// value including the current usage.
high_water: usize = 0,
/// An exponential moving average for estimating what the high water mark will be on the next reset.
usage_estimate: usize = 0,
/// The actual high water mark from the last time the allocator was reset.
prev_usage: usize = 0,

pub fn allocator(self: *Temp_Allocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
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

    switch (os) {
        .windows => {
            const w = std.os.windows;
            self.reservation.ptr = @alignCast(@ptrCast(try w.VirtualAlloc(null, max_capacity, w.MEM_RESERVE, w.PAGE_NOACCESS)));
            self.reservation.len = max_capacity;
        },
        else => {
            // N.B. We use MAP_NORESERVE to prevent clogging swap, but this does mean we open up the possibility of getting segfaults later
            // when the temporary allocator's memory is written to.  But linux's default vm.overcommit_memory sysctl means that can happen
            // for pretty much any allocation.  So Zig's use of errors to try to handle allocation failures is already broken on linux.
            const PROT = std.os.PROT;
            const MAP = std.os.MAP;
            self.reservation = try std.os.mmap(null, max_capacity, PROT.READ | PROT.WRITE, MAP.PRIVATE | MAP.ANONYMOUS | MAP.NORESERVE, -1, 0);
        }
    }

    self.uncommitted = self.reservation.len;
    self.available = self.reservation;
    self.available.len = 0;
}

pub fn deinit(self: *Temp_Allocator) void {
    if (self.reservation.len > 0) {
        switch (os) {
            .windows => {
                const w = std.os.windows;
                std.os.windows.VirtualFree(self.reservation.ptr, 0, w.MEM_RELEASE);
            },
            else => {
                std.os.munmap(self.reservation);
            },
        }
    }
    self.available = &[_]u8 {};
    self.reservation = &[_]u8 {};
    self.uncommitted = 0;
}

pub fn committed(self: *Temp_Allocator) usize {
    return self.reservation.len - self.uncommitted;
}

pub fn snapshot(self: *Temp_Allocator) usize {
    return self.reservation.len - self.uncommitted - self.available.len;
}

pub fn release_to_snapshot(self: *Temp_Allocator, snapshot_value: usize) void {
    const high_water = self.high_water_usage();
    self.high_water = high_water;
    std.debug.assert(snapshot_value <= high_water);

    const end_of_available = self.committed();
    self.available = self.reservation[snapshot_value..end_of_available];
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
        switch (os) {
            .windows => {
                const w = std.os.windows;
                w.VirtualFree(to_decommit.ptr, to_decommit.len, w.MEM_DECOMMIT);
            },
            else => {
                const MADV = std.os.MADV;
                std.os.madvise(@alignCast(to_decommit.ptr), to_decommit.len, MADV.DONTNEED) catch {
                    // ignore
                };
            },
        }

        committed_bytes = self.reservation.len - self.uncommitted;
    }

    self.available = self.reservation[0..committed_bytes];
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

fn alloc(ctx: *anyopaque, n: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
    _ = ra;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    const ptr_align = @as(usize, 1) << @intCast(log2_ptr_align);
    const align_offset = std.mem.alignPointerOffset(self.available.ptr, ptr_align) orelse return null;
    const needed = n + align_offset;
    if (needed > self.available.len) {

        const len_to_commit = std.mem.alignForward(usize, needed - self.available.len, commit_granularity);
        if (len_to_commit > self.uncommitted) {
            return null;
        }

        const end_of_available = self.committed();

        switch (os) {
            .windows => {
                const w = std.os.windows;
                _ = w.VirtualAlloc(self.reservation[end_of_available..].ptr, len_to_commit, w.MEM_COMMIT, w.PAGE_READWRITE) catch return null;
            },
            else => {
                // already mapped with RW access
            },
        }

        self.available = self.reservation[end_of_available - self.available.len .. end_of_available + len_to_commit];
        self.uncommitted -= len_to_commit;
    }

    const result = self.available[align_offset..needed];
    self.available = self.available[needed..];
    return result.ptr;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    _ = buf_align;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    if (buf.len >= new_len) {
        if (buf[buf.len..].ptr == self.available.ptr) {
            //shrinking the last allocation
            const high_water = self.high_water_usage();
            const end_of_available = self.committed();
            self.available = self.reservation[end_of_available - self.available.len - buf.len + new_len .. end_of_available];
            self.high_water = high_water;
        }
        return true;
    } else if (buf[buf.len..].ptr == self.available.ptr) {
        // expanding the last allocation
        const old_available = self.available;
        const end_of_available = self.committed();
        self.available = self.reservation[end_of_available - self.available.len - buf.len .. end_of_available];
        _ = alloc(ctx, new_len, 0, ret_addr) orelse {
            self.available = old_available;
            return false;
        };
        return true;
    } else {
        // can't expand an internal allocation
        return false;
    }
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    _ = buf_align;
    _ = ret_addr;

    const self: *Temp_Allocator = @ptrCast(@alignCast(ctx));

    if (buf[buf.len..].ptr == self.available.ptr) {
        // freeing the last allocation
        const high_water = self.high_water_usage();
        const end_of_available = self.committed();
        self.available = self.reservation[end_of_available - self.available.len - buf.len .. end_of_available];
        self.high_water = high_water;
    }
}

const Temp_Allocator = @This();
const os = @import("builtin").os.tag;
const std = @import("std");
