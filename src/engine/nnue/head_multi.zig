//! See "Multi-layer head" in docs/NNUE.md.

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch.zig");

const HIDDEN_SIZE = arch.HIDDEN_SIZE;
const OUTPUT_SIZE = arch.OUTPUT_SIZE;
const QA = arch.QA;
const SCALE = arch.SCALE;

pub const PAIRS: usize = HIDDEN_SIZE / 2;
pub const L1_INPUTS: usize = 2 * PAIRS;
pub const L1_BLOCKS: usize = L1_INPUTS / 4;
pub const L1_SIZE: usize = 16;
pub const L2_INPUTS: usize = 2 * L1_SIZE;
pub const L2_SIZE: usize = 32;

pub const FT_SHIFT = 9;
const FT_ROUND: i32 = 1 << (FT_SHIFT - 1);
pub const PAIRWISE_ONE: f64 = @as(f64, @floatFromInt(QA * QA)) / @as(f64, 1 << FT_SHIFT);

pub const ACT_BITS = 13;
pub const ONE: i32 = 1 << ACT_BITS;
pub const WEIGHT_BITS = 10;
pub const SUM_BITS = ACT_BITS + WEIGHT_BITS;

pub const L1_WEIGHT_SCALE: f64 = @as(f64, @floatFromInt(ONE)) / PAIRWISE_ONE;

pub const L1Shift = u3;
pub const L1_SHIFT_MAX: L1Shift = 7;

pub const WEIGHT_LIMIT: i32 = 2047;
pub const BIAS_LIMIT: i32 = 1 << 30;

pub const DESCRIPTION = std.fmt.comptimePrint("pairwise->{d}x2->{d}->1x{d}", .{ L1_SIZE, L2_SIZE, OUTPUT_SIZE });

pub const Weights = extern struct {
    l1_weights: [OUTPUT_SIZE][L1_BLOCKS][L1_SIZE][4]i8 align(64),
    l1_bias: [OUTPUT_SIZE][L1_SIZE]i32 align(64),
    l2_weights: [OUTPUT_SIZE][L2_INPUTS][L2_SIZE]i32 align(64),
    l2_bias: [OUTPUT_SIZE][L2_SIZE]i32 align(64),
    l3_weights: [OUTPUT_SIZE][L2_SIZE]i32 align(64),
    l3_bias: [OUTPUT_SIZE]i32 align(64),
};

pub const ValidateError = error{ WeightOutOfRange, BiasOutOfRange };

fn check_range(bytes: *const [@sizeOf(Weights)]u8, comptime field: []const u8, limit: i32) bool {
    const section = bytes[@offsetOf(Weights, field)..][0..@sizeOf(@FieldType(Weights, field))];
    var i: usize = 0;
    while (i < section.len) : (i += 4) {
        const value = std.mem.readInt(i32, section[i..][0..4], .little);
        if (value < -limit or value > limit) return false;
    }
    return true;
}

pub fn validate(bytes: *const [@sizeOf(Weights)]u8) ValidateError!void {
    inline for (.{ "l2_weights", "l3_weights" }) |field| {
        if (!check_range(bytes, field, WEIGHT_LIMIT)) return ValidateError.WeightOutOfRange;
    }
    inline for (.{ "l1_bias", "l2_bias", "l3_bias" }) |field| {
        if (!check_range(bytes, field, BIAS_LIMIT)) return ValidateError.BiasOutOfRange;
    }
}

pub const Activations = [L1_INPUTS]u8;
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

inline fn to_centipawns(output: i32) i32 {
    return @intCast((@as(i64, output) * SCALE + (1 << (SUM_BITS - 1))) >> SUM_BITS);
}

inline fn round_shift(value: i32, comptime bits: comptime_int) i32 {
    return (value + (1 << (bits - 1))) >> bits;
}

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

