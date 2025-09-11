//! Inspired on microzig

const std = @import("std");

/// Write to a memory-mapped IO register
fn write(addr: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = value;
}

/// Read from a memory-mapped IO register
fn read(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

/// Set specific bits in a register
fn setBits(addr: usize, mask: u32) void {
    const val = read(addr);
    write(addr, val | mask);
}

/// Clear specific bits in a register
fn clearBits(addr: usize, mask: u32) void {
    const val = read(addr);
    write(addr, val & ~mask);
}

const uart = struct {
    const UART0_BASE = 0x40034000;
    const UARTDR = UART0_BASE + 0x00; // Data Register
    const UARTFR = UART0_BASE + 0x18; // Flag Register
    const UARTIBRD = UART0_BASE + 0x24;
    const UARTFBRD = UART0_BASE + 0x28;
    const UARTLCR_H = UART0_BASE + 0x2C;
    const UARTCR = UART0_BASE + 0x30;
    const UARTICR = UART0_BASE + 0x44;

    const IO_BANK0_BASE = 0x40014000;
    const GPIO0_CTRL = IO_BANK0_BASE + 0x004;
    const GPIO1_CTRL = IO_BANK0_BASE + 0x00C;

    const PADS_BANK0_BASE = 0x4001c000;
    const PADS_GPIO0 = PADS_BANK0_BASE + 0x000;
    const PADS_GPIO1 = PADS_BANK0_BASE + 0x004;

    const UART0_TX_FUNCSEL = 2; // Function select value for UART0 TX
    const UART0_RX_FUNCSEL = 2; // Function select value for UART0 RX

    fn init() void {
        write(GPIO0_CTRL, UART0_TX_FUNCSEL); // GP0 as TX
        write(GPIO1_CTRL, UART0_RX_FUNCSEL); // GP1 as RX

        write(UARTCR, 0); // disable UART0
        write(UARTICR, 0x7FF); // clear interrupts

        // baudrate = UARTCLK / (16 * baud_divisor)
        // UARTCLK = 125_000_000 (default RP2040 clock)
        // baud_divisor = 125_000_000 / (16 * 115200) = ~67.8
        // Integer part: 67, Fractional: int(0.8 * 64 + 0.5) = 51
        write(UARTIBRD, 67); // Integer baud rate divisor
        write(UARTFBRD, 51); // Fractional baud rate divisor

        // line control for 8N1 (8 bits, no parity, 1 stop bit), FIFO disabled
        // WLEN=3 (8 bits), FEN=0 (FIFO disable)
        write(UARTLCR_H, (3 << 5));

        // UARTEN=1, TXE=1, RXE=1
        write(UARTCR, (1 << 9) | (1 << 8) | (1 << 0));
    }

    fn writeByte(byte: u8) void {
        // Wait until UART is ready to transmit (TXFF == 0)
        while (read(UARTFR) & (1 << 5) != 0) {}
        @as(*u8, @ptrFromInt(UARTDR)).* = byte;
    }

    fn writeSlice(bytes: []const u8) usize {
        for (bytes) |byte| {
            writeByte(byte);
        }

        return bytes.len;
    }

    fn writeBuffer(w: *std.Io.Writer) usize {
        const buff = w.buffered();
        w.end = 0;
        return writeSlice(buff);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        if (data.len == 0) return 0;

        var written: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            const dest = w.buffered();
            const len = @min(bytes.len, dest.len);
            @memcpy(dest[0..len], bytes[0..len]);

            if (bytes.len > dest.len) {
                written += writeBuffer(w);
            }
        }

        const pattern = data[data.len - 1];
        const dest = w.buffer[w.end..];
        switch (pattern.len) {
            0 => return 0,
            1 => {
                std.debug.assert(splat >= dest.len);
                @memset(dest, pattern[0]);
            },
            else => {
                written += writeBuffer(w);
                for (0..splat) |_| {
                    written += writeSlice(pattern);
                }
            },
        }

        return written;
    }

    fn writer(buffer: []u8) std.Io.Writer {
        return .{
            .buffer = buffer,
            .vtable = &.{
                .drain = drain,
            },
        };
    }
};

