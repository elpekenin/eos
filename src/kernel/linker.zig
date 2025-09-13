//! Symbols prrovided by the linker script

// RAM to be filled on startup
pub extern var __kernel_data_start: anyopaque;
pub extern var __kernel_data_end: anyopaque;

// RAM to be initialized with zeroes
pub extern var __kernel_bss_start: anyopaque;
pub extern var __kernel_bss_end: anyopaque;

// RAM used by main process
pub extern var __kernel_stack_start: anyopaque;
pub extern var __kernel_stack_end: anyopaque;

// RAM to be used as heap (malloc/free)
pub extern var __kernel_heap_start: anyopaque;
pub extern var __kernel_heap_end: anyopaque;

// location of values stored in flash to be copied into RAM
pub extern var __kernel_data_source: anyopaque;
