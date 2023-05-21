const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const nnue = @import("nnue.zig");

pub const Score = i32;

pub const MateScore: Score = 888888;

pub const UseNNUE = true;

pub const Mateiral: [6][2]Score = .{
    .{ 82, 94 },
    .{ 337, 281 },
    .{ 365, 297 },
    .{ 477, 512 },
    .{ 1025, 936 },
    .{ 0, 0 },
};

// PeSTO PSQT for testing purposes
pub const PSQT: [6][2][64]Score = .{
    .{
        .{
            0,   0,   0,   0,   0,   0,   0,  0,
            98,  134, 61,  95,  68,  126, 34, -11,
            -6,  7,   26,  31,  65,  56,  25, -20,
            -14, 13,  6,   21,  23,  12,  17, -23,
            -27, -2,  -5,  12,  17,  6,   10, -25,
            -26, -4,  -4,  -10, 3,   3,   33, -12,
            -35, -1,  -20, -23, -15, 24,  38, -22,
            0,   0,   0,   0,   0,   0,   0,  0,
        },
        .{
            0,   0,   0,   0,   0,   0,   0,   0,
            178, 173, 158, 134, 147, 132, 165, 187,
            94,  100, 85,  67,  56,  53,  82,  84,
            32,  24,  13,  5,   -2,  4,   17,  17,
            13,  9,   -3,  -7,  -7,  -8,  3,   -1,
            4,   7,   -6,  1,   0,   -5,  -1,  -8,
            13,  8,   8,   10,  13,  0,   2,   -7,
            0,   0,   0,   0,   0,   0,   0,   0,
        },
    },
    .{
        .{
            -167, -89, -34, -49, 61,  -97, -15, -107,
            -73,  -41, 72,  36,  23,  62,  7,   -17,
            -47,  60,  37,  65,  84,  129, 73,  44,
            -9,   17,  19,  53,  37,  69,  18,  22,
            -13,  4,   16,  13,  28,  19,  21,  -8,
            -23,  -9,  12,  10,  19,  17,  25,  -16,
            -29,  -53, -12, -3,  -1,  18,  -14, -19,
            -105, -21, -58, -33, -17, -28, -19, -23,
        },
        .{
            -58, -38, -13, -28, -31, -27, -63, -99,
            -25, -8,  -25, -2,  -9,  -25, -24, -52,
            -24, -20, 10,  9,   -1,  -9,  -19, -41,
            -17, 3,   22,  22,  22,  11,  8,   -18,
            -18, -6,  16,  25,  16,  17,  4,   -18,
            -23, -3,  -1,  15,  10,  -3,  -20, -22,
            -42, -20, -10, -5,  -2,  -20, -23, -44,
            -29, -51, -23, -15, -22, -18, -50, -64,
        },
    },
    .{
        .{
            -29, 4,  -82, -37, -25, -42, 7,   -8,
            -26, 16, -18, -13, 30,  59,  18,  -47,
            -16, 37, 43,  40,  35,  50,  37,  -2,
            -4,  5,  19,  50,  37,  37,  7,   -2,
            -6,  13, 13,  26,  34,  12,  10,  4,
            0,   15, 15,  15,  14,  27,  18,  10,
            4,   15, 16,  0,   7,   21,  33,  1,
            -33, -3, -14, -21, -13, -12, -39, -21,
        },
        .{
            -14, -21, -11, -8,  -7, -9,  -17, -24,
            -8,  -4,  7,   -12, -3, -13, -4,  -14,
            2,   -8,  0,   -1,  -2, 6,   0,   4,
            -3,  9,   12,  9,   14, 10,  3,   2,
            -6,  3,   13,  19,  7,  10,  -3,  -9,
            -12, -3,  8,   10,  13, 3,   -7,  -15,
            -14, -18, -7,  -1,  4,  -9,  -15, -27,
            -23, -9,  -23, -5,  -9, -16, -5,  -17,
        },
    },
    .{
        .{
            32,  42,  32,  51,  63, 9,  31,  43,
            27,  32,  58,  62,  80, 67, 26,  44,
            -5,  19,  26,  36,  17, 45, 61,  16,
            -24, -11, 7,   26,  24, 35, -8,  -20,
            -36, -26, -12, -1,  9,  -7, 6,   -23,
            -45, -25, -16, -17, 3,  0,  -5,  -33,
            -44, -16, -20, -9,  -1, 11, -6,  -71,
            -19, -13, 1,   17,  16, 7,  -37, -26,
        },
        .{
            13, 10, 18, 15, 12, 12,  8,   5,
            11, 13, 13, 11, -3, 3,   8,   3,
            7,  7,  7,  5,  4,  -3,  -5,  -3,
            4,  3,  13, 1,  2,  1,   -1,  2,
            3,  5,  8,  4,  -5, -6,  -8,  -11,
            -4, 0,  -5, -1, -7, -12, -8,  -16,
            -6, -6, 0,  2,  -9, -9,  -11, -3,
            -9, 2,  3,  -1, -5, -13, 4,   -20,
        },
    },
    .{
        .{
            -28, 0,   29,  12,  59,  44,  43,  45,
            -24, -39, -5,  1,   -16, 57,  28,  54,
            -13, -17, 7,   8,   29,  56,  47,  57,
            -27, -27, -16, -16, -1,  17,  -2,  1,
            -9,  -26, -9,  -10, -2,  -4,  3,   -3,
            -14, 2,   -11, -2,  -5,  2,   14,  5,
            -35, -8,  11,  2,   8,   15,  -3,  1,
            -1,  -18, -9,  10,  -15, -25, -31, -50,
        },
        .{
            -9,  22,  22,  27,  27,  19,  10,  20,
            -17, 20,  32,  41,  58,  25,  30,  0,
            -20, 6,   9,   49,  47,  35,  19,  9,
            3,   22,  24,  45,  57,  40,  57,  36,
            -18, 28,  19,  47,  31,  34,  39,  23,
            -16, -27, 15,  6,   9,   17,  10,  5,
            -22, -23, -30, -16, -16, -23, -36, -32,
            -33, -28, -22, -43, -5,  -32, -20, -41,
        },
    },
    .{
        .{
            -65, 23,  16,  -15, -56, -34, 2,   13,
            29,  -1,  -20, -7,  -8,  -4,  -38, -29,
            -9,  24,  2,   -16, -20, 6,   22,  -22,
            -17, -20, -12, -27, -30, -25, -14, -36,
            -49, -1,  -27, -39, -46, -44, -33, -51,
            -14, -14, -22, -46, -44, -30, -15, -27,
            1,   7,   -8,  -64, -43, -16, 9,   8,
            -15, 36,  12,  -54, 8,   -28, 24,  14,
        },
        .{
            -74, -35, -18, -18, -11, 15,  4,   -17,
            -12, 17,  14,  17,  17,  38,  23,  11,
            10,  17,  23,  15,  20,  45,  44,  13,
            -8,  22,  24,  27,  26,  33,  26,  3,
            -18, -4,  21,  24,  27,  23,  9,   -11,
            -19, -3,  11,  21,  23,  16,  7,   -9,
            -27, -11, 4,   13,  14,  4,   -5,  -17,
            -53, -34, -21, -11, -28, -14, -24, -43,
        },
    },
};

