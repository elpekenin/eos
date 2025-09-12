//! Symbols prrovided by the linker script

// RAM to be filled on startup
extern var __kernel_data_start: anyopaque;
extern var __kernel_data_end: anyopaque;

// RAM to be initialized with zeroes
extern var __kernel_bss_start: anyopaque;
extern var __kernel_bss_end: anyopaque;

// RAM used by main process
extern var __kernel_stack_start: anyopaque;
extern var __kernel_stack_end: anyopaque;

// RAM to be used as heap (malloc/free)
extern var __kernel_heap_start: anyopaque;
extern var __kernel_heap_end: anyopaque;

// location of values stored in flash to be copied into RAM
extern var __kernel_data_source: anyopaque;

//
//
//

pub const data_start: [*]u8 = @ptrCast(&__kernel_data_start);
pub const data_end: [*]u8 = @ptrCast(&__kernel_data_end);

pub const bss_start: [*]u8 = @ptrCast(&__kernel_bss_start);
pub const bss_end: [*]u8 = @ptrCast(&__kernel_bss_end);

pub const stack_start: [*]u8 = @ptrCast(&__kernel_stack_start);
pub const stack_end: [*]u8 = @ptrCast(&__kernel_stack_end);

pub const heap_start: [*]u8 = @ptrCast(&__kernel_heap_start);
pub const heap_end: [*]u8 = @ptrCast(&__kernel_heap_end);

pub const data_source: [*]const u8 = @ptrCast(&__kernel_data_source);
