pub const Piece = enum(u4) {
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

    pub inline fn color(self: Piece) Color {
        return if (@enumToInt(self) <= @enumToInt(Piece.WhiteKing)) Color.White else Color.Black;
    }
};

pub const PieceType = enum(u4) {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
};

pub const Color = enum(u1) {
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
