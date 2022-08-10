const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("./hce.zig");
const search = @import("./search.zig");
const see = @import("./see.zig");

pub const SortScore = i32;

pub const SortHash: SortScore = 20000;
pub const SortWinningCapture: SortScore = 10000;
pub const SortLosingCapture: SortScore = -35000;
pub const SortKiller: SortScore = 5000;

pub fn scoreMoves(searcher: *search.Searcher, pos: *position.Position, list: *std.ArrayList(types.Move), hashmove: types.Move) std.ArrayList(SortScore) {
    var res: std.ArrayList(SortScore) = std.ArrayList(SortScore).initCapacity(std.heap.c_allocator, list.items.len) catch unreachable;

    var hm = hashmove.to_u16();

    for (list.items) |move_| {
        var move: *const types.Move = &move_;
        var score: SortScore = 0;
        if (hm == move.to_u16()) {
            score += SortHash;
        } else if (move.is_capture()) {
            if (pos.mailbox[move.to] == types.Piece.NO_PIECE) {
                score += SortWinningCapture;
            } else {
                var see_value = see.see(pos, move.*);

                if (see_value >= 0) {
                    score += SortWinningCapture + see_value;
                } else {
                    score += SortLosingCapture + see_value;
                }
            }
        } else if (searcher.killer[searcher.ply][0].to_u16() == move.to_u16()) {
            score += SortKiller + 2000;
        } else if (searcher.killer[searcher.ply][1].to_u16() == move.to_u16()) {
            score += SortKiller + 500;
        } else if (searcher.killer[searcher.ply][2].to_u16() == move.to_u16()) {
            score += SortKiller;
        } else {
            score += -31000 + @intCast(i32, searcher.history[@enumToInt(pos.turn)][move.from][move.to]);
        }

        if (move.is_promotion()) {
            score += see.SeeWeight[move.get_flags().promote_type().index()];
        }

        res.appendAssumeCapacity(score);
    }

    return res;
}

pub fn getNextBest(list: *std.ArrayList(types.Move), evals: *std.ArrayList(SortScore), i: usize) types.Move {
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
