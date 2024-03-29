const std = @import("std");

const NNUE_SOURCE = @embedFile("../../nets/bingshan.nnue");

pub const INPUT_SIZE: usize = 768;
pub const HIDDEN_SIZE: usize = 512;
pub const OUTPUT_SIZE: usize = 8;

pub const NNUEWeights = struct {
    layer_1: [INPUT_SIZE * HIDDEN_SIZE]i16 align(64),
    layer_1_bias: [HIDDEN_SIZE]i16 align(64),
    layer_2: [OUTPUT_SIZE][HIDDEN_SIZE * 2]i16 align(64),
    layer_2_bias: [OUTPUT_SIZE]i16 align(64),
};

pub var MODEL: NNUEWeights = undefined;

pub fn do_nnue() void {
    if (@sizeOf(NNUEWeights) != NNUE_SOURCE.len) {
        std.debug.panic("Incompatible sizes Model={} vs Net={}", .{ @sizeOf(NNUEWeights), NNUE_SOURCE.len });
    }
    MODEL = std.mem.bytesAsValue(NNUEWeights, NNUE_SOURCE[0..@sizeOf(NNUEWeights)]).*;
}
