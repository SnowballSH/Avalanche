const std = @import("std");

const BB = @import("./bitboard.zig");
const Piece = @import("./piece.zig");
const Uci = @import("../uci/uci.zig");
const Patterns = @import("./patterns.zig");
const Encode = @import("../move/encode.zig");
const C = @import("../c.zig");
const Zobrist = @import("./zobrist.zig");
const HCE = @import("../evaluation/hce.zig");
const NNUE = @import("../evaluation/nnue.zig");

pub const STARTPOS = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

pub const Position = struct {
    bitboards: BB.Bitboards,
    mailbox: [64]?Piece.Piece,
    turn: Piece.Color,
    ep: ?u6,
    castling: u4,
    capture_stack: std.ArrayList(Piece.Piece),
    castle_stack: std.ArrayList(u4),
    ep_stack: std.ArrayList(?u6),
    hash_stack: std.ArrayList(u64),
    hash: u64,

    pub fn deinit(self: *Position) void {
        self.capture_stack.deinit();
        self.ep_stack.deinit();
        self.castle_stack.deinit();
        self.hash_stack.deinit();
    }

    pub fn display(self: *Position) void {
        for (self.mailbox) |x, i| {
            std.debug.print("{c}", .{if (x != null) Uci.pieces[@enumToInt(x.?)] else '.'});
            if (i % 8 == 7) {
                std.debug.print("\n", .{});
            } else {
                std.debug.print(" ", .{});
            }
        }
        if (self.turn == Piece.Color.White) {
            std.debug.print("White to move\n", .{});
        } else {
            std.debug.print("Black to move\n", .{});
        }

        std.debug.print("Castling: ", .{});
        if (self.castling & Piece.WhiteKingCastle != 0) {
            std.debug.print("K", .{});
        }
        if (self.castling & Piece.WhiteQueenCastle != 0) {
            std.debug.print("Q", .{});
        }
        if (self.castling & Piece.BlackKingCastle != 0) {
            std.debug.print("k", .{});
        }
        if (self.castling & Piece.BlackQueenCastle != 0) {
            std.debug.print("q", .{});
        }
        std.debug.print("\n", .{});

        if (self.ep != null) {
            std.debug.print("En Passant: {c}{c}\n", .{ Uci.alphabets[BB.file_of(self.ep.?)], Uci.numbers[BB.rank_of(self.ep.?)] });
        } else {
            std.debug.print("En Passant: no\n", .{});
        }

        std.debug.print("\n", .{});
    }

    pub fn is_square_attacked_by(self: *Position, square: u6, color: Piece.Color) bool {
        const bb_all = self.bitboards.WhiteAll | self.bitboards.BlackAll;
        // zig fmt: off
        if (color == Piece.Color.White) {
            return (
            Patterns.PawnCapturePatterns[1][square] & self.bitboards.WhitePawns != 0
                or Patterns.KnightPatterns[square] & self.bitboards.WhiteKnights != 0
                or Patterns.KingPatterns[square] & self.bitboards.WhiteKing != 0
                or Patterns.get_bishop_attacks(square, bb_all) & (self.bitboards.WhiteBishops | self.bitboards.WhiteQueens) != 0
                or Patterns.get_rook_attacks(square, bb_all) & (self.bitboards.WhiteRooks | self.bitboards.WhiteQueens) != 0
            );
        }
        return (
        Patterns.PawnCapturePatterns[0][square] & self.bitboards.BlackPawns != 0
            or Patterns.KnightPatterns[square] & self.bitboards.BlackKnights != 0
            or Patterns.KingPatterns[square] & self.bitboards.BlackKing != 0
            or Patterns.get_bishop_attacks(square, bb_all) & (self.bitboards.BlackBishops | self.bitboards.BlackQueens) != 0
            or Patterns.get_rook_attacks(square, bb_all) & (self.bitboards.BlackRooks | self.bitboards.BlackQueens) != 0
        );
        // zig fmt: on
    }

    pub fn square_attacked_bb(self: *Position, square: u6, color: Piece.Color) u64 {
        const bb_all = self.bitboards.WhiteAll | self.bitboards.BlackAll;
        // zig fmt: off
        if (color == Piece.Color.White) {
            return (
                (Patterns.PawnCapturePatterns[1][square] & self.bitboards.WhitePawns)
                | (Patterns.KnightPatterns[square] & self.bitboards.WhiteKnights)
                | (Patterns.KingPatterns[square] & self.bitboards.WhiteKing)
                | (Patterns.get_bishop_attacks(square, bb_all) & (self.bitboards.WhiteBishops | self.bitboards.WhiteQueens))
                | (Patterns.get_rook_attacks(square, bb_all) & (self.bitboards.WhiteRooks | self.bitboards.WhiteQueens))
            );
        }
        return (
            (Patterns.PawnCapturePatterns[0][square] & self.bitboards.BlackPawns)
            | (Patterns.KnightPatterns[square] & self.bitboards.BlackKnights)
            | (Patterns.KingPatterns[square] & self.bitboards.BlackKing)
            | (Patterns.get_bishop_attacks(square, bb_all) & (self.bitboards.BlackBishops | self.bitboards.BlackQueens))
            | (Patterns.get_rook_attacks(square, bb_all) & (self.bitboards.BlackRooks | self.bitboards.BlackQueens))
        );
        // zig fmt: on
    }

    pub fn square_attackers(self: *Position, square: u6, color: Piece.Color) u8 {
        var res: u8 = 0;

        const occupancy_all = self.bitboards.WhiteAll | self.bitboards.BlackAll;

        const bishops_rooks = if (color == Piece.Color.White)
            (self.bitboards.BlackBishops | self.bitboards.BlackRooks)
        else
            (self.bitboards.WhiteBishops | self.bitboards.WhiteRooks);
        const rooks_queens = if (color == Piece.Color.White)
            (self.bitboards.BlackQueens | self.bitboards.BlackRooks)
        else
            (self.bitboards.WhiteQueens | self.bitboards.WhiteRooks);
        const bishops_queens = if (color == Piece.Color.White)
            (self.bitboards.BlackQueens | self.bitboards.BlackBishops)
        else
            (self.bitboards.WhiteQueens | self.bitboards.WhiteBishops);

        const king_attacks = Patterns.KingPatterns[square];
        if (color == Piece.Color.White) {
            if (king_attacks & self.bitboards.BlackKing != 0) {
                res |= 1 << 7;
            }
        } else {
            if (king_attacks & self.bitboards.WhiteKing != 0) {
                res |= 1 << 7;
            }
        }

        const queen_attacks = Patterns.get_queen_attacks(square, occupancy_all & ~bishops_rooks);
        if (color == Piece.Color.White) {
            if (queen_attacks & self.bitboards.BlackQueens != 0) {
                res |= 1 << 6;
            }
        } else {
            if (queen_attacks & self.bitboards.WhiteQueens != 0) {
                res |= 1 << 6;
            }
        }

        const rook_attacks = Patterns.get_rook_attacks(square, occupancy_all & ~rooks_queens);
        if (color == Piece.Color.White) {
            if (rook_attacks & self.bitboards.BlackRooks != 0) {
                if (@popCount(u64, rook_attacks & self.bitboards.BlackRooks) == 1) {
                    res |= 1 << 4;
                } else {
                    res |= 3 << 4;
                }
            }
        } else {
            if (rook_attacks & self.bitboards.WhiteRooks != 0) {
                if (@popCount(u64, rook_attacks & self.bitboards.WhiteRooks) == 1) {
                    res |= 1 << 4;
                } else {
                    res |= 3 << 4;
                }
            }
        }

        var knight_bishop_count: u8 = 0;

        const knight_attacks = Patterns.KnightPatterns[square];
        if (color == Piece.Color.White) {
            if (knight_attacks & self.bitboards.BlackKnights != 0) {
                knight_bishop_count += @popCount(u64, knight_attacks & self.bitboards.BlackKnights);
            }
        } else {
            if (knight_attacks & self.bitboards.WhiteKnights != 0) {
                knight_bishop_count += @popCount(u64, knight_attacks & self.bitboards.WhiteKnights);
            }
        }

        const bishop_attacks = Patterns.get_bishop_attacks(square, occupancy_all & ~bishops_queens);
        if (color == Piece.Color.White) {
            if (bishop_attacks & self.bitboards.BlackBishops != 0) {
                knight_bishop_count += @popCount(u64, bishop_attacks & self.bitboards.BlackBishops);
            }
        } else {
            if (bishop_attacks & self.bitboards.WhiteBishops != 0) {
                knight_bishop_count += @popCount(u64, bishop_attacks & self.bitboards.WhiteBishops);
            }
        }

        if (knight_bishop_count != 0) {
            if (knight_bishop_count == 1) {
                res |= 1 << 1;
            } else if (knight_bishop_count == 2) {
                res |= 3 << 1;
            } else {
                res |= 7 << 1;
            }
        }

        const sq_bb = BB.ShiftLocations[square];
        const potential_enemy_pawns = if (color == Piece.Color.White)
            (self.bitboards.BlackPawns & king_attacks)
        else
            (self.bitboards.WhitePawns & king_attacks);

        const attacking_enemy_pawns = if (color == Piece.Color.White)
            (((potential_enemy_pawns >> 7) | (potential_enemy_pawns >> 9)) & sq_bb)
        else
            (((potential_enemy_pawns << 7) | (potential_enemy_pawns << 9)) & sq_bb);

        if (attacking_enemy_pawns != 0) {
            res |= 1;
        }

        return res;
    }

    pub fn add_piece(self: *Position, target: u6, piece: Piece.Piece, comptime modhash: bool) void {
        const st: u64 = BB.ShiftLocations[target];
        self.bitboards.get_bb_for(piece).* |= st;
        self.bitboards.get_occupancy_for(piece.color()).* |= st;

        if (modhash) {
            self.hash ^= Zobrist.ZobristKeys[@enumToInt(piece)][target];
        }

        self.mailbox[fen_sq_to_sq(target)] = piece;
    }

    pub fn remove_piece(self: *Position, target: u6, piece: Piece.Piece, comptime modhash: bool) void {
        const st: u64 = BB.ShiftLocations[target];
        self.bitboards.get_bb_for(piece).* &= ~st;
        self.bitboards.get_occupancy_for(piece.color()).* &= ~st;

        if (modhash) {
            self.hash ^= Zobrist.ZobristKeys[@enumToInt(piece)][target];
        }

        self.mailbox[fen_sq_to_sq(target)] = null;
    }

    pub fn move_piece(self: *Position, source: u6, target: u6, piece: Piece.Piece, comptime modhash: bool) void {
        const st: u64 = BB.ShiftLocations[source] | BB.ShiftLocations[target];
        self.bitboards.get_bb_for(piece).* ^= st;
        self.bitboards.get_occupancy_for(piece.color()).* ^= st;

        if (modhash) {
            self.hash ^= Zobrist.ZobristKeys[@enumToInt(piece)][source];
            self.hash ^= Zobrist.ZobristKeys[@enumToInt(piece)][target];
        }

        self.mailbox[fen_sq_to_sq(target)] = piece;
        self.mailbox[fen_sq_to_sq(source)] = null;
    }

    pub fn make_move(self: *Position, move: u24, nnue: ?*NNUE.NNUE) void {
        var source = Encode.source(move);
        var target = Encode.target(move);
        var piece = @intToEnum(Piece.Piece, Encode.pt(move));

        if (self.ep != null) {
            std.debug.assert(BB.rank_of(self.ep.?) == 2 or BB.rank_of(self.ep.?) == 5);
        }

        self.ep_stack.append(self.ep) catch {};
        self.castle_stack.append(self.castling) catch {};
        self.hash_stack.append(self.hash) catch {};

        if (self.ep != null) {
            self.hash ^= Zobrist.ZobristEpKeys[BB.file_of(self.ep.?)];
            self.ep = null;
        }

        if (piece == Piece.Piece.WhiteRook) {
            if (source == C.SQ_C.A1) {
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                self.castling &= ~Piece.WhiteQueenCastle;
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
            } else if (source == C.SQ_C.H1) {
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                self.castling &= ~Piece.WhiteKingCastle;
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
            }
        } else if (piece == Piece.Piece.BlackRook) {
            if (source == C.SQ_C.A8) {
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                self.castling &= ~Piece.BlackQueenCastle;
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
            } else if (source == C.SQ_C.H8) {
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                self.castling &= ~Piece.BlackKingCastle;
                self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
            }
        }

        if (piece == Piece.Piece.WhiteKing) {
            self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
            self.castling &= ~(Piece.WhiteKingCastle | Piece.WhiteQueenCastle);
            self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
        } else if (piece == Piece.Piece.BlackKing) {
            self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
            self.castling &= ~(Piece.BlackKingCastle | Piece.BlackQueenCastle);
            self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
        }

        if (Encode.capture(move) != 0) {
            if (Encode.enpassant(move) != 0) {
                if (self.turn == Piece.Color.White) {
                    var captured = self.mailbox[fen_sq_to_sq(target - 8)].?;
                    self.capture_stack.append(captured) catch {};
                    self.remove_piece(target - 8, captured, true);
                    if (nnue != null) {
                        nnue.?.deactivate(captured, target - 8);
                    }
                } else {
                    var captured = self.mailbox[fen_sq_to_sq(target + 8)].?;
                    self.capture_stack.append(captured) catch {};
                    self.remove_piece(target + 8, captured, true);
                    if (nnue != null) {
                        nnue.?.deactivate(captured, target + 8);
                    }
                }
            } else {
                var captured = self.mailbox[fen_sq_to_sq(target)].?;
                self.capture_stack.append(captured) catch {};
                self.remove_piece(target, captured, true);
                if (nnue != null) {
                    nnue.?.deactivate(captured, target);
                }
                if (captured == Piece.Piece.WhiteRook) {
                    if (target == C.SQ_C.A1) {
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                        self.castling &= ~Piece.WhiteQueenCastle;
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                    } else if (target == C.SQ_C.H1) {
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                        self.castling &= ~Piece.WhiteKingCastle;
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                    }
                } else if (captured == Piece.Piece.BlackRook) {
                    if (target == C.SQ_C.A8) {
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                        self.castling &= ~Piece.BlackQueenCastle;
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                    } else if (target == C.SQ_C.H8) {
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                        self.castling &= ~Piece.BlackKingCastle;
                        self.hash ^= Zobrist.ZobristCastleKeys[self.castling];
                    }
                }
            }
            self.move_piece(source, target, piece, true);
            if (nnue != null) {
                nnue.?.activate(piece, target);
                nnue.?.deactivate(piece, source);
            }
        } else if (Encode.double(move) != 0) {
            self.move_piece(source, target, piece, true);
            if (nnue != null) {
                nnue.?.activate(piece, target);
                nnue.?.deactivate(piece, source);
            }
            if (self.turn == Piece.Color.White) {
                self.ep = target - 8;
                std.debug.assert(BB.rank_of(self.ep.?) == 2 or BB.rank_of(self.ep.?) == 5);
                self.hash ^= Zobrist.ZobristEpKeys[BB.file_of(self.ep.?)];
            } else {
                self.ep = target + 8;
                std.debug.assert(BB.rank_of(self.ep.?) == 2 or BB.rank_of(self.ep.?) == 5);
                self.hash ^= Zobrist.ZobristEpKeys[BB.file_of(self.ep.?)];
            }
        } else if (Encode.castling(move) != 0) {
            switch (target) {
                C.SQ_C.G1 => {
                    self.move_piece(C.SQ_C.H1, C.SQ_C.F1, Piece.Piece.WhiteRook, true);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.WhiteRook, C.SQ_C.F1);
                        nnue.?.deactivate(Piece.Piece.WhiteRook, C.SQ_C.H1);
                    }
                    self.move_piece(source, target, piece, true);
                    if (nnue != null) {
                        nnue.?.activate(piece, target);
                        nnue.?.deactivate(piece, source);
                    }
                },
                C.SQ_C.C1 => {
                    self.move_piece(C.SQ_C.A1, C.SQ_C.D1, Piece.Piece.WhiteRook, true);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.WhiteRook, C.SQ_C.D1);
                        nnue.?.deactivate(Piece.Piece.WhiteRook, C.SQ_C.A1);
                    }
                    self.move_piece(source, target, piece, true);
                    if (nnue != null) {
                        nnue.?.activate(piece, target);
                        nnue.?.deactivate(piece, source);
                    }
                },
                C.SQ_C.G8 => {
                    self.move_piece(C.SQ_C.H8, C.SQ_C.F8, Piece.Piece.BlackRook, true);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.BlackRook, C.SQ_C.F8);
                        nnue.?.deactivate(Piece.Piece.BlackRook, C.SQ_C.H8);
                    }
                    self.move_piece(source, target, piece, true);
                    if (nnue != null) {
                        nnue.?.activate(piece, target);
                        nnue.?.deactivate(piece, source);
                    }
                },
                C.SQ_C.C8 => {
                    self.move_piece(C.SQ_C.A8, C.SQ_C.D8, Piece.Piece.BlackRook, true);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.BlackRook, C.SQ_C.D8);
                        nnue.?.deactivate(Piece.Piece.BlackRook, C.SQ_C.A8);
                    }
                    self.move_piece(source, target, piece, true);
                    if (nnue != null) {
                        nnue.?.activate(piece, target);
                        nnue.?.deactivate(piece, source);
                    }
                },
                else => unreachable,
            }
        } else {
            self.move_piece(source, target, piece, true);
            if (nnue != null) {
                nnue.?.activate(piece, target);
                nnue.?.deactivate(piece, source);
            }
        }

        var promo = Encode.promote(move);
        if (promo != 0) {
            self.remove_piece(target, piece, true);
            if (nnue != null) {
                nnue.?.deactivate(piece, target);
            }
            self.add_piece(target, @intToEnum(Piece.Piece, promo), true);
            if (nnue != null) {
                nnue.?.activate(@intToEnum(Piece.Piece, promo), target);
            }
        }

        self.hash ^= Zobrist.ZobristTurn;
        self.turn = self.turn.invert();
    }

    pub fn undo_move(self: *Position, move: u24, nnue: ?*NNUE.NNUE) void {
        const my_color = self.turn.invert();
        const opp_color = self.turn;

        var source = Encode.source(move);
        var target = Encode.target(move);
        var piece = @intToEnum(Piece.Piece, Encode.pt(move));

        self.hash = self.hash_stack.pop();
        self.ep = self.ep_stack.pop();
        self.castling = self.castle_stack.pop();

        var promo = Encode.promote(move);
        if (promo != 0) {
            self.remove_piece(target, @intToEnum(Piece.Piece, promo), false);
            if (nnue != null) {
                nnue.?.deactivate(@intToEnum(Piece.Piece, promo), target);
            }
            self.add_piece(target, piece, false);
            if (nnue != null) {
                nnue.?.activate(piece, target);
            }
        }

        if (Encode.capture(move) != 0) {
            var captured = self.capture_stack.pop();

            self.move_piece(target, source, piece, false);
            if (nnue != null) {
                nnue.?.activate(piece, source);
                nnue.?.deactivate(piece, target);
            }

            if (Encode.enpassant(move) != 0) {
                if (opp_color == Piece.Color.White) {
                    self.add_piece(target + 8, captured, false);
                    if (nnue != null) {
                        nnue.?.activate(captured, target + 8);
                    }
                } else {
                    self.add_piece(target - 8, captured, false);
                    if (nnue != null) {
                        nnue.?.activate(captured, target - 8);
                    }
                }
            } else {
                self.add_piece(target, captured, false);
                if (nnue != null) {
                    nnue.?.activate(captured, target);
                }
            }
        } else if (Encode.double(move) != 0) {
            self.move_piece(target, source, piece, false);
            if (nnue != null) {
                nnue.?.activate(piece, source);
                nnue.?.deactivate(piece, target);
            }
        } else if (Encode.castling(move) != 0) {
            switch (target) {
                C.SQ_C.G1 => {
                    self.move_piece(C.SQ_C.F1, C.SQ_C.H1, Piece.Piece.WhiteRook, false);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.WhiteRook, C.SQ_C.H1);
                        nnue.?.deactivate(Piece.Piece.WhiteRook, C.SQ_C.F1);
                    }
                    self.move_piece(target, source, piece, false);
                    if (nnue != null) {
                        nnue.?.activate(piece, source);
                        nnue.?.deactivate(piece, target);
                    }
                },
                C.SQ_C.C1 => {
                    self.move_piece(C.SQ_C.D1, C.SQ_C.A1, Piece.Piece.WhiteRook, false);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.WhiteRook, C.SQ_C.A1);
                        nnue.?.deactivate(Piece.Piece.WhiteRook, C.SQ_C.D1);
                    }
                    self.move_piece(target, source, piece, false);
                    if (nnue != null) {
                        nnue.?.activate(piece, source);
                        nnue.?.deactivate(piece, target);
                    }
                },
                C.SQ_C.G8 => {
                    self.move_piece(C.SQ_C.F8, C.SQ_C.H8, Piece.Piece.BlackRook, false);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.BlackRook, C.SQ_C.H8);
                        nnue.?.deactivate(Piece.Piece.BlackRook, C.SQ_C.F8);
                    }
                    self.move_piece(target, source, piece, false);
                    if (nnue != null) {
                        nnue.?.activate(piece, source);
                        nnue.?.deactivate(piece, target);
                    }
                },
                C.SQ_C.C8 => {
                    self.move_piece(C.SQ_C.D8, C.SQ_C.A8, Piece.Piece.BlackRook, false);
                    if (nnue != null) {
                        nnue.?.activate(Piece.Piece.BlackRook, C.SQ_C.A8);
                        nnue.?.deactivate(Piece.Piece.BlackRook, C.SQ_C.D8);
                    }
                    self.move_piece(target, source, piece, false);
                    if (nnue != null) {
                        nnue.?.activate(piece, source);
                        nnue.?.deactivate(piece, target);
                    }
                },
                else => unreachable,
            }
        } else {
            self.move_piece(target, source, piece, false);
            if (nnue != null) {
                nnue.?.activate(piece, source);
                nnue.?.deactivate(piece, target);
            }
        }

        self.turn = my_color;
    }

    pub fn make_null_move(self: *Position) void {
        self.ep_stack.append(self.ep) catch {};
        self.castle_stack.append(self.castling) catch {};
        self.hash_stack.append(self.hash) catch {};

        if (self.ep != null) {
            self.hash ^= Zobrist.ZobristEpKeys[BB.file_of(self.ep.?)];
            self.ep = null;
        }

        self.turn = self.turn.invert();
        self.hash ^= Zobrist.ZobristTurn;
    }

    pub fn undo_null_move(self: *Position) void {
        self.hash = self.hash_stack.pop();
        self.ep = self.ep_stack.pop();
        self.castling = self.castle_stack.pop();

        self.turn = self.turn.invert();
    }

    pub fn is_king_checked_for(self: *Position, color: Piece.Color) bool {
        if (color == Piece.Color.White) {
            if (self.bitboards.WhiteKing == 0) {
                return false;
            }
            return self.is_square_attacked_by(@intCast(u6, @ctz(u64, self.bitboards.WhiteKing)), Piece.Color.Black);
        } else {
            if (self.bitboards.BlackKing == 0) {
                return false;
            }
            return self.is_square_attacked_by(@intCast(u6, @ctz(u64, self.bitboards.BlackKing)), Piece.Color.White);
        }
    }

    pub fn calculate_hash(self: *Position) u64 {
        var hash: u64 = 0;

        for (self.mailbox) |piece, square| {
            if (piece != null) {
                hash ^= Zobrist.ZobristKeys[@enumToInt(piece.?)][fen_sq_to_sq(@intCast(u8, square))];
            }
        }

        if (self.ep != null) {
            hash ^= Zobrist.ZobristEpKeys[BB.file_of(self.ep.?)];
        }

        if (self.turn == Piece.Color.Black) {
            hash ^= Zobrist.ZobristTurn;
        }

        hash ^= Zobrist.ZobristCastleKeys[self.castling];

        return hash;
    }

    pub fn phase(self: *Position) usize {
        var phase_: usize = 0;
        phase_ += @popCount(u64, self.bitboards.WhiteKnights | self.bitboards.WhiteBishops);
        phase_ += @popCount(u64, self.bitboards.BlackKnights | self.bitboards.BlackBishops);
        phase_ += @popCount(u64, self.bitboards.WhiteRooks | self.bitboards.BlackRooks) * 2;
        phase_ += @popCount(u64, self.bitboards.WhiteQueens | self.bitboards.BlackQueens) * 4;
        return phase_;
    }
};

