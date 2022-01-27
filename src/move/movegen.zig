const std = @import("std");
const Position = @import("../board/position.zig");
const Patterns = @import("../board/patterns.zig");
const Piece = @import("../board/piece.zig");
const BB = @import("../board/bitboard.zig");
const Encode = @import("./encode.zig");
const C = @import("../c.zig");

pub fn generate_all_pseudo_legal_moves(board: *Position.Position) std.ArrayList(u24) {
    var list = std.ArrayList(u24).init(std.heap.page_allocator);

    list.ensureTotalCapacity(32) catch {};

    const bb_all = board.bitboards.WhiteAll | board.bitboards.BlackAll;

    for (board.mailbox) |pt, sq_| {
        if (pt == null) {
            continue;
        }
        const sq = Position.fen_sq_to_sq(@intCast(u8, sq_));
        const piece = pt.?;
        switch (piece) {
            Piece.Piece.WhitePawn => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const pawn_delta: i12 = 8;
                const promo_start = @enumToInt(Piece.Piece.WhiteQueen);
                const promo_end = @enumToInt(Piece.Piece.WhiteKnight);
                const my_second_rank = C.SQ_C.RANK_2;
                const my_last_rank = C.SQ_C.RANK_8;
                const opp_bb = board.bitboards.BlackAll;
                const sq_bb = @as(u64, 1) << sq;
                const ep_bb = if (board.ep == null) 0 else @as(u64, 1) << board.ep.?;

                var attacks = Patterns.PawnCapturePatterns[0][sq] & opp_bb;
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    if (to_bb & my_last_rank != 0) {
                        // Promotion
                        var pp: u4 = promo_start;
                        while (pp >= promo_end) {
                            list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), pp, 1, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, 1, 0, 0, 0)) catch {};
                    }
                    attacks ^= to_bb;
                }

                if ((Patterns.PawnCapturePatterns[0][sq] & ep_bb) != 0) {
                    list.append(Encode.move(sq, @intCast(u6, board.ep.?), @enumToInt(piece), 0, 1, 0, 1, 0)) catch {};
                }

                // Normal moves
                const single_target = @intCast(u6, @as(i12, sq) + pawn_delta);
                const single_target_bb = @as(u64, 1) << single_target;
                // only continue if that square is free
                if (single_target_bb & bb_all == 0) {
                    if (single_target_bb & my_last_rank != 0) {
                        // Promotion
                        var pp: u4 = promo_start;
                        while (pp >= promo_end) {
                            list.append(Encode.move(sq, @intCast(u6, single_target), @enumToInt(piece), pp, 0, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(sq, @intCast(u6, single_target), @enumToInt(piece), 0, 0, 0, 0, 0)) catch {};

                        // double pushes
                        const double_target = @intCast(u6, @as(i12, single_target) + pawn_delta);
                        const double_target_bb = @as(u64, 1) << double_target;

                        if (sq_bb & my_second_rank != 0 and double_target_bb & bb_all == 0) {
                            list.append(Encode.move(sq, @intCast(u6, double_target), @enumToInt(piece), 0, 0, 1, 0, 0)) catch {};
                            board.*.ep = double_target;
                        }
                    }
                }
            },

            Piece.Piece.BlackPawn => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const pawn_delta: i12 = -8;
                const promo_start = @enumToInt(Piece.Piece.BlackQueen);
                const promo_end = @enumToInt(Piece.Piece.BlackKnight);
                const my_second_rank = C.SQ_C.RANK_7;
                const my_last_rank = C.SQ_C.RANK_1;
                const opp_bb = board.bitboards.WhiteAll;
                const sq_bb = @as(u64, 1) << sq;
                const ep_bb = if (board.ep == null) 0 else @as(u64, 1) << board.ep.?;

                var attacks = Patterns.PawnCapturePatterns[1][sq] & opp_bb;
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    if (to_bb & my_last_rank != 0) {
                        // Promotion
                        var pp: u4 = promo_start;
                        while (pp >= promo_end) {
                            list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), pp, 1, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, 1, 0, 0, 0)) catch {};
                    }
                    attacks ^= to_bb;
                }

                if ((Patterns.PawnCapturePatterns[1][sq] & ep_bb) != 0) {
                    list.append(Encode.move(sq, @intCast(u6, board.ep.?), @enumToInt(piece), 0, 1, 0, 1, 0)) catch {};
                }

                // Normal moves
                const single_target = @intCast(u6, @as(i12, sq) + pawn_delta);
                const single_target_bb = @as(u64, 1) << single_target;
                // only continue if that square is free
                if (single_target_bb & bb_all == 0) {
                    if (single_target_bb & my_last_rank != 0) {
                        // Promotion
                        var pp: u4 = promo_start;
                        while (pp >= promo_end) {
                            list.append(Encode.move(sq, @intCast(u6, single_target), @enumToInt(piece), pp, 0, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(sq, @intCast(u6, single_target), @enumToInt(piece), 0, 0, 0, 0, 0)) catch {};

                        // double pushes
                        const double_target = @intCast(u6, @as(i12, single_target) + pawn_delta);
                        const double_target_bb = @as(u64, 1) << double_target;

                        if (sq_bb & my_second_rank != 0 and double_target_bb & bb_all == 0) {
                            list.append(Encode.move(sq, @intCast(u6, double_target), @enumToInt(piece), 0, 0, 1, 0, 0)) catch {};
                        }
                    }
                }
            },

            Piece.Piece.WhiteKnight => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.WhiteAll;
                const opp_bb = board.bitboards.BlackAll;

                var attacks = Patterns.KnightPatterns[sq] & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            Piece.Piece.BlackKnight => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.BlackAll;
                const opp_bb = board.bitboards.WhiteAll;

                var attacks = Patterns.KnightPatterns[sq] & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            Piece.Piece.WhiteKing => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.WhiteAll;
                const opp_bb = board.bitboards.BlackAll;

                var attacks = Patterns.KingPatterns[sq] & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }

                if (board.castling & Piece.WhiteKingCastle != 0) {
                    if (BB.get_at(bb_all, C.SQ_C.F1) == 0 and BB.get_at(bb_all, C.SQ_C.G1) == 0) {
                        if (!board.is_square_attacked_by(C.SQ_C.E1, Piece.Color.Black) and !board.is_square_attacked_by(C.SQ_C.F1, Piece.Color.Black)) {
                            list.append(Encode.move(sq, C.SQ_C.G1, @enumToInt(piece), 0, 0, 0, 0, 1)) catch {};
                        }
                    }
                }
                if (board.castling & Piece.WhiteQueenCastle != 0) {
                    if (BB.get_at(bb_all, C.SQ_C.D1) == 0 and BB.get_at(bb_all, C.SQ_C.C1) == 0 and BB.get_at(bb_all, C.SQ_C.B1) == 0) {
                        if (!board.is_square_attacked_by(C.SQ_C.E1, Piece.Color.Black) and !board.is_square_attacked_by(C.SQ_C.D1, Piece.Color.Black)) {
                            list.append(Encode.move(sq, C.SQ_C.C1, @enumToInt(piece), 0, 0, 0, 0, 1)) catch {};
                        }
                    }
                }

                if (board.castling & Piece.WhiteQueenCastle != 0) {}
            },

            Piece.Piece.BlackKing => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.BlackAll;
                const opp_bb = board.bitboards.WhiteAll;

                var attacks = Patterns.KingPatterns[sq] & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }

                if (board.castling & Piece.BlackKingCastle != 0) {
                    if (BB.get_at(bb_all, C.SQ_C.F8) == 0 and BB.get_at(bb_all, C.SQ_C.G8) == 0) {
                        if (!board.is_square_attacked_by(C.SQ_C.E8, Piece.Color.White) and !board.is_square_attacked_by(C.SQ_C.F8, Piece.Color.White)) {
                            list.append(Encode.move(sq, C.SQ_C.G8, @enumToInt(piece), 0, 0, 0, 0, 1)) catch {};
                        }
                    }
                }
                if (board.castling & Piece.BlackQueenCastle != 0) {
                    if (BB.get_at(bb_all, C.SQ_C.D8) == 0 and BB.get_at(bb_all, C.SQ_C.C8) == 0 and BB.get_at(bb_all, C.SQ_C.B8) == 0) {
                        if (!board.is_square_attacked_by(C.SQ_C.E8, Piece.Color.White) and !board.is_square_attacked_by(C.SQ_C.D8, Piece.Color.White)) {
                            list.append(Encode.move(sq, C.SQ_C.C8, @enumToInt(piece), 0, 0, 0, 0, 1)) catch {};
                        }
                    }
                }
            },

            Piece.Piece.WhiteBishop => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.WhiteAll;
                const opp_bb = board.bitboards.BlackAll;

                var attacks = Patterns.get_bishop_attacks(sq, bb_all) & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            Piece.Piece.BlackBishop => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.BlackAll;
                const opp_bb = board.bitboards.WhiteAll;

                var attacks = Patterns.get_bishop_attacks(sq, bb_all) & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            Piece.Piece.WhiteRook => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.WhiteAll;
                const opp_bb = board.bitboards.BlackAll;

                var attacks = Patterns.get_rook_attacks(sq, bb_all) & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            Piece.Piece.BlackRook => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.BlackAll;
                const opp_bb = board.bitboards.WhiteAll;

                var attacks = Patterns.get_rook_attacks(sq, bb_all) & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            Piece.Piece.WhiteQueen => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.WhiteAll;
                const opp_bb = board.bitboards.BlackAll;

                var attacks = Patterns.get_queen_attacks(sq, bb_all) & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            Piece.Piece.BlackQueen => {
                if (piece.color() != board.turn) {
                    continue;
                }
                const my_bb = board.bitboards.BlackAll;
                const opp_bb = board.bitboards.WhiteAll;

                var attacks = Patterns.get_queen_attacks(sq, bb_all) & (~my_bb);
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    const capture: u1 = @bitCast(u1, to_bb & opp_bb != 0);
                    list.append(Encode.move(sq, @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },
        }
    }

    return list;
}
