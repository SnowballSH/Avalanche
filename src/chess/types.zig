const std = @import("std");
const platform = @import("../platform.zig");
const position = @import("position.zig");

pub const Timer = struct {
    start_ns: i96,

    pub fn start() Timer {
        return Timer{ .start_ns = platform.now_ns() };
    }

    pub fn read(self: Timer) u64 {
        const now_ns = platform.now_ns();
        return @as(u64, @intCast(now_ns - self.start_ns));
    }
};

pub const N_COLORS: usize = 2;
pub const Color = enum(u8) {
    White,
    Black,
    pub inline fn invert(self: Color) Color {
        return @as(Color, @fromBackingInt(@intCast(@backingInt(self) ^ 1)));
    }
};

pub const Direction = enum(i32) {
    North = 8,
    NorthEast = 9,
    East = 1,
    SouthEast = -7,
    South = -8,
    SouthWest = -9,
    West = -1,
    NorthWest = 7,

    NorthNorth = 16,
    SouthSouth = -16,

    pub inline fn relative_dir(self: Direction, comptime c: Color) Direction {
        return if (c == Color.White) self else @as(Direction, @fromBackingInt(@intCast(-@backingInt(self))));
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

    pub inline fn index(self: PieceType) u8 {
        return @backingInt(self);
    }
};

pub const PieceString = "PNBRQK~>pnbrqk.";
pub const DEFAULT_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -";
pub const KIWIPETE_FEN = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -";
pub const ENDGAME_FEN = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - ";

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

    pub inline fn new(c: Color, pt: PieceType) Piece {
        return @as(Piece, @fromBackingInt(@intCast((@backingInt(c) << 3) + @backingInt(pt))));
    }

    pub inline fn new_comptime(comptime c: Color, comptime pt: PieceType) Piece {
        return @as(Piece, @fromBackingInt(@intCast((@backingInt(c) << 3) + @backingInt(pt))));
    }

    pub inline fn piece_type(self: Piece) PieceType {
        return @as(PieceType, @fromBackingInt(@intCast(@backingInt(self) & 0b111)));
    }

    pub inline fn color(self: Piece) Color {
        return @as(Color, @fromBackingInt(@intCast((@backingInt(self) & 0b1000) >> 3)));
    }

    pub inline fn index(self: Piece) u8 {
        return @backingInt(self);
    }

    pub inline fn pure_index(self: Piece) usize {
        return if (@backingInt(self) <= 5) @backingInt(self) else @backingInt(self) - 2;
    }
};

pub const Bitboard = u64;

pub const N_SQUARES = 64;

pub const Square = enum(u8) {
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

    pub inline fn add(self: Square, d: Direction) Square {
        return @as(Square, @fromBackingInt(@intCast(@backingInt(self) + @backingInt(d))));
    }

    pub inline fn sub(self: Square, d: Direction) Square {
        return @as(Square, @fromBackingInt(@intCast(@backingInt(self) - @backingInt(d))));
    }

    pub inline fn rank(self: Square) Rank {
        return @as(Rank, @fromBackingInt(@intCast(@backingInt(self) >> 3)));
    }

    pub inline fn file(self: Square) File {
        return @as(File, @fromBackingInt(@intCast(@backingInt(self) & 0b111)));
    }

    pub inline fn diagonal(self: Square) i32 {
        return @as(i32, @intCast(7 + @backingInt(self.rank()) - @backingInt(self.file())));
    }

    pub inline fn anti_diagonal(self: Square) i32 {
        return @as(i32, @intCast(@backingInt(self.rank()) + @backingInt(self.file())));
    }

    pub inline fn new(f: File, r: Rank) Square {
        return @as(Square, @fromBackingInt(@intCast(@backingInt(f) | (@backingInt(r) << 3))));
    }

    pub inline fn index(self: Square) u8 {
        return @as(u8, @intCast(@backingInt(self)));
    }
};

pub inline fn rank_plain(sq: usize) usize {
    return sq >> 3;
}

pub inline fn file_plain(sq: usize) usize {
    return sq & 0b111;
}

pub inline fn diagonal_plain(sq: usize) usize {
    return 7 + rank_plain(sq) - file_plain(sq);
}

