//! Memory allocator

const std = @import("std");
const List = std.DoublyLinkedList;

const linker = @import("linker.zig");

var heap: Heap = undefined;

const Heap = struct {
    const Allocation = struct {
        ptr: [*]u8,
        len: usize,

        node: List.Node,

        fn fromNode(node: *List.Node) *Allocation {
            return @fieldParentPtr("node", node);
        }
    };

    /// memory managed by this heap structure
    mem: []u8,

    allocations: List,

    fn from(mem: []u8) Heap {
        return .{
            .mem = mem,
            .allocations = .{},
        };
    }
};

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
