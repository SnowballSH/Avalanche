const std = @import("std");
pub const weights = @import("weights.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");

const QA: i32 = 255;
const QB: i32 = 64;
const QAB: i32 = QA * QB;

const SCALE: i32 = 400;

const SQUARED_ACTIVATION: bool = false;

pub const WhiteBlackPair = packed struct {
    white: usize,
    black: usize,
};

pub fn nnue_index(piece: types.Piece, sq: types.Square) WhiteBlackPair {
    const p: usize = piece.piece_type().index();
    const c: types.Color = piece.color();

    const white = @intCast(usize, @enumToInt(c)) * 64 * 6 + p * 64 + @intCast(usize, sq.index());
    const black = @intCast(usize, @enumToInt(c.invert())) * 64 * 6 + p * 64 + @intCast(usize, sq.index() ^ 56);

    return WhiteBlackPair{
        .white = white * weights.HIDDEN_SIZE,
        .black = black * weights.HIDDEN_SIZE,
    };
}

pub inline fn clipped_relu(input: i16) i32 {
    const k = @intCast(i32, @min(255, @max(0, input)));
    if (SQUARED_ACTIVATION) {
        return k * k;
    } else {
        return k;
    }
}

pub const Accumulator = packed struct {
    white: [weights.HIDDEN_SIZE]i16,
    black: [weights.HIDDEN_SIZE]i16,

    pub inline fn clear(self: *Accumulator) void {
        self.white = weights.MODEL.layer_1_bias;
        self.black = weights.MODEL.layer_1_bias;
    }

    pub fn update_weights(self: *Accumulator, comptime on: bool, data: WhiteBlackPair) void {
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += 1) {
            if (on) {
                self.white[i] += weights.MODEL.layer_1[data.white + i];
                self.black[i] += weights.MODEL.layer_1[data.black + i];
            } else {
                self.white[i] -= weights.MODEL.layer_1[data.white + i];
                self.black[i] -= weights.MODEL.layer_1[data.black + i];
            }
        }
    }

    pub fn exchange_weights(self: *Accumulator, from: WhiteBlackPair, to: WhiteBlackPair) void {
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += 1) {
            self.white[i] += weights.LAYER_1[to.white + i] - weights.LAYER_1[from.white + i];
            self.black[i] += weights.LAYER_1[to.black + i] - weights.LAYER_1[from.black + i];
        }
    }
};

pub const NNUE = struct {
    accumulator_stack: [search.MAX_PLY + 2]Accumulator,
    stack_index: usize,

    pub fn new() NNUE {
        return NNUE{
            .accumulator_stack = undefined,
            .stack_index = 0,
        };
    }

    pub inline fn toggle(self: *NNUE, comptime on: bool, piece: types.Piece, sq: types.Square) void {
        self.accumulator_stack[self.stack_index].update_weights(on, nnue_index(piece, sq));
    }

    pub fn refresh_accumulator(self: *NNUE, pos: *position.Position) void {
        self.stack_index = 0;
        self.accumulator_stack[0].clear();

        for (pos.mailbox) |pc, i| {
            if (pc == types.Piece.NO_PIECE) {
                continue;
            }

            self.toggle(true, pc, @intToEnum(types.Square, i));
        }
    }

    pub inline fn pop(self: *NNUE) void {
        self.stack_index -= 1;
    }

    pub inline fn push(self: *NNUE) void {
        self.accumulator_stack[self.stack_index + 1] = self.accumulator_stack[self.stack_index];
        self.stack_index += 1;
    }

    pub inline fn move(self: *NNUE, pc: types.Piece, from: types.Square, to: types.Square) void {
        self.accumulator_stack[self.stack_index].exchange_weights(nnue_index(pc, from), nnue_index(pc, to));
    }

    pub inline fn evaluate(self: *NNUE, turn: types.Color) i32 {
        return if (turn == types.Color.White) self.evaluate_comptime(types.Color.White) else self.evaluate_comptime(types.Color.Black);
    }

    pub inline fn evaluate_comptime(self: *NNUE, comptime turn: types.Color) i32 {
        const acc = &self.accumulator_stack[self.stack_index];

        var res: i32 = @intCast(i32, weights.MODEL.layer_2_bias);

        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += 1) {
            if (turn == types.Color.White) {
                res += clipped_relu(acc.white[i]) * weights.MODEL.layer_2[i];
                res += clipped_relu(acc.black[i]) * weights.MODEL.layer_2[i + weights.HIDDEN_SIZE];
            } else {
                res += clipped_relu(acc.black[i]) * weights.MODEL.layer_2[i];
                res += clipped_relu(acc.white[i]) * weights.MODEL.layer_2[i + weights.HIDDEN_SIZE];
            }
        }

        if (SQUARED_ACTIVATION) {
            return @divTrunc(@divTrunc(res, QA) * SCALE, QAB);
        } else {
            return @divTrunc(res * SCALE, QAB);
        }
    }
};
