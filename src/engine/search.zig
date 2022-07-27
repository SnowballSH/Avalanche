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
    while (depth < 64) : (depth += 1) {
        var moves = 1;
        while (moves < 64) : (moves += 1) {
            reductions[depth][moves] = @floatToInt(i32, @floor(0.75 + std.math.ln(@intToFloat(f32, depth)) * std.math.ln(@intToFloat(f32, moves)) / 2.25));
        }
    }
    break :init reductions;
};

pub const MAX_PLY = 128;
pub const MAX_GAMEPLY = 1024;

pub const Searcher = struct {
    max_millis: u64 = 0,
    timer: std.time.Timer = undefined,

    time_stop: bool = false,

    nodes: u64 = 0,
    ply: u32 = 0,
    stop: bool = false,
    is_searching: bool = false,

    exclude_move: [MAX_PLY]types.Move = undefined,

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

                self.exclude_move[i] = types.Move.empty();
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

    pub fn should_stop(self: *Searcher) bool {
        return self.stop or self.timer.read() / std.time.ns_per_ms > self.max_millis + 3;
    }

    pub fn iterative_deepening(self: *Searcher, pos: *position.Position, comptime color: types.Color, max_depth: ?u8) hce.Score {
        const aspiration_window: hce.Score = 25;

        var out = std.io.bufferedWriter(std.io.getStdOut().writer());
        var outW = out.writer();
        self.stop = false;
        self.is_searching = true;
        self.time_stop = false;
        self.reset_heuristics();
        self.nodes = 0;
        self.best_move = types.Move.empty();

        self.timer = std.time.Timer.start() catch unreachable;

        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var alpha = -hce.MateScore;
        var beta = hce.MateScore;

        var depth: usize = 1;
        var bound: usize = if (max_depth == null) MAX_PLY - 2 else max_depth.?;
        while (depth <= bound) {
            self.ply = 0;

            var val = self.negamax(pos, color, depth, alpha, beta, false, tt.Bound.Exact);

            if (self.time_stop or self.should_stop()) {
                break;
            }

            score = val;

            if (score <= alpha) {
                alpha = -hce.MateScore;
            } else if (score >= beta) {
                beta = hce.MateScore;
            } else {
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

                alpha = score - aspiration_window;
                beta = score + aspiration_window;

                depth += 1;
            }
        }

        self.best_move = bm;

        outW.writeAll("bestmove ") catch {};
        bm.uci_print(outW);
        outW.writeByte('\n') catch {};
        out.flush() catch {};

        self.is_searching = false;

        return score;
    }

    pub fn is_draw(self: *Searcher, pos: *position.Position) bool {
        if (pos.history[pos.game_ply].fifty >= 100) {
            return true;
        }

        if (hce.is_material_draw(pos)) {
            return true;
        }

        if (self.hash_history.items.len > 1) {
            var index: i16 = @intCast(i16, self.hash_history.items.len) - 3;
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

    pub fn negamax(self: *Searcher, pos: *position.Position, comptime color: types.Color, depth_: usize, alpha_: hce.Score, beta_: hce.Score, comptime is_null: bool, expected_bound: tt.Bound) hce.Score {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;
        comptime var opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        // >> Step 1: Preparations

        // Step 1.1: Stop if time is up
        if (self.nodes & 1023 == 0 and self.should_stop()) {
            self.time_stop = true;
            return 0;
        }

        var is_root = self.ply == 0;

        self.pv_size[self.ply] = 0;

        // Step 1.2: Prefetch
        if (depth != 0) {
            tt.GlobalTT.prefetch(pos.hash);
        }

        // Step 1.3: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return hce.evaluate(pos);
        }

        // Step 1.4: Mate-distance pruning
        if (!is_root) {
            var r_alpha = @maximum(-hce.MateScore + @intCast(hce.Score, self.ply), alpha);
            var r_beta = @minimum(hce.MateScore - @intCast(hce.Score, self.ply) - 1, beta);

            if (r_alpha >= r_beta) {
                return r_alpha;
            }
        }

        var in_check = pos.in_check(color);

        // Step 4.1: Check Extension (moved up)
        if (in_check) {
            depth += 1;
        }

        // Step 1.5: Go to Quiescence Search at Horizon
        if (depth == 0) {
            return self.quiescence_search(pos, color, alpha, beta);
        }

        self.nodes += 1;

        // Step 1.6: Draw check
        if (!is_root and self.is_draw(pos)) {
            return 0;
        }

        var on_pv: bool = beta - alpha > 1;

        // >> Step 2: TT Probe
        var hashmove = types.Move.empty();
        var tthit = false;
        var tt_eval: hce.Score = 0;
        var entry = tt.GlobalTT.get(pos.hash, depth);

        if (entry != null and !in_check) {
            tthit = true;
            tt_eval = entry.?.eval;
            if (tt_eval > hce.MateScore - 50 and tt_eval <= hce.MateScore) {
                tt_eval -= @intCast(hce.Score, self.ply);
            } else if (tt_eval < -hce.MateScore + 50 and tt_eval >= -hce.MateScore) {
                tt_eval += @intCast(hce.Score, self.ply);
            }
            hashmove = entry.?.bestmove;
            if (is_root) {
                self.best_move = hashmove;
            }

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

        var static_eval: hce.Score = if (in_check) -hce.MateScore + @intCast(i32, self.ply) else if (is_null) -self.eval_history[self.ply - 1] else hce.evaluate(pos);
        var best_score: hce.Score = static_eval;

        var high_estimate = if (!tthit or entry.?.flag == tt.Bound.Upper) static_eval else entry.?.eval;

        var low_estimate: hce.Score = -hce.MateScore - 1;

        self.eval_history[self.ply] = high_estimate;

        var improving = (!(self.ply <= 1 or in_check) and high_estimate > self.eval_history[self.ply - 2]);

        // >> Step 3: Prunings
        if (!in_check and !on_pv) {
            low_estimate = if (!tthit or entry.?.flag == tt.Bound.Lower) static_eval else entry.?.eval;

            // Step 3.1: Razoring
            if (depth <= 1 and high_estimate + 250 < alpha) {
                return self.quiescence_search(pos, color, alpha, beta);
            }

            // Step 3.2: Reverse Futility Pruning
            if (depth <= 6) {
                var n = @intCast(hce.Score, depth);
                if (depth >= 2 and improving) {
                    n -= 1;
                }
                if (high_estimate - 50 * n >= beta) {
                    return beta;
                }
            }

            // Step 3.3: Null move pruning
            if (!is_null and depth >= 2 and high_estimate >= beta and (!tthit or entry.?.flag != tt.Bound.Upper or entry.?.eval >= beta) and pos.has_non_pawns()) {
                // var r: usize = 3;
                var r = 4 + depth / 4;

                if (r >= depth) {
                    r = depth - 1;
                }

                pos.play_null_move();
                var null_score = -self.negamax(pos, opp_color, depth - r, -beta, -beta + 1, true, tt.Bound.Upper);
                pos.undo_null_move();

                if (self.time_stop) {
                    return 0;
                }

                if (null_score >= beta) {
                    return null_score;
                }
            }
        }

        // >> Step 4: Extensions (moved to other places)

        // >> Step 5: Search
        var tt_flag = tt.Bound.Upper;

        // Step 5.1: Move Generation
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

        var expected_child = switch (expected_bound) {
            .None => tt.Bound.None,
            .Upper => tt.Bound.Lower,
            .Lower => tt.Bound.Upper,
            .Exact => tt.Bound.Exact,
        };
        var raised_alpha = false;

        // Step 5.2: Move Ordering
        var evallist = movepick.scoreMoves(self, pos, &movelist, hashmove);
        defer evallist.deinit();

        // Step 5.3: Move Iteration
        var best_move = types.Move.empty();
        best_score = -hce.MateScore + @intCast(hce.Score, self.ply);

        var skip_quiet = false;

        var index: usize = 0;
        while (index < move_size) : (index += 1) {
            var move = movepick.getNextBest(&movelist, &evallist, index);
            if (move.to_u16() == self.exclude_move[self.ply].to_u16()) {
                continue;
            }

            var is_capture = move.is_capture();

            if (skip_quiet and !is_capture) {
                continue;
            }

            // Step 5.4: Futility Pruning
            if (!on_pv and expected_bound != tt.Bound.Exact and index > 0 and depth <= 7 and !is_capture and alpha > -hce.MateScore and low_estimate != -hce.MateScore - 1 and low_estimate + @intCast(i32, depth) * 100 < alpha) {
                skip_quiet = true;
                continue;
            }

            var new_depth = depth - 1;

            // Step 4.2: Singular extension
            // zig fmt: off
            if (self.ply > 0
                and depth >= 8
                and expected_bound != tt.Bound.Upper
                and !in_check
                and tthit
                and !hce.is_near_mate(entry.?.eval)
                and hashmove.to_u16() == move.to_u16()
                and entry.?.depth >= depth - 3
                and (
                    entry.?.flag == tt.Bound.Exact
                    or entry.?.flag == tt.Bound.Lower
                )
            ) {
            // zig fmt: on
                var margin = @intCast(i32, depth);
                self.exclude_move[self.ply] = hashmove;
                var singular_score = self.negamax(pos, color, depth / 2, entry.?.eval - margin - 1, entry.?.eval - margin, false, expected_bound);
                self.exclude_move[self.ply] = types.Move.empty();
                if (singular_score >= entry.?.eval - margin) {
                    if (entry.?.eval - margin >= beta) {
                        return entry.?.eval - margin;
                    }
                } else {
                    new_depth += 1;
                }
            }

            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};

            if (expected_bound == tt.Bound.Exact and raised_alpha) {
                expected_child = tt.Bound.Lower;
            }

            var score: hce.Score = 0;
            if (index == 0) {
                score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, expected_child);
            } else {
                // Step 5.5: Late-Move Reduction
                var reduction: i32 = 0;

                if (depth >= 2 and !is_capture and index >= 2 * @intCast(usize, @boolToInt(is_root))) {
                    reduction = QuietLMR[@minimum(depth, 63)][@minimum(index, 63)];

                    if (on_pv) {
                        reduction -= 1;
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

                // Step 5.6: Principal-Variation-Search (PVS)
                score = -self.negamax(pos, opp_color, new_depth - @intCast(usize, reduction), -alpha - 1, -alpha, false, expected_child);

                if (score > alpha and reduction > 0) {
                    score = -self.negamax(pos, opp_color, new_depth, -alpha - 1, -alpha, false, expected_child);
                }
                if (score > alpha and score < beta) {
                    score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, expected_child);
                }
            }

            self.ply -= 1;
            pos.undo_move(color, move);
            _ = self.hash_history.pop();

            if (self.time_stop) {
                return 0;
            }

            // Step 5.7: Alpha-Beta Pruning
            if (score > best_score) {
                best_score = score;
                best_move = move;

                self.pv[self.ply][0] = move;
                std.mem.copy(types.Move, self.pv[self.ply][1..(self.pv_size[self.ply + 1] + 1)], self.pv[self.ply + 1][0..(self.pv_size[self.ply + 1])]);
                self.pv_size[self.ply] = self.pv_size[self.ply + 1] + 1;
            }

            if (score > alpha) {
                raised_alpha = true;
                alpha = score;

                if (is_root) {
                    self.best_move = move;
                }
            }

            if (alpha >= beta) {
                if (!is_capture) {
                    var temp = self.killer[self.ply][0];
                    self.killer[self.ply][0] = move;
                    self.killer[self.ply][1] = temp;

                    self.history[@enumToInt(color)][move.from][move.to] += @intCast(u32, depth * depth);

                    if (self.history[@enumToInt(color)][move.from][move.to] >= 30000) {
                        for (self.history) |*a| {
                            for (a) |*b| {
                                for (b) |*c| {
                                    c.* = @divFloor(c.*, 2);
                                }
                            }
                        }
                    }
                }
                break;
            }
        }

        // >> Step 7: Transposition Table Update
        if (!skip_quiet) {
            if (alpha > beta) {
                tt_flag = tt.Bound.Lower;
            } else if (!raised_alpha) {
                tt_flag = tt.Bound.Upper;
            } else if (alpha == beta and (index != move_size or hce.is_near_mate(best_score))) {
                tt_flag = tt.Bound.Lower;
            } else {
                tt_flag = tt.Bound.Exact;
            }

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

        // >> Step 1: Preparation

        // Step 1.1: Stop if time is up
        if (self.nodes & 1023 == 0 and self.should_stop()) {
            self.time_stop = true;
            return 0;
        }

        self.nodes += 1;
        self.pv_size[self.ply] = 0;

        // Step 1.2: Material Draw Check
        if (hce.is_material_draw(pos)) {
            return 0;
        }

        // Step 1.3: Prefetch
        // tt.GlobalTT.prefetch(pos.hash);

        // Step 1.4: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return hce.evaluate(pos);
        }

        var in_check = pos.in_check(color);

        // >> Step 2: Prunings

        var best_score = -hce.MateScore + @intCast(hce.Score, self.ply);
        var static_eval = hce.evaluate(pos);
        if (!in_check) {
            best_score = static_eval;

            // Step 2.1: Delta pruning
            if (best_score + 1000 <= alpha) {
                return best_score;
            }

            // Step 2.2: Stand Pat pruning
            if (best_score >= beta) {
                return beta;
            }
            if (best_score > alpha) {
                alpha = best_score;
            }
        }

        if (static_eval >= beta) {
            return beta;
        }
        alpha = @maximum(alpha, static_eval);

        // >> Step 3: TT Probe
        var hashmove = types.Move.empty();
        var entry = tt.GlobalTT.get(pos.hash, 0);

        if (entry != null) {
            hashmove = entry.?.bestmove;
        }

        // >> Step 4: QSearch

        // Step 4.1: Q Move Generation
        var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 2) catch unreachable;
        defer movelist.deinit();
        pos.generate_q_moves(color, &movelist);
        var move_size = movelist.items.len;

        // Step 4.2: Q Move Ordering
        var evallist = movepick.scoreMoves(self, pos, &movelist, hashmove);
        defer evallist.deinit();

        // Step 4.3: Q Move Iteration
        var index: usize = 0;

        while (index < move_size) : (index += 1) {
            var move = movepick.getNextBest(&movelist, &evallist, index);

            // Step 4.4: SEE Pruning
            if (evallist.items[index] < 0) {
                break;
            }

            self.ply += 1;
            pos.play_move(color, move);
            var score = -self.quiescence_search(pos, opp_color, -beta, -alpha);
            self.ply -= 1;
            pos.undo_move(color, move);

            if (self.time_stop) {
                return 0;
            }

            // Step 4.5: Alpha-Beta Pruning
            if (score > best_score) {
                best_score = score;
                if (score > alpha) {
                    self.pv[self.ply][0] = move;
                    std.mem.copy(types.Move, self.pv[self.ply][1..(self.pv_size[self.ply + 1] + 1)], self.pv[self.ply + 1][0..(self.pv_size[self.ply + 1])]);
                    self.pv_size[self.ply] = self.pv_size[self.ply + 1] + 1;

                    if (score >= beta) {
                        return beta;
                    }

                    alpha = score;
                }
            }
        }

        return alpha;
    }
};
