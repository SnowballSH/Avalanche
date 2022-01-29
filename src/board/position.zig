const std = @import("std");

const BB = @import("./bitboard.zig");
const Piece = @import("./piece.zig");
const Uci = @import("../uci/uci.zig");
const Patterns = @import("./patterns.zig");
const Encode = @import("../move/encode.zig");
const C = @import("../c.zig");

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

    pub fn deinit(self: *Position) void {
        self.capture_stack.deinit();
        self.ep_stack.deinit();
        self.castle_stack.deinit();
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
        } else {
            return (
            Patterns.PawnCapturePatterns[0][square] & self.bitboards.BlackPawns != 0
                or Patterns.KnightPatterns[square] & self.bitboards.BlackKnights != 0
                or Patterns.KingPatterns[square] & self.bitboards.BlackKing != 0
                or Patterns.get_bishop_attacks(square, bb_all) & (self.bitboards.BlackBishops | self.bitboards.BlackQueens) != 0
                or Patterns.get_rook_attacks(square, bb_all) & (self.bitboards.BlackRooks | self.bitboards.BlackQueens) != 0
            );
        }
        // zig fmt: on
        return false;
    }

    pub fn add_piece(self: *Position, target: u6, piece: Piece.Piece) void {
        const st: u64 = BB.ShiftLocations[target];
        self.bitboards.get_bb_for(piece).* |= st;
        self.bitboards.get_occupancy_for(piece.color()).* |= st;

        self.mailbox[fen_sq_to_sq(target)] = piece;
    }

    pub fn remove_piece(self: *Position, target: u6, piece: Piece.Piece) void {
        const st: u64 = BB.ShiftLocations[target];
        self.bitboards.get_bb_for(piece).* &= ~st;
        self.bitboards.get_occupancy_for(piece.color()).* &= ~st;

        self.mailbox[fen_sq_to_sq(target)] = null;
    }

    pub fn move_piece(self: *Position, source: u6, target: u6, piece: Piece.Piece) void {
        const st: u64 = BB.ShiftLocations[source] | BB.ShiftLocations[target];
        self.bitboards.get_bb_for(piece).* ^= st;
        self.bitboards.get_occupancy_for(piece.color()).* ^= st;

        self.mailbox[fen_sq_to_sq(target)] = piece;
        self.mailbox[fen_sq_to_sq(source)] = null;
    }

    pub fn make_move(self: *Position, move: u24) void {
        var source = Encode.source(move);
        var target = Encode.target(move);
        var piece = @intToEnum(Piece.Piece, Encode.pt(move));

        self.ep_stack.append(self.ep) catch {};
        self.castle_stack.append(self.castling) catch {};

        self.ep = null;

        if (piece == Piece.Piece.WhiteRook) {
            if (source == C.SQ_C.A1) {
                self.castling &= ~Piece.WhiteQueenCastle;
            } else if (source == C.SQ_C.H1) {
                self.castling &= ~Piece.WhiteKingCastle;
            }
        } else if (piece == Piece.Piece.BlackRook) {
            if (source == C.SQ_C.A8) {
                self.castling &= ~Piece.BlackQueenCastle;
            } else if (source == C.SQ_C.H8) {
                self.castling &= ~Piece.BlackKingCastle;
            }
        }

        if (piece == Piece.Piece.WhiteKing) {
            self.castling &= ~(Piece.WhiteKingCastle | Piece.WhiteQueenCastle);
        } else if (piece == Piece.Piece.BlackKing) {
            self.castling &= ~(Piece.BlackKingCastle | Piece.BlackQueenCastle);
        }

        if (Encode.capture(move) != 0) {
            if (Encode.enpassant(move) != 0) {
                if (self.turn == Piece.Color.White) {
                    var captured = self.mailbox[fen_sq_to_sq(target - 8)].?;
                    self.capture_stack.append(captured) catch {};
                    self.remove_piece(target - 8, captured);
                } else {
                    var captured = self.mailbox[fen_sq_to_sq(target + 8)].?;
                    self.capture_stack.append(captured) catch {};
                    self.remove_piece(target + 8, captured);
                }
            } else {
                var captured = self.mailbox[fen_sq_to_sq(target)].?;
                self.capture_stack.append(captured) catch {};
                self.remove_piece(target, captured);
                if (captured == Piece.Piece.WhiteRook) {
                    if (target == C.SQ_C.A1) {
                        self.castling &= ~Piece.WhiteQueenCastle;
                    } else if (target == C.SQ_C.H1) {
                        self.castling &= ~Piece.WhiteKingCastle;
                    }
                } else if (captured == Piece.Piece.BlackRook) {
                    if (target == C.SQ_C.A8) {
                        self.castling &= ~Piece.BlackQueenCastle;
                    } else if (target == C.SQ_C.H8) {
                        self.castling &= ~Piece.BlackKingCastle;
                    }
                }
            }
            self.move_piece(source, target, piece);
        } else if (Encode.double(move) != 0) {
            self.move_piece(source, target, piece);
            if (self.turn == Piece.Color.White) {
                self.ep = target - 8;
            } else {
                self.ep = target + 8;
            }
        } else if (Encode.castling(move) != 0) {
            switch (target) {
                C.SQ_C.G1 => {
                    self.move_piece(C.SQ_C.H1, C.SQ_C.F1, Piece.Piece.WhiteRook);
                    self.move_piece(source, target, piece);
                },
                C.SQ_C.C1 => {
                    self.move_piece(C.SQ_C.A1, C.SQ_C.D1, Piece.Piece.WhiteRook);
                    self.move_piece(source, target, piece);
                },
                C.SQ_C.G8 => {
                    self.move_piece(C.SQ_C.H8, C.SQ_C.F8, Piece.Piece.BlackRook);
                    self.move_piece(source, target, piece);
                },
                C.SQ_C.C8 => {
                    self.move_piece(C.SQ_C.A8, C.SQ_C.D8, Piece.Piece.BlackRook);
                    self.move_piece(source, target, piece);
                },
                else => unreachable,
            }
        } else {
            self.move_piece(source, target, piece);
        }

        var promo = Encode.promote(move);
        if (promo != 0) {
            self.remove_piece(target, piece);
            self.add_piece(target, @intToEnum(Piece.Piece, promo));
        }

        self.turn = self.turn.invert();
    }

    pub fn undo_move(self: *Position, move: u24) void {
        const my_color = self.turn.invert();
        const opp_color = self.turn;

        var source = Encode.source(move);
        var target = Encode.target(move);
        var piece = @intToEnum(Piece.Piece, Encode.pt(move));

        self.ep = self.ep_stack.pop();
        // TODO figure out why this happens
        if (self.ep != null and self.ep.? == 0x1e) {
            self.ep = null;
        }
        self.castling = self.castle_stack.pop();

        var promo = Encode.promote(move);
        if (promo != 0) {
            self.remove_piece(target, @intToEnum(Piece.Piece, promo));
            self.add_piece(target, piece);
        }

        if (Encode.capture(move) != 0) {
            var captured = self.capture_stack.pop();

            self.move_piece(target, source, piece);

            if (Encode.enpassant(move) != 0) {
                if (opp_color == Piece.Color.White) {
                    self.add_piece(target + 8, captured);
                } else {
                    self.add_piece(target - 8, captured);
                }
            } else {
                self.add_piece(target, captured);
            }
        } else if (Encode.double(move) != 0) {
            self.move_piece(target, source, piece);
        } else if (Encode.castling(move) != 0) {
            switch (target) {
                C.SQ_C.G1 => {
                    self.move_piece(C.SQ_C.F1, C.SQ_C.H1, Piece.Piece.WhiteRook);
                    self.move_piece(target, source, piece);
                },
                C.SQ_C.C1 => {
                    self.move_piece(C.SQ_C.D1, C.SQ_C.A1, Piece.Piece.WhiteRook);
                    self.move_piece(target, source, piece);
                },
                C.SQ_C.G8 => {
                    self.move_piece(C.SQ_C.F8, C.SQ_C.H8, Piece.Piece.BlackRook);
                    self.move_piece(target, source, piece);
                },
                C.SQ_C.C8 => {
                    self.move_piece(C.SQ_C.D8, C.SQ_C.A8, Piece.Piece.BlackRook);
                    self.move_piece(target, source, piece);
                },
                else => unreachable,
            }
        } else {
            self.move_piece(target, source, piece);
        }

        self.turn = my_color;
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
        return position;
    }

    index += 1;
    if (index < fen.len) {
        if (fen[index] == '-') {
            position.ep = null;
        }
        // TODO: parse ep
    } else {
        return position;
    }

    return position;
}
