const std = @import("std");
const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");

const HCE = @import("./hce.zig");
const NNUE = @import("./nnue.zig");

pub fn is_material_drawn(pos: *Position.Position) bool {
    var pw = @popCount(u64, pos.bitboards.WhiteAll);
    var pb = @popCount(u64, pos.bitboards.BlackAll);
    if (pw == 1) {
        if (pb == 1) {
            // KvK
            return true;
        }

        if (pb == 2) {
            if (@popCount(u64, pos.bitboards.BlackKnights) == 1) {
                // KvKN
                return true;
            }
            if (@popCount(u64, pos.bitboards.BlackBishops) == 1) {
                // KvKB
                return true;
            }
        }
    } else if (pw == 2) {
        if (pb == 1) {
            if (@popCount(u64, pos.bitboards.WhiteKnights) == 1) {
                // KNvK
                return true;
            }
            if (@popCount(u64, pos.bitboards.WhiteBishops) == 1) {
                // KBvK
                return true;
            }
        }
    }

    return false;
}

pub const TEMPO_MG = 3;
pub const TEMPO_EG = 9;

pub fn is_basic_eg(pos: *Position.Position) bool {
    return (pos.bitboards.WhiteKing | pos.bitboards.BlackKing | pos.bitboards.WhiteRooks | pos.bitboards.BlackRooks) == (pos.bitboards.WhiteAll | pos.bitboards.BlackAll) or
        (pos.bitboards.WhiteKing | pos.bitboards.BlackKing | pos.bitboards.WhiteBishops | pos.bitboards.BlackBishops) == (pos.bitboards.WhiteAll | pos.bitboards.BlackAll) or
        (pos.bitboards.WhiteKing | pos.bitboards.BlackKing | pos.bitboards.WhiteQueens | pos.bitboards.BlackQueens) == (pos.bitboards.WhiteAll | pos.bitboards.BlackAll);
}

pub fn evaluate(pos: *Position.Position, nnue: *NNUE.NNUE, fifty: u8) i16 {
    if (is_material_drawn(pos)) {
        return 0;
    }

    const p = pos.phase();

    var stand_pat: i16 = 0;

    if (is_basic_eg(pos)) {
        stand_pat = HCE.evaluate(pos);
        if (pos.turn == Piece.Color.Black) {
            stand_pat = -stand_pat;
        }
    } else {
        // Uncomment if using multi-bucket net
        // var bucket = @minimum(@divFloor(p * NNUE.Weights.OUTPUT_SIZE, 24), NNUE.Weights.OUTPUT_SIZE - 1);
        const bucket = 0;
        nnue.evaluate(pos.turn, bucket);

        const nn = @intCast(i16, @minimum(nnue.result[bucket], 32767));
        stand_pat = nn;
    }

    if (p <= 6) {
        stand_pat += TEMPO_EG;
    } else {
        stand_pat += TEMPO_MG;
    }

    if (fifty >= 14 and p <= 14) {
        var red = fifty * (fifty - 2) / 40;

        if (fifty >= 50) {
            red += 40;
        }

        if (stand_pat > 0) {
            stand_pat = @maximum(0, stand_pat - red);
        } else {
            stand_pat = @minimum(0, stand_pat + red);
        }
    }

    return stand_pat;
}