const VECTOR_BYTES = @min(std.simd.suggestVectorLength(u8) orelse 16, arch.WIDEST_VECTOR_BITS / 8);
const PairwiseI16 = @Vector(VECTOR_BYTES, i16);
const PairwiseU16 = @Vector(VECTOR_BYTES, u16);
const ByteVector = @Vector(VECTOR_BYTES, u8);
const DOT_CHUNKS = 64 / VECTOR_BYTES;
const DotI8 = @Vector(VECTOR_BYTES, i8);
const DotI16 = @Vector(VECTOR_BYTES / 2, i16);
const DotI32 = @Vector(VECTOR_BYTES / 4, i32);
const DotU32 = @Vector(VECTOR_BYTES / 4, u32);
const NNZ_BLOCKS = 8;

comptime {
    std.debug.assert(PAIRS % VECTOR_BYTES == 0);
    std.debug.assert(L1_BLOCKS % NNZ_BLOCKS == 0);
    std.debug.assert(L1_SIZE * 4 == DOT_CHUNKS * VECTOR_BYTES);
}

const intrinsics = arch.intrinsics;
const x86_has = arch.x86_has;
const wasm_simd = arch.wasm_simd;
const neon = builtin.target.cpu.arch == .aarch64 and builtin.target.cpu.has(.aarch64, .neon);

pub const PAIRWISE_PATH: enum { mulhrs, umull, portable } = if (!intrinsics)
    .portable
else if (switch (VECTOR_BYTES) {
    64 => x86_has(.avx512bw),
    32 => x86_has(.avx2),
    16 => x86_has(.ssse3) or wasm_simd,
    else => false,
})
    .mulhrs
else if (neon and VECTOR_BYTES == 16)
    .umull
else
    .portable;

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
else if (builtin.target.cpu.arch == .aarch64 and VECTOR_BYTES == 16 and builtin.target.cpu.has(.aarch64, .dotprod))
    .sdot
else if ((wasm_simd or neon) and VECTOR_BYTES == 16)
    .extadd
else
    .portable;

const PAIR_PRODUCTS_INTRINSIC = arch.pair_products_intrinsic(8 * VECTOR_BYTES);

const L2_PATH: enum { pairs, wide } = if (PAIR_PRODUCTS_INTRINSIC != null) .pairs else .wide;

pub const SIMD_DESCRIPTION = std.fmt.comptimePrint("{d}-bit vectors, pairwise {s}, L1 {s}, L2 {s}", .{ VECTOR_BYTES * 8, @tagName(PAIRWISE_PATH), @tagName(L1_PATH), @tagName(L2_PATH) });

const HALF_LANES = VECTOR_BYTES / 2;
const HalfI16 = @Vector(HALF_LANES, i16);

