const std = @import("std");
const Weights = @import("../weights.zig");
const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");

pub fn clipped_relu(comptime N: usize, input: [N]i16) void {
    for (input) |*ptr| {
        ptr.* = std.math.min(64, std.math.max(0, ptr.*));
    }
}

pub fn clipped_relu_one(input: i16) i16 {
    return std.math.min(64, std.math.max(0, input));
}

pub const NNUE = struct {
    activations: [Weights.INPUT_SIZE]bool,
    layer1_out: [Weights.HIDDEN_SIZE]i16,
    result: [Weights.OUTPUT_SIZE]i16,

    pub fn new() NNUE {
        return NNUE{
            .activations = undefined,
            .layer1_out = undefined,
            .result = undefined,
        };
    }

    pub fn re_evaluate(self: *NNUE, pos: *Position.Position) void {
        // Reset activations
        for (self.activations) |*ptr| {
            ptr.* = false;
        }
        // Reset bias
        for (self.layer1_out) |*ptr, index| {
            ptr.* = Weights.BIAS_1[index];
        }
        for (self.result) |*ptr, index| {
            ptr.* = Weights.BIAS_2[index];
        }

        for (pos.mailbox) |pc, index| {
            if (pc == null) {
                continue;
            }

            var p = if (pos.turn == Piece.Color.Black)
                (@intCast(usize, @enumToInt(pc.?)) + 6) % 12
            else
                @intCast(usize, @enumToInt(pc.?));

            var sq = if (pos.turn == Piece.Color.Black)
                index ^ 56
            else
                index;

            self.activations[p * 64 + sq] = true;
            for (self.layer1_out) |*ptr, l_index| {
                ptr.* += Weights.LAYER_1[p * 64 + sq][l_index];
            }
        }

        for (self.layer1_out) |val, l_index| {
            for (self.result) |*ptr, r_index| {
                ptr.* += Weights.LAYER_2[l_index][r_index] * clipped_relu_one(val);
            }
        }

        for (self.result) |*ptr| {
            ptr.* = @divFloor(ptr.*, 64);
        }
    }
};
