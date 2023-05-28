const std = @import("std");
pub const weights = @import("weights.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");

pub inline fn clipped_relu_one(input: i16) i16 {
    return @min(64, @max(0, input));
}

pub inline fn normalize(val: i32) i16 {
    return @intCast(i16, (val * 85) >> 11); // * 170.0 / 64.0 / 64.0
}

pub inline fn normalize1(val: i32) i32 {
    return (val * 85) >> 11;
}

const UseResidual = weights.UseResidual;

pub const NNUE = struct {
    accumulator: [2][weights.HIDDEN_SIZE]i16,
    result: [weights.OUTPUT_SIZE]i32,
    residual: [2][weights.OUTPUT_SIZE]i32,

    pub fn new() NNUE {
        return NNUE{
            .accumulator = undefined,
            .result = undefined,
            .residual = undefined,
        };
    }

    pub fn refresh_accumulator(self: *NNUE, pos: *position.Position) void {
        if (UseResidual) {
            // Reset psqt
            for (self.residual) |*m| {
                for (m) |*ptr| {
                    ptr.* = 0;
                }
            }
        }

        // Reset bias
        for (self.accumulator[0]) |*ptr, index| {
            ptr.* = weights.BIAS_1[index];
        }
        for (self.accumulator[1]) |*ptr, index| {
            ptr.* = weights.BIAS_1[index];
        }

        for (pos.mailbox) |pc, index| {
            if (pc == types.Piece.NO_PIECE) {
                continue;
            }

            var wi = pc.pure_index() * 64 + index;
            var bi = ((pc.pure_index() + 6) % 12) * 64 + (index ^ 56);

            for (self.accumulator[0]) |*ptr, l_index| {
                ptr.* += weights.LAYER_1[wi][l_index];
            }
            for (self.accumulator[1]) |*ptr, l_index| {
                ptr.* += weights.LAYER_1[bi][l_index];
            }

            if (UseResidual) {
                for (self.residual[0]) |*ptr, res_index| {
                    ptr.* += weights.PSQT[wi][res_index];
                }
                for (self.residual[1]) |*ptr, res_index| {
                    ptr.* += weights.PSQT[bi][res_index];
                }
            }
        }
    }

    pub fn deactivate(self: *NNUE, pc: types.Piece, index: usize) void {
        var i = pc.pure_index();
        var wi = i * 64 + index;
        var bi = ((i + 6) % 12) * 64 + (index ^ 56);

        for (self.accumulator[0]) |*ptr, l_index| {
            ptr.* -= weights.LAYER_1[wi][l_index];
        }
        for (self.accumulator[1]) |*ptr, l_index| {
            ptr.* -= weights.LAYER_1[bi][l_index];
        }

        if (UseResidual) {
            for (self.residual[0]) |*ptr, res_index| {
                ptr.* -= weights.PSQT[wi][res_index];
            }
            for (self.residual[1]) |*ptr, res_index| {
                ptr.* -= weights.PSQT[bi][res_index];
            }
        }
    }

    pub fn activate(self: *NNUE, pc: types.Piece, index: usize) void {
        var i = pc.pure_index();
        var wi = i * 64 + index;
        var bi = ((i + 6) % 12) * 64 + (index ^ 56);

        for (self.accumulator[0]) |*ptr, l_index| {
            ptr.* += weights.LAYER_1[wi][l_index];
        }
        for (self.accumulator[1]) |*ptr, l_index| {
            ptr.* += weights.LAYER_1[bi][l_index];
        }

        if (UseResidual) {
            for (self.residual[0]) |*ptr, res_index| {
                ptr.* += weights.PSQT[wi][res_index];
            }
            for (self.residual[1]) |*ptr, res_index| {
                ptr.* += weights.PSQT[bi][res_index];
            }
        }
    }

    pub fn re_evaluate(self: *NNUE, pos: *position.Position) void {
        self.refresh_accumulator(pos);
        for (self.result) |*ptr, i| {
            ptr.* = weights.BIAS_2[i];
        }

        for (self.accumulator[@enumToInt(pos.turn)]) |val, l_index| {
            for (self.result) |*ptr, r_index| {
                ptr.* += weights.LAYER_2[l_index][r_index] * clipped_relu_one(val);
            }
        }

        for (self.result) |*ptr, idx| {
            ptr.* = normalize(ptr.*);
            if (UseResidual) {
                ptr.* += @divTrunc(self.residual[@enumToInt(pos.turn)][idx], 64);
            }
        }
    }

    pub inline fn evaluate(self: *NNUE, turn: types.Color, bucket: usize) i32 {
        var res = @intCast(i32, weights.BIAS_2[bucket]);

        for (self.accumulator[@enumToInt(turn)]) |val, l_index| {
            res += @intCast(i32, weights.LAYER_2[l_index][bucket]) * @intCast(i32, clipped_relu_one(val));
        }

        res = normalize1(res);

        if (UseResidual) {
            return res + (self.residual[@enumToInt(turn)][bucket] >> 6);
        }

        return res;
    }
};
