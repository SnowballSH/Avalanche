//! Multi-layer head, bucketed by material:
//! `(1024)x2 -> pairwise CReLU -> L1(1024 -> 16) -> [CReLU, CReLU^2] -> L2(32 -> 32) CReLU -> L3(32 -> 1)`.
//!
//! Everything is integer arithmetic with explicit shifts, so every path below
//! gives the same value on every target. docs/NNUE.md is the specification;
//! the trainer (training/src/multilayer.rs) writes the layout of `Weights`.

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch.zig");

const HIDDEN_SIZE = arch.HIDDEN_SIZE;
const OUTPUT_SIZE = arch.OUTPUT_SIZE;
const QA = arch.QA;
const SCALE = arch.SCALE;

/// Pairwise products per perspective.
pub const PAIRS: usize = HIDDEN_SIZE / 2;
/// L1 inputs: the side to move's pairwise products, then the opponent's.
pub const L1_INPUTS: usize = 2 * PAIRS;
/// L1 inputs are consumed in blocks of four, the unit of the sparse product.
pub const L1_BLOCKS: usize = L1_INPUTS / 4;
pub const L1_SIZE: usize = 16;
pub const L2_INPUTS: usize = 2 * L1_SIZE;
pub const L2_SIZE: usize = 32;

/// `(a * b + 256) >> FT_SHIFT` maps a product of two 0..255 activations to
/// 0..127, so it is a valid operand for both x86 `pmaddubsw` (which cannot
/// saturate with it) and NEON `sdot`.
pub const FT_SHIFT = 9;
pub const FT_ROUND: i32 = 1 << (FT_SHIFT - 1);
/// Integer activation of a pairwise product of 1.0: 255 * 255 / 512.
pub const PAIRWISE_ONE: f64 = @as(f64, @floatFromInt(QA * QA)) / @as(f64, 1 << FT_SHIFT);

/// Fixed-point position of the L1 output and of every later activation.
pub const ACT_BITS = 13;
pub const ONE: i32 = 1 << ACT_BITS;
/// Fixed-point position of the L2 and L3 weights.
pub const WEIGHT_BITS = 10;
/// Fixed-point position of the L2 and L3 biases and pre-activations.
pub const SUM_BITS = ACT_BITS + WEIGHT_BITS;

/// L1 weights are stored as `round(w * L1_WEIGHT_SCALE)`, which makes an L1
/// sum of quantised activations land exactly on `ACT_BITS`.
pub const L1_WEIGHT_SCALE: f64 = @as(f64, @floatFromInt(ONE)) / PAIRWISE_ONE;

/// Largest magnitude of an L2 or L3 weight, and of any bias. Together they
/// keep every i32 sum below 2^31: 32 * 2047 * 8192 < 2^29.
pub const WEIGHT_LIMIT: i32 = 2047;
pub const BIAS_LIMIT: i32 = 1 << 30;

/// The part of the architecture name after the feature transformer.
pub const DESCRIPTION = std.fmt.comptimePrint("pairwise->{d}x2->{d}->1x{d}", .{ L1_SIZE, L2_SIZE, OUTPUT_SIZE });

pub const Weights = extern struct {
    /// `[bucket][input block][output][input within the block]`.
    l1_weights: [OUTPUT_SIZE][L1_BLOCKS][L1_SIZE][4]i8 align(64),
    l1_bias: [OUTPUT_SIZE][L1_SIZE]i32 align(64),
    /// `[bucket][input][output]`; inputs are the 16 CReLU values, then their squares.
    l2_weights: [OUTPUT_SIZE][L2_INPUTS][L2_SIZE]i32 align(64),
    l2_bias: [OUTPUT_SIZE][L2_SIZE]i32 align(64),
    l3_weights: [OUTPUT_SIZE][L2_SIZE]i32 align(64),
    l3_bias: [OUTPUT_SIZE]i32 align(64),
};

