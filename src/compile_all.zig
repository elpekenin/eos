const std = @import("std");
const targets = @import("targets");

fn fields(comptime T: type) []const std.builtin.Type.EnumField {
    return @typeInfo(T).@"enum".fields;
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    const alloc = allocator.allocator();

    var stdout: std.fs.File = .stdout();
    var writer = stdout.writer(&.{}).interface;

    try writer.print("compiling for every target\n", .{});
    inline for (fields(targets.Soc)) |field| {
        const soc = field.name;

        const args: []const []const u8 = &.{
            "zig",
            "build",
            std.fmt.comptimePrint("-Dsoc={s}", .{soc}),
        };

        var process: std.process.Child = .init(args, alloc);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;

        const config: std.Io.tty.Config = .detect(stdout);

        switch (try process.spawnAndWait()) {
            .Exited => |code| {
                const color: std.Io.tty.Color = switch (code) {
                    0 => .green,
                    else => .red,
                };

                try config.setColor(&writer, color);
                try writer.print("  {s}", .{soc});
                try config.setColor(&writer, .reset);
            },
            else => |exit| {
                try config.setColor(&writer, .red);
                try writer.print("ended unexpectedly: {}", .{exit});
                try config.setColor(&writer, .reset);
            },
        }
        try writer.print("\n", .{});
    }
    try writer.print("\n", .{});
}
