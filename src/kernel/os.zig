const std = @import("std");
const options = @import("options");

const linker = @import("linker.zig");
// const kmem = @import("kmem.zig"); // TODO
const scheduler = @import("scheduler.zig");
const Process = scheduler.Process;

const rp2040 = if (options.soc == .rp2040)
    @import("soc/rp2040.zig")
else
    @compileError("TODO: Make things more flexible");

export fn _start() callconv(.c) noreturn {
    rp2040.init();

    const data_start = linker.data_start;
    const data_end = linker.data_end;

    const data: []u8 = data_start[0 .. data_end - data_start];
    @memcpy(data, linker.data_source[0..data.len]);

    const bss_start = linker.bss_start;
    const bss_end = linker.bss_end;

    const bss: []u8 = bss_start[0 .. bss_end - bss_start];
    @memset(bss, 0);

    rp2040.led.off();
    delay(500_000);

    kmain() catch |err| {
        std.log.err("kmain() returned error: '{t}'", .{err});

        if (@errorReturnTrace()) |trace| {
            var index: usize = 0;
            var n_frames: usize = @min(trace.index, trace.instruction_addresses.len);

            std.log.err("stack trace:", .{});
            while (n_frames != 0) {
                defer n_frames -= 1;
                defer index = (index + 1) % trace.instruction_addresses.len;

                const address = trace.instruction_addresses[index];
                std.log.err("\t0x{x}", .{address});
            }
        } else {
            std.log.err("could not unwind stack trace", .{});
        }

        @panic("kmain() returned an error");
    };

    @panic("somehow got out of kmain() with no error");
}

export var foo: u32 = 0xDEAD_BEEF;

fn kmain() !noreturn {
    std.log.info("reached kmain", .{});
    rp2040.led.on();

    if (foo == 0xDEAD_BEEF) {
        rp2040.led.off();
    }

    // kmem.init();

    scheduler.init();

    var on_process: Process = .create(on.func, null, &on.stack);
    var off_process: Process = .create(off.func, null, &off.stack);

    scheduler.enqueue(&on_process);
    scheduler.enqueue(&off_process);

    scheduler.run();

    std.log.warn("all process finished, nothing else to do ...", .{});

    return error.SystemExit;
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn panicFn(message: []const u8, ret_addr: ?usize) noreturn {
    std.log.err("panic: {s} ({?X})", .{ message, ret_addr });
    @panic(message);
}

pub const panic = std.debug.FullPanic(panicFn);

const ISR = *const fn () callconv(.c) void;

fn unhandedInterrupt(comptime msg: []const u8) ISR {
    return struct {
        fn _() callconv(.c) void {
            @panic(msg);
        }
    }._;
}

const VectorTable = extern struct {
    sp: *const anyopaque, // first "interrupt" is the initial stack pointer
    reset: ISR, // entrypoint of the device
    nmi: ISR = unhandedInterrupt("nmi"),
    hard_fault: ISR = unhandedInterrupt("hard_fault"),
    mem_manage: ISR = unhandedInterrupt("mem_manage"),
    bus_fault: ISR = unhandedInterrupt("bus_fault"),
    usage_fault: ISR = unhandedInterrupt("usage_fault"),
    reserved_exception_7: ISR = unhandedInterrupt("reserved exception 7"),
    reserved_exception_8: ISR = unhandedInterrupt("reserved exception 8"),
    reserved_exception_9: ISR = unhandedInterrupt("reserved exception 9"),
    reserved_exception_10: ISR = unhandedInterrupt("reserved exception 10"),
    svcall: ISR = unhandedInterrupt("svcall"),
    debug_monitor: ISR = unhandedInterrupt("debug_monitor"),
    reserved_exception_13: ISR = unhandedInterrupt("reserved exception 13"),
    pendsv: ISR = unhandedInterrupt("pendsv"),
    systick: ISR = unhandedInterrupt("systick"),
};

export const vector_table: VectorTable linksection(".startup") = .{
    .sp = linker.stack_end,
    .reset = _start,
};

fn delay(ticks: usize) void {
    for (0..ticks) |_| {
        asm volatile ("nop" ::: .{ .memory = true });
    }
}

const cc = scheduler.cc;

const on = struct {
    var stack: [256]u8 = undefined;

    fn func(_: Process.Args) callconv(cc) Process.ExitCode {
        while (true) {
            rp2040.led.on();
            delay(500_000);
            scheduler.yield();
        }

        return 0;
    }
};

const off = struct {
    var stack: [256]u8 = undefined;

    fn func(_: Process.Args) callconv(cc) Process.ExitCode {
        while (true) {
            rp2040.led.off();
            delay(500_000);
            scheduler.yield();
        }

        return 0;
    }
};
