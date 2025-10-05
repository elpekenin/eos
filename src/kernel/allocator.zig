//! Memory allocator

const std = @import("std");

const linker = @import("linker.zig");

// SAFETY: will be set prior to usage
var heap: std.heap.FixedBufferAllocator = undefined;

pub fn init() void {
    var buffer: []u8 = undefined;
    buffer.ptr = @ptrCast(&linker.__kernel_heap_start);
    buffer.len = @intFromPtr(&linker.__kernel_heap_end) - @intFromPtr(&linker.__kernel_heap_start);

    heap = .init(buffer);
}

pub fn allocator() std.mem.Allocator {
    return heap.allocator();
}
