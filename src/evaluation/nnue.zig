const std = @import("std");
pub const Weights = @import("../weights.zig");
const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");

pub inline fn clipped_relu_one(input: i16) i16 {
    return std.math.min(64, std.math.max(0, input));
}

pub inline fn normalize(val: i32) i16 {
    return @floatToInt(i16, @intToFloat(f32, val) * 170.0 / 64.0 / 64.0);
}

pub const NNUE = struct {
    activations: [2][Weights.INPUT_SIZE]bool,
    accumulator: [2][Weights.HIDDEN_SIZE]i16,
    result: [Weights.OUTPUT_SIZE]i32,
    residual: [2][Weights.OUTPUT_SIZE]i32,

    pub fn new() NNUE {
        return NNUE{
            .activations = undefined,
            .accumulator = undefined,
            .result = undefined,
            .residual = undefined,
        };
    }

    pub fn refresh_accumulator(self: *NNUE, pos: *Position.Position) void {
        // Reset activations
        for (self.activations[0]) |*ptr| {
            ptr.* = false;
        }
        for (self.activations[1]) |*ptr| {
            ptr.* = false;
        }

        // Reset psqt
        for (self.residual) |*m| {
            for (m) |*ptr| {
                ptr.* = 0;
            }
        }

        // Reset bias
        for (self.accumulator[0]) |*ptr, index| {
            ptr.* = Weights.BIAS_1[index];
        }
        for (self.accumulator[1]) |*ptr, index| {
            ptr.* = Weights.BIAS_1[index];
        }

        for (pos.mailbox) |pc, index_| {
            if (pc == null) {
                continue;
            }

            var index = Position.fen_sq_to_sq(@intCast(u8, index_));

            var wi = @intCast(usize, @enumToInt(pc.?)) * 64 + index;
            var bi = ((@intCast(usize, @enumToInt(pc.?)) + 6) % 12) * 64 + (index ^ 56);

            self.activations[0][wi] = true;
            self.activations[1][bi] = true;

            for (self.accumulator[0]) |*ptr, l_index| {
                ptr.* += Weights.LAYER_1[wi][l_index];
            }
            for (self.accumulator[1]) |*ptr, l_index| {
                ptr.* += Weights.LAYER_1[bi][l_index];
            }

            for (self.residual[0]) |*ptr, res_index| {
                ptr.* += Weights.PSQT[wi][res_index];
            }
            for (self.residual[1]) |*ptr, res_index| {
                ptr.* += Weights.PSQT[bi][res_index];
            }
        }
    }

    pub fn deactivate(self: *NNUE, pc: Piece.Piece, index: usize) void {
        var wi = @intCast(usize, @enumToInt(pc)) * 64 + index;
        var bi = ((@intCast(usize, @enumToInt(pc)) + 6) % 12) * 64 + (index ^ 56);

        self.activations[0][wi] = false;
        self.activations[1][bi] = false;

        for (self.accumulator[0]) |*ptr, l_index| {
            ptr.* -= Weights.LAYER_1[wi][l_index];
        }
        for (self.accumulator[1]) |*ptr, l_index| {
            ptr.* -= Weights.LAYER_1[bi][l_index];
        }

        for (self.residual[0]) |*ptr, res_index| {
            ptr.* -= Weights.PSQT[wi][res_index];
        }
        for (self.residual[1]) |*ptr, res_index| {
            ptr.* -= Weights.PSQT[bi][res_index];
        }
    }

    pub fn activate(self: *NNUE, pc: Piece.Piece, index: usize) void {
        var wi = @intCast(usize, @enumToInt(pc)) * 64 + index;
        var bi = ((@intCast(usize, @enumToInt(pc)) + 6) % 12) * 64 + (index ^ 56);

        self.activations[0][wi] = true;
        self.activations[1][bi] = true;

        for (self.accumulator[0]) |*ptr, l_index| {
            ptr.* += Weights.LAYER_1[wi][l_index];
        }
        for (self.accumulator[1]) |*ptr, l_index| {
            ptr.* += Weights.LAYER_1[bi][l_index];
        }

        for (self.residual[0]) |*ptr, res_index| {
            ptr.* += Weights.PSQT[wi][res_index];
        }
        for (self.residual[1]) |*ptr, res_index| {
            ptr.* += Weights.PSQT[bi][res_index];
        }
    }

    pub fn re_evaluate(self: *NNUE, pos: *Position.Position) void {
        self.refresh_accumulator(pos);
        for (self.result) |*ptr, i| {
            ptr.* = Weights.BIAS_2[i];
        }

        for (self.accumulator[@enumToInt(pos.turn)]) |val, l_index| {
            for (self.result) |*ptr, r_index| {
                ptr.* += Weights.LAYER_2[l_index][r_index] * clipped_relu_one(val);
            }
        }

        for (self.result) |*ptr, idx| {
            ptr.* = normalize(ptr.*) + @divFloor(self.residual[@enumToInt(pos.turn)][idx], 64);
        }
    }

    pub fn evaluate(self: *NNUE, turn: Piece.Color, bucket: usize) void {
        self.result[bucket] = Weights.BIAS_2[bucket];

        for (self.accumulator[@enumToInt(turn)]) |val, l_index| {
            self.result[bucket] += Weights.LAYER_2[l_index][bucket] * clipped_relu_one(val);
        }

        self.result[bucket] = normalize(self.result[bucket]) + @divFloor(self.residual[@enumToInt(turn)][bucket], 64);
    }
};
