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

const kmem = @import("allocator.zig");
const CriticalSection = @import("CriticalSection.zig");

comptime {
    const v6m: std.Target.arm.Feature = .v6m;
    const is_v6m = cpu.features.isEnabled(@intFromEnum(v6m));

    if (cpu.arch == .thumb and !is_v6m) {
        const msg = "scheduler only supports armv6m (CortexM0+) for now";
        @compileError(msg);
    }
}

pub const stack_alignment = switch (cpu.arch) {
    else => unreachable,
    .thumb => 8,
};

/// This data structure is used by assembly, do not change it
const Context = switch (cpu.arch) {
    else => unreachable,
    .thumb => extern struct {
        sp: usize, // r13
        fp: usize, // r11
        pc: usize, // r15
    },
};

var current_process: ?*Process = null;

var queue: Queue = .{};

fn nextProcess() ?*Process {
    const node = queue.popFirst() orelse return null;
    return Process.fromNode(node);
}

const kernel = struct {
    var stack: [128]u8 align(stack_alignment) = @splat(0);
    var process: Process = undefined;

    fn run(_: Process.Args) callconv(.c) Process.ExitCode {
        @panic("kernel's main should not run");
    }
};

fn getKernelProcess() *Process {
    const S = struct {
        var init = false;
    };

    if (!S.init) {
        S.init = true;

        kernel.process = .create(kernel.run, null, &kernel.stack, "kernel");
    }

    return &kernel.process;
}

pub const Process = struct {
    pub const Args = *anyopaque;
    pub const ExitCode = usize;
    pub const Entrypoint = *const fn (Args) callconv(.c) ExitCode;

    name: []const u8,
    context: Context,
    exit_code: ?ExitCode,
    node: Queue.Node,
    stack: []u8,

    pub fn create(entrypoint: Entrypoint, args: ?Args, stack: []align(stack_alignment) u8, name: []const u8) Process {
        assert(stack.len % stack_alignment == 0);

        var sp = @intFromPtr(stack.ptr) + stack.len;
        assert(sp % stack_alignment == 0);

        const Data = extern struct {
            func: Entrypoint,
            args: ?Args,
        };

        // push args and entrypoint
        sp = std.mem.alignBackward(usize, sp - @sizeOf(Data), @alignOf(Data));

        const data: *Data = @ptrFromInt(sp);
        data.* = .{
            .func = entrypoint,
            .args = args,
        };

        assert(sp % stack_alignment == 0);

        return .{
            .name = name,
            .context = .{
                .sp = sp,
                .fp = 0,
                .pc = @intFromPtr(&trampoline),
            },
            .stack = stack,
            .exit_code = null,
            .node = .{},
        };
    }

    pub const SpawnOptions = struct {
        stack_size: usize = 512,
        name: ?[]const u8 = null,
    };

    pub fn spawn(entrypoint: Entrypoint, args: ?Args, comptime options: SpawnOptions) !Process {
        const stack = try kmem.allocator().alignedAlloc(
            u8,
            .fromByteUnits(stack_alignment),
            options.stack_size,
        );
        return .create(entrypoint, args, stack, options.name orelse "anonymous");
    }

    fn fromNode(node: *Queue.Node) *Process {
        return @fieldParentPtr("node", node);
    }
};

pub fn run() void {
    assert(current_process == null);

    const next = nextProcess() orelse {
        logger.warn("no processes in queue, nothing to do", .{});
        return;
    };

    const kernel_process = getKernelProcess();

    // without this, assert on doSwitch would fail
    current_process = kernel_process;
    doSwitch(kernel_process, next);
    current_process = null; // cleanup
}

inline fn doSwitch(noalias prev: *Process, noalias next: *Process) void {
    const cs: CriticalSection = .enter();
    defer cs.exit();

    if (prev == next) {
        logger.debug("prev == next ({s}), noop", .{prev.name});
        return;
    }

    assert(prev == current_process);
    current_process = next;

    logger.debug("switching '{s}' -> '{s}'", .{
        prev.name,
        next.name,
    });

    switch (cpu.arch) {
        else => unreachable,
        .thumb => asm volatile (
        // Calculate return address and set Thumb bit
        // CRITICAL: adds r2, #1 sets LSB to indicate Thumb mode
            \\ adr r2, 0f
            \\ adds r2, #1
            \\ mov r3, sp
            \\ str r3, [r0, #0]
            \\ str r7, [r0, #4]
            \\ str r2, [r0, #8]
            \\
            \\ ldr r3, [r1, #0]
            \\ mov sp, r3
            \\ ldr r7, [r1, #4]
            \\ ldr r2, [r1, #8]
            \\ bx r2
            \\
            \\.balign 4
            \\0:
            :
            : [_] "{r0}" (&prev.context),
              [_] "{r1}" (&next.context),
            : .{
              .r0 = true,
              .r1 = true,
              .r2 = true,
              .r3 = true,
              .r4 = true,
              .r5 = true,
              .r6 = true,
              .r7 = false, // frame pointer (saved)
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = false, // stack pointer (saved)
              .r14 = true, // link register (could be clobbered)
              .d0 = true,
              .d1 = true,
              .d2 = true,
              .d3 = true,
              .d4 = true,
              .d5 = true,
              .d6 = true,
              .d7 = true,
              .d8 = true,
              .d9 = true,
              .d10 = true,
              .d11 = true,
              .d12 = true,
              .d13 = true,
              .d14 = true,
              .d15 = true,
              .d16 = true,
              .d17 = true,
              .d18 = true,
              .d19 = true,
              .d20 = true,
              .d21 = true,
              .d22 = true,
              .d23 = true,
              .d24 = true,
              .d25 = true,
              .d26 = true,
              .d27 = true,
              .d28 = true,
              .d29 = true,
              .d30 = true,
              .d31 = true,
            //   .fpscr = true,
              .memory = true,
            }),
    }
}

/// execute entrypoint(args), reading them from process' stack
fn trampoline() callconv(.naked) noreturn {
    switch (cpu.arch) {
        else => unreachable,
        .thumb => asm volatile (
            \\ ldr r0, [sp, #4] // args
            \\ ldr r2, [sp, #0] // entrypoint
            \\ bx r2
            // TODO: call exit
        ),
    }
}

/// this function simply adds a node to the processes' queue
pub fn enqueue(process: *Process) void {
    queue.append(&process.node);
}

pub export fn yield() void {
    const prev = current_process orelse @panic("kernel called yield()");
    queue.append(&prev.node);

    // just added `old` to queue, we will surely get a new value out (at the very least, pop'ing it back)
    const next = nextProcess() orelse unreachable;

    doSwitch(prev, next);
}

export fn exit(code: Process.ExitCode) callconv(.c) noreturn {
    const prev = current_process orelse @panic("kernel called exit()");

    queue.remove(&prev.node);
    prev.exit_code = code;

    const next = nextProcess() orelse getKernelProcess();

    doSwitch(prev, next);
    @panic("unreachable after switching back from ending processs");
}
