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
        return @intToEnum(Color, @boolToInt(@enumToInt(self) > @enumToInt(Piece.WhiteKing)));
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

    pub inline fn invert(self: *Color) Color {
        return @intToEnum(Color, ~@enumToInt(self.*));
    }
};

test "color operations" {
    const std = @import("std");

    std.debug.assert(Color.invert(Color.White) == Color.Black);
    std.debug.assert(Color.invert(Color.Black) == Color.White);
}

pub const WhiteKingCastle: u4 = 1;
pub const WhiteQueenCastle: u4 = 2;
pub const BlackKingCastle: u4 = 4;
pub const BlackQueenCastle: u4 = 8;
