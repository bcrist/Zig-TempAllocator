# Zig Temp Allocator

A stack allocator similar to std.heap.ArenaAllocator, except:

- A fixed amount of virtual address space will be used (which must be known at initialization time) but not all of it need be mapped to real pages unless needed.
- You can take a snapshot at any time and later invalidate/free all allocations after that point, but preserving allocations before it.
- It will track how much memory is usually used before being reset, and release some if it remains significantly lower than the current committed capacity.
- The inner "child allocator" is not configurable; internally it uses OS memory management facilities directly.

The primary use-cases are real-time interactive programs and simulations (games, GUIs, etc.), but it can be useful for anything where work is done sequentially in a main loop, and it's easy to guarantee that memory allocated from it won't be held across resets.

## Usage Example

```zig
const std = @import("std");
const Temp_Allocator = @import("Temp_Allocator");
const app = @import("whatever.zig");

pub fn main() void {
    var temp = Temp_Allocator.init(1024*1024*1024); // 1GB of virtual address space
    defer temp.deinit();

    var n: usize = 0;
    while (!app.shouldExit()) {
        temp.reset();
        n += 1;

        var temp: []u8 = std.fmt.allocPrint(temp.allocator(), "number {} is {s}", .{ n, "Something" });
        app.doSomethingWithAString(temp);
    }
}
```

## Implementation Notes

The allocator utilizes a fixed chunk of virtual address space to allocate from.  The size of this chunk must be specified when initializing the allocator, and can't be changed while the allocator is in use.  But the maximum size may be enormous (up to several terabytes on windows, and possibly even more on other systems).  This is because the full virtual address chunk won't be "committed" to physical memory and/or swap pages until it's actually used.

### Windows
The full virtual address chunk is allocated with:

    VirtualAlloc(null, capacity, MEM_RESERVE, PAGE_NOACCESS)

Then when regions need to be used, they're committed with:

    VirtualAlloc(ptr, len, MEM_COMMIT, PAGE_READWRITE)

Later, those regions may be decommitted with:

    VirtualFree(ptr, len, MEM_DECOMMIT)

### Linux/MacOS
The full virtual address chunk is allocated with:

    mmap(null, capacity, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE)

Then when regions need to be used, they're committed with:

    mprotect(ptr, len, PROT_READ | PROT_WRITE)

Later, those regions may be decommitted with:

    madvise(ptr, len, MADV_DONTNEED);
    mprotect(ptr, len, PROT_NONE);

The use of `MAP_NORESERVE` means we open up the possibility of getting segfaults later when the allocator's memory is written to, if the system runs out of physical memory.  But linux's default `vm.overcommit_memory` sysctl (and some other linux design decisions around OOM handling) means that out-of-memory conditions on linux simply can't be handled gracefully anyway.
