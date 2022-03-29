const std = @import("std");

const NNUE_SOURCE = @embedFile("./nets/default.nnue");

fn le_to_u32(comptime idx: usize) u32 {
    return @as(u32, NNUE_SOURCE[idx + 0]) | (@as(u32, NNUE_SOURCE[idx + 1]) << 8) | (@as(u32, NNUE_SOURCE[idx + 2]) << 16) | (@as(u32, NNUE_SOURCE[idx + 3]) << 24);
}

fn le_to_i8(comptime idx: usize) i8 {
    comptime var k = @intCast(i8, NNUE_SOURCE[idx] & 0b0111_1111);
    if (NNUE_SOURCE[idx] & 0b1000_0000 != 0) {
        k = ~(127 - k);
    }

    return k;
}

fn le_to_i32(comptime idx: usize) i32 {
    var num = le_to_u32(idx);
    comptime var k = @intCast(i32, num & 0b0111_1111_1111_1111_1111_1111_1111_1111);
    if (num & 0b1000_0000_0000_0000_0000_0000_0000_0000 != 0) {
        k = ~(2147483647 - k);
    }

    return k;
}

fn next_u32(comptime idx: *usize) u32 {
    var v = le_to_u32(idx.*);
    idx.* += 4;
    return v;
}

fn next_dense(comptime idx: *usize, comptime input: u32, comptime output: u32) [input][output]i8 {
    comptime var arr: [input][output]i8 = undefined;
    comptime var i = 0;
    while (i < input) {
        comptime var j = 0;
        while (j < output) {
            arr[i][j] = le_to_i8(idx.*);
            idx.* += 1;
            j += 1;
        }
        i += 1;
    }
    return arr;
}

fn next_dense_32(comptime idx: *usize, comptime input: u32, comptime output: u32) [input][output]i32 {
    comptime var arr: [input][output]i32 = undefined;
    comptime var i = 0;
    while (i < input) {
        comptime var j = 0;
        while (j < output) {
            arr[i][j] = le_to_i32(idx.*);
            idx.* += 4;
            j += 1;
        }
        i += 1;
    }
    return arr;
}

fn next_bias(comptime idx: *usize, comptime output: u32) [output]i8 {
    comptime var arr: [output]i8 = undefined;
    comptime var j = 0;
    while (j < output) {
        arr[j] = le_to_i8(idx.*);
        idx.* += 1;
        j += 1;
    }
    return arr;
}

fn do_nnue() void {
    @setEvalBranchQuota(10000000);

    comptime var index: usize = 0;

    const file = std.fs.cwd().createFile(
        "src/weights.zig",
        .{ .read = true },
    ) catch {
        std.debug.panic("Unable to open src/weights.zig", .{});
        unreachable;
    };
    const writer = file.writer();

    comptime var input_size = next_u32(&index);

    comptime var hidden_size = next_u32(&index);

    comptime var output_size = next_u32(&index);

    writer.print("pub const INPUT_SIZE: usize = {};\npub const HIDDEN_SIZE: usize = {};\npub const OUTPUT_SIZE: usize = {};\n", .{ input_size, hidden_size, output_size }) catch {};

    comptime var layer1 = next_dense(&index, input_size, hidden_size);

    writer.writeAll("pub const LAYER_1: [INPUT_SIZE][HIDDEN_SIZE]i8 = .{") catch {};

    for (layer1) |k| {
        writer.writeAll(".{") catch {};
        for (k) |v| {
            writer.print("{},", .{v}) catch {};
        }
        writer.writeAll("},") catch {};
    }

    writer.writeAll("};\n") catch {};

    comptime var bias1 = next_bias(&index, hidden_size);

    writer.writeAll("pub const BIAS_1: [HIDDEN_SIZE]i16 = .{") catch {};

    for (bias1) |k| {
        writer.print("{},", .{k}) catch {};
    }

    writer.writeAll("};\n") catch {};

    comptime var layer2 = next_dense(&index, hidden_size, output_size);

    writer.writeAll("pub const LAYER_2: [HIDDEN_SIZE][OUTPUT_SIZE]i8 = .{") catch {};

    for (layer2) |k| {
        writer.writeAll(".{") catch {};
        for (k) |v| {
            writer.print("{},", .{v}) catch {};
        }
        writer.writeAll("},") catch {};
    }

    writer.writeAll("};\n") catch {};

    comptime var bias2 = next_bias(&index, output_size);

    writer.writeAll("pub const BIAS_2: [OUTPUT_SIZE]i16 = .{") catch {};

    for (bias2) |k| {
        writer.print("{},", .{k}) catch {};
    }

    writer.writeAll("};\n") catch {};

    comptime var residual = next_dense_32(&index, input_size, output_size);

    writer.writeAll("pub const PSQT: [INPUT_SIZE][OUTPUT_SIZE]i32 = .{") catch {};

    for (residual) |k| {
        writer.writeAll(".{") catch {};
        for (k) |v| {
            writer.print("{},", .{v}) catch {};
        }
        writer.writeAll("},") catch {};
    }

    writer.writeAll("};\n") catch {};

    std.debug.assert(index == std.mem.len(NNUE_SOURCE));
}

pub fn build(b: *std.build.Builder) void {
    if (b.args != null) {
        for (b.args.?) |arg| {
            if (std.mem.eql(u8, arg, "nnue")) {
                do_nnue();
                break;
            }
        }
    }

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("Avalanche", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkSystemLibrary("c");
    exe.addIncludeDir("./src/c");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
