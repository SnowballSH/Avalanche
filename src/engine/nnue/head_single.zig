//! See "Single-layer head" in docs/NNUE.md.

const std = @import("std");
const arch = @import("arch.zig");

const HIDDEN_SIZE = arch.HIDDEN_SIZE;
const OUTPUT_SIZE = arch.OUTPUT_SIZE;
const QA = arch.QA;
const QB: i32 = 64;
const QAB: i32 = QA * QB;
const SCALE = arch.SCALE;

pub const OUTPUT_WEIGHT_MIN: i16 = -128;
pub const OUTPUT_WEIGHT_MAX: i16 = 127;

pub const DESCRIPTION = std.fmt.comptimePrint("{d}", .{OUTPUT_SIZE});

pub const Weights = extern struct {
    layer_2: [OUTPUT_SIZE][HIDDEN_SIZE * 2]i16 align(64),
    layer_2_bias: [OUTPUT_SIZE]i16 align(64),
};

pub const ValidateError = error{OutputWeightOutOfRange};

pub fn validate(bytes: *const [@sizeOf(Weights)]u8) ValidateError!void {
    const layer_2 = bytes[@offsetOf(Weights, "layer_2")..][0..@sizeOf(@FieldType(Weights, "layer_2"))];
    var i: usize = 0;
    while (i < layer_2.len) : (i += 2) {
        const weight = std.mem.readInt(i16, layer_2[i..][0..2], .little);
        if (weight < OUTPUT_WEIGHT_MIN or weight > OUTPUT_WEIGHT_MAX) return ValidateError.OutputWeightOutOfRange;
    }
}

const OUTPUT_LANES = @min(std.simd.suggestVectorLength(i16) orelse 8, arch.WIDEST_VECTOR_BITS / 16);
const OutputI16 = @Vector(OUTPUT_LANES, i16);
const OutputI32 = @Vector(OUTPUT_LANES / 2, i32);

comptime {
    std.debug.assert(HIDDEN_SIZE % (OUTPUT_LANES * 4) == 0);
}

inline fn madd_i16(a: OutputI16, b: OutputI16) OutputI32 {
    if (comptime arch.pair_products_intrinsic(@bitSizeOf(OutputI16))) |name| {
        return @extern(*const fn (OutputI16, OutputI16) callconv(arch.intrinsic_call) OutputI32, .{ .name = name }).*(a, b);
    }

    const a_parts = std.simd.deinterlace(2, a);
    const b_parts = std.simd.deinterlace(2, b);
    const even = @as(OutputI32, @intCast(a_parts[0])) * @as(OutputI32, @intCast(b_parts[0]));
    const odd = @as(OutputI32, @intCast(a_parts[1])) * @as(OutputI32, @intCast(b_parts[1]));
    return even + odd;
}

pub inline fn evaluate(head: *const Weights, own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize) i32 {
    const w2 = &head.layer_2[bucket];

    const zero: OutputI16 = @splat(0);
    const cap: OutputI16 = @splat(QA);

    var sums: [4]OutputI32 = @splat(@splat(0));
    var i: usize = 0;
    while (i < HIDDEN_SIZE) {
        inline for (&sums) |*sum| {
            const own_activation = std.math.clamp(@as(OutputI16, own[i..][0..OUTPUT_LANES].*), zero, cap);
            const opp_activation = std.math.clamp(@as(OutputI16, opp[i..][0..OUTPUT_LANES].*), zero, cap);
            const own_weights: OutputI16 = w2[i..][0..OUTPUT_LANES].*;
            const opp_weights: OutputI16 = w2[HIDDEN_SIZE + i ..][0..OUTPUT_LANES].*;

            sum.* +%= madd_i16(own_activation *% own_weights, own_activation) +
                madd_i16(opp_activation *% opp_weights, opp_activation);
            i += OUTPUT_LANES;
        }
    }

    var sum = sums[0];
    inline for (sums[1..]) |partial| sum +%= partial;
    const result = @reduce(.Add, sum);
    const scaled = (@as(i64, @divTrunc(result, QA)) + head.layer_2_bias[bucket]) * SCALE;
    return @intCast(@divTrunc(scaled, QAB));
}

