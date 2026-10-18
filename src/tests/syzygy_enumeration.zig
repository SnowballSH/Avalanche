//! A fixed set of positions probed through any prober, so that the results of two implementations
//! can be compared through a few numbers.

const std = @import("std");
const tables = @import("../chess/tables.zig");
const tablebases = @import("../syzygy/tablebases.zig");

const Board = tablebases.Board;
const PieceType = tablebases.PieceType;

pub const Summary = struct {
    /// Indexed by WDL + 2; the last counts failed probes.
    wdl: [6]u64,
    roots: u64,
    /// FNV-1a over each root probe's success and its moves and ranks.
    hash: u64,
};

pub const Material = struct {
    white: PieceType,
    /// A black piece, placed on each of `black_squares` in turn.
    black: ?PieceType = null,
    black_squares: []const u6 = &.{},
};

const WHITE_KING_SQUARES = [_]u6{ 0, 13, 27, 38 };
const RULE50 = [_]u8{ 0, 90 };

fn bit(sq: u6) u64 {
    return @as(u64, 1) << sq;
}

fn add(b: *Board, piece: PieceType, sq: u6) void {
    switch (piece) {
        .pawn => b.pawns |= bit(sq),
        .knight => b.knights |= bit(sq),
        .bishop => b.bishops |= bit(sq),
        .rook => b.rooks |= bit(sq),
        .queen => b.queens |= bit(sq),
        .king => b.kings |= bit(sq),
    }
}

fn on_back_rank(sq: u6) bool {
    return sq < 8 or sq >= 56;
}

/// The white king on a1, f2, d4 or g5, the black king and the white piece anywhere legal, either
/// side to move, probed for WDL; a sixteenth of them with White to move also for root DTZ, with the
/// counter at 0 and at 90. `prober` has `wdl(*const Board) ?i32` and
/// `root_dtz(*const Board, *tablebases.RootMoves) bool`.
pub fn summarize(prober: anytype, material: Material) Summary {
    var summary: Summary = .{ .wdl = @splat(0), .roots = 0, .hash = 0 };
    var hash: std.hash.Fnv1a_64 = .init();
    const black_squares: []const u6 = if (material.black == null) &.{0} else material.black_squares;
    for (WHITE_KING_SQUARES) |wk| for (black_squares) |bp| for (0..64) |bk_index| for (0..64) |sq_index| {
        const bk: u6 = @intCast(bk_index);
        const sq: u6 = @intCast(sq_index);
        if (wk == bk or wk == sq or bk == sq) continue;
        if (tables.KingAttacks[wk] & bit(bk) != 0) continue;
        if (material.white == .pawn and on_back_rank(sq)) continue;
        var b: Board = .{
            .white = bit(wk) | bit(sq),
            .black = bit(bk),
            .kings = bit(wk) | bit(bk),
            .queens = 0,
            .rooks = 0,
            .bishops = 0,
            .knights = 0,
            .pawns = 0,
            .white_to_move = true,
        };
        add(&b, material.white, sq);
        if (material.black) |black| {
            if (bp == wk or bp == bk or bp == sq) continue;
            if (black == .pawn and on_back_rank(bp)) continue;
            b.black |= bit(bp);
            add(&b, black, bp);
        }

        for ([_]bool{ true, false }) |white_to_move| {
            b.white_to_move = !white_to_move;
            if (b.is_check()) continue;
            b.white_to_move = white_to_move;

            summary.wdl[if (prober.wdl(&b)) |v| @intCast(v + 2) else 5] += 1;

            if (!white_to_move or (@as(usize, bk) + sq) % 16 != 0) continue;
            for (RULE50) |rule50| {
                var root = b;
                root.rule50 = rule50;
                summary.roots += 1;
                var ranked: tablebases.RootMoves = .{};
                const ok = prober.root_dtz(&root, &ranked);
                hash.update(&.{@intFromBool(ok)});
                if (!ok) continue;
                for (ranked.slice()) |root_move| {
                    const move: u16 = @bitCast(root_move.move);
                    hash.update(std.mem.asBytes(&move));
                    hash.update(std.mem.asBytes(&root_move.rank));
                }
            }
        }
    };
    summary.hash = hash.final();
    return summary;
}

/// `summarize` through the Zig tables.
pub const ZigProber = struct {
    tablebases: *tablebases.Tablebases,

    pub fn wdl(self: ZigProber, b: *const Board) ?i32 {
        return @backingInt(self.tablebases.probe_wdl(b) orelse return null);
    }

    pub fn root_dtz(self: ZigProber, b: *const Board, out: *tablebases.RootMoves) bool {
        self.tablebases.probe_root_dtz(b, false, out) catch return false;
        return true;
    }
};
