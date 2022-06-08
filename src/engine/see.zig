const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("./hce.zig");
const movepick = @import("./movepick.zig");

pub const SeeWeight = [_]movepick.SortScore{ 100, 375, 375, 500, 1025, 10000 };

pub fn see(pos: *position.Position, move: types.Move) movepick.SortScore {
    var max_depth: usize = 0;
    var defenders: types.Bitboard = 0;
    var piece_bb: types.Bitboard = 0;

    var to_sq = move.get_to();
    var all_pieces = pos.all_pieces(types.Color.White) | pos.all_pieces(types.Color.Black);
    var gains: [16]movepick.SortScore = undefined;
    var opp = pos.turn.invert();
    var blockers = all_pieces & ~types.SquareIndexBB[move.to];

    gains[0] = SeeWeight[pos.mailbox[move.to].piece_type().index()];
    var last_piece_pts = SeeWeight[pos.mailbox[move.from].piece_type().index()];

    var depth: usize = 1;
    outer: while (depth < gains.len) : (depth += 1) {
        gains[depth] = last_piece_pts - gains[depth - 1];
        if (opp == types.Color.White) {
            defenders = pos.all_pieces(types.Color.White) & blockers;
        } else {
            defenders = pos.all_pieces(types.Color.Black) & blockers;
        }
        var pt = types.PieceType.Pawn.index();
        var ending = types.PieceType.King.index();
        while (pt <= ending) : (pt += 1) {
            last_piece_pts = SeeWeight[pt];
            piece_bb = (if (pt == 0) (if (opp == types.Color.White) tables.get_pawn_attacks(types.Color.Black, to_sq) else tables.get_pawn_attacks(types.Color.White, to_sq)) else (tables.get_attacks(@intToEnum(types.PieceType, pt), to_sq, blockers))) & defenders & (pos.piece_bitboards[pt] | pos.piece_bitboards[pt + 8]);
            if (piece_bb != 0) {
                blockers &= ~(types.SquareIndexBB[@intCast(usize, types.lsb(piece_bb))]);
                opp = opp.invert();
                continue :outer;
            }
        }

        max_depth = depth;
        break;
    }

    depth = max_depth - 1;
    while (depth >= 1) : (depth -= 1) {
        gains[depth - 1] = -@maximum(-gains[depth - 1], gains[depth]);
    }

    return gains[0];
}