pub const led = struct {
    const GPIO_BASE = 0x40014000;
    const SIO_BASE = 0xd0000000;
    const CLOCKS_BASE = 0x40008000;
    const RESETS_BASE = 0x4000c000;

    const GPIO_OE_OFFSET = 0x20;
    const GPIO_OUT_OFFSET = 0x10;

    const RESETS_RESET = RESETS_BASE + 0x0;
    const RESETS_RESET_DONE = RESETS_BASE + 0x8;

    const CLOCKS_CLK_PERI_CTRL = CLOCKS_BASE + 0x48;

    const LED_PIN = 25;

    fn init() void {
        clearBits(RESETS_RESET, (1 << 5) | (1 << 8) | (1 << 1)); // IO_BANK0, PADS_BANK0, SIO

        // Unreset IO bank, pads, and SIO
        clearBits(RESETS_RESET, (1 << 5) | (1 << 8) | (1 << 1)); // IO_BANK0, PADS_BANK0, SIO

        // Wait for reset to complete
        while ((read(RESETS_RESET_DONE) & ((1 << 5) | (1 << 8) | (1 << 1))) != ((1 << 5) | (1 << 8) | (1 << 1))) {}

        // Enable GPIO function for pin 25
        const gpio25_ctrl = GPIO_BASE + 0xcc; // GPIO25 control register
        write(gpio25_ctrl, 5); // FUNCSEL = 5 (SIO)

        // Enable output for GPIO25
        setBits(SIO_BASE + GPIO_OE_OFFSET, 1 << LED_PIN);
    }

    pub fn on() void {
        setBits(SIO_BASE + GPIO_OUT_OFFSET, 1 << LED_PIN);
    }

    pub fn off() void {
        clearBits(SIO_BASE + GPIO_OUT_OFFSET, 1 << LED_PIN);
    }
};

pub fn init() void {
    // uart.init();
    led.init();
}

// pub fn logFn(
//     comptime level: std.log.Level,
//     comptime scope: @Type(.enum_literal),
//     comptime format: []const u8,
//     args: anytype,
// ) void {
//     const prefix = comptime level.asText() ++ switch (scope) {
//         .default => ": ",
//         else => " (" ++ @tagName(scope) ++ "): ",
//     };

//     var buffer: [100]u8 = undefined;
//     var writer = uart.writer(&buffer);
//     writer.print(prefix ++ format ++ "\r\n", args) catch {};
// }

fn prepareBootSector(comptime stage2_rom: []const u8) [256]u8 {
    @setEvalBranchQuota(10_000);

    var bootrom: [256]u8 = @splat(0xFF);
    @memcpy(bootrom[0..stage2_rom.len], stage2_rom);

    // 2.8.1.3.1. Checksum
    // The last four bytes of the image loaded from flash (which we hope is a valid flash second stage) are a CRC32 checksum
    // of the first 252 bytes. The parameters of the checksum are:
    // • Polynomial: 0x04c11db7
    // • Input reflection: no
    // • Output reflection: no
    // • Initial value: 0xffffffff
    // • Final XOR: 0x00000000
    // • Checksum value appears as little-endian integer at end of image
    // The Bootrom makes 128 attempts of approximately 4ms each for a total of approximately 0.5 seconds before giving up
    // and dropping into USB code to load and checksum the second stage with varying SPI parameters. If it sees a checksum
    // pass it will immediately jump into the 252-byte payload which contains the flash second stage.
    const Hash = std.hash.crc.Crc(u32, .{
        .polynomial = 0x04c11db7,
        .initial = 0xffffffff,
        .reflect_input = false,
        .reflect_output = false,
        .xor_output = 0x00000000,
    });

    std.mem.writeInt(u32, bootrom[252..256], Hash.hash(bootrom[0..252]), .little);

    return bootrom;
}

export const bootloader_data: [256]u8 linksection(".boot2") = prepareBootSector(@embedFile("bootloader"));

comptime {
    _ = bootloader_data;
}
