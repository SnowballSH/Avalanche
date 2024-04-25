const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const search = @import("search.zig");
const see = @import("see.zig");

pub const MVV_LVA = [6][6]i32{ .{ 205, 204, 203, 202, 201, 200 }, .{ 305, 304, 303, 302, 301, 300 }, .{ 405, 404, 403, 402, 401, 400 }, .{ 505, 504, 503, 502, 501, 500 }, .{ 605, 604, 603, 602, 601, 600 }, .{ 705, 704, 703, 702, 701, 700 } };

pub const SortHash: i32 = 6_000_000;
pub const SortWinningCapture: i32 = 1_000_000;
pub const SortLosingCapture: i32 = 0;
pub const SortQuiet: i32 = 0;
pub const SortKiller1: i32 = 900_000;
pub const SortKiller2: i32 = 800_000;
pub const SortCounterMove: i32 = 600_000;

pub fn scoreMoves(searcher: *search.Searcher, pos: *position.Position, list: *std.ArrayList(types.Move), hashmove: types.Move, comptime is_null: bool) std.ArrayList(i32) {
    var res: std.ArrayList(i32) = std.ArrayList(i32).initCapacity(std.heap.c_allocator, list.items.len) catch unreachable;

    const hm = hashmove.to_u16();

    for (list.items) |move_| {
        var move: *const types.Move = &move_;
        var score: i32 = 0;
        if (move.is_promotion()) {
            if (move.get_flags().promote_type() == types.PieceType.Queen) {
                score += 1_000_000;
            } else if (move.get_flags().promote_type() == types.PieceType.Knight) {
                score += 650_000;
            }
        }
        if (hm == move.to_u16()) {
            score += SortHash;
        } else if (move.is_capture()) {
            if (pos.mailbox[move.to] == types.Piece.NO_PIECE) {
                score += SortWinningCapture + MVV_LVA[0][0];
            } else {
                const see_value = see.see_threshold(pos, move.*, -90);

                score += MVV_LVA[pos.mailbox[move.to].piece_type().index()][pos.mailbox[move.from].piece_type().index()];

                if (see_value) {
                    score += SortWinningCapture;
                    // recapture
                    // var last = if (searcher.ply > 0) searcher.move_history[searcher.ply - 1] else types.Move.empty();
                    // var last_last_last = if (searcher.ply > 2) searcher.move_history[searcher.ply - 3] else types.Move.empty();
                    // if (last.to == move.to) {
                    //     score += 30;
                    // }
                    // if (last_last_last.to == move.to) {
                    //     score += 10;
                    // }
                } else {
                    score += SortLosingCapture;
                }
            }
        } else {
            const last = if (searcher.ply > 0) searcher.move_history[searcher.ply - 1] else types.Move.empty();
            if (searcher.killer[searcher.ply][0].to_u16() == move.to_u16()) {
                score += SortKiller1;
            } else if (searcher.killer[searcher.ply][1].to_u16() == move.to_u16()) {
                score += SortKiller2;
            } else if (searcher.ply >= 1 and searcher.counter_moves[@intFromEnum(pos.turn)][last.from][last.to].to_u16() == move.to_u16()) {
                score += SortCounterMove;
            } else {
                score += SortQuiet;
                score += searcher.history[@intFromEnum(pos.turn)][move.from][move.to];
                if (!is_null and searcher.ply >= 1) {
                    const plies: [3]usize = .{ 0, 1, 3 };
                    for (plies) |plies_ago| {
                        const divider: i32 = 1;
                        if (searcher.ply >= plies_ago + 1) {
                            const prev = searcher.move_history[searcher.ply - plies_ago - 1];
                            if (prev.to_u16() == 0) continue;

                            score += @divTrunc(searcher.continuation[searcher.moved_piece_history[searcher.ply - plies_ago - 1].pure_index()][prev.to][move.from][move.to], divider);
                        }
                    }
                }
            }
        }

        res.appendAssumeCapacity(score);
    }

    return res;
}

pub inline fn getNextBest(list: *std.ArrayList(types.Move), evals: *std.ArrayList(i32), i: usize) types.Move {
    const move_size = list.items.len;
    var j = i + 1;
    while (j < move_size) : (j += 1) {
        if (evals.items[i] < evals.items[j]) {
            std.mem.swap(types.Move, &list.items[i], &list.items[j]);
            std.mem.swap(i32, &evals.items[i], &evals.items[j]);
        }
    }
    return list.items[i];
}