pub const ValidateError = error{ WeightOutOfRange, BiasOutOfRange };

fn check_range(bytes: []const u8, comptime field: []const u8, limit: i32) bool {
    const section = bytes[@offsetOf(Weights, field)..][0..@sizeOf(@FieldType(Weights, field))];
    var i: usize = 0;
    while (i < section.len) : (i += 4) {
        const value = std.mem.readInt(i32, section[i..][0..4], .little);
        if (value < -limit or value > limit) return false;
    }
    return true;
}

/// Checks the head's bytes (the layout of `Weights`) for the ranges that keep
/// the i32 sums from overflowing. Every i8 is a valid L1 weight.
pub fn validate(bytes: []const u8) ValidateError!void {
    inline for (.{ "l2_weights", "l3_weights" }) |field| {
        if (!check_range(bytes, field, WEIGHT_LIMIT)) return ValidateError.WeightOutOfRange;
    }
    inline for (.{ "l1_bias", "l2_bias", "l3_bias" }) |field| {
        if (!check_range(bytes, field, BIAS_LIMIT)) return ValidateError.BiasOutOfRange;
    }
}

const Activations = [L1_INPUTS]u8;

inline fn pairwise(a: i16, b: i16) u8 {
    const ca: i32 = std.math.clamp(a, 0, QA);
    const cb: i32 = std.math.clamp(b, 0, QA);
    return @intCast((ca * cb + FT_ROUND) >> FT_SHIFT);
}

fn activate_scalar(own: *const arch.Accumulator, opp: *const arch.Accumulator, out: *Activations) void {
    for ([_]*const arch.Accumulator{ own, opp }, 0..) |acc, side| {
        for (0..PAIRS) |i| out[side * PAIRS + i] = pairwise(acc[i], acc[i + PAIRS]);
    }
}

inline fn to_centipawns(output: i32) i32 {
    return @intCast(@divTrunc(@as(i64, output) * SCALE, 1 << SUM_BITS));
}

inline fn round_shift(value: i32, comptime bits: comptime_int) i32 {
    return (value + (1 << (bits - 1))) >> bits;
}

/// The reference implementation: one plain loop per stage of docs/NNUE.md.
pub fn evaluate_scalar(head: *const Weights, own: *const arch.Accumulator, opp: *const arch.Accumulator, bucket: usize) i32 {
    var activations: Activations = undefined;
    activate_scalar(own, opp, &activations);

    var z1 = head.l1_bias[bucket];
    for (0..L1_BLOCKS) |block| {
        const inputs = activations[block * 4 ..][0..4];
        if (std.mem.readInt(u32, inputs, .little) == 0) continue;
        for (&z1, &head.l1_weights[bucket][block]) |*sum, *block_weights| {
            for (inputs, block_weights) |input, weight| sum.* += @as(i32, input) * weight;
        }
    }

    var hidden: [L2_INPUTS]i32 = undefined;
    for (z1, 0..) |sum, j| {
        const clipped = std.math.clamp(sum, 0, ONE);
        hidden[j] = clipped;
        hidden[L1_SIZE + j] = round_shift(clipped * clipped, ACT_BITS);
    }

    var z2 = head.l2_bias[bucket];
    for (hidden, &head.l2_weights[bucket]) |input, *column| {
        for (&z2, column) |*sum, weight| sum.* += input * weight;
    }

    var output = head.l3_bias[bucket];
    for (z2, head.l3_weights[bucket]) |sum, weight| {
        output += std.math.clamp(round_shift(sum, WEIGHT_BITS), 0, ONE) * weight;
    }
    return to_centipawns(output);
}

const PAIR_LANES = @min(std.simd.suggestVectorLength(i16) orelse 8, 32);
const DOT_LANES = @min(std.simd.suggestVectorLength(i8) orelse 16, 64);
const DOT_CHUNKS = 64 / DOT_LANES;
const DotI8 = @Vector(DOT_LANES, i8);
const DotI16 = @Vector(DOT_LANES / 2, i16);
const DotI32 = @Vector(DOT_LANES / 4, i32);
/// L1 inputs examined per step of the non-zero block search.
const NNZ_BYTES = 64;

