//! See docs/NNUE.md.

const std = @import("std");
const builtin = @import("builtin");

pub const FEATURES_PER_PIECE: usize = 64;
pub const FEATURES_PER_COLOR: usize = 6 * FEATURES_PER_PIECE;
pub const FEATURES_PER_BUCKET: usize = 2 * FEATURES_PER_COLOR;
pub const HIDDEN_SIZE: usize = 1024;
pub const OUTPUT_SIZE: usize = 8;
pub const QA: i32 = 255;
pub const SCALE: i32 = 400;

pub inline fn output_bucket(piece_count: u8) usize {
    return @min((piece_count -| 2) / 4, OUTPUT_SIZE - 1);
}

pub const Accumulator = [HIDDEN_SIZE]i16;
pub const AccumulatorPtr = *align(64) const Accumulator;

pub const WIDEST_VECTOR_BITS: comptime_int = if (builtin.target.cpu.arch == .aarch64) 128 else 512;

/// LLVM leaves target intrinsics unresolved at -Doptimize=debug.
pub const intrinsics = builtin.mode != .debug;

pub const wasm_simd = builtin.target.cpu.arch.isWasm() and builtin.target.cpu.has(.wasm, .simd128);

pub fn x86_has(comptime feature: std.Target.x86.Feature) bool {
    return builtin.target.cpu.arch.isX86() and builtin.target.cpu.has(.x86, feature);
}

/// For declaring LLVM intrinsics: passes every vector, masks included, as a vector.
pub const INTRINSIC_CALL: std.lang.CallingConvention = if (builtin.target.cpu.arch == .x86_64) .{ .x86_64_vectorcall = .{} } else .c;

pub fn pair_products_intrinsic(comptime vector_bits: usize) ?[]const u8 {
    if (!intrinsics) return null;
    if (wasm_simd and vector_bits == 128) return "llvm.wasm.dot";
    return switch (vector_bits) {
        512 => if (x86_has(.avx512bw)) "llvm.x86.avx512.pmaddw.d.512" else null,
        256 => if (x86_has(.avx2)) "llvm.x86.avx2.pmadd.wd" else null,
        128 => if (x86_has(.sse2)) "llvm.x86.sse2.pmadd.wd" else null,
        else => null,
    };
}

/// The bytes of `value` read as a `To`; `@bitCast` compiles array casts bit by bit (docs/NNUE.md).
pub inline fn reinterpret(comptime To: type, value: anytype) To {
    comptime std.debug.assert(@bitSizeOf(To) == @bitSizeOf(@TypeOf(value)) and @bitSizeOf(To) == 8 * @sizeOf(To));
    return @as(*align(1) const To, @ptrCast(&value)).*;
}
