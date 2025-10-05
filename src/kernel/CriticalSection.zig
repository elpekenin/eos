const cpu = @import("builtin").target.cpu;

const CriticalSection = @This();

enabled: bool,

fn areInterruptsEnabled() bool {
    switch (cpu.arch) {
        else => unreachable,
        .thumb => {
            var primask: usize = 0;
            asm volatile ("mrs %[out], primask" : [out] "=r" (primask) :: .{
                .memory = true,
            });
            return (primask & 1) == 0;
        }
    }
}

fn disableInterrupts() void {
    switch (cpu.arch) {
        else => unreachable,
        .thumb => asm volatile ("cpsid i"),
    }
}

fn enableInterrupts() void {
    switch (cpu.arch) {
        else => unreachable,
        .thumb => asm volatile ("cpsie i"),
    }
}

pub fn enter() CriticalSection {
    const self: CriticalSection = .{
        .enabled = areInterruptsEnabled(),
    };

    if (self.enabled) {
        disableInterrupts();
    }

    return self;
}

pub fn exit(self: *const CriticalSection) void {
    if (self.enabled) {
        enableInterrupts();
    }
}
