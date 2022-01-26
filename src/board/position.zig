const std = @import("std");

const BB = @import("./bitboard.zig");
const Piece = @import("./piece.zig");
const Uci = @import("../uci/uci.zig");
const Patterns = @import("./patterns.zig");

pub const Position = struct {
    bitboards: BB.Bitboards,
    mailbox: [64]?Piece.Piece,
    turn: Piece.Color,
    ep: ?u6,
    castling: u4,

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
    }

    pub fn is_square_attacked_by(self: *Position, square: u6, color: Piece.Color) bool {
        if (color == Piece.Color.White) {
            if (Patterns.PawnCapturePatterns[1][square] & self.bitboards.WhitePawns != 0) {
                return true;
            }
            if (Patterns.KnightPatterns[square] & self.bitboards.WhiteKnights != 0) {
                return true;
            }
            if (Patterns.KingPatterns[square] & self.bitboards.WhiteKing != 0) {
                return true;
            }
            if (Patterns.get_bishop_attacks(square, self.bitboards.WhiteAll | self.bitboards.BlackAll) & (self.bitboards.WhiteBishops | self.bitboards.WhiteQueens) != 0) {
                return true;
            }
            if (Patterns.get_rook_attacks(square, self.bitboards.WhiteAll | self.bitboards.BlackAll) & (self.bitboards.WhiteRooks | self.bitboards.WhiteQueens) != 0) {
                return true;
            }
        } else {
            if (Patterns.PawnCapturePatterns[0][square] & self.bitboards.BlackPawns != 0) {
                return true;
            }
            if (Patterns.KnightPatterns[square] & self.bitboards.BlackKnights != 0) {
                return true;
            }
            if (Patterns.KingPatterns[square] & self.bitboards.BlackKing != 0) {
                return true;
            }
            if (Patterns.get_bishop_attacks(square, self.bitboards.WhiteAll | self.bitboards.BlackAll) & (self.bitboards.BlackBishops | self.bitboards.BlackQueens) != 0) {
                return true;
            }
            if (Patterns.get_rook_attacks(square, self.bitboards.WhiteAll | self.bitboards.BlackAll) & (self.bitboards.BlackRooks | self.bitboards.BlackQueens) != 0) {
                return true;
            }
        }
        return false;
    }
};

pub inline fn fen_sq_to_sq(fsq: u8) u6 {
    return @intCast(u6, (fsq % 8) + (7 - fsq / 8) * 8);
}

pub fn new_position_by_fen(fen: anytype) Position {
    var position = std.mem.zeroes(Position);

    position.castling = 0b1111;

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
    }

    return position;
}
