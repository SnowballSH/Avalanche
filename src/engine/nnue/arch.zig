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

/// Calling convention for declaring LLVM target intrinsics. Every vector, a mask included, has
/// to be passed as a vector, which the x86-64 C conventions do not do.
pub const intrinsic_call: std.lang.CallingConvention = if (builtin.target.cpu.arch == .x86_64) .{ .x86_64_vectorcall = .{} } else .c;
