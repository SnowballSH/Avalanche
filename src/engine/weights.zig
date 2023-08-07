const std = @import("std");

const NNUE_SOURCE = @embedFile("../../nets/new.nnue");

pub const INPUT_SIZE: usize = 768;
pub const HIDDEN_SIZE: usize = 256;

pub const NNUEWeights = packed struct {
    layer_1: [INPUT_SIZE * HIDDEN_SIZE]i16,
    layer_1_bias: [HIDDEN_SIZE]i16,
    layer_2: [HIDDEN_SIZE * 2]i16,
    layer_2_bias: i16,
};

pub var MODEL: NNUEWeights = undefined;

pub fn do_nnue() void {
    MODEL = std.mem.bytesAsValue(NNUEWeights, NNUE_SOURCE[0..@sizeOf(NNUEWeights)]).*;
}
