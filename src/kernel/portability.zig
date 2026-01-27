const std = @import("std");

pub const stack_alignment = @bitSizeOf(usize) / std.mem.byte_size_in_bits;
