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
pub const TEMPO_EG = 6;

pub fn evaluate(pos: *Position.Position, nnue: *NNUE.NNUE, fifty: u8) i16 {
    if (is_material_drawn(pos)) {
        return 0;
    }

    const p = pos.phase();

    // Uncomment if using multi-bucket net
    // var bucket = @minimum(@divFloor(p * NNUE.Weights.OUTPUT_SIZE, 24), NNUE.Weights.OUTPUT_SIZE - 1);
    const bucket = 0;
    nnue.evaluate(pos.turn, bucket);

    const nn = @intCast(i16, @minimum(nnue.result[bucket], 32767));
    var stand_pat = nn;

    if (p <= 10) {
        stand_pat += TEMPO_EG;
    } else {
        stand_pat += TEMPO_MG;
    }

    if (fifty >= 14) {
        const red = fifty * (fifty - 2) / 16;

        if (stand_pat > 0) {
            stand_pat = @maximum(0, stand_pat - red);
        } else {
            stand_pat = @minimum(0, stand_pat + red);
        }
    }

    return stand_pat;
}
