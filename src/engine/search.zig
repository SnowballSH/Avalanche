const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("./hce.zig");
const tt = @import("./tt.zig");
const movepick = @import("./movepick.zig");

pub const MAX_PLY = 100;

pub const Searcher = struct {
    max_millis: u64 = 0,
    timer: std.time.Timer = undefined,

    nodes: u64 = 0,
    ply: u32 = 0,
    stop: bool = false,
    is_searching: bool = false,

    hash_history: std.ArrayList(u64) = undefined,

    best_move: types.Move = undefined,

    killer: [MAX_PLY][2]types.Move = undefined,

    pub fn new() Searcher {
        var s = Searcher{};

        s.hash_history = std.ArrayList(u64).init(std.heap.c_allocator);

        return s;
    }

    pub inline fn should_stop(self: *Searcher) bool {
        return self.stop or self.timer.read() / std.time.ns_per_ms > self.max_millis + 3;
    }

    pub fn iterative_deepening(self: *Searcher, pos: *position.Position, comptime color: types.Color, max_depth: ?u8) hce.Score {
        var out = std.io.bufferedWriter(std.io.getStdOut().writer());
        var outW = out.writer();
        self.stop = false;
        self.is_searching = true;

        self.timer = std.time.Timer.start() catch unreachable;

        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var depth: usize = 1;
        var bound: usize = if (max_depth == null) MAX_PLY - 1 else max_depth.?;
        while (depth <= bound) : (depth += 1) {
            self.ply = 0;

            var val = self.negamax(pos, color, depth, -hce.MateScore, hce.MateScore);

            if (self.should_stop()) {
                break;
            }

            score = val;
            bm = self.best_move;

            outW.print("info depth {} nodes {} time {} score cp {} pv ", .{
                depth,
                self.nodes,
                self.timer.read() / std.time.ns_per_ms,
                score,
            }) catch {};
            bm.uci_print(outW);
            outW.writeByte('\n') catch {};
            out.flush() catch {};
        }

        outW.print("info depth {} nodes {} time {} score cp {} pv ", .{
            depth - 1,
            self.nodes,
            self.timer.read() / std.time.ns_per_ms,
            score,
        }) catch {};
        bm.uci_print(outW);
        outW.writeAll("\nbestmove ") catch {};
        bm.uci_print(outW);
        outW.writeByte('\n') catch {};
        out.flush() catch {};

        self.is_searching = false;

        tt.GlobalTT.clear();

        return score;
    }

    pub fn is_draw(self: *Searcher, pos: *position.Position) bool {
        if (pos.history[pos.game_ply].fifty >= 100) {
            return true;
        }

        if (std.mem.len(self.hash_history.items) > 1) {
            var index: i16 = @intCast(i16, std.mem.len(self.hash_history.items)) - 3;
            var limit: i16 = index - @intCast(i16, pos.history[pos.game_ply].fifty) - 1;
            var count: u8 = 0;
            while (index >= limit and index >= 0) {
                if (self.hash_history.items[@intCast(usize, index)] == pos.hash) {
                    count += 1;
                    return true;
                }
                index -= 2;
            }
        }

        return false;
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

        if (!is_root) {
            if (self.is_draw(pos)) {
                return 0;
            }

            // Mate-distance pruning

            var r_alpha = if (alpha > -hce.MateScore + @intCast(i32, self.ply)) alpha else -hce.MateScore + @intCast(i32, self.ply);
            var r_beta = if (beta < hce.MateScore - @intCast(i32, self.ply) - 1) beta else hce.MateScore - @intCast(i32, self.ply) - 1;

            if (r_alpha >= r_beta) {
                return r_alpha;
            }
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
        defer movelist.deinit();
        pos.generate_legal_moves(color, &movelist);
        var move_size = movelist.items.len;

        self.killer[self.ply + 1][0] = types.Move.empty();
        self.killer[self.ply + 1][1] = types.Move.empty();

        if (move_size == 0) {
            if (pos.in_check(color)) {
                // Checkmate
                return -hce.MateScore + @intCast(i32, self.ply);
            } else {
                // Stalemate
                return 0;
            }
        }

        var evallist = movepick.score_moves(self, pos, &movelist);
        defer evallist.deinit();

        var best_move = types.Move.empty();

        var index: usize = 0;

        while (index < move_size) : (index += 1) {
            var move = movepick.get_next_best(&movelist, &evallist, index);

            var is_capture = move.is_capture();

            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};
            var score = -self.negamax(pos, opp_color, depth - 1, -beta, -alpha);
            self.ply -= 1;
            pos.undo_move(color, move);
            _ = self.hash_history.pop();

            if (self.should_stop()) {
                return 0;
            }

            if (score > alpha) {
                best_move = move;
                alpha = score;
                tt_flag = tt.Bound.Exact;

                if (is_root) {
                    self.best_move = move;
                }
                if (alpha >= beta) {
                    tt_flag = tt.Bound.Lower;
                    if (!is_capture) {
                        var temp = self.killer[self.ply][0];
                        self.killer[self.ply][0] = move;
                        self.killer[self.ply][1] = temp;
                    }
                    break;
                }
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
        defer movelist.deinit();
        pos.generate_q_moves(color, &movelist);
        var move_size = movelist.items.len;

        var eval = hce.evaluate(pos);

        if (eval >= beta) {
            return beta;
        }
        alpha = @maximum(alpha, eval);

        var evallist = movepick.score_moves(self, pos, &movelist);
        defer evallist.deinit();

        var index: usize = 0;

        while (index < move_size) : (index += 1) {
            var move = movepick.get_next_best(&movelist, &evallist, index);

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