pub inline fn anti_diagonal_plain(sq: usize) usize {
    return rank_plain(sq) + file_plain(sq);
}

pub const File = enum(u8) {
    AFILE,
    BFILE,
    CFILE,
    DFILE,
    EFILE,
    FFILE,
    GFILE,
    HFILE,

    pub inline fn index(self: File) u8 {
        return @backingInt(self);
    }
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

    pub inline fn index(self: Rank) u8 {
        return @backingInt(self);
    }

    pub inline fn relative_rank(self: Rank, comptime c: Color) Rank {
        return if (c == Color.White) self else @as(Rank, @fromBackingInt(@intCast(@backingInt(Rank.RANK8) - @backingInt(self))));
    }
};

// zig fmt: off
pub const SquareToString = [_][:0]const u8{
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

pub inline fn popcount(x: Bitboard) i32 {
    return @as(i32, @intCast(@popCount(x)));
}

pub inline fn popcount_usize(x: Bitboard) usize {
    return @as(usize, @intCast(@popCount(x)));
}

pub inline fn lsb(x: Bitboard) i32 {
    return @as(i32, @intCast(@ctz(x)));
}

pub inline fn pop_lsb(x: *Bitboard) Square {
    const l = lsb(x.*);
    x.* &= x.* - 1;
    return @as(Square, @fromBackingInt(@intCast(l)));
}

pub inline fn shift_bitboard(x: Bitboard, comptime d: Direction) Bitboard {
    return switch (d) {
        Direction.North => x << 8,
        Direction.South => x >> 8,
        Direction.NorthNorth => x << 16,
        Direction.SouthSouth => x >> 16,
        Direction.East => (x & ~MaskFile[@backingInt(File.HFILE)]) << 1,
        Direction.West => (x & ~MaskFile[@backingInt(File.AFILE)]) >> 1,
        Direction.NorthEast => (x & ~MaskFile[@backingInt(File.HFILE)]) << 9,
        Direction.NorthWest => (x & ~MaskFile[@backingInt(File.AFILE)]) << 7,
        Direction.SouthEast => (x & ~MaskFile[@backingInt(File.HFILE)]) >> 7,
        Direction.SouthWest => (x & ~MaskFile[@backingInt(File.AFILE)]) >> 9,
    };
}

pub const PromMoveTypeString = [_][:0]const u8{ "", "", "", " ", "n", "b", "r", "q", "", "", "", "", "n", "b", "r", "q" };

pub const MoveFlags = enum(u4) {
    QUIET = 0b0000,
    DOUBLE_PUSH = 0b0001,
    OO = 0b0010,
    OOO = 0b0011,
    PR_KNIGHT = 0b0100,
    PR_BISHOP = 0b0101,
    PR_ROOK = 0b0110,
    PR_QUEEN = 0b0111,
    CAPTURE = 0b1000,
    EN_PASSANT = 0b1010,
    PC_KNIGHT = 0b1100,
    PC_BISHOP = 0b1101,
    PC_ROOK = 0b1110,
    PC_QUEEN = 0b1111,

    const CAPTURE_BIT: u4 = @backingInt(MoveFlags.CAPTURE);

    pub inline fn promote_type(self: MoveFlags) PieceType {
        return switch (@backingInt(self) & ~CAPTURE_BIT) {
            @backingInt(MoveFlags.PR_KNIGHT) => PieceType.Knight,
            @backingInt(MoveFlags.PR_BISHOP) => PieceType.Bishop,
            @backingInt(MoveFlags.PR_ROOK) => PieceType.Rook,
            @backingInt(MoveFlags.PR_QUEEN) => PieceType.Queen,
            else => unreachable,
        };
    }
};

pub const Move = packed struct {
    flags: u4,
    from: u6,
    to: u6,

    pub inline fn to_u16(self: Move) u16 {
        return @as(u16, @bitCast(self));
    }

    pub inline fn get_flags(self: Move) MoveFlags {
        return @as(MoveFlags, @fromBackingInt(@intCast(self.flags)));
    }

    pub inline fn get_from(self: Move) Square {
        return @as(Square, @fromBackingInt(@intCast(self.from)));
    }

    pub inline fn get_to(self: Move) Square {
        return @as(Square, @fromBackingInt(@intCast(self.to)));
    }

    pub inline fn empty() Move {
        return Move{ .flags = 0, .from = 0, .to = 0 };
    }

    pub inline fn new_from_to(from: Square, to: Square) Move {
        return Move{ .flags = 0, .from = @as(u6, @intCast(@backingInt(from))), .to = @as(u6, @intCast(@backingInt(to))) };
    }

    pub inline fn new_from_to_flag(from: Square, to: Square, flag: MoveFlags) Move {
        return Move{ .flags = @backingInt(flag), .from = @as(u6, @intCast(@backingInt(from))), .to = @as(u6, @intCast(@backingInt(to))) };
    }

    pub fn parse(pos: *position.Position, text: []const u8) ?Move {
        const from = parse_square(text, 0) orelse return null;
        const to = parse_square(text, 2) orelse return null;
        const promo: ?u8 = if (text.len >= 5) text[4] else null;
        const chess960 = pos.chess960_notation();

        const list = pos.legal_moves();
        for (list.items()) |m| {
            if (m.from != from.index()) continue;
            const destination = if (m.is_castle() and !chess960) m.castle_king_destination().index() else m.to;
            if (destination != to.index() and !(m.is_castle() and m.to == to.index())) continue;
            if (promo) |p| {
                const expected = PromMoveTypeString[m.flags];
                if (expected.len == 0 or expected[0] != p) continue;
            }
            return m;
        }
        return null;
    }

    fn parse_square(text: []const u8, offset: usize) ?Square {
        if (text.len < offset + 2) return null;
        const f = text[offset];
        const r = text[offset + 1];
        if (f < 'a' or f > 'h' or r < '1' or r > '8') return null;
        return Square.new(@fromBackingInt(@intCast(f - 'a')), @fromBackingInt(@intCast(r - '1')));
    }

    pub inline fn make_all(comptime flag: MoveFlags, from: Square, to: Bitboard, list: *MoveList) void {
        var to_t = to;
        while (to_t != 0) {
            list.append(Move.new_from_to_flag(from, pop_lsb(&to_t), flag));
        }
    }

    pub inline fn is_capture(self: Move) bool {
        return (self.flags & MoveFlags.CAPTURE_BIT) != 0;
    }

    pub inline fn is_promotion(self: Move) bool {
        return (self.flags >= @backingInt(MoveFlags.PR_KNIGHT) and self.flags <= @backingInt(MoveFlags.PR_QUEEN)) or
            (self.flags >= @backingInt(MoveFlags.PC_KNIGHT) and self.flags <= @backingInt(MoveFlags.PC_QUEEN));
    }

    pub inline fn is_castle(self: Move) bool {
        return self.flags == @backingInt(MoveFlags.OO) or self.flags == @backingInt(MoveFlags.OOO);
    }

    pub inline fn castle_king_destination(self: Move) Square {
        const file: File = if (self.to > self.from) .GFILE else .CFILE;
        return Square.new(file, self.get_from().rank());
    }

    pub fn uci_print(self: Move, writer: *std.Io.Writer, chess960: bool) void {
        const to = if (self.is_castle() and !chess960) self.castle_king_destination().index() else self.to;
        writer.print("{s}{s}", .{
            SquareToString[self.from],
            SquareToString[to],
        }) catch {};
        if (self.is_promotion()) {
            writer.print("{c}", .{
                PromMoveTypeString[self.flags][0],
            }) catch {};
        }
    }
};

pub const MoveList = struct {
    pub const capacity = 256;

    buffer: [capacity]Move = undefined,
    len: usize = 0,

    pub inline fn append(self: *MoveList, move: Move) void {
        if (self.len == capacity) return;
        self.buffer[self.len] = move;
        self.len += 1;
    }

    pub inline fn items(self: *const MoveList) []const Move {
        return self.buffer[0..self.len];
    }

    pub inline fn mutable_items(self: *MoveList) []Move {
        return self.buffer[0..self.len];
    }

    pub inline fn truncate(self: *MoveList, len: usize) void {
        std.debug.assert(len <= self.len);
        self.len = len;
    }
};
