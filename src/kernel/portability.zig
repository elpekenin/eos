const std = @import("std");
const cpu = @import("builtin").target.cpu;

pub const Word = switch (cpu.arch) {
    else => unreachable,
    .thumb => u32,
};

pub const stack_alignment = switch (cpu.arch) {
    else => unreachable,
    .thumb => 8,
};

comptime {
    std.debug.assert(std.math.isPowerOfTwo(@sizeOf(Word)));
    std.debug.assert(std.math.isPowerOfTwo(stack_alignment));
}