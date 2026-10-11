const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");

pub const SeeWeight = [_]i32{ 93, 308, 346, 521, 994, 20000 };

fn pinned_pieces(pos: *position.Position, comptime color: types.Color, occ: types.Bitboard) types.Bitboard {
    const opp = if (color == types.Color.White) types.Color.Black else types.Color.White;
    const king_piece = types.Piece.new_comptime(color, types.PieceType.King);
    const king_bb = pos.piece_bitboards[king_piece.index()] & occ;
    if (king_bb == 0) return 0;

    const king_sq = @as(types.Square, @fromBackingInt(@intCast(types.lsb(king_bb))));
    const us = pos.all_pieces(color) & occ;
    const pieces = us | (pos.all_pieces(opp) & occ);
    var snipers = tables.PseudoLegalAttacks[types.PieceType.Rook.index()][king_sq.index()] & pos.orthogonal_sliders(opp);
    snipers |= tables.PseudoLegalAttacks[types.PieceType.Bishop.index()][king_sq.index()] & pos.diagonal_sliders(opp);
    snipers &= occ;

    var pinned: types.Bitboard = 0;
    while (snipers != 0) {
        const sniper = types.pop_lsb(&snipers);
        const between = tables.SquaresBetween[king_sq.index()][sniper.index()] & pieces;
        if (between & us != 0 and (between & (between - 1)) == 0) {
            pinned |= between;
        }
    }
    return pinned;
}

fn legal_attackers(pos: *position.Position, comptime color: types.Color, target: types.Square, occ: types.Bitboard, attackers: types.Bitboard) types.Bitboard {
    if (attackers == 0) return 0;

    var legal = attackers;
    var pinned = pinned_pieces(pos, color, occ) & attackers;
    if (pinned == 0) return legal;

    const king_piece = types.Piece.new_comptime(color, types.PieceType.King);
    const king_sq = @as(types.Square, @fromBackingInt(@intCast(types.lsb(pos.piece_bitboards[king_piece.index()] & occ))));
    const target_bb = types.SquareIndexBB[target.index()];
    while (pinned != 0) {
        const sq = types.pop_lsb(&pinned);
        if (tables.LineOf[king_sq.index()][sq.index()] & target_bb == 0) {
            legal &= ~types.SquareIndexBB[sq.index()];
        }
    }
    return legal;
}

pub fn see_threshold(pos: *position.Position, move: types.Move, threshold: i32) bool {
    if (move.is_castle()) {
        return threshold <= 0;
    }
    const from = move.from;
    const to = move.to;
    const attacker = pos.mailbox[from].piece_type().index();
    const is_ep = move.get_flags() == types.MoveFlags.EN_PASSANT;
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
        const cap_idx: usize = if (stm == types.Color.White) @as(usize, to) - 8 else @as(usize, to) + 8;
        occ ^= types.SquareIndexBB[cap_idx];
    }
    occ |= types.SquareIndexBB[to];
    var attackers = (pos.attackers_from(types.Color.White, @as(types.Square, @fromBackingInt(@intCast(to))), occ) | pos.attackers_from(types.Color.Black, @as(types.Square, @fromBackingInt(@intCast(to))), occ)) & occ;

    var stm = pos.mailbox[from].color().invert();
    if (attackers & (if (stm == types.Color.White) white_pieces else black_pieces) == 0) {
        return true;
    }

    const bishops = pos.diagonal_sliders(types.Color.White) | pos.diagonal_sliders(types.Color.Black);
    const rooks = pos.orthogonal_sliders(types.Color.White) | pos.orthogonal_sliders(types.Color.Black);

    while (true) {
        attackers &= occ;
        const pseudo_attackers = attackers & (if (stm == types.Color.White) white_pieces else black_pieces);
        const my_attackers = if (stm == types.Color.White)
            legal_attackers(pos, types.Color.White, @as(types.Square, @fromBackingInt(@intCast(to))), occ, pseudo_attackers)
        else
            legal_attackers(pos, types.Color.Black, @as(types.Square, @fromBackingInt(@intCast(to))), occ, pseudo_attackers);
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

        // Not else-if: a queen (pt == 4) leaving the exchange uncovers x-ray attackers on both kinds of line.
        if (pt == 0 or pt == 2 or pt == 4) {
            attackers |= tables.get_bishop_attacks(@as(types.Square, @fromBackingInt(@intCast(to))), occ) & bishops;
        }
        if (pt == 3 or pt == 4) {
            attackers |= tables.get_rook_attacks(@as(types.Square, @fromBackingInt(@intCast(to))), occ) & rooks;
        }
    }

    return stm != pos.mailbox[from].color();
}
