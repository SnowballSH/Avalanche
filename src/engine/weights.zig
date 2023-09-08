const std = @import("std");

const NNUE_SOURCE = @embedFile("../../nets/net015_50.nnue");

pub const INPUT_SIZE: usize = 768;
pub const HIDDEN_SIZE: usize = 384;

pub const NNUEWeights = struct {
    layer_1: [INPUT_SIZE * HIDDEN_SIZE]i16 align(64),
    layer_1_bias: [HIDDEN_SIZE]i16 align(64),
    layer_2: [HIDDEN_SIZE * 2]i16 align(64),
    layer_2_bias: i16 align(64),
};

pub var MODEL: NNUEWeights = undefined;

pub fn do_nnue() void {
    if (@sizeOf(NNUEWeights) != NNUE_SOURCE.len) {
        std.debug.panic("Incompatible sizes Model={} vs Net={}", .{ @sizeOf(NNUEWeights), NNUE_SOURCE.len });
    }
    MODEL = std.mem.bytesAsValue(NNUEWeights, NNUE_SOURCE[0..@sizeOf(NNUEWeights)]).*;
}
