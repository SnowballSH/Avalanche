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
fn pinnedPieces(pos: *position.Position, comptime color: types.Color, occ: types.Bitboard) types.Bitboard {
    const opp = if (color == types.Color.White) types.Color.Black else types.Color.White;
    const king_piece = types.Piece.new_comptime(color, types.PieceType.King);
    const king_bb = pos.piece_bitboards[king_piece.index()] & occ;
    if (king_bb == 0) return 0;

    const king_sq = @as(types.Square, @enumFromInt(types.lsb(king_bb)));
    const us = pos.all_pieces(color) & occ;
    const them = pos.all_pieces(opp) & occ;
    var candidates = tables.get_rook_attacks(king_sq, them) & pos.orthogonal_sliders(opp) & occ;
    candidates |= tables.get_bishop_attacks(king_sq, them) & pos.diagonal_sliders(opp) & occ;

    var pinned: types.Bitboard = 0;
    while (candidates != 0) {
        const pinner = types.pop_lsb(&candidates);
        const between = tables.SquaresBetween[king_sq.index()][pinner.index()] & us;
        if (between != 0 and (between & (between - 1)) == 0) {
            pinned |= between;
        }
    }
    return pinned;
}

fn legalAttackers(pos: *position.Position, comptime color: types.Color, target: types.Square, occ: types.Bitboard, attackers: types.Bitboard) types.Bitboard {
    var legal = attackers;
    var pinned = pinnedPieces(pos, color, occ) & attackers;
    if (pinned == 0) return legal;

    const king_piece = types.Piece.new_comptime(color, types.PieceType.King);
    const king_sq = @as(types.Square, @enumFromInt(types.lsb(pos.piece_bitboards[king_piece.index()] & occ)));
    const target_bb = types.SquareIndexBB[target.index()];
    while (pinned != 0) {
        const sq = types.pop_lsb(&pinned);
        // A pinned piece may only recapture along its king-pinner line.
        if (tables.LineOf[king_sq.index()][sq.index()] & target_bb == 0) {
            legal &= ~types.SquareIndexBB[sq.index()];
        }
    }
    return legal;
}

pub fn see_threshold(pos: *position.Position, move: types.Move, threshold: i32) bool {
    const from = move.from;
    const to = move.to;
    const attacker = pos.mailbox[from].piece_type().index();
    const is_ep = move.get_flags() == types.MoveFlags.EN_PASSANT;
    // Quiet moves land on an empty square (victim 0). En passant captures a pawn
    // that is not on `to`. Ordinary captures take the piece on `to`.
    const victim_value: i32 = if (is_ep)
        SeeWeight[types.PieceType.Pawn.index()]
    else blk: {
        const victim_piece = pos.mailbox[to];
        break :blk if (victim_piece == types.Piece.NO_PIECE) 0 else SeeWeight[victim_piece.piece_type().index()];
    };
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

    var occ = all ^ types.SquareIndexBB[from];
    if (is_ep) {
        const stm = pos.mailbox[from].color();
        // Captured pawn sits one square behind the EP target from the capturer's perspective.
        const cap_idx: usize = if (stm == types.Color.White) @as(usize, to) - 8 else @as(usize, to) + 8;
        occ ^= types.SquareIndexBB[cap_idx];
    }
    occ |= types.SquareIndexBB[to];
    var attackers = (pos.attackers_from(types.Color.White, @as(types.Square, @enumFromInt(to)), occ) | pos.attackers_from(types.Color.Black, @as(types.Square, @enumFromInt(to)), occ)) & occ;

    const bishops = pos.diagonal_sliders(types.Color.White) | pos.diagonal_sliders(types.Color.Black);
    const rooks = pos.orthogonal_sliders(types.Color.White) | pos.orthogonal_sliders(types.Color.Black);

    var stm = pos.mailbox[from].color().invert();

    while (true) {
        attackers &= occ;
        const pseudo_attackers = attackers & (if (stm == types.Color.White) white_pieces else black_pieces);
        const my_attackers = if (stm == types.Color.White)
            legalAttackers(pos, types.Color.White, @as(types.Square, @enumFromInt(to)), occ, pseudo_attackers)
        else
            legalAttackers(pos, types.Color.Black, @as(types.Square, @enumFromInt(to)), occ, pseudo_attackers);
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
