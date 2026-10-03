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

/// L1 weights are stored as `round(w * L1_WEIGHT_SCALE * 2^l1_shift)`. At
/// shift 0 an L1 sum of quantised activations lands exactly on `ACT_BITS`.
pub const L1_WEIGHT_SCALE: f64 = @as(f64, @floatFromInt(ONE)) / PAIRWISE_ONE;

/// Extra fixed-point bits of one network's L1 weights, bias and sum, from its
/// header. The trainer picks the largest shift that keeps every stored weight
/// in an i8, so that a net with small L1 weights still uses the whole i8
/// range. The L1 sum is rounded back to `ACT_BITS` before the activation.
pub const L1Shift = u3;
pub const L1_SHIFT_MAX: L1Shift = 7;

/// The shift the trainer picks for a net whose largest L1 weight magnitude,
/// as a float, is `max_weight`. Only the tests call it: the trainer makes the
/// choice (`l1_shift` in training/src/multilayer.rs), and rounds an f32 product
/// where this rounds an f64 one, so the two can differ for a weight within f32
/// rounding of a boundary.
pub fn l1_shift_for(max_weight: f64) L1Shift {
    var shift: L1Shift = 0;
    while (shift < L1_SHIFT_MAX and @round(max_weight * L1_WEIGHT_SCALE * @as(f64, @floatFromInt(@as(u32, 2) << shift))) <= 127) shift += 1;
    return shift;
}

/// Largest magnitude of an L2 or L3 weight, and of any bias. Together they
/// keep every i32 sum below 2^31: 32 * 2047 * 8192 < 2^29 for L2 and L3, and
/// 1024 * 127 * 128 < 2^24 for L1 at any shift.
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

/// Largest difference, in centipawns, between `evaluate` and `evaluate_float`
/// that the tests accept; docs/NNUE.md explains both.
///
/// With the engine's own pairwise products the rest of the head differs from
/// exact arithmetic by the final rounding (0.5) and the two rounding shifts.
pub const QUANTISED_TOLERANCE_CP: f64 = 0.75;
/// Against exact pairwise products, for weights of trained magnitude
/// (`parity.REALISTIC_RANGE`): the rounding of up to 1024 products to 1/127.
pub const TRAINER_TOLERANCE_CP: f64 = 16.0;
/// Against float L1 weights, on the engine's pairwise products, for a net
/// stored with the shift `l1_shift_for` picks: the rounding of the L1 weights
/// to at least 64 levels of the largest one.
pub const L1_ROUNDING_TOLERANCE_CP: f64 = 16.0;

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

pub const Activations = [L1_INPUTS]u8;
/// The largest pairwise product. The L1 dot products are exact only up to it:
/// `pmaddubsw` saturates and `sdot` reads a larger byte as negative.
pub const ACTIVATION_MAX: u8 = (QA * QA + FT_ROUND) >> FT_SHIFT;

pub inline fn pairwise(a: i16, b: i16) u8 {
    const ca: i32 = std.math.clamp(a, 0, QA);
    const cb: i32 = std.math.clamp(b, 0, QA);
    return @intCast((ca * cb + FT_ROUND) >> FT_SHIFT);
}

fn activate_scalar(own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, out: *Activations) void {
    for ([_]arch.AccumulatorPtr{ own, opp }, 0..) |acc, side| {
        for (0..PAIRS) |i| out[side * PAIRS + i] = pairwise(acc[i], acc[i + PAIRS]);
    }
}

/// Rounds to the nearest centipawn, halves up.
inline fn to_centipawns(output: i32) i32 {
    return @intCast((@as(i64, output) * SCALE + (1 << (SUM_BITS - 1))) >> SUM_BITS);
}

inline fn round_shift(value: i32, comptime bits: comptime_int) i32 {
    return (value + (1 << (bits - 1))) >> bits;
}

