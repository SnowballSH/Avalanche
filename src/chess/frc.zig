const std = @import("std");
const types = @import("types.zig");

/// Chess960 starting positions in Scharnagl numbering; index 518 is the
/// standard chess setup.
pub const N_POSITIONS: u16 = 960;
pub const STANDARD_INDEX: u16 = 518;

const KNIGHT_PLACEMENTS = [10][2]u3{
    .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 0, 4 }, .{ 1, 2 },
    .{ 1, 3 }, .{ 1, 4 }, .{ 2, 3 }, .{ 2, 4 }, .{ 3, 4 },
};

pub fn back_rank(index: u16) [8]types.PieceType {
    std.debug.assert(index < N_POSITIONS);
    var rank: [8]?types.PieceType = @splat(null);
    var n = index;

    rank[2 * (n % 4) + 1] = .Bishop;
    n /= 4;
    rank[2 * (n % 4)] = .Bishop;
    n /= 4;
    place_on_nth_empty(&rank, n % 6, .Queen);
    n /= 6;
    const knights = KNIGHT_PLACEMENTS[n];
    place_on_nth_empty(&rank, knights[1], .Knight);
    place_on_nth_empty(&rank, knights[0], .Knight);
    place_on_nth_empty(&rank, 0, .Rook);
    place_on_nth_empty(&rank, 0, .King);
    place_on_nth_empty(&rank, 0, .Rook);

    var result: [8]types.PieceType = undefined;
    for (rank, &result) |piece, *out| out.* = piece.?;
    return result;
}

fn place_on_nth_empty(rank: *[8]?types.PieceType, nth: usize, piece: types.PieceType) void {
    var seen: usize = 0;
    for (rank) |*square| {
        if (square.* != null) continue;
        if (seen == nth) {
            square.* = piece;
            return;
        }
        seen += 1;
    }
    unreachable;
}

pub const FEN_CAPACITY = 64;

/// Double Fischer Random start: each side gets its own Chess960 back rank.
pub fn dfrc_fen(white_index: u16, black_index: u16, buf: *[FEN_CAPACITY]u8) []const u8 {
    var black: [8]u8 = undefined;
    var white: [8]u8 = undefined;
    for (back_rank(black_index), back_rank(white_index), &black, &white) |b, w, *bc, *wc| {
        bc.* = types.PieceString[types.Piece.new(.Black, b).index()];
        wc.* = types.PieceString[types.Piece.new(.White, w).index()];
    }
    return std.fmt.bufPrint(buf, "{s}/pppppppp/8/8/8/8/PPPPPPPP/{s} w KQkq - 0 1", .{ &black, &white }) catch unreachable;
}

pub fn frc_fen(index: u16, buf: *[FEN_CAPACITY]u8) []const u8 {
    return dfrc_fen(index, index, buf);
}