pub inline fn fen_sq_to_sq(fsq: u8) u6 {
    return @intCast(u6, fsq ^ 56);
}

pub fn new_position_by_fen(fen: anytype) Position {
    var position = Position{
        .bitboards = std.mem.zeroes(BB.Bitboards),
        .mailbox = std.mem.zeroes([64]?Piece.Piece),
        .turn = Piece.Color.White,
        .ep = null,
        .castling = 0b1111,
        .capture_stack = std.ArrayList(Piece.Piece).initCapacity(std.heap.page_allocator, 16) catch unreachable,
        .castle_stack = std.ArrayList(u4).initCapacity(std.heap.page_allocator, 16) catch unreachable,
        .ep_stack = std.ArrayList(?u6).initCapacity(std.heap.page_allocator, 16) catch unreachable,
        .hash_stack = std.ArrayList(u64).initCapacity(std.heap.page_allocator, 16) catch unreachable,
        .hash = 0,
    };

    var index: usize = 0;
    var sq: u8 = 0;

    while (fen[index] != ' ' and index < fen.len and sq < 64) {
        switch (fen[index]) {
            'P' => {
                position.mailbox[sq] = Piece.Piece.WhitePawn;
                position.bitboards.toggle_piece(Piece.Piece.WhitePawn, fen_sq_to_sq(sq));
                sq += 1;
            },
            'N' => {
                position.mailbox[sq] = Piece.Piece.WhiteKnight;
                position.bitboards.toggle_piece(Piece.Piece.WhiteKnight, fen_sq_to_sq(sq));
                sq += 1;
            },
            'B' => {
                position.mailbox[sq] = Piece.Piece.WhiteBishop;
                position.bitboards.toggle_piece(Piece.Piece.WhiteBishop, fen_sq_to_sq(sq));
                sq += 1;
            },
            'R' => {
                position.mailbox[sq] = Piece.Piece.WhiteRook;
                position.bitboards.toggle_piece(Piece.Piece.WhiteRook, fen_sq_to_sq(sq));
                sq += 1;
            },
            'Q' => {
                position.mailbox[sq] = Piece.Piece.WhiteQueen;
                position.bitboards.toggle_piece(Piece.Piece.WhiteQueen, fen_sq_to_sq(sq));
                sq += 1;
            },
            'K' => {
                position.mailbox[sq] = Piece.Piece.WhiteKing;
                position.bitboards.toggle_piece(Piece.Piece.WhiteKing, fen_sq_to_sq(sq));
                sq += 1;
            },
            'p' => {
                position.mailbox[sq] = Piece.Piece.BlackPawn;
                position.bitboards.toggle_piece(Piece.Piece.BlackPawn, fen_sq_to_sq(sq));
                sq += 1;
            },
            'n' => {
                position.mailbox[sq] = Piece.Piece.BlackKnight;
                position.bitboards.toggle_piece(Piece.Piece.BlackKnight, fen_sq_to_sq(sq));
                sq += 1;
            },
            'b' => {
                position.mailbox[sq] = Piece.Piece.BlackBishop;
                position.bitboards.toggle_piece(Piece.Piece.BlackBishop, fen_sq_to_sq(sq));
                sq += 1;
            },
            'r' => {
                position.mailbox[sq] = Piece.Piece.BlackRook;
                position.bitboards.toggle_piece(Piece.Piece.BlackRook, fen_sq_to_sq(sq));
                sq += 1;
            },
            'q' => {
                position.mailbox[sq] = Piece.Piece.BlackQueen;
                position.bitboards.toggle_piece(Piece.Piece.BlackQueen, fen_sq_to_sq(sq));
                sq += 1;
            },
            'k' => {
                position.mailbox[sq] = Piece.Piece.BlackKing;
                position.bitboards.toggle_piece(Piece.Piece.BlackKing, fen_sq_to_sq(sq));
                sq += 1;
            },
            '0'...'8' => {
                sq += @intCast(u6, fen[index] - '0');
            },
            '/' => {},
            else => {
                sq += 1;
            },
        }
        index += 1;
    }

    index += 1;
    if (index < fen.len) {
        if (fen[index] == 'w') {
            position.turn = Piece.Color.White;
        } else if (fen[index] == 'b') {
            position.turn = Piece.Color.Black;
        }
        index += 1;
    } else {
        position.hash = position.calculate_hash();
        return position;
    }

    index += 1;
    if (index < fen.len) {
        if (fen[index] == '-') {
            position.castling = 0;
            index += 1;
        } else {
            position.castling = 0;
            while (index < fen.len and fen[index] != ' ') {
                switch (fen[index]) {
                    'K' => {
                        position.castling |= Piece.WhiteKingCastle;
                    },
                    'Q' => {
                        position.castling |= Piece.WhiteQueenCastle;
                    },
                    'k' => {
                        position.castling |= Piece.BlackKingCastle;
                    },
                    'q' => {
                        position.castling |= Piece.BlackQueenCastle;
                    },
                    else => {},
                }
                index += 1;
            }
        }
    } else {
        position.hash = position.calculate_hash();
        return position;
    }

    index += 1;
    if (index < fen.len) {
        if (fen[index] == '-') {
            position.ep = null;
        }
        // TODO: parse ep
    } else {
        position.hash = position.calculate_hash();
        return position;
    }

    position.hash = position.calculate_hash();
    return position;
}
