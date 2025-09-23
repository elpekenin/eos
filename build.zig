const std = @import("std");
const targets = @import("src/targets.zig");

pub fn build(b: *std.Build) void {
    // build options
    //
    const soc = b.option(
        targets.Soc,
        "soc",
        "SoC to compile for",
    ) orelse .rp2040;

    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "optimize mode",
    ) orelse defaultOptimize(soc);

    // compile kernel
    //
    const info = targets.database.getAssertContains(soc);
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(info.query()),
            .optimize = optimize,
            .root_source_file = b.path("src/kernel/main.zig"),
            .sanitize_c = .off,
        }),
    });

    const options = b.addOptions();
    options.addOption(targets.Soc, "soc", soc);
    kernel.root_module.addImport("options", options.createModule());

    const script = info.linker_script orelse b.fmt("ld/{t}", .{soc});
    kernel.setLinkerScript(b.path(script));

    if (soc == .rp2040) {
        // we want .uf2 to flash rp2040
        setupStage2(b, kernel);
        const uf2 = toUf2(kernel, soc, .{});
        const copy_uf2 = b.addInstallFile(uf2, "kernel.uf2");
        b.getInstallStep().dependOn(&copy_uf2.step);
    }

    b.installArtifact(kernel);
    const elf = kernel.getEmittedBin();

    // steps
    //
    const usbipd = b.step("usbipd", "attach debugprobe to WSL");
    const usbipd_cmd = b.addSystemCommand(&.{
        "usbipd.exe",
        "attach",
        "--wsl",
        "--hardware-id",
        "2e8a:000c",
        "-a",
    });
    usbipd.dependOn(&usbipd_cmd.step);

    const flash = b.step("flash", "flash the binary");
    const flash_cmd = openocdCmd(b, soc);
    flash_cmd.addArgs(&.{
        "--command",
        // NOTE: path relies on default dir given by `installArtifact` and build script naming `kernel.elf`
        "program zig-out/bin/kernel.elf verify reset exit",
    });
    flash_cmd.addFileInput(elf);
    flash.dependOn(b.getInstallStep());
    flash.dependOn(&flash_cmd.step);

    const openocd = b.step("openocd", "spawn openocd server");
    const openocd_cmd = openocdCmd(b, soc);
    openocd.dependOn(&openocd_cmd.step);

    const debug = b.step("debug", "run debugger");
    const debug_cmd = b.addSystemCommand(&.{
        // FIXME: first 'arm-none-eabi-gdb' found in $PATH is QMK toolchains' one
        //        it depends on newer glibc than available on my ubuntu WSL image
        "/usr/bin/arm-none-eabi-gdb",
        "--quiet",
        "--command",
        b.fmt("gdb/{t}", .{soc}),
    });
    debug_cmd.addFileArg(elf);
    debug.dependOn(&debug_cmd.step);
}

fn defaultOptimize(soc: targets.Soc) std.builtin.OptimizeMode {
    return switch (soc) {
        .rp2040 => .Debug,
        .stm32h7s78 => .ReleaseSafe,
    };
}

fn openocdCmd(b: *std.Build, soc: targets.Soc) *std.Build.Step.Run {
    const argv = switch (soc) {
        else => unreachable,
        .rp2040 => &.{
            "openocd",
            "--file",
            "interface/cmsis-dap.cfg",
            "--file",
            "target/rp2040.cfg",
            "--command",
            "adapter speed 5000",
        },
    };

    return b.addSystemCommand(argv);
}

/// NOTE: this logic and the code being compiled were copied from MicroZig
///
/// given a binary (*Compile), adds to it an import named "bootloader" which
/// contains the binary for the compiled stage2 bootloader that sets up the
/// XIP flash
fn setupStage2(b: *std.Build, kernel: *std.Build.Step.Compile) void {
    const stage2 = b.addExecutable(.{
        .name = "stage2-w25q080",
        .root_module = b.createModule(.{
            .optimize = kernel.root_module.optimize,
            .target = kernel.root_module.resolved_target,
        }),
    });

    stage2.linkage = .static;
    stage2.build_id = .none;
    stage2.setLinkerScript(b.path("src/bootrom/stage2.ld"));
    stage2.addAssemblyFile(b.path("src/bootrom/w25q080.S"));
    stage2.entry = .{ .symbol_name = "_stage2_boot" };

    const bin = b.addObjCopy(stage2.getEmittedBin(), .{
        .basename = "stage2-w25q080.bin",
        .format = .bin,
    }).getOutput();

    kernel.root_module.addImport("bootloader", b.createModule(.{
        .root_source_file = bin,
    }));
}

const Uf2Options = struct {
    base: ?usize = null,
};

// TODO: migrate to zig?
/// given a binary file, create the equivalent UF2 for it
fn toUf2(kernel: *std.Build.Step.Compile, soc: targets.Soc, options: Uf2Options) std.Build.LazyPath {
    const b = kernel.step.owner;

    const family: []const u8 = switch (soc) {
        .rp2040 => "RP2040",
        else => unreachable,
    };

    const cmd = b.addSystemCommand(&.{
        "python3",
        "tools/uf2/uf2conv.py",
        "--family",
        family,
    });

    if (options.base) |base| {
        cmd.addArgs(&.{
            "--base",
            b.fmt("{}", .{base}),
        });
    }

    cmd.addArg("--convert");
    // NOTE: uf2conv does not support elf, and using bin does not (correctly?) infer base address
    const hex = b.addObjCopy(kernel.getEmittedBin(), .{
        .basename = "kernel.hex",
        .format = .hex,
    });
    cmd.addFileArg(hex.getOutput());

    cmd.addArg("--output");
    return cmd.addOutputFileArg("kernel.uf2");
}
