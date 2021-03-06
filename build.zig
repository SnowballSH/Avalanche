const std = @import("std");

var NNUE_SOURCE: [12]u8 = undefined;

fn le_to_u32(idx: usize) u32 {
    return @as(u32, NNUE_SOURCE[idx + 0]) | (@as(u32, NNUE_SOURCE[idx + 1]) << 8) | (@as(u32, NNUE_SOURCE[idx + 2]) << 16) | (@as(u32, NNUE_SOURCE[idx + 3]) << 24);
}

fn next_u32(idx: *usize) u32 {
    var v = le_to_u32(idx.*);
    idx.* += 4;
    return v;
}

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const targetName = b.option([]const u8, "target-name", "Change the out name of the binary") orelse "Avalanche";

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable(targetName, "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    const build_options = b.addOptions();
    exe.addOptions("build_options", build_options);

    {
        const nnue_file = std.fs.cwd().openFile(
            "nets/default.nnue",
            .{},
        ) catch {
            std.debug.panic("Unable to open nets/default.nnue", .{});
        };
        defer nnue_file.close();
        _ = nnue_file.read(NNUE_SOURCE[0..]) catch {
            std.debug.panic("Unable to read nets/default.nnue", .{});
        };

        var index: usize = 0;

        var input_size = next_u32(&index);
        var hidden_size = next_u32(&index);
        var output_size = next_u32(&index);

        build_options.addOption(usize, "INPUT_SIZE", @intCast(usize, input_size));
        build_options.addOption(usize, "HIDDEN_SIZE", @intCast(usize, hidden_size));
        build_options.addOption(usize, "OUTPUT_SIZE", @intCast(usize, output_size));
    }

    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/tests.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
