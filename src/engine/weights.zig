const std = @import("std");
const build_options = @import("build_options");

const NNUE_SOURCE = @embedFile("nnue");

/// King input buckets. 1 = flat Chess768; 16 = ChessBucketsMirrored.
pub const NUM_INPUT_BUCKETS: usize = build_options.input_buckets;

pub const INPUT_SIZE: usize = 768 * NUM_INPUT_BUCKETS;
pub const HIDDEN_SIZE: usize = 1024;
pub const OUTPUT_SIZE: usize = 8;
pub const OUTPUT_WEIGHT_MIN: i16 = -128;
pub const OUTPUT_WEIGHT_MAX: i16 = 127;

pub const NNUEWeights = struct {
    layer_1: [INPUT_SIZE * HIDDEN_SIZE]i16 align(64),
    layer_1_bias: [HIDDEN_SIZE]i16 align(64),
    layer_2: [OUTPUT_SIZE][HIDDEN_SIZE * 2]i16 align(64),
    layer_2_bias: [OUTPUT_SIZE]i16 align(64),
};

pub var MODEL: NNUEWeights = undefined;

pub fn do_nnue() void {
    // Quantised bullet checkpoints match @sizeOf(NNUEWeights), including any
    // trailing alignment padding (bullet writes a short "bullet" footer there).
    if (@sizeOf(NNUEWeights) != NNUE_SOURCE.len) {
        std.debug.panic("Incompatible sizes Model={} vs Net={} (INPUT_SIZE={} buckets={})", .{
            @sizeOf(NNUEWeights),
            NNUE_SOURCE.len,
            INPUT_SIZE,
            NUM_INPUT_BUCKETS,
        });
    }
    // Copy straight into the global. Do NOT assign through a by-value temporary.
    // A 25 MB MODEL on the stack may cause overflow.
    @memcpy(std.mem.asBytes(&MODEL), NNUE_SOURCE[0..@sizeOf(NNUEWeights)]);

    for (&MODEL.layer_2, 0..) |bucket, bucket_idx| {
        for (bucket, 0..) |weight, weight_idx| {
            if (weight < OUTPUT_WEIGHT_MIN or weight > OUTPUT_WEIGHT_MAX) {
                std.debug.panic("NNUE output weight out of range: bucket={} index={} value={}", .{ bucket_idx, weight_idx, weight });
            }
        }
    }
}
