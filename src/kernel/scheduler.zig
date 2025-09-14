//! Utilities for multi-processing
//!
//! References for assembly
//!   - https://developer.arm.com/documentation/dui0662/b/The-Cortex-M0--Processor/Programmers-model/Core-registers
//!   - https://github.com/Ashet-Technologies/Ashet-OS/blob/master/src/kernel/components/scheduler.zig

const std = @import("std");
const assert = std.debug.assert;
const logger = std.log.scoped(.scheduler);
const Queue = std.DoublyLinkedList;
const cpu = @import("builtin").target.cpu;

// const kmem = @import("kmem.zig");

comptime {
    const v6m: std.Target.arm.Feature = .v6m;
    const is_v6m = cpu.features.isEnabled(@intFromEnum(v6m));

    if (cpu.arch == .thumb and !is_v6m) {
        const msg = "code only supports armv6m (CortexM0+) for now";
        @compileError(msg);
    }
}

/// this is equivalent to = .c, AFAICT
pub const cc: std.builtin.CallingConvention = switch (cpu.arch) {
    else => unreachable,
    .thumb => .{ .arm_aapcs = .{} },
};

/// This data structure is used by the assembly code, do not change it
const Context = extern struct {
    sp: usize,
    pc: usize,
};

/// This data structure is used by the assembly code, do not change it
const Swap = extern struct {
    prev: *Context,
    next: *Context,
};

var current_process: ?*Process = null;

var queue: Queue = .{};

fn nextProcess() ?*Process {
    const node = queue.popFirst() orelse return null;
    return Process.fromNode(node);
}

const kernel = struct {
    var stack: [128]u8 align(4) = undefined;

    var process: Process = .{
        .context = undefined,
        .stack = &stack,
        .exit_code = null,
        .node = .{},
    };
};

fn getKernelProcess() *Process {
    return &kernel.process;
}

pub const Process = struct {
    pub const Args = ?*anyopaque;
    pub const ExitCode = usize;
    pub const Entrypoint = *const fn (Args) callconv(cc) ExitCode;

    context: Context,
    exit_code: ?ExitCode,
    node: Queue.Node,
    stack: []u8,

    pub fn create(entrypoint: Entrypoint, args: Args, stack: []u8) Process {
        const sp = @intFromPtr(stack.ptr) + stack.len;
        assert(sp & 0b11 == 0); // 4-byte aligned

        // TODO: insert entrypoint and args information
        var self: Process = .{
            .context = .{
                .sp = sp,
                .pc = @intFromPtr(&trampoline),
            },
            .stack = stack,
            .exit_code = null,
            .node = .{},
        };

        self.push(0); // r12 (unused)
        self.push(0); // r11 (unused)
        self.push(0); // r10 (unused)
        self.push(0); // r9 (unused)
        self.push(0); // r8 (unused)
        // self.push(0); // r7 is reserved as fp
        self.push(0); // r6 (unused)
        self.push(0); // r5 (unused)
        self.push(0); // r4 (unused)
        self.push(0); // r3 (unused)
        self.push(0); // r2 (unused)
        self.push(@intFromPtr(entrypoint)); // r1
        self.push(@intFromPtr(args)); // r0

        return self;
    }

    fn fromNode(node: *Queue.Node) *Process {
        return @fieldParentPtr("node", node);
    }

    fn fromContext(context: *Context) *Process {
        return @fieldParentPtr("context", context);
    }

    fn stackBase(self: *const Process) usize {
        return @intFromPtr(self.stack.ptr);
    }

    fn push(self: *Process, value: usize) void {
        self.context.sp -= @sizeOf(usize);
        std.debug.assert(self.context.sp >= self.stackBase());

        const ptr: *usize = @ptrFromInt(self.context.sp);
        ptr.* = value;
    }
};

pub fn init() void {
    // no-op for now
}

pub fn run() void {
    std.debug.assert(current_process == null);

    const next = nextProcess() orelse {
        logger.warn("no processes in queue, nothing to do", .{});
        return;
    };

    // without this, assert on doSwitch would fail
    current_process = getKernelProcess();

    doSwitch(&.{
        .prev = &getKernelProcess().context,
        .next = &next.context,
    });

    current_process = null; // cleanup
}

inline fn doSwitch(swap: *const Swap) void {
    assert(Process.fromContext(swap.prev) == current_process);
    current_process = Process.fromContext(swap.next);

    if (cpu.arch != .thumb) unreachable;

    // backup registers into stack
    asm volatile (
        \\push {r0-r6}
        \\
        \\mov r0, r8
        \\mov r1, r9
        \\mov r2, r10
        \\mov r3, r11
        \\mov r4, r12
        \\push {r0-r4}
        ::: .{
            .r0 = true,
            .r1 = true,
            .r2 = true,
            .r3 = true,
            .r4 = true,
            .r13 = true, // sp
            .memory = true,
        });

    // save special registers
    asm volatile (
        \\ldr r1, [r0, #0]
        \\
        \\mov r2, sp
        \\str r2, [r1, #0]
        \\
        \\mov r2, lr
        \\str r2, [r1, #4]
        :
        : [in] "{r0}" (swap),
        : .{
          .r1 = true,
          .r2 = true,
          .memory = true,
        });

    // restore special registers
    asm volatile (
        \\ldr r1, [r0, #4]
        \\
        \\ldr r2, [r1, #0]
        \\mov sp, r2
        \\
        \\ldr r2, [r1, #4]
        \\mov lr, r2
        ::: .{
            .r1 = true,
            .r2 = true,
            .r13 = true, // sp
            .r14 = true, // lr
        });

    // restore registers from stack
    asm volatile (
        \\pop {r0-r4}
        \\mov r8, r0
        \\mov r9, r1
        \\mov r10, r2
        \\mov r11, r3
        \\mov r12, r4
        \\
        \\pop {r0-r6}
        ::: .{
            .r0 = true,
            .r1 = true,
            .r2 = true,
            .r3 = true,
            .r4 = true,
            .r5 = true,
            .r6 = true,
            // .r7 = true, // reserved as fp
            .r8 = true,
            .r9 = true,
            .r10 = true,
            .r11 = true,
            .r12 = true,
            .r13 = true, // sp
        });

    // jump back
    asm volatile ("bx lr");
}

fn trampoline() callconv(cc) void {
    switch (cpu.arch) {
        else => unreachable,
        .thumb => {
            asm volatile (
                \\
                // Process.create pushes args and entrypoint such that they will pop into r0 and r1
                // we can just call into entrypoint
                \\blx r1
                // when entrypoint returns, exitcode is on r0, which is already ready to be arg0 for exit
                // we don't need to setup a link back before jumping, exit is noreturn
                \\b exit
                ::: .{
                    .r0 = true,
                });
        },
    }
}

/// this function simply adds a node to the processes' queue
pub fn enqueue(process: *Process) void {
    queue.append(&process.node);
}

pub export fn yield() void {
    const prev = current_process orelse @panic("kernel called yield()");
    queue.append(&prev.node);

    // just added `old` to queue, we will surely get a new value out (at least, pop'ing it back)
    const next = nextProcess() orelse unreachable;

    doSwitch(&.{
        .prev = &prev.context,
        .next = &next.context,
    });
}

export fn exit(code: Process.ExitCode) callconv(cc) noreturn {
    const prev = current_process orelse @panic("kernel called exit()");

    queue.remove(&prev.node);
    prev.exit_code = code;

    const next = nextProcess() orelse getKernelProcess();

    doSwitch(&.{
        .prev = &prev.context,
        .next = &next.context,
    });

    @panic("unreachable after switching back from ending processs");
}
