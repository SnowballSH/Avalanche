const std = @import("std");
pub const weights = @import("weights.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");

const QA: i32 = 255;
const QB: i32 = 64;
const QAB: i32 = QA * QB;

const SCALE: i32 = 400;

const SQUARED_ACTIVATION: bool = true;

pub const WhiteBlackPair = packed struct {
    white: usize,
    black: usize,
};

pub inline fn get_bucket(pos: *position.Position) usize {
    return (types.popcount_usize(pos.all_all_pieces()) - 2) / 4;
}

pub fn nnue_index(piece: types.Piece, sq: types.Square) WhiteBlackPair {
    const p: usize = piece.piece_type().index();
    const c: types.Color = piece.color();

    const white = @as(usize, @intCast(@intFromEnum(c))) * 64 * 6 + p * 64 + @as(usize, @intCast(sq.index()));
    const black = @as(usize, @intCast(@intFromEnum(c.invert()))) * 64 * 6 + p * 64 + @as(usize, @intCast(sq.index() ^ 56));

    return WhiteBlackPair{
        .white = white * weights.HIDDEN_SIZE,
        .black = black * weights.HIDDEN_SIZE,
    };
}

pub inline fn clipped_relu(input: i16) i32 {
    const k = @as(i32, std.math.clamp(input, 0, 255));
    if (SQUARED_ACTIVATION) {
        return k * k;
    } else {
        return k;
    }
}

// SIMD width in i16 lanes; HIDDEN_SIZE is a multiple of it.
const VL: usize = 32;

pub const Accumulator = struct {
    white: [weights.HIDDEN_SIZE]i16 align(64),
    black: [weights.HIDDEN_SIZE]i16 align(64),

    pub inline fn clear(self: *Accumulator) void {
        self.white = weights.MODEL.layer_1_bias;
        self.black = weights.MODEL.layer_1_bias;
    }

    pub fn update_weights(self: *Accumulator, comptime on: bool, data: WhiteBlackPair) void {
        const V = @Vector(VL, i16);
        const m1 = &weights.MODEL.layer_1;
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += VL) {
            const ww: V = self.white[i..][0..VL].*;
            const wb: V = self.black[i..][0..VL].*;
            const mw: V = m1[data.white + i ..][0..VL].*;
            const mb: V = m1[data.black + i ..][0..VL].*;
            if (on) {
                self.white[i..][0..VL].* = ww + mw;
                self.black[i..][0..VL].* = wb + mb;
            } else {
                self.white[i..][0..VL].* = ww - mw;
                self.black[i..][0..VL].* = wb - mb;
            }
        }
    }

    pub fn exchange_weights(self: *Accumulator, from: WhiteBlackPair, to: WhiteBlackPair) void {
        const V = @Vector(VL, i16);
        const m1 = &weights.MODEL.layer_1;
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += VL) {
            const fw: V = m1[from.white + i ..][0..VL].*;
            const tw: V = m1[to.white + i ..][0..VL].*;
            const fb: V = m1[from.black + i ..][0..VL].*;
            const tb: V = m1[to.black + i ..][0..VL].*;
            const ww: V = self.white[i..][0..VL].*;
            const wb: V = self.black[i..][0..VL].*;
            self.white[i..][0..VL].* = ww + tw - fw;
            self.black[i..][0..VL].* = wb + tb - fb;
        }
    }

    pub fn capture_weights(self: *Accumulator, captured: WhiteBlackPair, from: WhiteBlackPair, to: WhiteBlackPair) void {
        const V = @Vector(VL, i16);
        const m1 = &weights.MODEL.layer_1;
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += VL) {
            const cw: V = m1[captured.white + i ..][0..VL].*;
            const fw: V = m1[from.white + i ..][0..VL].*;
            const tw: V = m1[to.white + i ..][0..VL].*;
            const cb: V = m1[captured.black + i ..][0..VL].*;
            const fb: V = m1[from.black + i ..][0..VL].*;
            const tb: V = m1[to.black + i ..][0..VL].*;
            const ww: V = self.white[i..][0..VL].*;
            const wb: V = self.black[i..][0..VL].*;
            self.white[i..][0..VL].* = ww - cw - fw + tw;
            self.black[i..][0..VL].* = wb - cb - fb + tb;
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

        for (pos.mailbox, 0..) |pc, i| {
            if (pc == types.Piece.NO_PIECE) {
                continue;
            }

            self.toggle(true, pc, @as(types.Square, @enumFromInt(i)));
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

    pub inline fn capture(self: *NNUE, captured: types.Piece, pc: types.Piece, from: types.Square, to: types.Square) void {
        self.accumulator_stack[self.stack_index].capture_weights(nnue_index(captured, to), nnue_index(pc, from), nnue_index(pc, to));
    }

    pub inline fn evaluate(self: *NNUE, turn: types.Color, pos: *position.Position) i32 {
        return if (turn == types.Color.White) self.evaluate_comptime(types.Color.White, pos) else self.evaluate_comptime(types.Color.Black, pos);
    }

    pub inline fn evaluate_comptime(self: *NNUE, comptime turn: types.Color, pos: *position.Position) i32 {
        const acc = &self.accumulator_stack[self.stack_index];

        const bucket = get_bucket(pos);

        const w2 = &weights.MODEL.layer_2[bucket];
        const own = if (turn == types.Color.White) &acc.white else &acc.black;
        const opp = if (turn == types.Color.White) &acc.black else &acc.white;

        const Vi16 = @Vector(VL, i16);
        const Vi32 = @Vector(VL, i32);
        const zero: Vi16 = @splat(0);
        const cap: Vi16 = @splat(255);

        var sum: Vi32 = @splat(0);
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += VL) {
            const ov: Vi32 = @intCast(@min(@max(@as(Vi16, own[i..][0..VL].*), zero), cap));
            const owt: Vi32 = @intCast(@as(Vi16, w2[i..][0..VL].*));
            sum += (ov * ov) * owt;

            const pv: Vi32 = @intCast(@min(@max(@as(Vi16, opp[i..][0..VL].*), zero), cap));
            const pwt: Vi32 = @intCast(@as(Vi16, w2[weights.HIDDEN_SIZE + i ..][0..VL].*));
            sum += (pv * pv) * pwt;
        }

        const res = @reduce(.Add, sum);

        if (SQUARED_ACTIVATION) {
            return @divTrunc((@divTrunc(res, QA) + @as(i32, weights.MODEL.layer_2_bias[bucket])) * SCALE, QAB);
        } else {
            return @divTrunc((res + @as(i32, weights.MODEL.layer_2_bias[bucket])) * SCALE, QAB);
        }
    }
};
