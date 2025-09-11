//! Database of supported target devices for the kernel

const std = @import("std");
const arm = std.Target.arm;

pub const Soc = enum {
    rp2040,
    /// doesn't compile
    /// 
    /// added as a way to design for multiple targets
    stm32h7s78,
};

pub const Info = struct {
    abi: std.Target.Abi,
    arch: std.Target.Cpu.Arch,
    model: *const std.Target.Cpu.Model,
    linker_script: ?[]const u8 = null,

    pub fn query(self: *const Info) std.Target.Query {
        return .{
            .cpu_arch = self.arch,
            .cpu_model = .{ .explicit = self.model },
            .os_tag = .freestanding,
            .abi = self.abi,
            .ofmt = .elf,
        };
    }
};

pub const database: std.enums.EnumMap(Soc, Info) = .init(.{
    .rp2040 = .{
        .abi = .eabi,
        .arch = .thumb,
        .model = &arm.cpu.cortex_m0plus,
    },
    .stm32h7s78 = .{
        .abi = .eabihf,
        .arch = .thumb,
        .model = &arm.cpu.cortex_m7,
    },
});