const CenterManhattanDistance = [64]Score{
    6, 5, 4, 3, 3, 4, 5, 6,
    5, 4, 3, 2, 2, 3, 4, 5,
    4, 3, 2, 1, 1, 2, 3, 4,
    3, 2, 1, 0, 0, 1, 2, 3,
    3, 2, 1, 0, 0, 1, 2, 3,
    4, 3, 2, 1, 1, 2, 3, 4,
    5, 4, 3, 2, 2, 3, 4, 5,
    6, 5, 4, 3, 3, 4, 5, 6,
};

pub const DynamicEvaluator = struct {
    score_mg: Score = 0,
    score_eg_non_mat: Score = 0,
    score_eg_material: Score = 0,
    nnue_evaluator: nnue.NNUE = nnue.NNUE.new(),
    need_hce: bool = false,

    pub fn add_piece(self: *DynamicEvaluator, pc: types.Piece, sq: types.Square, _: *position.Position) void {
        if (UseNNUE) {
            self.nnue_evaluator.activate(pc, sq.index());
        }
        if (self.need_hce) {
            const i = pc.piece_type().index();
            if (pc.color() == types.Color.White) {
                self.score_mg += Mateiral[i][0];
                self.score_mg += PSQT[i][0][sq.index() ^ 56];
                self.score_eg_material += Mateiral[i][1];
                self.score_eg_non_mat += PSQT[i][1][sq.index() ^ 56];
            } else {
                self.score_mg -= Mateiral[i][0];
                self.score_mg -= PSQT[i][0][sq.index()];
                self.score_eg_material -= Mateiral[i][1];
                self.score_eg_non_mat -= PSQT[i][1][sq.index()];
            }
        }
    }

    pub fn remove_piece(self: *DynamicEvaluator, sq: types.Square, pos: *position.Position) void {
        const pc = pos.mailbox[sq.index()];

        if (pc != types.Piece.NO_PIECE) {
            if (UseNNUE) {
                self.nnue_evaluator.deactivate(pc, sq.index());
            }
            if (self.need_hce) {
                const i = pc.piece_type().index();
                if (pc.color() == types.Color.White) {
                    self.score_mg -= Mateiral[i][0];
                    self.score_mg -= PSQT[i][0][sq.index() ^ 56];
                    self.score_eg_material -= Mateiral[i][1];
                    self.score_eg_non_mat -= PSQT[i][1][sq.index() ^ 56];
                } else {
                    self.score_mg += Mateiral[i][0];
                    self.score_mg += PSQT[i][0][sq.index()];
                    self.score_eg_material += Mateiral[i][1];
                    self.score_eg_non_mat += PSQT[i][1][sq.index()];
                }
            }
        }
    }

    pub fn move_piece(self: *DynamicEvaluator, from: types.Square, to: types.Square, pos: *position.Position) void {
        self.remove_piece(to, pos);
        self.move_piece_quiet(from, to, pos);
    }

    pub fn move_piece_quiet(self: *DynamicEvaluator, from: types.Square, to: types.Square, pos: *position.Position) void {
        const pc = pos.mailbox[from.index()];
        if (pc != types.Piece.NO_PIECE) {
            if (UseNNUE) {
                self.nnue_evaluator.deactivate(pc, from.index());
                self.nnue_evaluator.activate(pc, to.index());
            }
            if (self.need_hce) {
                const i = pc.piece_type().index();
                if (pc.color() == types.Color.White) {
                    self.score_mg -= PSQT[i][0][from.index() ^ 56];
                    self.score_mg += PSQT[i][0][to.index() ^ 56];
                    self.score_eg_non_mat -= PSQT[i][1][from.index() ^ 56];
                    self.score_eg_non_mat += PSQT[i][1][to.index() ^ 56];
                } else {
                    self.score_mg += PSQT[i][0][from.index()];
                    self.score_mg -= PSQT[i][0][to.index()];
                    self.score_eg_non_mat += PSQT[i][1][from.index()];
                    self.score_eg_non_mat -= PSQT[i][1][to.index()];
                }
            }
        }
    }

    pub fn full_refresh(self: *DynamicEvaluator, pos: *position.Position) void {
        if (UseNNUE) {
            self.nnue_evaluator.refresh_accumulator(pos);
        }
        self.refresh_hce(pos);
    }

    pub fn refresh_hce(self: *DynamicEvaluator, pos: *position.Position) void {
        var mg: Score = 0;
        var eg_material: Score = 0;
        var eg_non_mat: Score = 0;
        for (pos.mailbox, 0..) |piece, index| {
            if (piece == types.Piece.NO_PIECE) {
                continue;
            }
            var i = piece.piece_type().index();
            if (piece.color() == types.Color.White) {
                mg += Mateiral[i][0];
                mg += PSQT[i][0][index ^ 56];
                eg_material += Mateiral[i][1];
                eg_non_mat += PSQT[i][1][index ^ 56];
            } else {
                mg -= Mateiral[i][0];
                mg -= PSQT[i][0][index];
                eg_material -= Mateiral[i][1];
                eg_non_mat -= PSQT[i][1][index];
            }
        }

        self.score_mg = mg;
        self.score_eg_material = eg_material;
        self.score_eg_non_mat = eg_non_mat;
    }
};

