const std = @import("std");
const options = @import("options");
const logger = std.log.scoped(.eos);

const linker = @import("linker.zig");
const kmem = @import("allocator.zig");
const scheduler = @import("scheduler.zig");
const Process = scheduler.Process;

const rp2040 = if (options.soc == .rp2040)
    @import("soc/rp2040.zig")
else
    @compileError("TODO: Make things more flexible");

export fn _start() callconv(.c) noreturn {
    rp2040.init();

    // fill bss with zeroes
    const bss_start = @intFromPtr(&linker.__kernel_bss_start);
    const bss_end = @intFromPtr(&linker.__kernel_bss_end);

    const bss_size = bss_end - bss_start;

    @memset(@as([*]volatile u32, @ptrFromInt(bss_start))[0 .. bss_size / 4], 0);

    // copy data to ram
    const data_source = @intFromPtr(&linker.__kernel_data_source);

    const data_start = @intFromPtr(&linker.__kernel_data_start);
    const data_end = @intFromPtr(&linker.__kernel_data_end);

    const data_size = data_end - data_start;

    @memcpy(
        @as([*]volatile u32, @ptrFromInt(data_start))[0 .. data_size / 4],
        @as([*]volatile u32, @ptrFromInt(data_source))[0 .. data_size / 4],
    );

    kmain() catch |err| {
        logger.err("{t}", .{err});

        if (@errorReturnTrace()) |trace| {
            var index: usize = 0;
            var n_frames: usize = @min(trace.index, trace.instruction_addresses.len);

            logger.err("stack trace:", .{});
            while (n_frames != 0) {
                defer n_frames -= 1;
                defer index = (index + 1) % trace.instruction_addresses.len;

                const address = trace.instruction_addresses[index];
                logger.err("\t0x{x}", .{address});
            }
        } else {
            logger.err("could not unwind stack trace", .{});
        }
    };

    logger.err("dying...", .{});
    while (true) {}
}

fn kmain() !noreturn {
    logger.debug("started", .{});

    kmem.init();
    scheduler.init();

    if (true) {
        var toggle_process: Process = try .spawn(toggle, null, .{
            .name = "led toggle",
        });
        scheduler.enqueue(&toggle_process);
    } else {
        var on_process: Process = try .spawn(on, null, .{
            .name = "led on",
        });
        scheduler.enqueue(&on_process);

        var off_process: Process = try .spawn(off, null, .{
            .name = "led off",
        });
        scheduler.enqueue(&off_process);
    }

    scheduler.run();

    logger.warn("all process finished", .{});
    return error.SystemExit;
}

fn noopLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = if (options.soc == .rp2040) rp2040.uart.log else noopLogFn,
};

fn panicFn(message: []const u8, ret_addr: ?usize) noreturn {
    std.log.err("panic: {s} ({?X})", .{ message, ret_addr });
    while (true) {}
}

pub const panic = std.debug.FullPanic(panicFn);

const ISR = *const fn () callconv(.c) void;

fn unhandledInterrupt(comptime msg: []const u8) ISR {
    return struct {
        fn _() callconv(.c) void {
            @panic("unhandled interrupt " ++ msg);
        }
    }._;
}

const VectorTable = extern struct {
    sp: *const anyopaque, // first "interrupt" is the initial stack pointer
    reset: ISR, // entrypoint of the device
    nmi: ISR = unhandledInterrupt("nmi"),
    hard_fault: ISR = unhandledInterrupt("hard_fault"),
    mem_manage: ISR = unhandledInterrupt("mem_manage"),
    bus_fault: ISR = unhandledInterrupt("bus_fault"),
    usage_fault: ISR = unhandledInterrupt("usage_fault"),
    reserved_exception_7: ISR = unhandledInterrupt("reserved exception 7"),
    reserved_exception_8: ISR = unhandledInterrupt("reserved exception 8"),
    reserved_exception_9: ISR = unhandledInterrupt("reserved exception 9"),
    reserved_exception_10: ISR = unhandledInterrupt("reserved exception 10"),
    svcall: ISR = unhandledInterrupt("svcall"),
    debug_monitor: ISR = unhandledInterrupt("debug_monitor"),
    reserved_exception_13: ISR = unhandledInterrupt("reserved exception 13"),
    pendsv: ISR = unhandledInterrupt("pendsv"),
    systick: ISR = unhandledInterrupt("systick"),
};

const vector_table: VectorTable = .{
    .sp = &linker.__kernel_stack_end,
    .reset = _start,
};

comptime {
    @export(&vector_table, .{
        .name = "vector_table",
        .section = ".startup",
    });
}

fn procFunc(func: fn () void) fn (Process.Args) callconv(.c) Process.ExitCode {
    return struct {
        fn _(_: Process.Args) callconv(.c) Process.ExitCode {
            while (true) {
                func();
                for (0..2_000_000) |_| asm volatile ("nop");
                scheduler.yield();
            }

            return 0;
        }
    }._;
}

const on = procFunc(rp2040.led.on);
const off = procFunc(rp2040.led.off);
const toggle = procFunc(rp2040.led.toggle);
