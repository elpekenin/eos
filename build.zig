const std = @import("std");
const targets = @import("src/targets.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "optimize mode",
    ) orelse .ReleaseSafe;

    // set up a step to build each target
    //
    // they are also added as dependencies of install step
    // this way, `zig build` builds everything
    for (std.enums.values(targets.Soc)) |soc| {
        const soc_step = b.step(
            @tagName(soc),
            b.fmt("compile for {t}", .{soc}),
        );
        soc_step.dependOn(compileKernel(b, soc, optimize));

        b.getInstallStep().dependOn(soc_step);
    }

    const fmt = b.step("fmt", "run code formatter");
    const run_fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src/",
        },
    });
    fmt.dependOn(&run_fmt.step);

    const lint_step = b.step("lint", "run code linter");
    runLint(lint_step); // TODO: zlint needs fix for 0.15
}

/// compiles the kernel for the given target and optimization level
fn compileKernel(b: *std.Build, soc: targets.Soc, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const info = targets.database.getAssertContains(soc);

    const exe = b.addExecutable(.{
        .name = b.fmt("kernel_{t}.elf", .{soc}),
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

    const kernel = b.addInstallArtifact(exe, .{});

    if (soc == .rp2040) {
        setupStage2(b, exe);
        return toUf2(exe, soc, .{});
    }

    return &kernel.step;
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
fn toUf2(exe: *std.Build.Step.Compile, soc: targets.Soc, options: Uf2Options) *std.Build.Step {
    const b = exe.step.owner;

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
    const hex = b.addObjCopy(exe.getEmittedBin(), .{
        .basename = "kernel.hex",
        .format = .hex,
    });
    cmd.addFileArg(hex.getOutput());

    cmd.addArg("--output");
    const uf2 = cmd.addOutputFileArg("kernel.uf2");

    return &b.addInstallFile(uf2, b.fmt("kernel_{t}.uf2", .{soc})).step;
}
