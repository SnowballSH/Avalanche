const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("./hce.zig");
const search = @import("./search.zig");

pub const SortScore = i32;

pub const SortHash: SortScore = 1700000;
pub const SortCapture: SortScore = 1600000;
pub const SortKiller: SortScore = 1500000;

pub fn score_moves(searcher: *search.Searcher, pos: *position.Position, list: *std.ArrayList(types.Move), hashmove: types.Move) std.ArrayList(SortScore) {
    var res: std.ArrayList(SortScore) = std.ArrayList(SortScore).initCapacity(std.heap.c_allocator, list.items.len) catch unreachable;

    var hm = hashmove.to_u16();

    for (list.items) |move_| {
        var move: *const types.Move = &move_;
        if (hm == move.to_u16()) {
            res.appendAssumeCapacity(SortHash);
        } else if (move.is_capture() or move.is_promotion()) {
            var s_piece: SortScore = hce.Mateiral[pos.mailbox[move.from].piece_type().index()][0];
            var s_captured: SortScore = if (pos.mailbox[move.to] == types.Piece.NO_PIECE) hce.Mateiral[0][0] else hce.Mateiral[pos.mailbox[move.to].piece_type().index()][0];
            var s_promotion: SortScore = if (move.is_promotion()) hce.Mateiral[move.get_flags().promote_type().index()][0] else 0;

            res.appendAssumeCapacity(SortCapture + 10 * (s_captured + s_promotion) - s_piece);
        } else if (searcher.killer[searcher.ply][0].to_u16() == move.to_u16() or searcher.killer[searcher.ply][1].to_u16() == move.to_u16()) {
            res.appendAssumeCapacity(SortKiller);
        } else {
            res.appendAssumeCapacity(1 + @intCast(i32, searcher.history[@enumToInt(pos.turn)][move.from][move.to]));
        }
    }

    return res;
}

pub fn get_next_best(list: *std.ArrayList(types.Move), evals: *std.ArrayList(SortScore), i: usize) types.Move {
    var move_size = list.items.len;
    var j = i + 1;
    while (j < move_size) : (j += 1) {
        if (evals.items[i] < evals.items[j]) {
            std.mem.swap(types.Move, &list.items[i], &list.items[j]);
            std.mem.swap(SortScore, &evals.items[i], &evals.items[j]);
        }
    }
    return list.items[i];
}
