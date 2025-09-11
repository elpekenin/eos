const std = @import("std");
const targets = @import("src/targets.zig");

pub fn build(b: *std.Build) void {
    const maybe_soc = b.option(
        targets.Soc,
        "soc",
        "target soc",
    );

    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "optimize mode",
    ) orelse .ReleaseSafe;

    const targets_mod = b.createModule(.{
        .root_source_file = b.path("src/targets.zig"),
    });

    const compile_all = b.step("compile-all", "try and compile for every target");
    compile_all.dependOn(&compileAll(b, targets_mod).step);

    const fmt = b.step("fmt", "run code formatter");
    fmt.dependOn(&b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src/",
        },
    }).step);

    const lint = b.step("lint", "run code linter");
    runLint(lint); // TODO: zlint needs fix for 0.15

    // selected a SoC -> compile kernel and quit
    if (maybe_soc) |soc| {
        compileKernel(b, soc, optimize);
    } else {
        b.getInstallStep().dependOn(&b.addSystemCommand(&.{ "echo", "missing SoC, can't compile" }).step);
    }
}

/// compiles the kernel for the given target and optimization level
fn compileKernel(b: *std.Build, soc: targets.Soc, optimize: std.builtin.OptimizeMode) void {
    const info = targets.database.getAssertContains(soc);

    const exe = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(info.query()),
            .optimize = optimize,
            .root_source_file = b.path("src/kernel/os.zig"),
        }),
    });

    const options = b.addOptions();
    options.addOption(targets.Soc, "soc", soc);
    exe.root_module.addImport("options", options.createModule());

    const script = info.linker_script orelse b.fmt("ld/{s}.ld", .{@tagName(soc)});
    exe.setLinkerScript(b.path(script));

    if (soc == .rp2040) {
        setupStage2(b, exe);
        toUf2(b, exe, .{
            .base = null,
            .family = .RP2040,
        });
    }

    b.installArtifact(exe);
}

/// configure a build step that will (try) compile every supported target
/// and report whether the build failed
fn compileAll(b: *std.Build, targets_mod: *std.Build.Module) *std.Build.Step.Run {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/compile_all.zig"),
        .target = b.resolveTargetQuery(.{}), // native
    });
    mod.addImport("targets", targets_mod);

    const options = b.addOptions();
    mod.addImport("options", options.createModule());

    const exe = b.addExecutable(.{
        .name = "compile-all",
        .root_module = mod,
    });
    b.installArtifact(exe);

    return b.addRunArtifact(exe);
}

fn runLint(step: *std.Build.Step) void {
    const b = step.owner;
    if (false) {
        const zlint = b.dependency("zlint", .{}).artifact("zlint");

        const lint = b.addRunArtifact(zlint);
        lint.addArg("--verbose");
        lint.addDirectoryArg(b.path(""));

        step.dependOn(&lint.step);
    }
}

/// NOTE: this logic and the code being compiled where copied from MicroZig
///
/// given a binary (*Compile), adds to it an import named "bootloader" which
/// contains the binary for the compiled stage2 bootloader that sets up the
/// XIP flash
fn setupStage2(b: *std.Build, kernel: *std.Build.Step.Compile) void {
    const exe = b.addExecutable(.{
        .name = "stage2-w25q080",
        .root_module = b.createModule(.{
            .optimize = kernel.root_module.optimize,
            .target = kernel.root_module.resolved_target,
        }),
    });

    exe.linkage = .static;
    exe.build_id = .none;
    exe.setLinkerScript(b.path("src/bootrom/stage2.ld"));
    exe.addAssemblyFile(b.path("src/bootrom/w25q080.S"));
    exe.entry = .{ .symbol_name = "_stage2_boot" };

    const bin = b.addObjCopy(exe.getEmittedBin(), .{
        .basename = "stage2-w25q080.bin",
        .format = .bin,
    });

    kernel.root_module.addImport("bootloader", b.createModule(.{
        .root_source_file = bin.getOutput(),
    }));
}

const Uf2Options = struct {
    base: ?usize = null,
    family: enum { RP2040 },
};

// TODO: migrate to zig?
/// given a binary file, create the equivalent UF2 for it
fn toUf2(b: *std.Build, exe: *std.Build.Step.Compile, options: Uf2Options) void {
    const cmd = b.addSystemCommand(&.{
        "python3",
        "tools/uf2/uf2conv.py",
        "--family",
        b.fmt("{t}", .{options.family}),
        "--convert",
    });

    if (options.base) |base| {
        cmd.addArgs(&.{
            "--base",
            b.fmt("{}", .{base}),
        });
    }

    // NOTE: uf2conv does not support elf
    // using bin does not (correctly?) infer the base address
    // as such: convert to hex
    const bin = b.addObjCopy(exe.getEmittedBin(), .{
        .basename = "kernel.hex",
        .format = .hex,
    });
    cmd.addFileArg(bin.getOutput());

    cmd.addArg("--output");
    const uf2 = cmd.addOutputFileArg("kernel.uf2");

    const copy = b.addInstallFile(uf2, "kernel.uf2");
    b.getInstallStep().dependOn(&copy.step);
}
