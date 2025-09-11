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
    .thumb => .{ .arm_aapcs = .{} },
    else => unreachable,
};

var current_process: ?*Process = null;

export var save_process: *Process = undefined;
export var restore_process: *Process = undefined;

var queue: Queue = .{};

fn nextProcess() ?*Process {
    const node = queue.popFirst() orelse return null;
    return .from(node);
}

const kernel = struct {
    var stack: [256]u8 = undefined;

    var process: Process = .{
        .pc = undefined,
        .sp = undefined,
        .stack = &stack,
        .exit_code = null,
        .node = .{},
    };
};

pub const Process = struct {
    pub const Args = ?*anyopaque;
    pub const ExitCode = usize;
    pub const Entrypoint = *const fn (Args) callconv(cc) ExitCode;

    pc: usize,
    sp: usize,
    stack: []u8,
    exit_code: ?ExitCode,

    node: Queue.Node,

    pub fn create(entrypoint: Entrypoint, args: Args, stack: []u8) Process {
        var self: Process = .{
            .pc = @intFromPtr(&asmTrampoline),
            .sp = @intFromPtr(stack.ptr) + stack.len,
            .stack = stack,
            .exit_code = null,
            .node = .{},
        };

        switch (cpu.arch) {
            .thumb => {
                self.push(0); // ip (unused)
                self.push(0); // fp (unused)
                self.push(0); // r10 (unused)
                self.push(0); // r9 (unused)
                self.push(0); // r8 (unused)
                self.push(@intFromPtr(entrypoint)); // r7
                self.push(0); // r6 (unused)
                self.push(0); // r5 (unused)
                self.push(0); // r4 (unused)
                self.push(0); // r3 (unused)
                self.push(0); // r2 (unused)
                self.push(0); // r1 (unused)
                self.push(@intFromPtr(args)); // r0
            },
            else => unreachable,
        }

        return self;
    }

    fn from(node: *Queue.Node) *Process {
        return @fieldParentPtr("node", node);
    }

    const SpawnOptions = struct {
        stack_size: usize = 1024,
    };

    // fn spawn(entrypoint: Entrypoint, args: Args, options: SpawnOptions) !Process {
    //     const stack = try kmem.alloc(options.stack_size);
    //     errdefer comptime unreachable;
    //     return create(entrypoint, args, stack[0..options.stack_size]);
    // }

    fn finished(self: *const Process) bool {
        return self.exitcode != null;
    }

    fn stackBase(self: *const Process) usize {
        return @intFromPtr(self.stack.ptr);
    }

    fn stackEnd(self: *const Process) usize {
        return self.stackBase() + self.stack.len;
    }

    fn push(self: *Process, value: usize) void {
        self.sp -= @sizeOf(usize);
        std.debug.assert(self.sp >= self.stackBase());

        const ptr: *usize = @ptrFromInt(self.sp);
        ptr.* = value;
    }
};

pub fn init() void {
    // no-op for now
}

pub fn run() void {
    std.debug.assert(current_process == null);
    current_process = &kernel.process;

    const node = queue.popFirst() orelse {
        logger.warn("no processes in queue, nothing to do", .{});
        return;
    };

    doSwitch(&kernel.process, .from(node));

    current_process = null; // cleanup
}

fn doSwitch(old: *Process, new: *Process) void {
    assert(old == current_process);

    save_process = old;
    restore_process = new;

    current_process = new;

    asmSwitch();
}

/// this function simply adds a node to the processes' queue
pub fn enqueue(process: *Process) void {
    queue.append(&process.node);
}

pub fn yield() void {
    const old = current_process orelse @panic("kernel called yield()");
    queue.append(&old.node);

    // just added `old` to queue, we will surely get a new value out (at least, pop'ing it back)
    const new = nextProcess() orelse unreachable;

    doSwitch(old, new);
}

export fn exit(code: Process.ExitCode) callconv(cc) noreturn {
    const old = current_process orelse @panic("kernel called exit()");

    queue.remove(&old.node);
    old.exit_code = code;

    const new = nextProcess() orelse &kernel.process;

    doSwitch(old, new);

    @panic("unreachable after switching back from ending processs");
}

extern fn asmSwitch() callconv(cc) void;
extern fn asmTrampoline() callconv(cc) void;

comptime {
    const offsets = std.fmt.comptimePrint(
        \\.equ PC_OFFSET, {[pc_offset]}
        \\.equ SP_OFFSET, {[sp_offset]}
        \\
    ,
        .{
            .pc_offset = @offsetOf(Process, "pc"),
            .sp_offset = @offsetOf(Process, "sp"),
        },
    );
    const assembly = (switch (cpu.arch) {
        else => unreachable,
        // armv6m-only (rp2040) for now
        .thumb =>
        // ---
        // trampoline
        // ---
        \\
        \\.thumb_func
        \\.global asmTrampoline
        \\asmTrampoline:
        // restored stack after Process.create
        // args was been pushed to r0 and entrypoint to r7
        // they already got pop'ed (r0 -> arg0)
        \\  blx r7
        // entrypoint returns exitcode (in r0)
        // we just need to jump into exit, as that's the register for arg0
        // no need to link back when jumping, exit is noreturn
        // however, `b exit` has limited range, must load address first
        \\  ldr r1, .exit
        \\  bx r1
        \\
        // required because of offset limits. if not aligned, loading them fails
        \\.align 2
        \\
        \\.exit:
        \\  .word exit
        \\
        // ---
        // switch
        // ---
        \\
        \\.thumb_func
        \\.global asmSwitch
        \\asmSwitch:
        // push registers
        // push's reglist only supports r0-r7, so we do it in 2 steps
        \\  push {r0-r7}
        \\  mov r0, r8
        \\  mov r1, r9
        \\  mov r2, r10
        \\  mov r3, fp
        \\  mov r4, ip
        \\  push {r0-r4}
        // load current process
        \\  ldr r0, .save
        \\  ldr r0, [r0]
        // backup current state
        // high registers (lr, sp) can' be used on str directy, need to be copied first
        \\  mov r1, lr
        \\  str r1, [r0, #PC_OFFSET]
        \\  mov r1, sp
        \\  str r1, [r0, #SP_OFFSET]
        // ---
        // load new process
        \\  ldr r0, .restore
        \\  ldr r0, [r0]  
        // restore state
        // same as above, must use intermediate register
        \\  ldr r1, [r0, #PC_OFFSET]
        \\  mov lr, r1
        \\  ldr r1, [r0, #SP_OFFSET]
        \\  mov sp, r1
        // pop registers
        // same as above, must be 2 steps
        \\  pop {r0-r4}
        \\  mov r8, r0
        \\  mov r9, r1
        \\  mov r10, r2
        \\  mov fp, r3
        \\  mov ip, r4
        \\  pop {r0-r7}
        // jump
        \\ bx lr
        \\
        // ---
        // aliases
        // ---
        \\
        // required because of offset limits. if not aligned, loading them fails
        \\.align 2
        \\
        \\.save:
        \\  .word save_process
        \\
        \\.restore:
        \\  .word restore_process
    });

    asm (offsets ++ assembly);
}
