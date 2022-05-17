const std = @import("std");

pub const N_COLORS: usize = 2;
pub const Color = enum(u8) {
    White,
    Black,
    pub inline fn invert(self: Color) Color {
        return @intToEnum(Color, @enumToInt(self) ^ 1);
    }
};

pub const N_DIRS: usize = 8;
pub const Direction = enum(i32) {
    North = 8,
    NorthEast = 9,
    East = 1,
    SouthEast = -7,
    South = -8,
    SouthWest = -9,
    West = -1,
    NorthWest = 7,

    // Double Push
    NorthNorth = 16,
    SouthSouth = -16,
};

pub const N_PT: usize = 6;
pub const PieceType = enum(u8) {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
};

pub const PieceString = "PNBRQK~>pnbrqk.";
pub const DEFAULT_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -";
// Tricky position
pub const KIWIPETE = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -";

pub const N_PIECES: usize = 15;
pub const Piece = enum(u8) {
    WHITE_PAWN,
    WHITE_KNIGHT,
    WHITE_BISHOP,
    WHITE_ROOK,
    WHITE_QUEEN,
    WHITE_KING,
    BLACK_PAWN = 8,
    BLACK_KNIGHT,
    BLACK_BISHOP,
    BLACK_ROOK,
    BLACK_QUEEN,
    BLACK_KING,
    NO_PIECE,

    pub fn new(c: Color, pt: PieceType) Piece {
        return @intToEnum(Piece, (@enumToInt(c) << 3) + @enumToInt(pt));
    }

    pub inline fn piece_type(self: Piece) PieceType {
        return @intToEnum(PieceType, @enumToInt(self) & 0b111);
    }

    pub inline fn color(self: Piece) Color {
        return @intToEnum(Color, (@enumToInt(self) & 0b1000) >> 3);
    }
};

// Square & Bitboard

pub const Bitboard = u64;

pub const N_SQUARES = 64;

pub const Square = enum(i32) {
    // zig fmt: off
    a1, b1, c1, d1, e1, f1, g1, h1,
    a2, b2, c2, d2, e2, f2, g2, h2,
    a3, b3, c3, d3, e3, f3, g3, h3,
    a4, b4, c4, d4, e4, f4, g4, h4,
    a5, b5, c5, d5, e5, f5, g5, h5,
    a6, b6, c6, d6, e6, f6, g6, h6,
    a7, b7, c7, d7, e7, f7, g7, h7,
    a8, b8, c8, d8, e8, f8, g8, h8,
    NO_SQUARE,
    // zig fmt: on

    pub inline fn inc(self: *Square) *Square {
        self.* = @intToEnum(Square, @enumToInt(self.*) + 1);
        return self;
    }

    pub inline fn add(self: Square, d: Direction) Square {
        return @intToEnum(Square, @enumToInt(self) + @enumToInt(d));
    }

    pub inline fn sub(self: Square, d: Direction) Square {
        return @intToEnum(Square, @enumToInt(self) - @enumToInt(d));
    }
};

pub const File = enum(u8) {
    AFILE,
    BFILE,
    CFILE,
    DFILE,
    EFILE,
    FFILE,
    GFILE,
    HFILE,
};

pub const Rank = enum(u8) {
    RANK1,
    RANK2,
    RANK3,
    RANK4,
    RANK5,
    RANK6,
    RANK7,
    RANK8,
};

// Magic stuff

// zig fmt: off
pub const SquareToString = .{
    "a1", "b1", "c1", "d1", "e1", "f1", "g1", "h1",
    "a2", "b2", "c2", "d2", "e2", "f2", "g2", "h2",
    "a3", "b3", "c3", "d3", "e3", "f3", "g3", "h3",
    "a4", "b4", "c4", "d4", "e4", "f4", "g4", "h4",
    "a5", "b5", "c5", "d5", "e5", "f5", "g5", "h5",
    "a6", "b6", "c6", "d6", "e6", "f6", "g6", "h6",
    "a7", "b7", "c7", "d7", "e7", "f7", "g7", "h7",
    "a8", "b8", "c8", "d8", "e8", "f8", "g8", "h8",
    "None"
};

pub const MaskFile = .{
    0x101010101010101, 0x202020202020202, 0x404040404040404, 0x808080808080808,
    0x1010101010101010, 0x2020202020202020, 0x4040404040404040, 0x8080808080808080,
};

pub const MaskRank = .{
    0xff, 0xff00, 0xff0000, 0xff000000,
    0xff00000000, 0xff0000000000, 0xff000000000000, 0xff00000000000000
};

pub const MaskDiagonal = .{
    0x80, 0x8040, 0x804020,
    0x80402010, 0x8040201008, 0x804020100804,
    0x80402010080402, 0x8040201008040201, 0x4020100804020100,
    0x2010080402010000, 0x1008040201000000, 0x804020100000000,
    0x402010000000000, 0x201000000000000, 0x100000000000000,
};

pub const MaskAntiDiagonal = .{
    0x1, 0x102, 0x10204,
    0x1020408, 0x102040810, 0x10204081020,
    0x1020408102040, 0x102040810204080, 0x204081020408000,
    0x408102040800000, 0x810204080000000, 0x1020408000000000,
    0x2040800000000000, 0x4080000000000000, 0x8000000000000000,
};

pub const SquareIndexBB = .{
    0x1, 0x2, 0x4, 0x8,
    0x10, 0x20, 0x40, 0x80,
    0x100, 0x200, 0x400, 0x800,
    0x1000, 0x2000, 0x4000, 0x8000,
    0x10000, 0x20000, 0x40000, 0x80000,
    0x100000, 0x200000, 0x400000, 0x800000,
    0x1000000, 0x2000000, 0x4000000, 0x8000000,
    0x10000000, 0x20000000, 0x40000000, 0x80000000,
    0x100000000, 0x200000000, 0x400000000, 0x800000000,
    0x1000000000, 0x2000000000, 0x4000000000, 0x8000000000,
    0x10000000000, 0x20000000000, 0x40000000000, 0x80000000000,
    0x100000000000, 0x200000000000, 0x400000000000, 0x800000000000,
    0x1000000000000, 0x2000000000000, 0x4000000000000, 0x8000000000000,
    0x10000000000000, 0x20000000000000, 0x40000000000000, 0x80000000000000,
    0x100000000000000, 0x200000000000000, 0x400000000000000, 0x800000000000000,
    0x1000000000000000, 0x2000000000000000, 0x4000000000000000, 0x8000000000000000,
    0x0
};

// zig fmt: on

pub fn debug_print_bitboard(b: Bitboard) void {
    var i: i32 = 56;
    while (i >= 0) : (i -= 8) {
        var j: i32 = 0;
        while (j < 8) : (j += 1) {
            if ((b >> @intCast(u6, i + j)) & 1 != 0) {
                std.debug.print("1 ", .{});
            } else {
                std.debug.print("0 ", .{});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}
