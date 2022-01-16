pub const Piece = enum {
    WhitePawn,
    WhiteKnight,
    WhiteBishop,
    WhiteRook,
    WhiteQueen,
    WhiteKing,
    BlackPawn,
    BlackKnight,
    BlackBishop,
    BlackRook,
    BlackQueen,
    BlackKing,
};

pub const PieceType = enum {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
};

pub const Color = enum {
    White,
    Black,

    pub inline fn invert(self: Color) Color {
        return if (self == Color.White) Color.Black else Color.White;
    }
};

test "color operations" {
    const std = @import("std");

    std.debug.assert(Color.invert(Color.White) == Color.Black);
    std.debug.assert(Color.invert(Color.Black) == Color.White);
}