/// The reference implementation: one plain loop per stage of docs/NNUE.md.
pub fn evaluate_scalar(head: *const Weights, l1_shift: L1Shift, own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize) i32 {
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
        // Back to ACT_BITS, to nearest, halves up; nothing to do at shift 0.
        const rounded = (sum + ((@as(i32, 1) << l1_shift) >> 1)) >> l1_shift;
        const clipped = std.math.clamp(rounded, 0, ONE);
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

/// Bytes per vector: the pairwise products made per step, and the L1 weights
/// per dot product.
const VECTOR_BYTES = @min(std.simd.suggestVectorLength(u8) orelse 16, 64);
const PairI16 = @Vector(VECTOR_BYTES, i16);
const PairU16 = @Vector(VECTOR_BYTES, u16);
const PairU8 = @Vector(VECTOR_BYTES, u8);
const DOT_CHUNKS = 64 / VECTOR_BYTES;
const DotI8 = @Vector(VECTOR_BYTES, i8);
const DotI16 = @Vector(VECTOR_BYTES / 2, i16);
const DotI32 = @Vector(VECTOR_BYTES / 4, i32);
const DotU32 = @Vector(VECTOR_BYTES / 4, u32);
/// Blocks examined per step of the non-zero block search: one table lookup.
const NNZ_BLOCKS = 8;

comptime {
    std.debug.assert(PAIRS % VECTOR_BYTES == 0);
    std.debug.assert(L1_BLOCKS % NNZ_BLOCKS == 0);
    std.debug.assert(L1_SIZE * 4 == DOT_CHUNKS * VECTOR_BYTES);
}

/// LLVM leaves target intrinsics unresolved at -ODebug.
const intrinsics = builtin.mode != .Debug;

fn x86_has(comptime feature: std.Target.x86.Feature) bool {
    return builtin.cpu.arch.isX86() and builtin.cpu.has(.x86, feature);
}

const wasm_simd = builtin.cpu.arch.isWasm() and builtin.cpu.has(.wasm, .simd128);

/// Which pairwise product this build compiled.
pub const PAIRWISE_PATH: enum { mulhrs, umull, portable } = if (!intrinsics)
    .portable
else if (switch (VECTOR_BYTES) {
    64 => x86_has(.avx512bw),
    32 => x86_has(.avx2),
    16 => x86_has(.ssse3) or wasm_simd,
    else => false,
})
    .mulhrs
else if (builtin.cpu.arch == .aarch64 and VECTOR_BYTES == 16 and builtin.cpu.has(.aarch64, .neon))
    .umull
else
    .portable;

/// Which L1 dot product this build compiled; the tests report when it is
/// only the portable one.
pub const L1_PATH: enum { dpbusd, maddubs, sdot, extadd, portable } = if (!intrinsics)
    .portable
else if (switch (VECTOR_BYTES) {
    64 => x86_has(.avx512vnni),
    32 => x86_has(.avxvnni) or (x86_has(.avx512vnni) and x86_has(.avx512vl)),
    else => false,
})
    .dpbusd
else if (switch (VECTOR_BYTES) {
    64 => x86_has(.avx512bw),
    32 => x86_has(.avx2),
    16 => x86_has(.ssse3),
    else => false,
})
    .maddubs
else if (builtin.cpu.arch == .aarch64 and VECTOR_BYTES == 16 and builtin.cpu.has(.aarch64, .dotprod))
    .sdot
else if (wasm_simd and VECTOR_BYTES == 16)
    .extadd
else
    .portable;

/// The instruction that multiplies i16 lanes and adds adjacent products.
const PAIR_PRODUCTS_INTRINSIC: ?[]const u8 = if (!intrinsics)
    null
else if (wasm_simd and VECTOR_BYTES == 16)
    "llvm.wasm.dot"
else switch (VECTOR_BYTES) {
    64 => if (x86_has(.avx512bw)) "llvm.x86.avx512.pmaddw.d.512" else null,
    32 => if (x86_has(.avx2)) "llvm.x86.avx2.pmadd.wd" else null,
    16 => if (x86_has(.sse2)) "llvm.x86.sse2.pmadd.wd" else null,
    else => null,
};

/// Which L2 product this build compiled: `pairs` where that instruction
/// exists, `wide` i32 multiplies elsewhere.
pub const L2_PATH: enum { pairs, wide } = if (PAIR_PRODUCTS_INTRINSIC != null) .pairs else .wide;

/// The compiled paths, for reports.
pub const SIMD_DESCRIPTION = std.fmt.comptimePrint("{d}-bit vectors, pairwise {s}, L1 {s}, L2 {s}", .{ VECTOR_BYTES * 8, @tagName(PAIRWISE_PATH), @tagName(L1_PATH), @tagName(L2_PATH) });

const HALF_LANES = VECTOR_BYTES / 2;
const HalfI16 = @Vector(HALF_LANES, i16);

inline fn halves(values: PairI16) [2]HalfI16 {
    return .{ std.simd.extract(values, 0, HALF_LANES), std.simd.extract(values, HALF_LANES, HALF_LANES) };
}

/// The 8-byte groups of a `packuswb` result, and where each group of the
/// operands in order is found in it: the first operand's are the even ones.
const PACKED_GROUPS = VECTOR_BYTES / 8;
const PackedGroups = @Vector(PACKED_GROUPS, u64);
const PACKED_ORDER: @Vector(PACKED_GROUPS, i32) = blk: {
    var order: [PACKED_GROUPS]i32 = undefined;
    for (&order, 0..) |*source, group| {
        source.* = if (group < PACKED_GROUPS / 2) 2 * group else 2 * (group - PACKED_GROUPS / 2) + 1;
    }
    break :blk order;
};

/// `pairwise` on every lane.
inline fn pairwise_lanes(a: PairI16, b: PairI16) PairU8 {
    const zero: PairI16 = @splat(0);
    const cap: PairI16 = @splat(QA);
    switch (PAIRWISE_PATH) {
        .mulhrs => {
            // `pmulhrsw` is (x * y + 2^14) >> 15, one native vector at a time.
            const mulhrs = @extern(*const fn (HalfI16, HalfI16) callconv(.c) HalfI16, .{ .name = switch (VECTOR_BYTES) {
                64 => "llvm.x86.avx512.pmul.hr.sw.512",
                32 => "llvm.x86.avx2.pmul.hr.sw",
                16 => if (wasm_simd) "llvm.wasm.q15mulr.sat.signed" else "llvm.x86.ssse3.pmul.hr.sw.128",
                else => unreachable,
            } });
            // With a scaled by 2^(15 - FT_SHIFT) that is (a * b + FT_ROUND) >> FT_SHIFT.
            // `b` keeps its sign: a negative one gives a product of at most 0.
            const scaled = halves(std.math.clamp(a, zero, cap) << @splat(15 - FT_SHIFT));
            const capped = halves(@min(b, cap));
            // `packuswb` narrows with saturation to 0..255, so a product
            // below 0 becomes 0, but it works on 128-bit lanes: the result
            // alternates 8 bytes of each operand.
            const packus = @extern(*const fn (HalfI16, HalfI16) callconv(.c) PairU8, .{ .name = switch (VECTOR_BYTES) {
                64 => "llvm.x86.avx512.packuswb.512",
                32 => "llvm.x86.avx2.packuswb",
                16 => if (wasm_simd) "llvm.wasm.narrow.unsigned.v16i8.v8i16" else "llvm.x86.sse2.packuswb.128",
                else => unreachable,
            } });
            const interleaved: PackedGroups = @bitCast(packus.*(mulhrs.*(scaled[0], capped[0]), mulhrs.*(scaled[1], capped[1])));
            return @bitCast(@shuffle(u64, interleaved, undefined, PACKED_ORDER));
        },
        .umull => {
            const HalfU8 = @Vector(HALF_LANES, u8);
            const HalfU16 = @Vector(HALF_LANES, u16);
            // `sqxtun` is clamp(x, 0, 255) as a byte; `umull` widens the product.
            const sqxtun = @extern(*const fn (HalfI16) callconv(.c) HalfU8, .{ .name = "llvm.aarch64.neon.sqxtun.v8i8" });
            const umull = @extern(*const fn (HalfU8, HalfU8) callconv(.c) HalfU16, .{ .name = "llvm.aarch64.neon.umull.v8i16" });
            var high: [2]HalfU8 = undefined;
            inline for (&high, halves(a), halves(b)) |*bytes, half_a, half_b| {
                bytes.* = @truncate(umull.*(sqxtun.*(half_a), sqxtun.*(half_b)) >> @splat(8));
            }
            // (p + 2^8) >> 9 is ((p >> 8) + 1) >> 1: the high bytes of both
            // halves at once (`uzp2`), then one rounding halving. The high
            // byte of 255 * 255 is 254, so the addition cannot wrap.
            comptime std.debug.assert(FT_SHIFT == 9);
            return (std.simd.join(high[0], high[1]) + @as(PairU8, @splat(1))) >> @splat(1);
        },
        .portable => {
            const ca: PairU16 = @bitCast(std.math.clamp(a, zero, cap));
            const cb: PairU16 = @bitCast(std.math.clamp(b, zero, cap));
            // 255 * 255 + 256 fits in a u16, so the wrapping product is exact.
            return @truncate((ca *% cb +% @as(PairU16, @splat(FT_ROUND))) >> @splat(FT_SHIFT));
        },
    }
}

/// The L1 inputs: the pairwise products of `own`, then those of `opp`.
pub fn activate(own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, out: *align(64) Activations) void {
    inline for (.{ own, opp }, 0..) |acc, side| {
        var i: usize = 0;
        while (i < PAIRS) : (i += VECTOR_BYTES) {
            out[side * PAIRS + i ..][0..VECTOR_BYTES].* = pairwise_lanes(acc[i..][0..VECTOR_BYTES].*, acc[i + PAIRS ..][0..VECTOR_BYTES].*);
        }
    }
}

/// A block index is a byte, so that the indices of the `NNZ_BLOCKS` blocks of
/// one search step are a single integer.
pub const BlockIndices = [L1_BLOCKS]u8;
const IndexGroup = u64;
/// A value with every byte of the group equal to 1.
const BYTE_ONES: IndexGroup = 0x0101_0101_0101_0101;

comptime {
    std.debug.assert(L1_BLOCKS - 1 <= std.math.maxInt(u8));
    std.debug.assert(@sizeOf(IndexGroup) == NNZ_BLOCKS);
}

/// For every mask of `NNZ_BLOCKS` bits, the positions of its set bits in
/// ascending order, one per byte from the lowest, and how many there are.
const SetBits = struct {
    positions: [1 << NNZ_BLOCKS]IndexGroup,
    counts: [1 << NNZ_BLOCKS]u8,
};

const SET_BITS: SetBits = blk: {
    @setEvalBranchQuota(10_000);
    var table: SetBits = .{ .positions = @splat(0), .counts = @splat(0) };
    for (&table.positions, &table.counts, 0..) |*positions, *count, mask| {
        for (0..NNZ_BLOCKS) |bit| {
            if (mask >> bit & 1 != 0) {
                positions.* |= @as(IndexGroup, bit) << @intCast(8 * count.*);
                count.* += 1;
            }
        }
    }
    break :blk table;
};

/// Bit i is set when block i, four activations from the lowest, is not zero.
inline fn nonzero_mask(activations: *const [NNZ_BLOCKS * 4]u8) u8 {
    if (comptime !(intrinsics and builtin.cpu.arch == .aarch64 and builtin.cpu.has(.aarch64, .neon))) {
        const blocks: @Vector(NNZ_BLOCKS, u32) = @bitCast(activations.*);
        return @bitCast(blocks != @as(@Vector(NNZ_BLOCKS, u32), @splat(0)));
    }
    // AArch64 has no instruction for the mask of a comparison. `umaxp` twice
    // leaves the largest activation of each block in one byte of a u64, and
    // the minimum with 1 makes it a flag.
    const Bytes = @Vector(16, u8);
    const umaxp = @extern(*const fn (Bytes, Bytes) callconv(.c) Bytes, .{ .name = "llvm.aarch64.neon.umaxp.v16i8" });
    const pairs = umaxp.*(activations[0..16].*, activations[16..32].*);
    // Typed, because @min would otherwise narrow the element type.
    const flag_bytes: Bytes = @min(umaxp.*(pairs, pairs), @as(Bytes, @splat(1)));
    const flags: u64 = @as(@Vector(2, u64), @bitCast(flag_bytes))[0];
    // The multiplication moves bit 8i to bit 56 + i.
    return @truncate((flags *% 0x0102_0408_1020_4080) >> 56);
}

/// Indices of the four-input blocks with a non-zero activation, in ascending
/// order; returns how many there are.
pub fn nonzero_blocks(activations: *align(64) const Activations, indices: *BlockIndices) usize {
    var count: usize = 0;
    var base: usize = 0;
    while (base < L1_BLOCKS) : (base += NNZ_BLOCKS) {
        const mask = nonzero_mask(activations[base * 4 ..][0 .. NNZ_BLOCKS * 4]);
        // A whole group is written whatever the mask holds and only the used
        // bytes are kept, so there is no data-dependent branch. After n blocks
        // `count <= n`, so the write stays inside `indices`. No byte carries:
        // a position plus `base` is a block index.
        std.mem.writeInt(IndexGroup, indices[count..][0..NNZ_BLOCKS], SET_BITS.positions[mask] + @as(IndexGroup, base) * BYTE_ONES, .little);
        count += SET_BITS.counts[mask];
    }
    return count;
}

/// `a[2i] * b[2i] + a[2i + 1] * b[2i + 1]` in i32, which cannot overflow for
/// an activation pair with a pair of L2 weights, or for two L1 products.
inline fn pair_products(a: DotI16, b: DotI16) DotI32 {
    if (PAIR_PRODUCTS_INTRINSIC) |name| return @extern(*const fn (DotI16, DotI16) callconv(.c) DotI32, .{ .name = name }).*(a, b);
    const a_parts = std.simd.deinterlace(2, a);
    const b_parts = std.simd.deinterlace(2, b);
    return @as(DotI32, a_parts[0]) * @as(DotI32, b_parts[0]) + @as(DotI32, a_parts[1]) * @as(DotI32, b_parts[1]);
}

/// The running sum of one vector of dot products: the i32 sums themselves,
/// except on the `extadd` path, which keeps each one as two halves.
const DotSum = if (L1_PATH == .extadd) [2]DotI32 else DotI32;

inline fn add_sums(a: DotSum, b: DotSum) DotSum {
    if (L1_PATH != .extadd) return a + b;
    return .{ a[0] + b[0], a[1] + b[1] };
}

inline fn output_sums(sum: DotSum) DotI32 {
    if (L1_PATH != .extadd) return sum;
    const halves_of = std.simd.deinterlace(2, std.simd.join(sum[0], sum[1]));
    return halves_of[0] + halves_of[1];
}

/// `sum[i] + dot(inputs[4i..4i+4], block_weights[4i..4i+4])`. `inputs` holds
/// activations, 0..127. No intrinsic path can saturate in that range, so
/// every path gives the exact sum.
inline fn dot_accumulate(sum: DotSum, inputs: DotI8, block_weights: DotI8) DotSum {
    switch (L1_PATH) {
        .dpbusd => {
            const name = switch (VECTOR_BYTES) {
                64 => "llvm.x86.avx512.vpdpbusd.512",
                32 => "llvm.x86.avx512.vpdpbusd.256",
                else => unreachable,
            };
            return @extern(*const fn (DotI32, DotI32, DotI32) callconv(.c) DotI32, .{ .name = name }).*(sum, @bitCast(inputs), @bitCast(block_weights));
        },
        .maddubs => {
            const maddubs = @extern(*const fn (DotI8, DotI8) callconv(.c) DotI16, .{ .name = switch (VECTOR_BYTES) {
                64 => "llvm.x86.avx512.pmaddubs.w.512",
                32 => "llvm.x86.avx2.pmadd.ub.sw",
                16 => "llvm.x86.ssse3.pmadd.ub.sw.128",
                else => unreachable,
            } });
            const maddwd = @extern(*const fn (DotI16, DotI16) callconv(.c) DotI32, .{ .name = switch (VECTOR_BYTES) {
                64 => "llvm.x86.avx512.pmaddw.d.512",
                32 => "llvm.x86.avx2.pmadd.wd",
                16 => "llvm.x86.sse2.pmadd.wd",
                else => unreachable,
            } });
            return sum + maddwd.*(maddubs.*(inputs, block_weights), @splat(1));
        },
        .sdot => return @extern(*const fn (DotI32, DotI8, DotI8) callconv(.c) DotI32, .{ .name = "llvm.aarch64.neon.sdot.v4i32.v16i8" }).*(sum, inputs, block_weights),
        .extadd => {
            // Wasm has no byte dot product. A product fits an i16, and the
            // pairwise widening addition leaves two i32 per output; they
            // are kept apart until `output_sums`, which needs a shuffle.
            const extadd = @extern(*const fn (HalfI16) callconv(.c) DotI32, .{ .name = "llvm.wasm.extadd.pairwise.signed.v4i32" });
            var result = sum;
            inline for (&result, 0..) |*pair_sums, half| {
                const half_inputs: @Vector(HALF_LANES, i8) = std.simd.extract(inputs, half * HALF_LANES, HALF_LANES);
                const half_weights: @Vector(HALF_LANES, i8) = std.simd.extract(block_weights, half * HALF_LANES, HALF_LANES);
                pair_sums.* += extadd.*(@as(HalfI16, half_inputs) *% @as(HalfI16, half_weights));
            }
            return result;
        },
        .portable => {
            const Wide = @Vector(VECTOR_BYTES, i16);
            const products = std.simd.deinterlace(4, @as(Wide, inputs) * @as(Wide, block_weights));
            var result = sum;
            inline for (products) |part| result += @as(DotI32, part);
            return result;
        },
    }
}

/// The 16 L1 sums as `DOT_CHUNKS` vectors.
const L1Sums = [DOT_CHUNKS]DotSum;
pub const L1Vector = @Vector(L1_SIZE, i32);
const BlockWeights = [L1_SIZE * 4]i8;

/// Independent partial sums, so that a block does not wait for the block
/// before it. `dpbusd` and `sdot` add into the sum and take several cycles;
/// on the other paths the sum is a separate addition of one cycle.
const L1_CHAINS = switch (L1_PATH) {
    .dpbusd => 8 / DOT_CHUNKS,
    .sdot => 4,
    .maddubs, .extadd, .portable => 1,
};
const L1Chains = [L1_CHAINS]L1Sums;

/// Adds to `sums` the products of one block: its four activations, repeated
/// in every lane of `inputs`, with the block's weights for the 16 outputs.
inline fn add_block(sums: *L1Sums, inputs: DotU32, block_weights: *const BlockWeights) void {
    inline for (sums, 0..) |*sum, chunk| {
        sum.* = dot_accumulate(sum.*, @bitCast(inputs), block_weights[chunk * VECTOR_BYTES ..][0..VECTOR_BYTES].*);
    }
}

inline fn add_indexed_block(sums: *L1Sums, activations: *align(64) const Activations, l1_weights: *const [L1_BLOCKS]BlockWeights, block: usize) void {
    add_block(sums, @splat(std.mem.readInt(u32, activations[block * 4 ..][0..4], .little)), &l1_weights[block]);
}

fn add_listed_blocks(chains: *L1Chains, activations: *align(64) const Activations, l1_weights: *const [L1_BLOCKS]BlockWeights, indices: []const u8) void {
    var i: usize = 0;
    while (i + L1_CHAINS <= indices.len) : (i += L1_CHAINS) {
        inline for (chains, 0..) |*chain, k| add_indexed_block(chain, activations, l1_weights, indices[i + k]);
    }
    // Fewer blocks than chains are left: still one chain each.
    inline for (chains[0 .. L1_CHAINS - 1], 0..) |*chain, k| {
        if (i + k < indices.len) add_indexed_block(chain, activations, l1_weights, indices[i + k]);
    }
}

/// The L1 sums of step 2 of docs/NNUE.md, before the shift: the bias plus the
/// products of the non-zero blocks. Every activation must be at most
/// `ACTIVATION_MAX`, as the output of `activate` is.
pub fn l1_sums(head: *const Weights, activations: *align(64) const Activations, bucket: usize) L1Vector {
    std.debug.assert(@reduce(.Max, @as(@Vector(L1_INPUTS, u8), activations.*)) <= ACTIVATION_MAX);
    var indices: BlockIndices = undefined;
    const count = nonzero_blocks(activations, &indices);

    const l1_weights: *const [L1_BLOCKS]BlockWeights = @ptrCast(&head.l1_weights[bucket]);
    var chains: L1Chains = std.mem.zeroes(L1Chains);
    add_listed_blocks(&chains, activations, l1_weights, indices[0..count]);

    var outputs: [DOT_CHUNKS]DotI32 = undefined;
    inline for (&outputs, 0..) |*output, chunk| {
        var total = chains[0][chunk];
        inline for (chains[1..]) |*chain| total = add_sums(total, chain[chunk]);
        output.* = output_sums(total);
    }
    return @as(L1Vector, @bitCast(outputs)) + @as(L1Vector, head.l1_bias[bucket]);
}

/// The 32 L2 sums as vectors of the dot product's width.
const L2_CHUNKS = L2_SIZE * 4 / VECTOR_BYTES;
const L2Sums = [L2_CHUNKS]DotI32;
/// The L2 weights of one L1 output: for each L2 output, the weight of the
/// CReLU value, then the weight of its square.
const L2PairWeights = [L2_SIZE][2]i16;

/// What the engine derives from a network once, when the network is installed.
pub const Prepared = struct {
    l1_shift: L1Shift,
    /// `[bucket][L1 output]`: `l2_weights` narrowed to i16, which the
    /// validated range fits, and interleaved for `pair_products`.
    l2_pairs: [OUTPUT_SIZE][L1_SIZE]L2PairWeights align(64),

    pub fn init(head: *const Weights, l1_shift: L1Shift) Prepared {
        var self: Prepared = .{ .l1_shift = l1_shift, .l2_pairs = undefined };
        for (&self.l2_pairs, &head.l2_weights) |*bucket_pairs, *bucket_weights| {
            for (bucket_pairs, 0..) |*pairs, j| {
                for (pairs, bucket_weights[j], bucket_weights[L1_SIZE + j]) |*pair, linear, squared| {
                    pair.* = .{ @intCast(linear), @intCast(squared) };
                }
            }
        }
        return self;
    }
};

comptime {
    std.debug.assert(WEIGHT_LIMIT <= std.math.maxInt(i16) and ONE <= std.math.maxInt(i16));
}

/// Steps 3 to 6 of docs/NNUE.md: from the L1 sums to centipawns.
pub fn finish(head: *const Weights, prepared: *const Prepared, bucket: usize, sums: L1Vector) i32 {
    const L1 = L1Vector;
    const L2 = @Vector(L2_SIZE, i32);

    const half: i32 = (@as(i32, 1) << prepared.l1_shift) >> 1;
    const z1 = (sums + @as(L1, @splat(half))) >> @splat(prepared.l1_shift);
    // Typed, because @min would otherwise narrow the element type.
    const clipped: L1 = @min(@max(z1, @as(L1, @splat(0))), @as(L1, @splat(ONE)));
    const squared: L1 = (clipped * clipped + @as(L1, @splat(1 << (ACT_BITS - 1)))) >> @splat(ACT_BITS);

    const z2: L2 = switch (L2_PATH) {
        .pairs => blk: {
            // Each output's value and square as two adjacent i16.
            const pairs: [L1_SIZE]u32 = @bitCast(clipped | squared << @splat(16));
            var sums_2: L2Sums = @bitCast(head.l2_bias[bucket]);
            inline for (pairs, &prepared.l2_pairs[bucket]) |pair, *weights| {
                const inputs: DotI16 = @bitCast(@as(DotU32, @splat(pair)));
                const pair_weights: *const [L2_CHUNKS]DotI16 = @ptrCast(weights);
                inline for (&sums_2, pair_weights) |*sum, chunk| sum.* += pair_products(inputs, chunk);
            }
            break :blk @bitCast(sums_2);
        },
        .wide => blk: {
            const hidden: [L2_INPUTS]i32 = @bitCast([2]L1{ clipped, squared });
            var sums_2: L2 = head.l2_bias[bucket];
            inline for (hidden, &head.l2_weights[bucket]) |input, *column| {
                sums_2 += @as(L2, @splat(input)) * @as(L2, column.*);
            }
            break :blk sums_2;
        },
    };

    const rounded: L2 = (z2 + @as(L2, @splat(1 << (WEIGHT_BITS - 1)))) >> @splat(WEIGHT_BITS);
    const activated: L2 = @min(@max(rounded, @as(L2, @splat(0))), @as(L2, @splat(ONE)));
    const output = head.l3_bias[bucket] + @reduce(.Add, activated * @as(L2, head.l3_weights[bucket]));
    return to_centipawns(output);
}

/// Same value as `evaluate_scalar`, with vectors.
pub fn evaluate_simd(head: *const Weights, prepared: *const Prepared, own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize) i32 {
    var activations: Activations align(64) = undefined;
    activate(own, opp, &activations);
    return finish(head, prepared, bucket, l1_sums(head, &activations, bucket));
}

/// Evaluation in centipawns for the side to move, whose accumulator is `own`.
pub inline fn evaluate(head: *const Weights, prepared: *const Prepared, own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize) i32 {
    return evaluate_simd(head, prepared, own, opp, bucket);
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
pub fn evaluate_float(head: *const Weights, l1_shift: L1Shift, own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize, mode: FloatMode) f64 {
    const shifted: f64 = @floatFromInt(@as(u32, 1) << l1_shift);
    const one: f64 = @as(f64, @floatFromInt(ONE)) * shifted;
    const l1_weight_one = L1_WEIGHT_SCALE * shifted;
    const qa: f64 = @floatFromInt(QA);

    var z1: [L1_SIZE]f64 = undefined;
    for (&z1, head.l1_bias[bucket]) |*sum, bias| sum.* = @as(f64, @floatFromInt(bias)) / one;
    for ([_]arch.AccumulatorPtr{ own, opp }, 0..) |acc, side| {
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
                sum.* += activation * @as(f64, @floatFromInt(block_weights[input % 4])) / l1_weight_one;
            }
        }
    }
    return evaluate_float_from_l1(head, bucket, z1);
}