pub fn distance_eval(pos: *position.Position, comptime white_winning: bool) Score {
    var k1 = @intToEnum(types.Square, types.lsb(pos.piece_bitboards[types.Piece.WHITE_KING.index()]));
    var k2 = @intToEnum(types.Square, types.lsb(pos.piece_bitboards[types.Piece.BLACK_KING.index()]));

    var r1 = @intCast(Score, k1.rank().index());
    var r2 = @intCast(Score, k2.rank().index());
    var c1 = @intCast(Score, k1.file().index());
    var c2 = @intCast(Score, k2.file().index());

    var score: Score = 0;
    var m_dist: Score = (std.math.absInt(r1 - r2) catch 0) + (std.math.absInt(c1 - c2) catch 0);

    if (white_winning) {
        score -= m_dist * 5;
        score += CenterManhattanDistance[k2.index()] * 10;
    } else {
        score += m_dist * 5;
        score -= CenterManhattanDistance[k1.index()] * 10;
    }

    return score;
}

pub fn evaluate(pos: *position.Position) Score {
    var phase = pos.phase();
    var result: Score = 0;
    if (UseNNUE and (phase >= 3 or pos.has_pawns())) {
        result = evaluate_nnue(pos);
    } else {
        if (!pos.evaluator.need_hce) {
            pos.evaluator.need_hce = true;
            pos.evaluator.refresh_hce(pos);
        }
        // Tapered eval

        var mg_phase: Score = 0;
        var eg_phase: Score = 0;
        var mg_score: Score = 0;
        var eg_score: Score = 0;

        mg_phase = @intCast(i32, phase);
        if (mg_phase > 24) {
            mg_phase = 24;
        }
        eg_phase = 24 - mg_phase;

        mg_score = pos.evaluator.score_mg;
        eg_score = pos.evaluator.score_eg_material;

        while (true) {
            // Late endgame with one side winning
            if (phase <= 4 and phase >= 1 and !pos.has_pawns()) {
                if (pos.piece_bitboards[types.Piece.BLACK_KING.index()] == pos.all_pieces(types.Color.Black)) {
                    // White is winning
                    eg_score += distance_eval(pos, true);
                    eg_score += @divFloor(pos.evaluator.score_eg_non_mat, 2);
                    eg_score = @max(100, eg_score - @intCast(Score, pos.history[pos.game_ply].fifty));
                    break;
                } else if (pos.piece_bitboards[types.Piece.WHITE_KING.index()] == pos.all_pieces(types.Color.White)) {
                    // Black is winning
                    eg_score += distance_eval(pos, false);
                    eg_score += @divFloor(pos.evaluator.score_eg_non_mat, 2);
                    eg_score = @min(-100, eg_score + @intCast(Score, pos.history[pos.game_ply].fifty));
                    break;
                }
            }

            eg_score += pos.evaluator.score_eg_non_mat;

            break;
        }

        var score = @divFloor(mg_score * mg_phase + eg_score * eg_phase, 24);
        if (pos.turn == types.Color.White) {
            result = score;
        } else {
            result = -score;
        }
    }

    if (phase <= 5 and std.math.absInt(result) catch 0 >= 16 and is_material_drawish(pos)) {
        const drawish_factor: Score = 8;
        result = @divTrunc(result, drawish_factor);
    }

    return result;
}