comptime {
    std.debug.assert(PAIRS % PAIR_LANES == 0);
    std.debug.assert(L1_INPUTS % NNZ_BYTES == 0);
    std.debug.assert(L1_SIZE * 4 == DOT_CHUNKS * DOT_LANES);
}

fn activate_simd(own: *const arch.Accumulator, opp: *const arch.Accumulator, out: *align(64) Activations) void {
    const I16 = @Vector(PAIR_LANES, i16);
    const U16 = @Vector(PAIR_LANES, u16);
    const zero: I16 = @splat(0);
    const cap: I16 = @splat(QA);
    inline for (.{ own, opp }, 0..) |acc, side| {
        var i: usize = 0;
        while (i < PAIRS) : (i += PAIR_LANES) {
            const a: U16 = @bitCast(std.math.clamp(@as(I16, acc[i..][0..PAIR_LANES].*), zero, cap));
            const b: U16 = @bitCast(std.math.clamp(@as(I16, acc[i + PAIRS ..][0..PAIR_LANES].*), zero, cap));
            // 255 * 255 + 256 fits in a u16, so the wrapping product is exact.
            const product = (a *% b +% @as(U16, @splat(FT_ROUND))) >> @splat(FT_SHIFT);
            out[side * PAIRS + i ..][0..PAIR_LANES].* = @as(@Vector(PAIR_LANES, u8), @truncate(product));
        }
    }
}

/// Indices of the four-input blocks with a non-zero activation, in ascending order.
fn nonzero_blocks(activations: *align(64) const Activations, indices: *[L1_BLOCKS]u16) usize {
    const Blocks = @Vector(NNZ_BYTES / 4, u32);
    const zero: Blocks = @splat(0);
    var count: usize = 0;
    var base: usize = 0;
    while (base < L1_BLOCKS) : (base += NNZ_BYTES / 4) {
        const bytes: @Vector(NNZ_BYTES, u8) = activations[base * 4 ..][0..NNZ_BYTES].*;
        var mask: std.meta.Int(.unsigned, NNZ_BYTES / 4) = @bitCast(@as(Blocks, @bitCast(bytes)) != zero);
        while (mask != 0) : (mask &= mask - 1) {
            indices[count] = @intCast(base + @ctz(mask));
            count += 1;
        }
    }
    return count;
}

const use_maddubs = builtin.mode != .Debug and builtin.cpu.arch.isX86() and switch (DOT_LANES) {
    64 => builtin.cpu.has(.x86, .avx512bw),
    32 => builtin.cpu.has(.x86, .avx2),
    16 => builtin.cpu.has(.x86, .ssse3),
    else => false,
};
const use_sdot = builtin.mode != .Debug and builtin.cpu.arch == .aarch64 and DOT_LANES == 16 and builtin.cpu.has(.aarch64, .dotprod);