/// The float forward pass from the L1 pre-activations on, in centipawns.
pub fn evaluate_float_from_l1(head: *const Weights, bucket: usize, z1: [L1_SIZE]f64) f64 {
    const weight_one: f64 = @floatFromInt(1 << WEIGHT_BITS);
    const sum_one: f64 = @floatFromInt(1 << SUM_BITS);

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
    /// Goes into the header; it also scales `l1_bias`, given at shift 0.
    l1_shift: L1Shift = 0,
    weight: i32 = WEIGHT_LIMIT,
    l1_bias: i32 = ONE,
    bias: i32 = 1 << SUM_BITS,
};

/// Fills `head` with uniform random weights inside the validated ranges.
pub fn fill_random(head: *Weights, random: std.Random, range: RandomRange) void {
    for (std.mem.asBytes(&head.l1_weights)) |*byte| {
        byte.* = @bitCast(random.intRangeAtMost(i8, -range.l1_weight, range.l1_weight));
    }
    inline for (.{ "l2_weights", "l3_weights", "l1_bias", "l2_bias", "l3_bias" }, .{ range.weight, range.weight, range.l1_bias << range.l1_shift, range.bias, range.bias }) |field, limit| {
        const values: *[@sizeOf(@FieldType(Weights, field)) / 4]i32 = @ptrCast(&@field(head, field));
        for (values) |*value| value.* = random.intRangeAtMost(i32, -limit, limit);
    }
}
