const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("./hce.zig");
const tt = @import("./tt.zig");
const movepick = @import("./movepick.zig");

pub const QuietLMR: [64][64]i32 = init: {
    @setEvalBranchQuota(64 * 64 * 6);
    var reductions: [64][64]i32 = undefined;
    var depth = 1;
    inline while (depth < 64) : (depth += 1) {
        var moves = 1;
        inline while (moves < 64) : (moves += 1) {
            reductions[depth][moves] = @floatToInt(i32, @floor(0.45 + std.math.ln(@intToFloat(f32, depth)) * std.math.ln(@intToFloat(f32, moves)) / 2.60));
        }
    }
    break :init reductions;
};

pub const MAX_PLY = 128;
pub const MAX_GAMEPLY = 512;

pub const Searcher = struct {
    max_millis: u64 = 0,
    timer: std.time.Timer = undefined,

    nodes: u64 = 0,
    ply: u32 = 0,
    stop: bool = false,
    is_searching: bool = false,

    hash_history: std.ArrayList(u64) = undefined,
    eval_history: [MAX_PLY]hce.Score = undefined,

    best_move: types.Move = undefined,
    pv: [MAX_PLY][MAX_PLY]types.Move = undefined,
    pv_size: [MAX_PLY]usize = undefined,

    killer: [MAX_PLY][2]types.Move = undefined,
    history: [2][64][64]u32 = undefined,

    pub fn new() Searcher {
        var s = Searcher{};

        s.hash_history = std.ArrayList(u64).initCapacity(std.heap.c_allocator, MAX_GAMEPLY) catch unreachable;
        s.reset_heuristics();

        return s;
    }

    pub fn reset_heuristics(self: *Searcher) void {
        {
            var i: usize = 0;
            while (i < MAX_PLY) : (i += 1) {
                self.killer[i][0] = types.Move.empty();
                self.killer[i][1] = types.Move.empty();
            }
        }

        {
            var i: usize = 0;
            while (i < 2) : (i += 1) {
                var j: usize = 0;
                while (j < 64) : (j += 1) {
                    var k: usize = 0;
                    while (k < 64) : (k += 1) {
                        self.history[i][j][k] = 0;
                    }
                }
            }
        }

        {
            var j: usize = 0;
            while (j < MAX_PLY) : (j += 1) {
                var k: usize = 0;
                while (k < MAX_PLY) : (k += 1) {
                    self.pv[j][k] = types.Move.empty();
                }
                self.pv_size[j] = 0;
                self.eval_history[j] = 0;
            }
        }
    }

    pub inline fn should_stop(self: *Searcher) bool {
        return self.stop or self.timer.read() / std.time.ns_per_ms > self.max_millis + 3;
    }

    pub fn iterative_deepening(self: *Searcher, pos: *position.Position, comptime color: types.Color, max_depth: ?u8) hce.Score {
        var out = std.io.bufferedWriter(std.io.getStdOut().writer());
        var outW = out.writer();
        self.stop = false;
        self.is_searching = true;
        self.reset_heuristics();
        self.nodes = 0;

        self.timer = std.time.Timer.start() catch unreachable;

        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var depth: usize = 1;
        var bound: usize = if (max_depth == null) MAX_PLY - 1 else max_depth.?;
        while (depth <= bound) : (depth += 1) {
            self.ply = 0;

            var val = self.negamax(pos, color, depth, -hce.MateScore, hce.MateScore, false);

            if (self.should_stop()) {
                break;
            }

            score = val;
            bm = self.best_move;

            outW.print("info depth {} nodes {} time {} score ", .{
                depth,
                self.nodes,
                self.timer.read() / std.time.ns_per_ms,
            }) catch {};

            if ((std.math.absInt(score) catch 0) >= (hce.MateScore - hce.MaxMate)) {
                outW.print("mate {} pv", .{
                    (@divFloor(hce.MateScore - (std.math.absInt(score) catch 0), 2) + 1) * @as(hce.Score, if (score > 0) 1 else -1),
                }) catch {};
                if (bound == MAX_PLY - 1) {
                    bound = depth + 2;
                }
            } else {
                outW.print("cp {} pv", .{
                    score,
                }) catch {};
            }

            if (self.pv_size[0] > 0) {
                var i: usize = 0;
                while (i < self.pv_size[0]) : (i += 1) {
                    outW.writeByte(' ') catch {};
                    self.pv[0][i].uci_print(outW);
                }
            } else {
                outW.writeByte(' ') catch {};
                bm.uci_print(outW);
            }

            outW.writeByte('\n') catch {};
            out.flush() catch {};
        }

        outW.print("info depth {} nodes {} time {} score ", .{
            depth,
            self.nodes,
            self.timer.read() / std.time.ns_per_ms,
        }) catch {};

        if (std.math.absInt(score) catch 0 >= (hce.MateScore - hce.MaxMate)) {
            outW.print("mate {} pv", .{
                (@divFloor(hce.MateScore - (std.math.absInt(score) catch 0), 2) + 1) * @as(hce.Score, if (score > 0) 1 else -1),
            }) catch {};
        } else {
            outW.print("cp {} pv", .{
                score,
            }) catch {};
        }

        if (self.pv_size[0] > 0) {
            var i: usize = 0;
            while (i < self.pv_size[0]) : (i += 1) {
                outW.writeByte(' ') catch {};
                self.pv[0][i].uci_print(outW);
            }
        } else {
            outW.writeByte(' ') catch {};
            bm.uci_print(outW);
        }

        outW.writeAll("\nbestmove ") catch {};
        bm.uci_print(outW);
        outW.writeByte('\n') catch {};
        out.flush() catch {};

        self.is_searching = false;

        tt.GlobalTT.clear();

        return score;
    }

    pub fn is_draw(self: *Searcher, pos: *position.Position) bool {
        if (pos.history[pos.game_ply].fifty >= hce.MaxMate) {
            return true;
        }

        if (hce.is_material_draw(pos)) {
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

    pub fn negamax(self: *Searcher, pos: *position.Position, comptime color: types.Color, depth_: usize, alpha_: hce.Score, beta_: hce.Score, comptime is_null: bool) hce.Score {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;
        comptime var opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        var is_root = self.ply == 0;

        self.nodes += 1;
        self.pv_size[self.ply] = 0;

        if (self.ply == MAX_PLY) {
            return hce.evaluate(pos);
        }

        if (!is_root) {
            if (self.is_draw(pos)) {
                return 0;
            }

            // Mate-distance pruning

            alpha = @maximum(alpha, -hce.MateScore + @intCast(hce.Score, self.ply));
            beta = @minimum(beta, hce.MateScore - @intCast(hce.Score, self.ply) - 1);
            if (alpha >= beta) {
                return alpha;
            }
        }

        var in_check = pos.in_check(color);

        if (in_check) {
            depth += 1;
        }

        var on_pv: bool = beta - alpha > 1;

        var hashmove = types.Move.empty();
        var tthit = false;
        var tt_eval: hce.Score = 0;
        var entry = tt.GlobalTT.get(pos.hash, depth);

        if (entry != null and !in_check) {
            tthit = true;
            tt_eval = entry.?.eval;
            if (tt_eval > hce.MateScore - 100 and tt_eval <= hce.MateScore) {
                tt_eval -= 100;
            } else if (tt_eval < -hce.MateScore + 100 and tt_eval >= -hce.MateScore) {
                tt_eval += 100;
            }
            hashmove = entry.?.bestmove;

            if (pos.history[pos.game_ply].fifty < 90 and (depth == 0 or !on_pv)) {
                switch (entry.?.flag) {
                    .Exact => {
                        return tt_eval;
                    },
                    .Lower => {
                        alpha = @maximum(alpha, tt_eval);
                    },
                    .Upper => {
                        beta = @minimum(beta, tt_eval);
                    },
                    else => {},
                }
                if (alpha >= beta) {
                    return tt_eval;
                }
            }
        }

        if (self.should_stop()) {
            return 0;
        }

        if (depth == 0) {
            self.nodes -= 1;
            return self.quiescence_search(pos, color, alpha, beta);
        }

        var static_eval: hce.Score = if (in_check) -hce.MateScore + @intCast(i32, self.ply) else if (is_null) -self.eval_history[self.ply - 1] else hce.evaluate(pos);
        var best_score: hce.Score = static_eval;

        self.eval_history[self.ply] = static_eval;

        // Prunings
        if (!in_check and !on_pv) {
            // Razoring
            if (depth <= 1 and static_eval + 250 < alpha) {
                return self.quiescence_search(pos, color, alpha, beta);
            }

            // Static nmp
            if (depth <= 8 and best_score - @intCast(hce.Score, 90 * depth) > beta) {
                return best_score;
            }

            // Null move pruning
            if (!is_null and depth >= 2 and best_score >= beta and (!tthit or entry.?.flag != tt.Bound.Upper or tt_eval >= beta) and pos.has_non_pawns()) {
                var r = 4 + depth / 4 + @intCast(usize, @minimum(3, @divFloor(best_score - beta, 128)));

                if (r >= depth) {
                    r = depth - 1;
                }

                pos.play_null_move();
                var null_score = -self.negamax(pos, opp_color, depth - r, -beta, -beta + 1, true);
                pos.undo_null_move();

                if (null_score >= beta) {
                    if (hce.is_near_mate(null_score)) {
                        return beta;
                    }
                    return null_score;
                }
            }
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
                return -hce.MateScore + @intCast(hce.Score, self.ply);
            } else {
                // Stalemate
                return 0;
            }
        }

        var evallist = movepick.score_moves(self, pos, &movelist, hashmove);
        defer evallist.deinit();

        var best_move = types.Move.empty();
        best_score = -hce.MateScore + @intCast(hce.Score, self.ply);

        var skip_quiet = false;

        var index: usize = 0;
        while (index < move_size) : (index += 1) {
            var move = movepick.get_next_best(&movelist, &evallist, index);

            var is_capture = move.is_capture();

            if (skip_quiet and !is_capture) {
                continue;
            }

            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};

            var new_depth = depth - 1;

            var score: hce.Score = 0;
            if (index == 0) {
                score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false);
            } else {
                // LMR
                var reduction: i32 = 0;

                if (depth >= 3 and !is_capture and index > 2 * @intCast(usize, @boolToInt(is_root))) {
                    reduction = QuietLMR[@minimum(depth, 63)][@minimum(index, 63)];

                    if (on_pv) {
                        reduction -= 2;
                    }

                    if (move.to_u16() == self.killer[self.ply][0].to_u16() or move.to_u16() == self.killer[self.ply][1].to_u16()) {
                        reduction -= 1;
                    }

                    if (reduction >= new_depth) {
                        reduction = @intCast(i32, new_depth - 1);
                    } else if (reduction < 0) {
                        reduction = 0;
                    }
                }

                score = -self.negamax(pos, opp_color, new_depth - @intCast(usize, reduction), -alpha - 1, -alpha, false);

                if (score > alpha and reduction > 0) {
                    score = -self.negamax(pos, opp_color, new_depth, -alpha - 1, -alpha, false);
                }
                if (score > alpha and score < beta) {
                    score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false);
                }
            }

            self.ply -= 1;
            pos.undo_move(color, move);
            _ = self.hash_history.pop();

            if (self.should_stop()) {
                return 0;
            }

            if (score > best_score) {
                best_score = score;
                best_move = move;
                if (score > alpha) {
                    alpha = score;
                    tt_flag = tt.Bound.Exact;

                    self.pv[self.ply][0] = move;
                    std.mem.copy(types.Move, self.pv[self.ply][1..(self.pv_size[self.ply + 1] + 1)], self.pv[self.ply + 1][0..(self.pv_size[self.ply + 1])]);
                    self.pv_size[self.ply] = self.pv_size[self.ply + 1] + 1;

                    if (is_root) {
                        self.best_move = move;
                    }
                    if (alpha >= beta) {
                        tt_flag = tt.Bound.Lower;
                        if (!is_capture) {
                            var temp = self.killer[self.ply][0];
                            self.killer[self.ply][0] = move;
                            self.killer[self.ply][1] = temp;

                            self.history[@enumToInt(color)][move.from][move.to] = @minimum(self.history[@enumToInt(color)][move.from][move.to] + @intCast(u32, depth * depth), 2000000000);
                        }
                        break;
                    }
                }
            }
        }

        if (!skip_quiet) {
            tt.GlobalTT.set(tt.Item{
                .eval = best_score,
                .bestmove = best_move,
                .flag = tt_flag,
                .depth = @intCast(u14, depth),
                .hash = pos.hash,
            });
        }

        return alpha;
    }

    pub fn quiescence_search(self: *Searcher, pos: *position.Position, comptime color: types.Color, alpha_: hce.Score, beta_: hce.Score) hce.Score {
        var alpha = alpha_;
        var beta = beta_;
        comptime var opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        self.nodes += 1;
        self.pv_size[self.ply] = 0;

        if (hce.is_material_draw(pos)) {
            return 0;
        }

        if (self.ply == MAX_PLY) {
            return hce.evaluate(pos);
        }

        var in_check = pos.in_check(color);

        // Stand Pat pruning
        var best_score = -hce.MateScore + @intCast(hce.Score, self.ply);
        if (!in_check) {
            best_score = hce.evaluate(pos);

            if (best_score + 1000 <= alpha) {
                return best_score;
            }

            if (best_score >= beta) {
                return beta;
            }
            if (best_score > alpha) {
                alpha = best_score;
            }
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

        var evallist = movepick.score_moves(self, pos, &movelist, types.Move.empty());
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

            if (score > best_score) {
                best_score = score;
                if (score > alpha) {
                    self.pv[self.ply][0] = move;
                    std.mem.copy(types.Move, self.pv[self.ply][1..(self.pv_size[self.ply + 1] + 1)], self.pv[self.ply + 1][0..(self.pv_size[self.ply + 1])]);
                    self.pv_size[self.ply] = self.pv_size[self.ply + 1] + 1;

                    alpha = score;
                }
            }

            if (alpha >= beta) {
                alpha = beta;
                break;
            }
        }

        return alpha;
    }
};
