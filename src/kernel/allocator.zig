//! Memory allocator

const std = @import("std");
const List = std.DoublyLinkedList;

const linker = @import("linker.zig");

const Allocation = struct {
    ptr: usize,
    len: usize,

    node: List.Node,

    fn fromNode(node: *List.Node) *Allocation {
        return @fieldParentPtr("node", node);
    }
};

const Heap = struct {
    /// memory managed by this heap structure
    mem: struct {
        start: usize,
        end: usize,
    },

    allocations: List,

    fn from(mem: []u8) Heap {
        return .{
            .mem = mem,
            .allocations = .{},
        };
    }
};

var heap: Heap = undefined;

pub fn init() void {
    const start = linker.kernel_heap_start;
    const end = linker.kernel_heap_end;

    heap = .from(start[0 .. end - start]);
}

pub fn alloc(size: usize) ![*]u8 {
    _ = size;
    return error.OutOfMemory;
}

pub fn free(ptr: [*]u8, size: usize) void {
    init.call();
    _ = ptr;
    _ = size;
}
