//! See docs/NNUE.md.

const std = @import("std");
const builtin = @import("builtin");

pub const HIDDEN_SIZE: usize = 1024;
pub const OUTPUT_SIZE: usize = 8;
pub const QA: i32 = 255;
pub const SCALE: i32 = 400;

pub const Accumulator = [HIDDEN_SIZE]i16;
pub const AccumulatorPtr = *align(64) const Accumulator;

pub const WIDEST_VECTOR_BITS: comptime_int = if (builtin.target.cpu.arch == .aarch64) 128 else 512;

/// For declaring LLVM intrinsics: passes every vector, masks included, as a vector.
pub const intrinsic_call: std.lang.CallingConvention = if (builtin.target.cpu.arch == .x86_64) .{ .x86_64_vectorcall = .{} } else .c;

/// The bytes of `value` read as a `To`; `@bitCast` compiles array casts bit by bit (docs/NNUE.md).
pub inline fn reinterpret(comptime To: type, value: anytype) To {
    comptime std.debug.assert(@bitSizeOf(To) == @bitSizeOf(@TypeOf(value)) and @bitSizeOf(To) == 8 * @sizeOf(To));
    return @as(*align(1) const To, @ptrCast(&value)).*;
}
