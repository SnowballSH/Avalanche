const std = @import("std");

const piece = @import("./piece.zig");
const Patterns = @import("./patterns.zig");

// Definition

pub const Bitboards = struct {
    WhitePawns: u64 = 0,
    WhiteKnights: u64 = 0,
    WhiteBishops: u64 = 0,
    WhiteRooks: u64 = 0,
    WhiteQueens: u64 = 0,
    WhiteKing: u64 = 0,
    BlackPawns: u64 = 0,
    BlackKnights: u64 = 0,
    BlackBishops: u64 = 0,
    BlackRooks: u64 = 0,
    BlackQueens: u64 = 0,
    BlackKing: u64 = 0,

    WhiteAll: u64 = 0,
    BlackAll: u64 = 0,

    pub fn get_bb_for(self: *Bitboards, pc: piece.Piece) *u64 {
        return switch (pc) {
            piece.Piece.WhitePawn => &self.WhitePawns,
            piece.Piece.WhiteKnight => &self.WhiteKnights,
            piece.Piece.WhiteBishop => &self.WhiteBishops,
            piece.Piece.WhiteRook => &self.WhiteRooks,
            piece.Piece.WhiteQueen => &self.WhiteQueens,
            piece.Piece.WhiteKing => &self.WhiteKing,
            piece.Piece.BlackPawn => &self.BlackPawns,
            piece.Piece.BlackKnight => &self.BlackKnights,
            piece.Piece.BlackBishop => &self.BlackBishops,
            piece.Piece.BlackRook => &self.BlackRooks,
            piece.Piece.BlackQueen => &self.BlackQueens,
            piece.Piece.BlackKing => &self.BlackKing,
        };
    }

    pub fn get_occupancy_for(self: *Bitboards, pc: piece.Color) *u64 {
        return switch (pc) {
            piece.Color.White => &self.WhiteAll,
            piece.Color.Black => &self.BlackAll,
        };
    }

    pub fn toggle_piece(self: *Bitboards, pc: piece.Piece, sq: u6) void {
        self.get_bb_for(pc).* ^= Patterns.index_to_bb(sq);
        if (@enumToInt(pc) >= @enumToInt(piece.Piece.BlackPawn)) {
            self.BlackAll ^= Patterns.index_to_bb(sq);
        } else {
            self.WhiteAll ^= Patterns.index_to_bb(sq);
        }
    }
};

test "bb functions" {
    comptime var my_bbs = Bitboards{
        .WhiteBishops = 0b101011,
        .BlackKing = 0b111010001,
    };

    std.debug.assert(my_bbs.get_bb_for(piece.Piece.WhiteBishop) == 0b101011);
    std.debug.assert(my_bbs.get_bb_for(piece.Piece.BlackKing) == 0b111010001);
}

// BitLoc

// Util functions

pub inline fn get_at(bb: u64, index: u6) u1 {
    return @intCast(u1, 1 & (bb >> index));
}

pub inline fn rank_of(sq: usize) u3 {
    return @intCast(u3, sq / 8);
}

pub inline fn file_of(sq: usize) u3 {
    return @intCast(u3, sq & 7);
}

// Direction manipulation

pub inline fn east_one(bb: u64) u64 {
    return bb >> 1;
}

pub inline fn west_one(bb: u64) u64 {
    return bb << 1;
}

pub inline fn north_one(bb: u64) u64 {
    return bb >> 8;
}

pub inline fn south_one(bb: u64) u64 {
    return bb << 8;
}

// Display

pub fn display(bb: u64) void {
    var rank: i8 = 7;
    while (rank >= 0) {
        std.debug.print("{d} ", .{rank + 1});
        var file: i8 = 0;
        while (file < 8) {
            const sq = @intCast(u6, (rank << 3) + file);

            const bit = get_at(bb, sq);

            if (bit == 1) {
                std.debug.print(". ", .{});
            } else {
                std.debug.print("  ", .{});
            }

            file += 1;
        }
        std.debug.print("\n", .{});
        rank -= 1;
    }

    std.debug.print("  A B C D E F G H\n", .{});
}

pub const ShiftLocations: [64]u64 = .{
    0x1,
    0x2,
    0x4,
    0x8,
    0x10,
    0x20,
    0x40,
    0x80,
    0x100,
    0x200,
    0x400,
    0x800,
    0x1000,
    0x2000,
    0x4000,
    0x8000,
    0x10000,
    0x20000,
    0x40000,
    0x80000,
    0x100000,
    0x200000,
    0x400000,
    0x800000,
    0x1000000,
    0x2000000,
    0x4000000,
    0x8000000,
    0x10000000,
    0x20000000,
    0x40000000,
    0x80000000,
    0x100000000,
    0x200000000,
    0x400000000,
    0x800000000,
    0x1000000000,
    0x2000000000,
    0x4000000000,
    0x8000000000,
    0x10000000000,
    0x20000000000,
    0x40000000000,
    0x80000000000,
    0x100000000000,
    0x200000000000,
    0x400000000000,
    0x800000000000,
    0x1000000000000,
    0x2000000000000,
    0x4000000000000,
    0x8000000000000,
    0x10000000000000,
    0x20000000000000,
    0x40000000000000,
    0x80000000000000,
    0x100000000000000,
    0x200000000000000,
    0x400000000000000,
    0x800000000000000,
    0x1000000000000000,
    0x2000000000000000,
    0x4000000000000000,
    0x8000000000000000,
};
