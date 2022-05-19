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

    pub inline fn relative_dir(self: Direction, comptime c: Color) Direction {
        return if (c == Color.White) self else @intToEnum(Direction, -@enumToInt(self));
    }
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

    pub inline fn rank(self: Square) Rank {
        return @intToEnum(Rank, @enumToInt(self) >> 3);
    }

    pub inline fn file(self: Square) File {
        return @intToEnum(File, @enumToInt(self) & 0b111);
    }

    pub inline fn diagonal(self: Square) i32 {
        return @intCast(i32, 7 + @enumToInt(self.rank()) - @enumToInt(self.file()));
    }

    pub inline fn anti_diagonal(self: Square) i32 {
        return @intCast(i32, @enumToInt(self.rank()) + @enumToInt(self.file()));
    }

    pub inline fn new(f: File, r: Rank) Square {
        return @intToEnum(Square, @enumToInt(f) | (@enumToInt(r) << 3));
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

    pub inline fn relative_rank(self: Rank, comptime c: Color) Rank {
        return if (c == Color.White) self else @intToEnum(Rank, @enumToInt(Rank.RANK8) - @enumToInt(self));
    }
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

pub const MaskFile = [_]Bitboard{
    0x101010101010101, 0x202020202020202, 0x404040404040404, 0x808080808080808,
    0x1010101010101010, 0x2020202020202020, 0x4040404040404040, 0x8080808080808080,
};

pub const MaskRank = [_]Bitboard{
    0xff, 0xff00, 0xff0000, 0xff000000,
    0xff00000000, 0xff0000000000, 0xff000000000000, 0xff00000000000000
};

pub const MaskDiagonal = [_]Bitboard{
    0x80, 0x8040, 0x804020,
    0x80402010, 0x8040201008, 0x804020100804,
    0x80402010080402, 0x8040201008040201, 0x4020100804020100,
    0x2010080402010000, 0x1008040201000000, 0x804020100000000,
    0x402010000000000, 0x201000000000000, 0x100000000000000,
};

pub const MaskAntiDiagonal = [_]Bitboard{
    0x1, 0x102, 0x10204,
    0x1020408, 0x102040810, 0x10204081020,
    0x1020408102040, 0x102040810204080, 0x204081020408000,
    0x408102040800000, 0x810204080000000, 0x1020408000000000,
    0x2040800000000000, 0x4080000000000000, 0x8000000000000000,
};

pub const SquareIndexBB = [_]Bitboard{
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

pub const k1: Bitboard = 0x5555555555555555;
pub const k2: Bitboard = 0x3333333333333333;
pub const k3: Bitboard = 0x0f0f0f0f0f0f0f0f;
pub const kf: Bitboard = 0x0101010101010101;

pub inline fn popcount(x: Bitboard) i32 {
    return @intCast(i32, @popCount(u64, x));
}

pub inline fn lsb(x: Bitboard) i32 {
    return @intCast(i32, @ctz(u64, x));
    // Ancient machines:
    //const DEBRUIJN64: [64]i32 = .{
    //    // zig fmt: off
    //    0, 47,  1, 56, 48, 27,  2, 60,
    //    57, 49, 41, 37, 28, 16,  3, 61,
    //    54, 58, 35, 52, 50, 42, 21, 44,
    //    38, 32, 29, 23, 17, 11,  4, 62,
    //    46, 55, 26, 59, 40, 36, 15, 53,
    //    34, 51, 20, 43, 31, 22, 10, 45,
    //    25, 39, 14, 33, 19, 30,  9, 24,
    //    13, 18,  8, 12,  7,  6,  5, 63
    //    // zig fmt: on
    //};
    // const MagicNumber: Bitboard = 0x03f79d71b4cb0a89;
    // return DEBRUIJN64[(MagicNumber *% (x ^ (x-%1))) >> 58];
}

pub inline fn pop_lsb(x: *Bitboard) Square {
    var l = lsb(x.*);
    x.* &= x.* - 1;
    return @intToEnum(Square, l);
}

pub inline fn shift_bitboard(x: Bitboard, comptime d: Direction) Bitboard {
    return switch (d) {
        Direction.North => x << 8,
        Direction.South => x >> 8,
        Direction.NorthNorth => x << 16,
        Direction.SouthSouth => x >> 16,
        Direction.East => (x & ~MaskFile[@enumToInt(File.HFILE)]) << 1,
        Direction.West => (x & ~MaskFile[@enumToInt(File.AFILE)]) >> 1,
        Direction.NorthEast => (x & ~MaskFile[@enumToInt(File.HFILE)]) << 9,
        Direction.NorthWest => (x & ~MaskFile[@enumToInt(File.AFILE)]) << 7,
        Direction.SouthEast => (x & ~MaskFile[@enumToInt(File.HFILE)]) >> 7,
        Direction.SouthWest => (x & ~MaskFile[@enumToInt(File.AFILE)]) >> 9,
    };
}

pub const MoveTypeString = [_]*const []u8{ "", "", " O-O", " O-O-O", "N", "B", "R", "Q", " (capture)", "", " e.p.", "", "N", "B", "R", "Q" };

pub const MoveFlags = enum(u4) {
    QUIET = 0b0000,
    DOUBLE_PUSH = 0b0001,
    OO = 0b0010,
    OOO = 0b0011,
    CAPTURE = 0b1000,
    CAPTURES = 0b1111,
    EN_PASSANT = 0b1010,
    PROMOTIONS = 0b0111,
    PROMOTION_CAPTURES = 0b1100,
};

pub const PR_KNIGHT: u4 = 0b0100;
pub const PR_BISHOP: u4 = 0b0101;
pub const PR_ROOK: u4 = 0b0110;
pub const PR_QUEEN: u4 = 0b0111;
pub const PC_KNIGHT: u4 = 0b1100;
pub const PC_BISHOP: u4 = 0b1101;
pub const PC_ROOK: u4 = 0b1110;
pub const PC_QUEEN: u4 = 0b1111;

// Packed Struct makes it fit into a 16-bit integer.
pub const Move = packed struct {
    flags: u4,
    from: u6,
    to: u6,

    pub inline fn get_flags(self: Move) MoveFlags {
        return @intToEnum(MoveFlags, self.flags);
    }

    pub inline fn get_from(self: Move) Square {
        return @intToEnum(Square, self.from);
    }

    pub inline fn get_to(self: Move) Square {
        return @intToEnum(Square, self.to);
    }

    pub inline fn empty() Move {
        return Move{ .flags = 0, .from = 0, .to = 0 };
    }

    pub inline fn clone(self: Move) Move {
        return Move{ .flags = self.flags, .from = self.from, .to = self.to };
    }

    pub inline fn new_from_to(from: Square, to: Square) Move {
        return Move{ .flags = 0, .from = @intCast(u6, @enumToInt(from)), .to = @intCast(u6, @enumToInt(to)) };
    }

    pub inline fn new_from_to_flag(from: Square, to: Square, flag: MoveFlags) Move {
        return Move{ .flags = @enumToInt(flag), .from = @intCast(u6, @enumToInt(from)), .to = @intCast(u6, @enumToInt(to)) };
    }

    pub fn new_from_string(move: [:0]const u8) Move {
        return Move{
            .flags = 0,
            .from = @intCast(u6, @enumToInt(Square.new(@intToEnum(File, move[0] - 'a'), @intToEnum(Rank, move[1] - '1')))),
            .to = @intCast(u6, @enumToInt(Square.new(@intToEnum(File, move[2] - 'a'), @intToEnum(Rank, move[3] - '1')))),
        };
    }
};

pub fn debug_print_move() void {}