/// `sum[i] + dot(inputs[4i..4i+4], block_weights[4i..4i+4])`. `inputs` holds
/// activations, 0..127. The intrinsic paths cannot saturate in that range, so
/// all three give the exact sum.
inline fn dot_accumulate(sum: DotI32, inputs: DotI8, block_weights: DotI8) DotI32 {
    if (comptime use_maddubs) {
        const maddubs = @extern(*const fn (DotI8, DotI8) callconv(.c) DotI16, .{ .name = switch (DOT_LANES) {
            64 => "llvm.x86.avx512.pmaddubs.w.512",
            32 => "llvm.x86.avx2.pmadd.ub.sw",
            16 => "llvm.x86.ssse3.pmadd.ub.sw.128",
            else => unreachable,
        } });
        const maddwd = @extern(*const fn (DotI16, DotI16) callconv(.c) DotI32, .{ .name = switch (DOT_LANES) {
            64 => "llvm.x86.avx512.pmaddw.d.512",
            32 => "llvm.x86.avx2.pmadd.wd",
            16 => "llvm.x86.sse2.pmadd.wd",
            else => unreachable,
        } });
        return sum + maddwd.*(maddubs.*(inputs, block_weights), @splat(1));
    }
    if (comptime use_sdot) {
        return @extern(*const fn (DotI32, DotI8, DotI8) callconv(.c) DotI32, .{ .name = "llvm.aarch64.neon.sdot.v4i32.v16i8" }).*(sum, inputs, block_weights);
    }

    const Wide = @Vector(DOT_LANES, i16);
    const products = std.simd.deinterlace(4, @as(Wide, inputs) * @as(Wide, block_weights));
    var result = sum;
    inline for (products) |part| result += @as(DotI32, part);
    return result;
}

fn l1_simd(head: *const Weights, activations: *align(64) const Activations, bucket: usize) @Vector(L1_SIZE, i32) {
    var indices: [L1_BLOCKS]u16 = undefined;
    const count = nonzero_blocks(activations, &indices);

    var sums: [DOT_CHUNKS]DotI32 = @bitCast(head.l1_bias[bucket]);
    const l1_weights: *const [L1_BLOCKS][L1_SIZE * 4]i8 = @ptrCast(&head.l1_weights[bucket]);
    for (indices[0..count]) |block| {
        const block_inputs = std.mem.readInt(u32, activations[@as(usize, block) * 4 ..][0..4], .little);
        const inputs: DotI8 = @bitCast(@as(@Vector(DOT_LANES / 4, u32), @splat(block_inputs)));
        inline for (&sums, 0..) |*sum, chunk| {
            const block_weights: DotI8 = l1_weights[block][chunk * DOT_LANES ..][0..DOT_LANES].*;
            sum.* = dot_accumulate(sum.*, inputs, block_weights);
        }
    }
    return @bitCast(sums);
}

/// Same value as `evaluate_scalar`, with vectors.
pub fn evaluate_simd(head: *const Weights, own: *const arch.Accumulator, opp: *const arch.Accumulator, bucket: usize) i32 {
    var activations: Activations align(64) = undefined;
    activate_simd(own, opp, &activations);

    const L1 = @Vector(L1_SIZE, i32);
    const L2 = @Vector(L2_SIZE, i32);

    const z1 = l1_simd(head, &activations, bucket);
    const clipped = @min(@max(z1, @as(L1, @splat(0))), @as(L1, @splat(ONE)));
    const squared = (clipped * clipped + @as(L1, @splat(1 << (ACT_BITS - 1)))) >> @splat(ACT_BITS);
    const hidden: [L2_INPUTS]i32 = @bitCast([2]L1{ clipped, squared });

    var z2: L2 = head.l2_bias[bucket];
    inline for (hidden, &head.l2_weights[bucket]) |input, *column| {
        z2 += @as(L2, @splat(input)) * @as(L2, column.*);
    }

    const rounded = (z2 + @as(L2, @splat(1 << (WEIGHT_BITS - 1)))) >> @splat(WEIGHT_BITS);
    const activated = @min(@max(rounded, @as(L2, @splat(0))), @as(L2, @splat(ONE)));
    const output = head.l3_bias[bucket] + @reduce(.Add, activated * @as(L2, head.l3_weights[bucket]));
    return to_centipawns(output);
}

/// Evaluation in centipawns for the side to move, whose accumulator is `own`.
pub inline fn evaluate(head: *const Weights, own: *const arch.Accumulator, opp: *const arch.Accumulator, bucket: usize) i32 {
    return evaluate_simd(head, own, opp, bucket);
}

pub const FloatMode = enum {
    /// The trainer's forward pass: exact pairwise products.
    trainer,
    /// The pairwise products the engine computes, 0..127 in steps of 1/127.002;
    /// isolates the layers after the pairwise step.
    quantised_pairwise,
};

