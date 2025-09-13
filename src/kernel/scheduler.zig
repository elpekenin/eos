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

const clobbers: std.builtin.assembly.Clobbers = switch (cpu.arch) {
    else => unreachable,
    .thumb => .{
        .r0 = true,
        .r1 = true,
        .r2 = true,
        .r3 = true,
        .r4 = true,
        .r5 = true,
        .r6 = true,
        // .r7 = true, // reserved
        .r8 = true,
        .r9 = true,
        .r10 = true,
        .r11 = true,
        .r12 = true,
        .r13 = true,
        .r14 = true,
        // this goes up to r15...
        // https://github.com/ARM-software/abi-aa/blob/main/aapcs32/aapcs32.rst#611core-registers
    },
};

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

        // TODO: insert entrypoint and args information
        var self: Process = .{
            .context = .{
                .sp = sp,
                .fp = undefined,
                .pc = @intFromPtr(&trampoline),
            },
            .stack = stack,
            .exit_code = null,
            .node = .{},
        };

        self.push(@intFromPtr(entrypoint));
        self.push(@intFromPtr(args));

        switch (cpu.arch) {
            else => unreachable,
            .thumb => {
                // clobbers is r0-r14
                for (0..15) |r| {
                    if (r == 7) continue; // ... but r7 is reserved
                    self.push(0); // unused value, just put a 0
                }
            },
        }

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

    switch (cpu.arch) {
        else => unreachable,
        // FIXME: assumes word size == 4, does that always hold?
        .thumb => asm volatile (
            // `swap` is a ptr to a struct where
            //   - first word is another ptr, to the prev context
            //   - second word is another ptr, to the next context
            \\ldr r1, [r0, #0]
            \\ldr r2, [r0, #4]
            \\
            // NOTE: some registers can't be accessed directly, need to be copied first
            // backup current state into prev
            \\mov r3, sp
            \\str r3, [r1, #0]
            \\mov r3, lr
            \\str r3, [r1, #4]
            \\mov r3, fp
            \\str r3, [r1, #8]
            \\
            // restore state from next
            \\ldr r3, [r2, #0]
            \\mov sp, r3
            \\ldr r3, [r2, #4]
            \\mov lr, r3
            \\ldr r3, [r2, #8]
            \\mov fp, r3
            \\
            // jump back
            \\bx lr
            :
            : [input] "{r0}" (swap)
            : clobbers
        )
    }
}

fn trampoline() callconv(.c) void {
    switch (cpu.arch) {
        else => unreachable,
        .thumb => asm volatile (
            // Process.create pushes args and entrypoint (will pop into r0 and r1)
            // it also pushes a dummy context (r0-r14) that will be ignored after doSwitch
            \\pop {r0-r1}
            \\blx r1
            // when entrypoint returns, exitcode is on r0, which is already ready to be arg0 for exit
            // we don't need to setup a link back before jumping, exit is noreturn
            \\b exit
        )
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
