const std = @import("std");

const piece = @import("./piece.zig");

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

    pub fn get_bb_for(self: *Bitboards, pc: piece.Piece) u64 {
        return switch (pc) {
            piece.Piece.WhitePawn => self.WhitePawns,
            piece.Piece.WhiteKnight => self.WhiteKnights,
            piece.Piece.WhiteBishop => self.WhiteBishops,
            piece.Piece.WhiteRook => self.WhiteRooks,
            piece.Piece.WhiteQueen => self.WhiteQueens,
            piece.Piece.WhiteKing => self.WhiteKing,
            piece.Piece.BlackPawn => self.BlackPawns,
            piece.Piece.BlackKnight => self.BlackKnights,
            piece.Piece.BlackBishop => self.BlackBishops,
            piece.Piece.BlackRook => self.BlackRooks,
            piece.Piece.BlackQueen => self.BlackQueens,
            piece.Piece.BlackKing => self.BlackKing,
        };
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
