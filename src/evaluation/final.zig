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

pub fn evaluate(pos: *Position.Position, nnue: *NNUE.NNUE) i16 {
    if (is_material_drawn(pos)) {
        return 0;
    }

    var stand_pat = HCE.evaluate(pos);
    if (pos.turn == Piece.Color.Black) {
        stand_pat *= -1;
    }
    if (std.math.absInt(stand_pat) catch 0 <= 800) {
        var bucket = @minimum(@divFloor(pos.phase() * NNUE.Weights.OUTPUT_SIZE, 24), NNUE.Weights.OUTPUT_SIZE - 1);
        nnue.evaluate(pos.turn, bucket);

        var nn = @truncate(i16, nnue.result[bucket]);
        stand_pat = @divFloor(stand_pat + nn * 3, 4);
    }

    return stand_pat;
}
