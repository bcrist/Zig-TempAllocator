# Zig-TempAllocator

A stack allocator similar to std.heap.ArenaAllocator, except:

- You can reset the whole allocator without releasing the underlying memory back to the OS.
- You can take a snapshot at any time and later invalidate/free all allocations after that point, but preserving allocations before it.
- It will track how much memory is usually used before being reset, and release some if it remains significantly lower than the current committed capacity.
- The inner "child allocator" is not configurable; internally it uses OS memory management facilities directly.

The primary use-cases for TempAllocator are real-time interactive programs and simulations (games, GUIs, etc.), but it can be useful for anything where work is done sequentially in a main loop, and it's easy to guarantee that memory allocated from it won't be held across resets.

## Usage Example

```zig
const std = @import("std");
const TempAllocator = @import("temp_allocator.zig");
const app = @import("myApp.zig");

pub fn main() void {
    var tempalloc = TempAllocator.init(1024*1024*1024); // 1GB of virtual address space
    defer tempalloc.deinit();

    var n: usize = 0;
    while (!app.shouldExit()) {
        tempalloc.reset();
        n += 1;

        var temp: []u8 = std.fmt.allocPrint(tempalloc.allocator(), "number {} is {s}", .{ n, "Something" });
        app.doSomethingWithAString(temp);
    }
}
```

## Zig Version

Last updated for `zig 0.12.0-dev.1591+3fc6a2f11`; use with significantly older or newer versions may require adjustments

## Implementation Notes

TempAllocator utilizes a fixed chunk of virtual address space to allocate from.  The size of this chunk must be specified when initializing the allocator, and can't be changed while the allocator is in use.  But the maximum size may be enormous (up to several terabytes on windows, and possibly even more on other systems).  This is because the full virtual address chunk won't be "committed" to physical memory and/or swap pages until it's actually used.

### Windows
The full virtual address chunk is allocated with:

    VirtualAlloc(null, capacity, MEM_RESERVE, PAGE_NOACCESS)

Then when regions need to be used, they're committed with:

    VirtualAlloc(ptr, len, MEM_COMMIT, PAGE_READWRITE)

Later, those regions may be decommitted with:

    VirtualFree(ptr, len, MEM_DECOMMIT)

### Linux/MacOS
The full virtual address chunk is allocated with:

    mmap(null, capacity, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE)

The use of `MAP_NORESERVE` means we open up the possibility of getting segfaults later when the allocator's memory is written to, if the system runs out of physical memory.  But linux's default `vm.overcommit_memory` sysctl means that can already happen for pretty much any allocation anyway.  Zig's use of errors to try to handle allocation failures is more or less useless on linux.

The full virtual address range is `mmap`ed as writable, but real pages won't be assigned until they're written to.  But we still keep track of "committed" pages so that later we can mark them unused when we would normally decommit them on Windows:

    madvise(ptr, len, MADV_DONTNEED)