pub inline fn evaluate_nnue(pos: *position.Position) Score {
    var bucket: usize = 0;
    if (nnue.weights.OUTPUT_SIZE != 1) {
        bucket = @min(@divFloor(pos.phase() * nnue.weights.OUTPUT_SIZE, 24), nnue.weights.OUTPUT_SIZE - 1);
    }
    return pos.evaluator.nnue_evaluator.evaluate(pos.turn, bucket);
}

pub fn is_material_draw(pos: *position.Position) bool {
    var all = pos.all_pieces(types.Color.White) | pos.all_pieces(types.Color.Black);
    var kings = pos.piece_bitboards[types.Piece.WHITE_KING.index()] | pos.piece_bitboards[types.Piece.BLACK_KING.index()];

    if (kings == all) {
        return true;
    }

    var wb = pos.piece_bitboards[types.Piece.WHITE_BISHOP.index()];
    var bb = pos.piece_bitboards[types.Piece.BLACK_BISHOP.index()];
    var wn = pos.piece_bitboards[types.Piece.WHITE_KNIGHT.index()];
    var bn = pos.piece_bitboards[types.Piece.BLACK_KNIGHT.index()];

    var wbc = types.popcount(wb);
    var bbc = types.popcount(bb);
    var wnc = types.popcount(wn);
    var bnc = types.popcount(bn);

    // KB vs K
    if (wbc == 1 and wb | kings == all) {
        return true;
    }

    if (bbc == 1 and bb | kings == all) {
        return true;
    }

    // KN vs K
    if (wnc == 1 and wn | kings == all) {
        return true;
    }

    if (bnc == 1 and bn | kings == all) {
        return true;
    }

    return false;
}

