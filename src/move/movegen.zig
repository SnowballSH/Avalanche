const std = @import("std");
const Position = @import("../board/position.zig");
const Patterns = @import("../board/patterns.zig");
const Piece = @import("../board/piece.zig");
const BB = @import("../board/bitboard.zig");
const Encode = @import("./encode.zig");
const C = @import("../c.zig");

pub fn generate_all_pseudo_legal_moves(board: Position.Position) std.ArrayList(u24) {
    var list = std.ArrayList(u24).init(std.heap.page_allocator);

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

                var attacks = Patterns.PawnCapturePatterns[0][sq] & opp_bb;
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    if (to_bb & my_last_rank != 0) {
                        // Promotion
                        var pp: u4 = promo_start;
                        while (pp >= promo_end) {
                            list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), pp, 1, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), 0, 1, 0, 0, 0)) catch {};
                    }
                    attacks ^= to_bb;
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
                            list.append(Encode.move(@intCast(u6, sq), @intCast(u6, single_target), @enumToInt(piece), pp, 0, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(@intCast(u6, sq), @intCast(u6, single_target), @enumToInt(piece), 0, 0, 0, 0, 0)) catch {};

                        // double pushes
                        const double_target = @intCast(u6, @as(i12, single_target) + pawn_delta);
                        const double_target_bb = @as(u64, 1) << double_target;

                        if (sq_bb & my_second_rank != 0 and double_target_bb & bb_all == 0) {
                            list.append(Encode.move(@intCast(u6, sq), @intCast(u6, double_target), @enumToInt(piece), 0, 0, 1, 0, 0)) catch {};
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

                var attacks = Patterns.PawnCapturePatterns[1][sq] & opp_bb;
                while (attacks != 0) {
                    const to = @intCast(u6, @ctz(u64, attacks));
                    const to_bb = @as(u64, 1) << to;
                    if (to_bb & my_last_rank != 0) {
                        // Promotion
                        var pp: u4 = promo_start;
                        while (pp >= promo_end) {
                            list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), pp, 1, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), 0, 1, 0, 0, 0)) catch {};
                    }
                    attacks ^= to_bb;
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
                            list.append(Encode.move(@intCast(u6, sq), @intCast(u6, single_target), @enumToInt(piece), pp, 0, 0, 0, 0)) catch {};
                            pp -= 1;
                        }
                    } else {
                        list.append(Encode.move(@intCast(u6, sq), @intCast(u6, single_target), @enumToInt(piece), 0, 0, 0, 0, 0)) catch {};

                        // double pushes
                        const double_target = @intCast(u6, @as(i12, single_target) + pawn_delta);
                        const double_target_bb = @as(u64, 1) << double_target;

                        if (sq_bb & my_second_rank != 0 and double_target_bb & bb_all == 0) {
                            list.append(Encode.move(@intCast(u6, sq), @intCast(u6, double_target), @enumToInt(piece), 0, 0, 1, 0, 0)) catch {};
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
                    list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
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
                    list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
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
                    list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
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
                    list.append(Encode.move(@intCast(u6, sq), @intCast(u6, to), @enumToInt(piece), 0, capture, 0, 0, 0)) catch {};
                    attacks ^= to_bb;
                }
            },

            else => {},
        }
    }

    return list;
}
