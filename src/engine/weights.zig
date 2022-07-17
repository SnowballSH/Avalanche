const std = @import("std");
const arch = @import("build_options");

const builtin = @import("builtin");
pub fn suggestVectorSizeForCpu(comptime T: type, cpu: std.Target.Cpu) usize {
    switch (cpu.arch) {
        .x86_64 => {
            // Note: This is mostly just guesswork. It'd be great if someone more qualified were to take a
            // proper look at this.

            if (T == bool and std.Target.x86.featureSetHas(.prefer_mask_registers)) return 64;

            const vector_bit_size = blk: {
                if (std.Target.x86.featureSetHas(.avx512f)) break :blk 512;
                if (std.Target.x86.featureSetHas(.prefer_256_bit)) break :blk 256;
                if (std.Target.x86.featureSetHas(.prefer_128_bit)) break :blk 128;
                break :blk 64;
            };
            const element_bit_size = @maximum(8, std.math.ceilPowerOfTwo(T, @bitSizeOf(T)) catch @panic("Never"));
            return @divExact(vector_bit_size, element_bit_size);
        },
        else => {
            const element_bit_size = @maximum(8, std.math.ceilPowerOfTwo(T, @bitSizeOf(T)) catch @panic("Never"));
            return @divExact(128, element_bit_size);
        },
    }
}

pub fn suggestVectorSize(comptime T: type) usize {
    return suggestVectorSizeForCpu(T, builtin.cpu);
}

pub const VECTOR_SIZE = suggestVectorSize(u16);

const NNUE_SOURCE = @embedFile("../../nets/default.nnue");

pub var LAYER_1: [arch.INPUT_SIZE][arch.HIDDEN_SIZE / VECTOR_SIZE]@Vector(VECTOR_SIZE, i16) = undefined;
pub var BIAS_1: [arch.HIDDEN_SIZE]i16 = undefined;
pub var LAYER_2: [arch.HIDDEN_SIZE][arch.OUTPUT_SIZE]i16 = undefined;
pub var BIAS_2: [arch.OUTPUT_SIZE]i16 = undefined;
pub var PSQT: [arch.INPUT_SIZE][arch.OUTPUT_SIZE]i32 = undefined;

pub const INPUT_SIZE = arch.INPUT_SIZE;
pub const HIDDEN_SIZE = arch.HIDDEN_SIZE;
pub const OUTPUT_SIZE = arch.OUTPUT_SIZE;

fn le_to_u32(idx: usize) u32 {
    return @as(u32, NNUE_SOURCE[idx + 0]) | (@as(u32, NNUE_SOURCE[idx + 1]) << 8) | (@as(u32, NNUE_SOURCE[idx + 2]) << 16) | (@as(u32, NNUE_SOURCE[idx + 3]) << 24);
}

fn le_to_i8(idx: usize) i8 {
    var k = @intCast(i8, NNUE_SOURCE[idx] & 0b0111_1111);
    if (NNUE_SOURCE[idx] & 0b1000_0000 != 0) {
        k = ~(127 - k);
    }

    return k;
}

fn le_to_i32(idx: usize) i32 {
    var num = le_to_u32(idx);
    var k = @intCast(i32, num & 0b0111_1111_1111_1111_1111_1111_1111_1111);
    if (num & 0b1000_0000_0000_0000_0000_0000_0000_0000 != 0) {
        k = ~(2147483647 - k);
    }

    return k;
}

fn next_u32(idx: *usize) u32 {
    var v = le_to_u32(idx.*);
    idx.* += 4;
    return v;
}

fn next_dense(idx: *usize, comptime input: u32, comptime output: u32) [input][output]i16 {
    var arr: [input][output]i16 = undefined;
    var i: usize = 0;
    while (i < input) {
        var j: usize = 0;
        while (j < output) {
            arr[i][j] = @intCast(i16, le_to_i8(idx.*));
            idx.* += 1;
            j += 1;
        }
        i += 1;
    }
    return arr;
}

fn next_dense_32(idx: *usize, comptime input: u32, comptime output: u32) [input][output]i32 {
    var arr: [input][output]i32 = undefined;
    var i: usize = 0;
    while (i < input) {
        var j: usize = 0;
        while (j < output) {
            arr[i][j] = le_to_i32(idx.*);
            idx.* += 4;
            j += 1;
        }
        i += 1;
    }
    return arr;
}

fn next_bias(idx: *usize, comptime output: u32) [output]i16 {
    var arr: [output]i16 = undefined;
    var j: usize = 0;
    while (j < output) {
        arr[j] = @intCast(i16, le_to_i8(idx.*));
        idx.* += 1;
        j += 1;
    }
    return arr;
}

pub fn do_nnue() void {
    var index: usize = 0;

    _ = next_u32(&index);
    _ = next_u32(&index);
    _ = next_u32(&index);

    const input_size = INPUT_SIZE;
    const hidden_size = HIDDEN_SIZE;
    const output_size = OUTPUT_SIZE;

    var l1 = next_dense(&index, input_size, hidden_size);
    for (LAYER_1) |*ptr, i| {
        inline for (@as([HIDDEN_SIZE / VECTOR_SIZE]u0, undefined)) |_, j| {
            var v: @Vector(VECTOR_SIZE, i16) = l1[i][(j * VECTOR_SIZE)..][0..VECTOR_SIZE].*;
            ptr.*[j] = v;
        }
    }

    BIAS_1 = next_bias(&index, hidden_size);

    LAYER_2 = next_dense(&index, hidden_size, output_size);

    BIAS_2 = next_bias(&index, output_size);

    PSQT = next_dense_32(&index, input_size, output_size);

    std.debug.assert(index == std.mem.len(NNUE_SOURCE));
}
