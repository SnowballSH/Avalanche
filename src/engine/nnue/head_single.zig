//! Single-layer head: `(1024)x2 -> SCReLU -> 1x8`, i16 weights.

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch.zig");

const HIDDEN_SIZE = arch.HIDDEN_SIZE;
const OUTPUT_SIZE = arch.OUTPUT_SIZE;
const QA = arch.QA;
const QB: i32 = 64;
const QAB: i32 = QA * QB;
const SCALE = arch.SCALE;

pub const OUTPUT_WEIGHT_MIN: i16 = -128;
pub const OUTPUT_WEIGHT_MAX: i16 = 127;

/// The part of the architecture name after the feature transformer.
pub const DESCRIPTION = std.fmt.comptimePrint("{d}", .{OUTPUT_SIZE});

pub const Weights = extern struct {
    layer_2: [OUTPUT_SIZE][HIDDEN_SIZE * 2]i16 align(64),
    layer_2_bias: [OUTPUT_SIZE]i16 align(64),
};

pub const ValidateError = error{OutputWeightOutOfRange};

/// Checks the head's bytes (the layout of `Weights`) for the output-weight
/// range the SIMD inference assumes.
pub fn validate(bytes: []const u8) ValidateError!void {
    const layer_2 = bytes[@offsetOf(Weights, "layer_2")..][0..@sizeOf(@FieldType(Weights, "layer_2"))];
    var i: usize = 0;
    while (i < layer_2.len) : (i += 2) {
        const weight = std.mem.readInt(i16, layer_2[i..][0..2], .little);
        if (weight < OUTPUT_WEIGHT_MIN or weight > OUTPUT_WEIGHT_MAX) return ValidateError.OutputWeightOutOfRange;
    }
}

const OUTPUT_LANES = @min(std.simd.suggestVectorLength(i16) orelse 8, 32);
const OutputI16 = @Vector(OUTPUT_LANES, i16);
const OutputI32 = @Vector(OUTPUT_LANES / 2, i32);

comptime {
    std.debug.assert(HIDDEN_SIZE % (OUTPUT_LANES * 4) == 0);
}

/// Pairwise signed i16 dot product. Optimized x86 builds use pmaddwd directly;
/// Debug and other architectures retain the portable expression. LLVM leaves
/// x86 intrinsics unresolved at -ODebug, hence the explicit mode guard.
inline fn madd_i16(a: OutputI16, b: OutputI16) OutputI32 {
    if (comptime builtin.mode != .debug and builtin.target.cpu.arch.isX86()) {
        if (comptime OUTPUT_LANES == 32 and builtin.target.cpu.has(.x86, .avx512f) and builtin.target.cpu.has(.x86, .avx512bw)) {
            return @extern(*const fn (OutputI16, OutputI16) callconv(arch.intrinsic_call) OutputI32, .{ .name = "llvm.x86.avx512.pmaddw.d.512" }).*(a, b);
        }
        if (comptime OUTPUT_LANES == 16 and builtin.target.cpu.has(.x86, .avx2)) {
            return @extern(*const fn (OutputI16, OutputI16) callconv(arch.intrinsic_call) OutputI32, .{ .name = "llvm.x86.avx2.pmadd.wd" }).*(a, b);
        }
        if (comptime OUTPUT_LANES == 8 and builtin.target.cpu.has(.x86, .sse2)) {
            return @extern(*const fn (OutputI16, OutputI16) callconv(arch.intrinsic_call) OutputI32, .{ .name = "llvm.x86.sse2.pmadd.wd" }).*(a, b);
        }
    }
    if (comptime builtin.mode != .debug and builtin.target.cpu.arch.isWasm() and OUTPUT_LANES == 8) {
        return @extern(*const fn (OutputI16, OutputI16) callconv(arch.intrinsic_call) OutputI32, .{ .name = "llvm.wasm.dot" }).*(a, b);
    }

    const a_parts = std.simd.deinterlace(2, a);
    const b_parts = std.simd.deinterlace(2, b);
    const even = @as(OutputI32, @intCast(a_parts[0])) * @as(OutputI32, @intCast(b_parts[0]));
    const odd = @as(OutputI32, @intCast(a_parts[1])) * @as(OutputI32, @intCast(b_parts[1]));
    return even + odd;
}

/// Evaluation in centipawns for the side to move, whose accumulator is `own`.
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

            sum.* += madd_i16(own_activation *% own_weights, own_activation) +
                madd_i16(opp_activation *% opp_weights, opp_activation);
            i += OUTPUT_LANES;
        }
    }

    var sum = sums[0];
    inline for (sums[1..]) |partial| sum += partial;
    const result = @reduce(.Add, sum);
    return @divTrunc((@divTrunc(result, QA) + @as(i32, head.layer_2_bias[bucket])) * SCALE, QAB);
}