inline fn halves(values: PairwiseI16) [2]HalfI16 {
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

inline fn pairwise_lanes(a: PairwiseI16, b: PairwiseI16) ByteVector {
    const zero: PairwiseI16 = @splat(0);
    const cap: PairwiseI16 = @splat(QA);
    switch (PAIRWISE_PATH) {
        .mulhrs => {
            // `pmulhrsw` is (x * y + 2^14) >> 15, one native vector at a time.
            const mulhrs = @extern(*const fn (HalfI16, HalfI16) callconv(arch.intrinsic_call) HalfI16, .{ .name = switch (VECTOR_BYTES) {
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
            const packus = @extern(*const fn (HalfI16, HalfI16) callconv(arch.intrinsic_call) ByteVector, .{ .name = switch (VECTOR_BYTES) {
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
            const sqxtun = @extern(*const fn (HalfI16) callconv(arch.intrinsic_call) HalfU8, .{ .name = "llvm.aarch64.neon.sqxtun.v8i8" });
            const umull = @extern(*const fn (HalfU8, HalfU8) callconv(arch.intrinsic_call) HalfU16, .{ .name = "llvm.aarch64.neon.umull.v8i16" });
            var high: [2]HalfU8 = undefined;
            inline for (&high, halves(a), halves(b)) |*bytes, half_a, half_b| {
                bytes.* = @truncate(umull.*(sqxtun.*(half_a), sqxtun.*(half_b)) >> @splat(8));
            }
            // (p + 2^8) >> 9 is ((p >> 8) + 1) >> 1: the high bytes of both
            // halves at once (`uzp2`), then one rounding halving. The high
            // byte of 255 * 255 is 254, so the addition cannot wrap.
            comptime std.debug.assert(QA == std.math.maxInt(u8) and FT_SHIFT == 9);
            return (std.simd.join(high[0], high[1]) + @as(ByteVector, @splat(1))) >> @splat(1);
        },
        .portable => {
            const ca: PairwiseU16 = @bitCast(std.math.clamp(a, zero, cap));
            const cb: PairwiseU16 = @bitCast(std.math.clamp(b, zero, cap));
            // 255 * 255 + 256 fits in a u16, so the wrapping product is exact.
            return @truncate((ca *% cb +% @as(PairwiseU16, @splat(FT_ROUND))) >> @splat(FT_SHIFT));
        },
    }
}

pub fn activate(own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, out: *align(64) Activations) void {
    inline for (.{ own, opp }, 0..) |acc, side| {
        var i: usize = 0;
        while (i < PAIRS) : (i += VECTOR_BYTES) {
            out[side * PAIRS + i ..][0..VECTOR_BYTES].* = pairwise_lanes(acc[i..][0..VECTOR_BYTES].*, acc[i + PAIRS ..][0..VECTOR_BYTES].*);
        }
    }
}

pub const BlockIndices = [L1_BLOCKS]u8;
const IndexGroup = u64;
const BYTE_ONES: IndexGroup = 0x0101_0101_0101_0101;

comptime {
    std.debug.assert(L1_BLOCKS - 1 <= std.math.maxInt(u8));
    std.debug.assert(@sizeOf(IndexGroup) == NNZ_BLOCKS);
}

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

const NNZ_COMPRESS: ?[]const u8 = if (!intrinsics or !x86_has(.avx512vbmi2) or L1_BLOCKS % VECTOR_BYTES != 0)
    null
else switch (VECTOR_BYTES) {
    64 => "llvm.x86.avx512.mask.compress.v64i8",
    32 => if (x86_has(.avx512vl)) "llvm.x86.avx512.mask.compress.v32i8" else null,
    else => null,
};

inline fn nonzero_mask(activations: *const [NNZ_BLOCKS * 4]u8) u8 {
    if (comptime !(intrinsics and neon)) {
        const blocks = arch.reinterpret(@Vector(NNZ_BLOCKS, u32), activations.*);
        return @bitCast(blocks != @as(@Vector(NNZ_BLOCKS, u32), @splat(0)));
    }
    // AArch64 has no instruction for the mask of a comparison. `umaxp` twice
    // leaves the largest activation of each block in one byte of a u64, and
    // the minimum with 1 makes it a flag.
    const Bytes = @Vector(16, u8);
    const umaxp = @extern(*const fn (Bytes, Bytes) callconv(arch.intrinsic_call) Bytes, .{ .name = "llvm.aarch64.neon.umaxp.v16i8" });
    const pairs = umaxp.*(activations[0..16].*, activations[16..32].*);
    // Typed, because @min would otherwise narrow the element type.
    const flag_bytes: Bytes = @min(umaxp.*(pairs, pairs), @as(Bytes, @splat(1)));
    const flags: u64 = @as(@Vector(2, u64), @bitCast(flag_bytes))[0];
    // The multiplication moves bit 8i to bit 56 + i.
    return @truncate((flags *% 0x0102_0408_1020_4080) >> 56);
}

pub fn nonzero_blocks(activations: *align(64) const Activations, indices: *BlockIndices) usize {
    var count: usize = 0;
    if (NNZ_COMPRESS) |vpcompressb| {
        // One vector of block indices per step, of which `vpcompressb` keeps
        // those of the non-zero blocks, packed at the front. The whole vector
        // is stored; as below, `count` never passes the step's first block.
        const compress = @extern(*const fn (ByteVector, ByteVector, @Vector(VECTOR_BYTES, bool)) callconv(arch.intrinsic_call) ByteVector, .{ .name = vpcompressb });
        const Blocks = @Vector(VECTOR_BYTES, u32);
        var block_indices: ByteVector = std.simd.iota(u8, VECTOR_BYTES);
        var first: usize = 0;
        while (first < L1_BLOCKS) : (first += VECTOR_BYTES) {
            const blocks = arch.reinterpret(Blocks, activations[first * 4 ..][0 .. VECTOR_BYTES * 4].*);
            const nonzero = blocks != @as(Blocks, @splat(0));
            indices[count..][0..VECTOR_BYTES].* = compress.*(block_indices, @splat(0), nonzero);
            count += std.simd.countTrues(nonzero);
            block_indices +%= @splat(VECTOR_BYTES);
        }
        return count;
    }
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

/// `a[2i] * b[2i] + a[2i + 1] * b[2i + 1]` in i32. Only four operands of -32768 overflow it.
inline fn pair_products(a: DotI16, b: DotI16) DotI32 {
    return @extern(*const fn (DotI16, DotI16) callconv(arch.intrinsic_call) DotI32, .{ .name = PAIR_PRODUCTS_INTRINSIC.? }).*(a, b);
}

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

inline fn byte_products(inputs: DotI8, block_weights: DotI8, comptime half: usize) HalfI16 {
    const half_inputs: @Vector(HALF_LANES, i8) = std.simd.extract(inputs, half * HALF_LANES, HALF_LANES);
    const half_weights: @Vector(HALF_LANES, i8) = std.simd.extract(block_weights, half * HALF_LANES, HALF_LANES);
    return @as(HalfI16, half_inputs) *% @as(HalfI16, half_weights);
}

inline fn widened_pairs(products: HalfI16) DotI32 {
    const name = if (wasm_simd) "llvm.wasm.extadd.pairwise.signed.v4i32" else "llvm.aarch64.neon.saddlp.v4i32.v8i16";
    return @extern(*const fn (HalfI16) callconv(arch.intrinsic_call) DotI32, .{ .name = name }).*(products);
}

/// Exact only for `inputs` in 0..127: `vpdpbusd` and `pmaddubsw` read them as unsigned, `sdot` as signed.
inline fn dot_accumulate(sum: DotSum, inputs: DotI8, block_weights: DotI8) DotSum {
    switch (L1_PATH) {
        .dpbusd => {
            const name = switch (VECTOR_BYTES) {
                64 => "llvm.x86.avx512.vpdpbusd.512",
                32 => "llvm.x86.avx512.vpdpbusd.256",
                else => unreachable,
            };
            return @extern(*const fn (DotI32, DotI32, DotI32) callconv(arch.intrinsic_call) DotI32, .{ .name = name }).*(sum, @bitCast(inputs), @bitCast(block_weights));
        },
        .maddubs => {
            const maddubs = @extern(*const fn (DotI8, DotI8) callconv(arch.intrinsic_call) DotI16, .{ .name = switch (VECTOR_BYTES) {
                64 => "llvm.x86.avx512.pmaddubs.w.512",
                32 => "llvm.x86.avx2.pmadd.ub.sw",
                16 => "llvm.x86.ssse3.pmadd.ub.sw.128",
                else => unreachable,
            } });
            return sum + pair_products(maddubs.*(inputs, block_weights), @splat(1));
        },
        .sdot => return @extern(*const fn (DotI32, DotI8, DotI8) callconv(arch.intrinsic_call) DotI32, .{ .name = "llvm.aarch64.neon.sdot.v4i32.v16i8" }).*(sum, inputs, block_weights),
        .extadd => {
            // A product fits an i16, and the pairwise widening addition leaves
            // two i32 per output; they are kept apart until `output_sums`,
            // which needs a shuffle.
            var result = sum;
            inline for (&result, 0..) |*pair_sums, half| pair_sums.* += widened_pairs(byte_products(inputs, block_weights, half));
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

const L1Sums = [DOT_CHUNKS]DotSum;
pub const L1Vector = @Vector(L1_SIZE, i32);
const BlockWeights = [L1_SIZE * 4]i8;

const L1_CHAINS = switch (L1_PATH) {
    .dpbusd => 8 / DOT_CHUNKS,
    .sdot => 4,
    .maddubs, .extadd, .portable => 1,
};
const L1Chains = [L1_CHAINS]L1Sums;

inline fn add_block(sums: *L1Sums, inputs: DotU32, block_weights: *const BlockWeights) void {
    inline for (sums, 0..) |*sum, chunk| {
        sum.* = dot_accumulate(sum.*, @bitCast(inputs), block_weights[chunk * VECTOR_BYTES ..][0..VECTOR_BYTES].*);
    }
}

inline fn add_indexed_block(sums: *L1Sums, activations: *align(64) const Activations, l1_weights: *const [L1_BLOCKS]BlockWeights, block: usize) void {
    add_block(sums, @splat(std.mem.readInt(u32, activations[block * 4 ..][0..4], .little)), &l1_weights[block]);
}

/// Two blocks at once on the `extadd` path: the products of both fit an i16
/// together (2 * 127 * 128), so one widening addition serves the two.
inline fn add_block_pair(sums: *L1Sums, activations: *align(64) const Activations, l1_weights: *const [L1_BLOCKS]BlockWeights, blocks: [2]usize) void {
    @setEvalBranchQuota(10_000);
    var inputs: [2]DotI8 = undefined;
    inline for (&inputs, blocks) |*lanes, block| {
        lanes.* = @bitCast(@as(DotU32, @splat(std.mem.readInt(u32, activations[block * 4 ..][0..4], .little))));
    }
    inline for (sums, 0..) |*sum, chunk| {
        inline for (sum, 0..) |*pair_sums, half| {
            var products: HalfI16 = @splat(0);
            inline for (inputs, blocks) |lanes, block| {
                products +%= byte_products(lanes, l1_weights[block][chunk * VECTOR_BYTES ..][0..VECTOR_BYTES].*, half);
            }
            pair_sums.* += widened_pairs(products);
        }
    }
}

fn add_listed_blocks(chains: *L1Chains, activations: *align(64) const Activations, l1_weights: *const [L1_BLOCKS]BlockWeights, indices: []const u8) void {
    var i: usize = 0;
    if (L1_PATH == .extadd) {
        while (i + 2 <= indices.len) : (i += 2) add_block_pair(&chains[0], activations, l1_weights, .{ indices[i], indices[i + 1] });
    }
    while (i + L1_CHAINS <= indices.len) : (i += L1_CHAINS) {
        const round = std.mem.readInt(@Int(.unsigned, 8 * L1_CHAINS), indices[i..][0..L1_CHAINS], .little);
        inline for (chains, 0..) |*chain, k| {
            add_indexed_block(chain, activations, l1_weights, @as(u8, @truncate(round >> (8 * k))));
        }
    }
    inline for (chains[0 .. L1_CHAINS - 1], 0..) |*chain, k| {
        if (i + k < indices.len) add_indexed_block(chain, activations, l1_weights, indices[i + k]);
    }
}

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
    return arch.reinterpret(L1Vector, outputs) + @as(L1Vector, head.l1_bias[bucket]);
}

const L2_CHUNKS = L2_SIZE * 4 / VECTOR_BYTES;
const L2Sums = [L2_CHUNKS]DotI32;
const L2PairWeights = [L2_SIZE][2]i16;

pub const Prepared = struct {
    l1_shift: L1Shift,
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
            const pairs = arch.reinterpret([L1_SIZE]u32, clipped | squared << @splat(16));
            var sums_2 = arch.reinterpret(L2Sums, head.l2_bias[bucket]);
            inline for (pairs, &prepared.l2_pairs[bucket]) |pair, *weights| {
                const inputs: DotI16 = @bitCast(@as(DotU32, @splat(pair)));
                const pair_weights: *const [L2_CHUNKS]DotI16 = @ptrCast(weights);
                inline for (&sums_2, pair_weights) |*sum, chunk| sum.* += pair_products(inputs, chunk);
            }
            break :blk arch.reinterpret(L2, sums_2);
        },
        .wide => blk: {
            const hidden = arch.reinterpret([L2_INPUTS]i32, [2]L1{ clipped, squared });
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

pub fn evaluate(head: *const Weights, prepared: *const Prepared, own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize) i32 {
    var activations: Activations align(64) = undefined;
    activate(own, opp, &activations);
    return finish(head, prepared, bucket, l1_sums(head, &activations, bucket));
}