const TestAccumulators = struct {
    own: arch.Accumulator align(64),
    opp: arch.Accumulator align(64),

    const saturated: TestAccumulators = .{ .own = @splat(QA), .opp = @splat(QA) };
};

fn exact_sum(head: *const Weights, acc: *const TestAccumulators, bucket: usize) i64 {
    var sum: i64 = 0;
    for (acc.own, acc.opp, head.layer_2[bucket][0..HIDDEN_SIZE], head.layer_2[bucket][HIDDEN_SIZE..]) |own, opp, own_weight, opp_weight| {
        const own_activation: i64 = std.math.clamp(own, 0, QA);
        const opp_activation: i64 = std.math.clamp(opp, 0, QA);
        sum += own_activation * own_activation * own_weight + opp_activation * opp_activation * opp_weight;
    }
    return sum;
}

fn exact_centipawns(sum: i32, bias: i16) i64 {
    return @divTrunc((@as(i64, @divTrunc(sum, QA)) + bias) * SCALE, QAB);
}

fn extreme_bias(weight: i16) i16 {
    return if (weight > 0) std.math.maxInt(i16) else std.math.minInt(i16);
}

test "single head: a sum beyond i32 wraps instead of overflowing" {
    const head = try std.testing.allocator.create(Weights);
    defer std.testing.allocator.destroy(head);
    const acc: TestAccumulators = .saturated;

    for ([_]i16{ OUTPUT_WEIGHT_MAX, OUTPUT_WEIGHT_MIN }) |weight| {
        for (&head.layer_2) |*bucket_weights| @memset(bucket_weights, weight);
        @memset(&head.layer_2_bias, extreme_bias(weight));
        try validate(std.mem.asBytes(head));

        const sum = exact_sum(head, &acc, 0);
        try std.testing.expect(@abs(sum) > std.math.maxInt(i32));
        try std.testing.expectEqual(exact_centipawns(@truncate(sum), extreme_bias(weight)), evaluate(head, &acc.own, &acc.opp, 0));
    }
}

test "single head: a sum at the edge of i32 is scaled to centipawns without overflow" {
    const head = try std.testing.allocator.create(Weights);
    defer std.testing.allocator.destroy(head);
    const acc: TestAccumulators = .saturated;

    for ([_]i16{ OUTPUT_WEIGHT_MAX, OUTPUT_WEIGHT_MIN }) |weight| {
        const fitting_weights: usize = @intCast(@divTrunc(std.math.maxInt(i32), QA * QA * @as(i32, @abs(weight))));
        @memset(std.mem.asBytes(&head.layer_2), 0);
        @memset(head.layer_2[0][0..fitting_weights], weight);
        @memset(&head.layer_2_bias, extreme_bias(weight));
        try validate(std.mem.asBytes(head));

        const sum = std.math.cast(i32, exact_sum(head, &acc, 0)).?;
        const expected = exact_centipawns(sum, extreme_bias(weight));
        try std.testing.expect(@abs(expected) * QAB > std.math.maxInt(i32));
        try std.testing.expectEqual(expected, evaluate(head, &acc.own, &acc.opp, 0));
    }
}

test "single head: the vector path follows the formula on random weights and accumulators" {
    const head = try std.testing.allocator.create(Weights);
    defer std.testing.allocator.destroy(head);
    var prng = std.Random.DefaultPrng.init(0x51_0001);
    const random = prng.random();

    for (0..8) |_| {
        for (&head.layer_2) |*bucket_weights| {
            for (bucket_weights) |*weight| weight.* = random.intRangeAtMost(i16, OUTPUT_WEIGHT_MIN, OUTPUT_WEIGHT_MAX);
        }
        for (&head.layer_2_bias) |*bias| bias.* = random.int(i16);
        try validate(std.mem.asBytes(head));

        var acc: TestAccumulators = undefined;
        for (&acc.own, &acc.opp) |*own, *opp| {
            own.* = random.intRangeAtMost(i16, -QA, 2 * QA);
            opp.* = random.intRangeAtMost(i16, -QA, 2 * QA);
        }
        for (0..OUTPUT_SIZE) |bucket| {
            const sum = std.math.cast(i32, exact_sum(head, &acc, bucket)).?;
            try std.testing.expectEqual(exact_centipawns(sum, head.layer_2_bias[bucket]), evaluate(head, &acc.own, &acc.opp, bucket));
        }
    }
}