pub fn is_material_drawish(pos: *position.Position) bool {
    var all = pos.all_pieces(types.Color.White) | pos.all_pieces(types.Color.Black);
    var kings = pos.piece_bitboards[types.Piece.WHITE_KING.index()] | pos.piece_bitboards[types.Piece.BLACK_KING.index()];

    if (kings == all) {
        return true;
    }

    var wb = pos.piece_bitboards[types.Piece.WHITE_BISHOP.index()];
    var bb = pos.piece_bitboards[types.Piece.BLACK_BISHOP.index()];
    var wn = pos.piece_bitboards[types.Piece.WHITE_KNIGHT.index()];
    var bn = pos.piece_bitboards[types.Piece.BLACK_KNIGHT.index()];

    var wbc = types.popcount(wb);
    var bbc = types.popcount(bb);
    var wnc = types.popcount(wn);
    var bnc = types.popcount(bn);

    // KN vs K or KNN vs K
    if (wnc <= 2 and wn | kings == all) {
        return true;
    }

    if (bnc <= 2 and bn | kings == all) {
        return true;
    }

    // KN vs KN
    if (wnc == 1 and bnc == 1 and wn | bn | kings == all) {
        return true;
    }

    // KB vs KB
    if (wbc == 1 and bbc == 1 and wb | bb | kings == all) {
        return true;
    }

    // KB vs KN
    if (wbc == 1 and bnc == 1 and wb | bn | kings == all) {
        return true;
    }

    if (bbc == 1 and wnc == 1 and bb | wn | kings == all) {
        return true;
    }

    // KNN vs KB
    if (wnc == 2 and bbc == 1 and wn | bb | kings == all) {
        return true;
    }

    if (bnc == 2 and wbc == 1 and bn | wb | kings == all) {
        return true;
    }

    // KBN vs KB
    if (wbc == 1 and wnc == 1 and bbc == 1 and wb | wn | bb | kings == all) {
        return true;
    }

    if (bbc == 1 and bnc == 1 and wbc == 1 and bb | bn | wb | kings == all) {
        return true;
    }

    return false;
}

pub const MaxMate: i32 = 256;

pub fn is_near_mate(score: Score) bool {
    return score >= MateScore - MaxMate or score <= -MateScore + MaxMate;
}
