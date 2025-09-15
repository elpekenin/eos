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
    fp: usize,
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

        var self: Process = .{
            .context = .{
                .sp = sp,
                .pc = @intFromPtr(&asmTrampoline),
                .fp = undefined,
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
        // r7 (fp) is stored onto context
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

export var swap: *const Swap = undefined;

inline fn doSwitch(s: *const Swap) void {
    assert(Process.fromContext(s.prev) == current_process);
    current_process = Process.fromContext(s.next);
    swap = s;
    asmSwitch();
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

extern fn asmSwitch() callconv(cc) void;
extern fn asmTrampoline() callconv(cc) void;

comptime {
    switch (cpu.arch) {
        else => unreachable,
        .thumb => asm (
            \\.thumb_func
            \\.global asmTrampoline
            \\.type asmTrampoline, %function
            \\asmTrampoline:
            // Process.create pushes values such that args and entrypoint will get pop'ed into r0 and r1 when switching
            // as such, we can just call into entrypoint
            \\  blx r1
            // when entrypoint returns, exitcode is on r0, which is already ready to be arg0 for exit
            // we don't need to setup lr to come back, exit is noreturn
            \\  b exit
            \\
            // ---
            \\
            \\.thumb_func
            \\.global asmSwitch
            \\.type asmSwitch, %function
            \\asmSwitch:
            // backup registers into stack
            \\  push {r0-r6}
            \\
            \\  mov r0, r8
            \\  mov r1, r9
            \\  mov r2, r10
            \\  mov r3, r11
            \\  mov r4, r12
            \\  push {r0-r4}
            // load swap var
            \\  ldr r0, .swap
            // save special registers
            \\  ldr r1, [r0, #0]
            \\
            \\  mov r2, sp
            \\  str r2, [r1, #0]
            \\
            \\  mov r2, lr
            \\  str r2, [r1, #4]
            \\
            \\  mov r2, fp
            \\  str r2, [r1, #8]
            // restore special registers
            \\  ldr r1, [r0, #4]
            \\
            \\  ldr r2, [r1, #0]
            \\  mov sp, r2
            \\
            \\  ldr r2, [r1, #4]
            \\  mov lr, r2
            \\
            \\  ldr r2, [r1, #8]
            \\  mov fp, r2
            // restore registers from stack
            \\  pop {r0-r4}
            \\  mov r8, r0
            \\  mov r9, r1
            \\  mov r10, r2
            \\  mov r11, r3
            \\  mov r12, r4
            \\
            \\  pop {r0-r6}
            // jump back
            \\  bx lr
            // label to load global
            \\.swap:
            \\  .word swap
        ),
    }
}
