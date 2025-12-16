//! Inspired on microzig

const std = @import("std");
const logger = std.log.scoped(.uart);

// base addresses
const GPIO_BASE = 0x40014000;
const RESETS_BASE = 0x4000C000;
const SIO_BASE = 0xD0000000;
const XOSC_BASE = 0x40024000;
const CLOCKS_BASE = 0x40008000;
const UART0_BASE = 0x40034000;

// resets
const RESETS_RESET = RESETS_BASE + 0x00;
const RESETS_RESET_DONE = RESETS_BASE + 0x08;

// XOSC
const XOSC_CTRL = XOSC_BASE + 0x00;
const XOSC_STATUS = XOSC_BASE + 0x04;
const XOSC_STARTUP = XOSC_BASE + 0x0C;

// clocks
const CLK_REF_CTRL = CLOCKS_BASE + 0x30;
const CLK_REF_DIV = CLOCKS_BASE + 0x34;
const CLK_SYS_CTRL = CLOCKS_BASE + 0x3C;
const CLK_PERI_CTRL = CLOCKS_BASE + 0x48;

// uart
const UART0_IBRD = UART0_BASE + 0x24;
const UART0_FBRD = UART0_BASE + 0x28;
const UART0_LCR_H = UART0_BASE + 0x2C;
const UART0_CR = UART0_BASE + 0x30;
const UART0_DR = UART0_BASE + 0x00;
const UART0_FR = UART0_BASE + 0x18;
const UART0_ICR = UART0_BASE + 0x44;

const GPIO0_CTRL = GPIO_BASE + 0x004;
const GPIO1_CTRL = GPIO_BASE + 0x00C;
const GPIO25_CTRL = GPIO_BASE + 0x0CC;

const PADS_BANK0_BASE = 0x4001c000;
const PADS_GPIO0 = PADS_BANK0_BASE + 0x000;
const PADS_GPIO1 = PADS_BANK0_BASE + 0x004;

const UART0_TX_FUNCSEL = 2; // Function select value for UART0 TX
const UART0_RX_FUNCSEL = 2; // Function select value for UART0 RX

const GPIO_OE_OFFSET = 0x20;
const GPIO_OUT_OFFSET = 0x10;

const CLOCKS_CLK_PERI_CTRL = CLOCKS_BASE + 0x48;

const LED_PIN = 25;

fn write(addr: u32, value: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = value;
}

fn read(addr: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn setBits(addr: u32, mask: u32) void {
    const val = read(addr);
    write(addr, val | mask);
}

fn clearBits(addr: u32, mask: u32) void {
    const val = read(addr);
    write(addr, val & ~mask);
}

fn toggleBits(addr: u32, mask: u32) void {
    const start = read(addr);
    write(addr, start ^ mask);
}

fn setupClocks() void {
    write(XOSC_CTRL, 0xAA0); // Frequency range: 1-15 MHz
    write(XOSC_STARTUP, 0xC4); // Startup delay
    setBits(XOSC_CTRL, 0xFAB000); // Enable oscillator (magic)

    // Wait for oscillator to become stable
    while ((read(XOSC_STATUS) & 0x8000_0000) == 0) {}

    // Set up clocks to use XOSC
    write(CLK_REF_CTRL, 2); // REF -> xosc_clksrc
    write(CLK_SYS_CTRL, 0); // SYS -> clk_ref
    write(CLK_REF_DIV, 1 << 8); // REF divisor = 1
    write(CLK_PERI_CTRL, (1 << 11) | (4 << 5)); // PERI enable, AUX SRC = xosc
}

fn resetSubsys() void {
    // SIO
    clearBits(RESETS_RESET, 1 << 1);
    while ((read(RESETS_RESET_DONE) & (1 << 1)) == 0) {}

    // IO
    clearBits(RESETS_RESET, 1 << 5);
    while ((read(RESETS_RESET_DONE) & (1 << 5)) == 0) {}

    // pads
    clearBits(RESETS_RESET, 1 << 8);
    while ((read(RESETS_RESET_DONE) & (1 << 8)) == 0) {}

    // UART0
    clearBits(RESETS_RESET, 1 << 22);
    while ((read(RESETS_RESET_DONE) & (1 << 22)) == 0) {}
}

pub const uart = struct {
    const putty = struct {
        const clear_screen = "\x1B[2J";
        const reset_cursor = "\x1B[H";
    };

    fn init() void {
        // 9600 baud rate
        write(UART0_IBRD, 78);
        write(UART0_FBRD, 8);

        // WLEN=3 (8 bits), FEN=1 (FIFO enable)
        write(UART0_LCR_H, (3 << 5) | (1 << 4));

        // UARTEN=1, TXE=1, RXE=1
        write(UART0_CR, (1 << 9) | (1 << 8) | (1 << 0));
    }

    fn writeByte(byte: u8) void {
        // convert \n to \r\n
        if (byte == '\n') writeByte('\r');

        // Wait until UART is ready to transmit (TXFF == 0)
        while (read(UART0_FR) & (1 << 5) != 0) {}
        @as(*u8, @ptrFromInt(UART0_DR)).* = byte;
    }

    fn writeSlice(bytes: []const u8) usize {
        for (bytes) |byte| {
            writeByte(byte);
        }

        return bytes.len;
    }

    fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        var n: usize = 0;

        for (data, 0..) |bytes, i| {
            n += writeSlice(bytes);

            // splat element
            if (i == data.len - 1) {
                // already sent it once, thus splat-1
                for (0..splat - 1) |_| {
                    n += writeSlice(bytes);
                }
            }
        }

        return n;
    }

    fn streamingWriter() std.Io.Writer {
        return .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drain,
            },
        };
    }

    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @Type(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const prefix = comptime level.asText() ++ switch (scope) {
            .default => ": ",
            else => " (" ++ @tagName(scope) ++ "): ",
        };

        var w = streamingWriter();
        w.print(prefix ++ format ++ "\n", args) catch |e| {
            _ = writeSlice(@errorName(e));
            writeByte('\n');
        };
    }
};

pub const led = struct {
    pub fn on() void {
        setBits(SIO_BASE + GPIO_OUT_OFFSET, 1 << LED_PIN);
    }

    pub fn off() void {
        clearBits(SIO_BASE + GPIO_OUT_OFFSET, 1 << LED_PIN);
    }

    pub fn toggle() void {
        toggleBits(SIO_BASE + GPIO_OUT_OFFSET, 1 << LED_PIN);
    }
};

pub fn init() void {
    setupClocks();
    resetSubsys();

    write(GPIO0_CTRL, UART0_TX_FUNCSEL); // GP0 as TX
    write(GPIO1_CTRL, UART0_RX_FUNCSEL); // GP1 as RX
    uart.init();

    // assumes putty is connected, reset its output
    _ = uart.writeSlice(uart.putty.clear_screen);
    _ = uart.writeSlice(uart.putty.reset_cursor);

    logger.debug("configured 9600 baud rate", .{});

    write(GPIO25_CTRL, 5); // GP25 as SIO
    setBits(SIO_BASE + GPIO_OE_OFFSET, 1 << LED_PIN); // enable output
}

fn prepareBootSector(comptime stage2_rom: []const u8) [256]u8 {
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
