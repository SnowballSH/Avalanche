const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("./hce.zig");
const tt = @import("./tt.zig");

pub const MAX_PLY = 100;

pub const Searcher = struct {
    max_millis: u64,
    timer: std.time.Timer,

    nodes: u64,
    ply: u32,

    best_move: types.Move,

    pub fn new() Searcher {
        var s = std.mem.zeroes(Searcher);

        return s;
    }

    pub inline fn should_stop(self: *Searcher) bool {
        return self.timer.read() / std.time.ns_per_ms > self.max_millis;
    }

    pub fn iterative_deepening(self: *Searcher, pos: *position.Position, comptime color: types.Color) hce.Score {
        var out = std.io.getStdOut().writer();

        self.timer = std.time.Timer.start() catch unreachable;

        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var depth: usize = 1;
        while (depth < MAX_PLY) : (depth += 1) {
            self.ply = 0;

            var val = self.negamax(pos, color, depth, -hce.MateScore, hce.MateScore);

            if (self.should_stop()) {
                depth -= 1;
                break;
            }

            score = val;
            bm = self.best_move;

            out.print("info depth {} nodes {} time {} cp {} pv ", .{
                depth,
                self.nodes,
                self.timer.read() / std.time.ns_per_ms,
                score,
            }) catch {};
            bm.debug_print();
            out.writeByte('\n') catch {};
        }

        out.print("info depth {} nodes {} time {} cp {} pv ", .{
            depth,
            self.nodes,
            self.timer.read() / std.time.ns_per_ms,
            score,
        }) catch {};
        bm.debug_print();
        out.writeAll("\nbestmove ") catch {};
        bm.debug_print();
        out.writeByte('\n') catch {};

        return score;
    }

    pub fn negamax(self: *Searcher, pos: *position.Position, comptime color: types.Color, depth_: usize, alpha_: hce.Score, beta_: hce.Score) hce.Score {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;
        comptime var opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        var is_root = self.ply == 0;

        self.nodes += 1;

        if (self.ply == MAX_PLY) {
            return hce.evaluate(pos);
        }

        if (pos.in_check(color)) {
            depth += 1;
        }

        var entry = tt.GlobalTT.get(pos.hash, depth);
        if (entry != null) {
            switch (entry.?.flag) {
                .Exact => {
                    return entry.?.eval;
                },
                .Lower => {
                    alpha = @maximum(alpha, entry.?.eval);
                },
                .Upper => {
                    beta = @minimum(beta, entry.?.eval);
                },
                else => {},
            }
            if (alpha >= beta) {
                return entry.?.eval;
            }
        }

        if (depth == 0) {
            return self.quiescence_search(pos, color, alpha, beta);
        }

        if (self.should_stop()) {
            return 0;
        }

        // Search
        var tt_flag = tt.Bound.Upper;

        var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 8) catch unreachable;
        pos.generate_legal_moves(color, &movelist);

        if (movelist.items.len == 0) {
            if (pos.in_check(color)) {
                // Checkmate
                return -hce.MateScore + @intCast(i32, self.ply);
            } else {
                // Stalemate
                return 0;
            }
        }

        var best_move = types.Move.empty();

        for (movelist.items) |move| {
            self.ply += 1;
            pos.play_move(color, move);
            var score = -self.negamax(pos, opp_color, depth - 1, -beta, -alpha);
            self.ply -= 1;
            pos.undo_move(color, move);

            if (self.should_stop()) {
                return 0;
            }

            if (score > alpha) {
                best_move = move;
                if (is_root) {
                    self.best_move = move;
                }
                if (score >= beta) {
                    tt_flag = tt.Bound.Lower;
                    alpha = beta;
                    break;
                }
                alpha = score;
                tt_flag = tt.Bound.Exact;
            }
        }

        tt.GlobalTT.set(tt.Item{
            .eval = alpha,
            .bestmove = best_move,
            .flag = tt_flag,
            .depth = @intCast(u14, depth),
            .hash = pos.hash,
        });

        return alpha;
    }

    pub fn quiescence_search(self: *Searcher, pos: *position.Position, comptime color: types.Color, alpha_: hce.Score, beta_: hce.Score) hce.Score {
        var alpha = alpha_;
        var beta = beta_;
        comptime var opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        self.nodes += 1;

        if (self.ply == MAX_PLY) {
            return hce.evaluate(pos);
        }

        if (self.should_stop()) {
            return 0;
        }

        var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 2) catch unreachable;
        pos.generate_q_moves(color, &movelist);

        var eval = hce.evaluate(pos);

        if (eval >= beta) {
            return beta;
        }
        alpha = @maximum(alpha, eval);

        for (movelist.items) |move| {
            // std.debug.assert(move.flags & @enumToInt(types.MoveFlags.CAPTURES) != 0);
            self.ply += 1;
            pos.play_move(color, move);
            var score = -self.quiescence_search(pos, opp_color, -beta, -alpha);
            self.ply -= 1;
            pos.undo_move(color, move);

            if (self.should_stop()) {
                return 0;
            }

            if (score > alpha) {
                if (score >= beta) {
                    alpha = beta;
                    break;
                }
                alpha = score;
            }
        }

        return alpha;
    }
};
