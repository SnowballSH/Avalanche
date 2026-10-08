//! Dimensions shared by the feature transformer and every output head.

const std = @import("std");
const builtin = @import("builtin");

/// Width of one perspective's accumulator.
pub const HIDDEN_SIZE: usize = 1024;
/// Material output buckets: `min((piece_count - 2) / 4, 7)`.
pub const OUTPUT_SIZE: usize = 8;
/// Feature-transformer quantisation: accumulator value 255 is activation 1.0.
pub const QA: i32 = 255;
/// Centipawns per unit of network output.
pub const SCALE: i32 = 400;

pub const Accumulator = [HIDDEN_SIZE]i16;
/// How a head receives an accumulator: aligned, as the engine stores them, so
/// that vector loads from it are aligned loads.
pub const AccumulatorPtr = *align(64) const Accumulator;

/// The widest vectors the heads have instructions for. On AArch64 that is NEON, also where SVE
/// makes `std.simd.suggestVectorLength` say more.
pub const WIDEST_VECTOR_BITS: comptime_int = if (builtin.target.cpu.arch == .aarch64) 128 else 512;

/// For declaring LLVM intrinsics: passes every vector, masks included, as a vector.
pub const intrinsic_call: std.lang.CallingConvention = if (builtin.target.cpu.arch == .x86_64) .{ .x86_64_vectorcall = .{} } else .c;

/// The bytes of `value` read as a `To`; the array casts `@bitCast` compiles bit by bit (docs/NNUE.md).
pub inline fn reinterpret(comptime To: type, value: anytype) To {
    comptime std.debug.assert(@bitSizeOf(To) == @bitSizeOf(@TypeOf(value)) and @bitSizeOf(To) == 8 * @sizeOf(To));
    return @as(*align(1) const To, @ptrCast(&value)).*;
}
