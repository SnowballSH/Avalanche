const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");

pub const Side = enum(u1) {
    King,
    Queen,

    pub inline fn index(self: Side) usize {
        return @backingInt(self);
    }
};

pub const Rights = u4;
pub const NO_RIGHTS: Rights = 0;

pub inline fn right(color: types.Color, side: Side) Rights {
    const shift: u2 = @intCast(2 * @as(u8, @backingInt(color)) + @backingInt(side));
    return @as(Rights, 1) << shift;
}

pub inline fn color_rights(color: types.Color) Rights {
    return right(color, .King) | right(color, .Queen);
}

/// Geometry of one castling move. Every square set is precomputed so movegen
/// only performs mask tests.
pub const Rule = struct {
    king_from: types.Square = .NO_SQUARE,
    rook_from: types.Square = .NO_SQUARE,
    king_to: types.Square = .NO_SQUARE,
    rook_to: types.Square = .NO_SQUARE,
    must_be_empty: types.Bitboard = 0,
    must_be_safe: types.Bitboard = 0,
    // The castling rook can shield `king_to` from a rank attack only when it is
    // not on an edge file; only then does movegen re-check `king_to` without it.
    rook_may_shield: bool = false,

    pub fn init(color: types.Color, side: Side, king_from: types.Square, rook_from: types.Square) Rule {
        const back_rank: types.Rank = if (color == .White) .RANK1 else .RANK8;
        const king_to = types.Square.new(if (side == .King) .GFILE else .CFILE, back_rank);
        const rook_to = types.Square.new(if (side == .King) .FFILE else .DFILE, back_rank);
        const movers = types.SquareIndexBB[king_from.index()] | types.SquareIndexBB[rook_from.index()];
        const king_path = path(king_from, king_to);
        const rook_path = path(rook_from, rook_to);
        const rook_file = rook_from.file();
        return .{
            .king_from = king_from,
            .rook_from = rook_from,
            .king_to = king_to,
            .rook_to = rook_to,
            .must_be_empty = (king_path | rook_path) & ~movers,
            .must_be_safe = king_path,
            .rook_may_shield = rook_file != .AFILE and rook_file != .HFILE,
        };
    }

    // Squares strictly between `from` and `to` plus `to` itself.
    fn path(from: types.Square, to: types.Square) types.Bitboard {
        const between = if (from == to) 0 else tables.SquaresBetween[from.index()][to.index()];
        return between | types.SquareIndexBB[to.index()];
    }

    pub inline fn is_standard(self: Rule) bool {
        return self.king_from.file() == .EFILE and
            self.rook_from.file() == (if (self.king_to.file() == .GFILE) types.File.HFILE else types.File.AFILE);
    }
};

/// Castling configuration of a game: which rook castles on which side, and the
/// rights each square revokes when a piece leaves or lands on it.
pub const Setup = struct {
    rules: [types.N_COLORS][2]Rule = .{ .{ .{}, .{} }, .{ .{}, .{} } },
    revoked_by: [types.N_SQUARES]Rights = @splat(0),
    is_chess960: bool = false,

    pub fn add(self: *Setup, color: types.Color, side: Side, king_from: types.Square, rook_from: types.Square) Rights {
        const added = Rule.init(color, side, king_from, rook_from);
        const bit = right(color, side);
        self.rules[@backingInt(color)][side.index()] = added;
        self.revoked_by[king_from.index()] |= bit;
        self.revoked_by[rook_from.index()] |= bit;
        self.is_chess960 = self.is_chess960 or !added.is_standard();
        return bit;
    }

    pub inline fn rule(self: *const Setup, color: types.Color, side: Side) *const Rule {
        return &self.rules[@backingInt(color)][side.index()];
    }

    pub inline fn revoked(self: *const Setup, from: u6, to: u6) Rights {
        return self.revoked_by[from] | self.revoked_by[to];
    }
};

pub inline fn side_of(flags: types.MoveFlags) Side {
    return if (flags == .OO) .King else .Queen;
}
