const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const search = @import("search.zig");
const see = @import("see.zig");

pub const SortScore = i32;

pub const MVV_LVA = [6][6]SortScore{ .{ 205, 204, 203, 202, 201, 200 }, .{ 305, 304, 303, 302, 301, 300 }, .{ 405, 404, 403, 402, 401, 400 }, .{ 505, 504, 503, 502, 501, 500 }, .{ 605, 604, 603, 602, 601, 600 }, .{ 705, 704, 703, 702, 701, 700 } };

pub const SortHash: SortScore = 6000000;
pub const SortWinningCapture: SortScore = 200000;
pub const SortLosingCapture: SortScore = -800000000;
pub const SortKiller: SortScore = 10000;
pub const SortCounterMove: SortScore = 3000;

pub fn scoreMoves(searcher: *search.Searcher, pos: *position.Position, list: *std.ArrayList(types.Move), hashmove: types.Move, is_null: bool) std.ArrayList(SortScore) {
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
                var see_value = see.see_threshold(pos, move.*, -100);

                score += MVV_LVA[pos.mailbox[move.to].piece_type().index()][pos.mailbox[move.from].piece_type().index()];

                if (see_value) {
                    score += SortWinningCapture;
                } else {
                    score += SortLosingCapture;
                }
            }
        } else {
            var last = searcher.move_history[searcher.ply - 1];
            if (searcher.killer[searcher.ply][0].to_u16() == move.to_u16()) {
                score += SortKiller + 1000;
            } else if (searcher.killer[searcher.ply][1].to_u16() == move.to_u16()) {
                score += SortKiller;
            } else {
                score += -500000001 + @intCast(i32, searcher.history[@enumToInt(pos.turn)][move.from][move.to]);
            }

            if (searcher.ply >= 1 and !is_null and searcher.counter_moves[last.from][last.to].to_u16() == move.to_u16()) {
                score += SortCounterMove;
            }
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