/// The forward pass in floating point, in centipawns, from the quantised
/// weights of `head` and accumulators of the quantised feature transformer.
/// It never rounds an intermediate value.
pub fn evaluate_float(head: *const Weights, own: *const arch.Accumulator, opp: *const arch.Accumulator, bucket: usize, mode: FloatMode) f64 {
    const one: f64 = @floatFromInt(ONE);
    const weight_one: f64 = @floatFromInt(1 << WEIGHT_BITS);
    const sum_one: f64 = @floatFromInt(1 << SUM_BITS);
    const qa: f64 = @floatFromInt(QA);

    var z1: [L1_SIZE]f64 = undefined;
    for (&z1, head.l1_bias[bucket]) |*sum, bias| sum.* = @as(f64, @floatFromInt(bias)) / one;
    for ([_]*const arch.Accumulator{ own, opp }, 0..) |acc, side| {
        for (0..PAIRS) |i| {
            const activation: f64 = switch (mode) {
                .trainer => blk: {
                    const a: f64 = @floatFromInt(std.math.clamp(acc[i], 0, QA));
                    const b: f64 = @floatFromInt(std.math.clamp(acc[i + PAIRS], 0, QA));
                    break :blk (a / qa) * (b / qa);
                },
                .quantised_pairwise => @as(f64, @floatFromInt(pairwise(acc[i], acc[i + PAIRS]))) / PAIRWISE_ONE,
            };
            const input = side * PAIRS + i;
            for (&z1, &head.l1_weights[bucket][input / 4]) |*sum, *block_weights| {
                sum.* += activation * @as(f64, @floatFromInt(block_weights[input % 4])) / L1_WEIGHT_SCALE;
            }
        }
    }

    var hidden: [L2_INPUTS]f64 = undefined;
    for (z1, 0..) |sum, j| {
        const clipped = std.math.clamp(sum, 0.0, 1.0);
        hidden[j] = clipped;
        hidden[L1_SIZE + j] = clipped * clipped;
    }

    var output: f64 = @as(f64, @floatFromInt(head.l3_bias[bucket])) / sum_one;
    for (0..L2_SIZE) |o| {
        var sum: f64 = @as(f64, @floatFromInt(head.l2_bias[bucket][o])) / sum_one;
        for (hidden, &head.l2_weights[bucket]) |input, *column| {
            sum += input * @as(f64, @floatFromInt(column[o])) / weight_one;
        }
        output += std.math.clamp(sum, 0.0, 1.0) * @as(f64, @floatFromInt(head.l3_weights[bucket][o])) / weight_one;
    }
    return output * @as(f64, @floatFromInt(SCALE));
}

/// Largest L1 weight magnitudes `fill_random` draws from; trained networks are
/// far below the i8 range, and the float comparison is only meaningful there.
pub const RandomRange = struct {
    l1_weight: i8 = 127,
    weight: i32 = WEIGHT_LIMIT,
    l1_bias: i32 = ONE,
    bias: i32 = 1 << SUM_BITS,
};

/// Fills `head` with uniform random weights inside the validated ranges.
pub fn fill_random(head: *Weights, random: std.Random, range: RandomRange) void {
    for (std.mem.asBytes(&head.l1_weights)) |*byte| {
        byte.* = @bitCast(random.intRangeAtMost(i8, -range.l1_weight, range.l1_weight));
    }
    inline for (.{ "l2_weights", "l3_weights", "l1_bias", "l2_bias", "l3_bias" }, .{ range.weight, range.weight, range.l1_bias, range.bias, range.bias }) |field, limit| {
        const values: *[@sizeOf(@FieldType(Weights, field)) / 4]i32 = @ptrCast(&@field(head, field));
        for (values) |*value| value.* = random.intRangeAtMost(i32, -limit, limit);
    }
}
