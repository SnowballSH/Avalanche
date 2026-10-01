//! Dimensions shared by the feature transformer and every output head.

/// Width of one perspective's accumulator.
pub const HIDDEN_SIZE: usize = 1024;
/// Material output buckets: `min((piece_count - 2) / 4, 7)`.
pub const OUTPUT_SIZE: usize = 8;
/// Feature-transformer quantisation: accumulator value 255 is activation 1.0.
pub const QA: i32 = 255;
/// Centipawns per unit of network output.
pub const SCALE: i32 = 400;

pub const Accumulator = [HIDDEN_SIZE]i16;
