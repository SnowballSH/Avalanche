const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const movepick = @import("movepick.zig");

pub const SeeWeight = [_]i32{ 93, 308, 346, 521, 994, 20000 };

pub fn see_score(pos: *position.Position, move: types.Move) i32 {
    var max_depth: usize = 0;
    var defenders: types.Bitboard = 0;
    var piece_bb: types.Bitboard = 0;

    const to_sq = move.get_to();
    const white_pieces = pos.all_pieces(types.Color.White);
    const black_pieces = pos.all_pieces(types.Color.Black);
    const all_pieces = white_pieces | black_pieces;
    var gains: [16]i32 = undefined;
    var opp = pos.turn.invert();
    var blockers = all_pieces & ~types.SquareIndexBB[move.to];

    gains[0] = SeeWeight[pos.mailbox[move.to].piece_type().index()];
    var last_piece_pts = SeeWeight[pos.mailbox[move.from].piece_type().index()];

    var depth: usize = 1;
    outer: while (depth < gains.len) : (depth += 1) {
        gains[depth] = last_piece_pts - gains[depth - 1];
        defenders = (if (opp == types.Color.White) white_pieces else black_pieces) & blockers;
        var pt = types.PieceType.Pawn.index();
        const ending = types.PieceType.King.index();
        while (pt <= ending) : (pt += 1) {
            last_piece_pts = SeeWeight[pt];
            piece_bb = (if (pt == 0) (if (opp == types.Color.White) tables.get_pawn_attacks(types.Color.Black, to_sq) else tables.get_pawn_attacks(types.Color.White, to_sq)) else (tables.get_attacks(@as(types.PieceType, @enumFromInt(pt)), to_sq, blockers))) & defenders & (pos.piece_bitboards[pt] | pos.piece_bitboards[pt + 8]);
            if (piece_bb != 0) {
                blockers &= ~(types.SquareIndexBB[@as(usize, @intCast(types.lsb(piece_bb)))]);
                opp = opp.invert();
                continue :outer;
            }
        }

        max_depth = depth;
        break;
    }

    if (max_depth == 0) max_depth = gains.len - 1;
    depth = max_depth - 1;
    while (depth >= 1) : (depth -= 1) {
        gains[depth - 1] = -@max(-gains[depth - 1], gains[depth]);
    }

    return gains[0];
}

// Logic https://github.com/TerjeKir/weiss
pub fn see_threshold(pos: *position.Position, move: types.Move, threshold: i32) bool {
    const from = move.from;
    const to = move.to;
    const attacker = pos.mailbox[from].piece_type().index();
    // Quiet moves (used by main-search SEE pruning) land on an empty square, so
    // there is no captured victim — value 0. Capture callers always have a piece
    // on `to`, so their behaviour is unchanged.
    const victim_piece = pos.mailbox[to];
    const victim_value: i32 = if (victim_piece == types.Piece.NO_PIECE) 0 else SeeWeight[victim_piece.piece_type().index()];
    var swap = victim_value - threshold;
    if (swap < 0) {
        return false;
    }
    swap -= SeeWeight[attacker];
    if (swap >= 0) {
        return true;
    }

    const white_pieces = pos.all_pieces(types.Color.White);
    const black_pieces = pos.all_pieces(types.Color.Black);
    const all = white_pieces | black_pieces;

    var occ = (all ^ types.SquareIndexBB[from]) | types.SquareIndexBB[to];
    var attackers = (pos.attackers_from(types.Color.White, @as(types.Square, @enumFromInt(to)), occ) | pos.attackers_from(types.Color.Black, @as(types.Square, @enumFromInt(to)), occ)) & occ;

    const bishops = pos.diagonal_sliders(types.Color.White) | pos.diagonal_sliders(types.Color.Black);
    const rooks = pos.orthogonal_sliders(types.Color.White) | pos.orthogonal_sliders(types.Color.Black);

    var stm = pos.mailbox[from].color().invert();

    while (true) {
        attackers &= occ;
        const my_attackers = attackers & (if (stm == types.Color.White) white_pieces else black_pieces);
        if (my_attackers == 0) {
            break;
        }

        var pt: usize = 0;
        while (pt <= 5) : (pt += 1) {
            if (my_attackers & (pos.piece_bitboards[pt] | pos.piece_bitboards[pt + 8]) != 0) {
                break;
            }
        }

        stm = stm.invert();

        swap = -swap - 1 - SeeWeight[pt];

        if (swap >= 0) {
            if (pt == 5) {
                if (attackers & (if (stm == types.Color.White) white_pieces else black_pieces) != 0) {
                    stm = stm.invert();
                }
            }
            break;
        }

        occ ^= types.SquareIndexBB[@as(usize, @intCast(types.lsb(my_attackers & (pos.piece_bitboards[pt] | pos.piece_bitboards[pt + 8]))))];

        // Independent ifs (not else-if): a captured queen (pt == 4) must reveal
        // BOTH diagonal and orthogonal x-ray attackers, matching the Weiss source.
        if (pt == 0 or pt == 2 or pt == 4) {
            attackers |= tables.get_bishop_attacks(@as(types.Square, @enumFromInt(to)), occ) & bishops;
        }
        if (pt == 3 or pt == 4) {
            attackers |= tables.get_rook_attacks(@as(types.Square, @enumFromInt(to)), occ) & rooks;
        }
    }

    return stm != pos.mailbox[from].color();
}
