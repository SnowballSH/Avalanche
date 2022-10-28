const std = @import("std");

const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const tt = @import("tt.zig");
const movepick = @import("movepick.zig");
const see = @import("see.zig");

const parameters = @import("parameters.zig");

pub const QuietLMR: [64][64]i32 = init: {
    @setEvalBranchQuota(64 * 64 * 6);
    var reductions: [64][64]i32 = undefined;
    var depth = 1;
    while (depth < 64) : (depth += 1) {
        var moves = 1;
        while (moves < 64) : (moves += 1) {
            const a = parameters.LMRWeight * std.math.ln(@intToFloat(f32, depth)) * std.math.ln(@intToFloat(f32, moves)) + parameters.LMRBias;
            reductions[depth][moves] = @floatToInt(i32, @floor(a));
        }
    }
    break :init reductions;
};

pub const MAX_PLY = 128;
pub const MAX_GAMEPLY = 1024;

pub const NodeType = enum {
    Root,
    PV,
    NonPV,
};

pub const Searcher = struct {
    max_millis: u64 = 0,
    timer: std.time.Timer = undefined,

    time_stop: bool = false,

    nodes: u64 = 0,
    ply: u32 = 0,
    seldepth: u32 = 0,
    stop: bool = false,
    is_searching: bool = false,

    exclude_move: [MAX_PLY]types.Move = undefined,

    hash_history: std.ArrayList(u64) = undefined,
    eval_history: [MAX_PLY]hce.Score = undefined,
    move_history: [MAX_PLY]types.Move = undefined,

    best_move: types.Move = undefined,
    pv: [MAX_PLY][MAX_PLY]types.Move = undefined,
    pv_size: [MAX_PLY]usize = undefined,

    killer: [MAX_PLY][2]types.Move = undefined,
    history: [2][64][64]u32 = undefined,

    counter_moves: [64][64]types.Move = undefined,

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
            var j: usize = 0;
            while (j < 64) : (j += 1) {
                var k: usize = 0;
                while (k < 64) : (k += 1) {
                    var i: usize = 0;
                    while (i < 2) : (i += 1) {
                        self.history[i][j][k] = 0;
                    }
                    self.counter_moves[j][k] = types.Move.empty();
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
                self.move_history[j] = types.Move.empty();
            }
        }
    }

    pub fn should_stop(self: *Searcher) bool {
        return self.stop or self.timer.read() / std.time.ns_per_ms > self.max_millis + 3;
    }

    pub fn iterative_deepening(self: *Searcher, pos: *position.Position, comptime color: types.Color, max_depth: ?u8) hce.Score {
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
        outer: while (depth <= bound) {
            var aspiration_window: f32 = @intToFloat(f32, parameters.AspirationWindow);

            self.ply = 0;
            self.seldepth = 0;

            if (depth >= 4) {
                alpha = score - @floatToInt(hce.Score, aspiration_window);
                beta = score + @floatToInt(hce.Score, aspiration_window);
            } else {
                alpha = -hce.MateScore;
                beta = hce.MateScore;
            }

            while (true) {
                if (alpha < -3400) {
                    alpha = -hce.MateScore;
                } else if (beta > 3400) {
                    beta = hce.MateScore;
                }

                var val = self.negamax(pos, color, depth, alpha, beta, false, NodeType.Root);

                if (self.time_stop or self.should_stop()) {
                    break :outer;
                }

                score = val;

                if (score <= alpha) {
                    beta = @divFloor(alpha + beta, 2);
                    alpha = @max(alpha - @floatToInt(hce.Score, aspiration_window), -hce.MateScore);
                } else if (score >= beta) {
                    beta = @min(beta + @floatToInt(hce.Score, aspiration_window), hce.MateScore);
                } else {
                    break;
                }

                aspiration_window *= parameters.AspirationWindowBonus;

                // Credit: Mr Bob Chess
                if (score <= alpha) {
                    aspiration_window += 5;
                } else {
                    aspiration_window += 3;
                }
            }

            bm = self.best_move;

            outW.print("info depth {} seldepth {} nodes {} time {} score ", .{
                depth,
                self.seldepth,
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

            depth += 1;
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

    pub fn negamax(self: *Searcher, pos: *position.Position, comptime color: types.Color, depth_: usize, alpha_: hce.Score, beta_: hce.Score, comptime is_null: bool, comptime node: NodeType) hce.Score {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;
        comptime var opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        self.pv_size[self.ply] = 0;

        // >> Step 1: Preparations

        // Step 1.1: Stop if time is up
        if (self.nodes & 1023 == 0 and self.should_stop()) {
            self.time_stop = true;
            return 0;
        }

        self.seldepth = @max(self.seldepth, self.ply);

        var is_root = node == NodeType.Root;
        var on_pv: bool = node != NodeType.NonPV;

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
            var r_alpha = @max(-hce.MateScore + @intCast(hce.Score, self.ply), alpha);
            var r_beta = @min(hce.MateScore - @intCast(hce.Score, self.ply) - 1, beta);

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

        // >> Step 2: TT Probe
        var hashmove = types.Move.empty();
        var tthit = false;
        var tt_eval: hce.Score = 0;
        var entry = tt.GlobalTT.get(pos.hash);

        if (entry != null) {
            tthit = true;
            tt_eval = entry.?.eval;
            if (tt_eval > hce.MateScore - hce.MaxMate and tt_eval <= hce.MateScore) {
                tt_eval -= @intCast(hce.Score, self.ply);
            } else if (tt_eval < -hce.MateScore + hce.MaxMate and tt_eval >= -hce.MateScore) {
                tt_eval += @intCast(hce.Score, self.ply);
            }
            hashmove = entry.?.bestmove;
            if (is_root) {
                self.best_move = hashmove;
            }

            if (!is_null and !on_pv and !is_root and entry.?.depth >= depth) {
                if (pos.history[pos.game_ply].fifty < 90 and (depth == 0 or !on_pv)) {
                    switch (entry.?.flag) {
                        .Exact => {
                            return tt_eval;
                        },
                        .Lower => {
                            alpha = @max(alpha, tt_eval);
                        },
                        .Upper => {
                            beta = @min(beta, tt_eval);
                        },
                        else => {},
                    }
                    if (alpha >= beta) {
                        return tt_eval;
                    }
                }
            }
        }

        var static_eval: hce.Score = if (in_check) -hce.MateScore + @intCast(i32, self.ply) else if (tthit) entry.?.eval else if (is_null) -self.eval_history[self.ply - 1] else hce.evaluate(pos);
        var best_score: hce.Score = static_eval;

        var low_estimate: hce.Score = -hce.MateScore - 1;

        self.eval_history[self.ply] = static_eval;

        var improving = !(self.ply <= 1 or in_check) and static_eval > self.eval_history[self.ply - 2];

        // >> Step 3: Prunings
        if (!in_check and !is_root) {
            low_estimate = if (!tthit or entry.?.flag == tt.Bound.Lower) static_eval else entry.?.eval;

            // Step 3.1: Razoring
            if (depth <= 1 and static_eval + parameters.RazoringMargin < alpha) {
                return self.quiescence_search(pos, color, alpha, beta);
            }

            // Step 3.2: Reverse Futility Pruning
            if (std.math.absInt(beta) catch 0 < hce.MateScore - hce.MaxMate and depth <= parameters.RFPDepth) {
                var n = @intCast(hce.Score, depth) * parameters.RFPMultiplier;
                if (improving) {
                    n -= parameters.RFPImprovingDeduction;
                }
                if (static_eval - n >= beta) {
                    return beta;
                }
            }

            // Step 3.3: Null move pruning
            if (!is_null and depth >= 3 and static_eval >= beta and pos.has_non_pawns()) {
                var r = parameters.NMPBase + depth / parameters.NMPDepthDivisor;
                r += @min(3, @intCast(usize, static_eval - beta) / parameters.NMPBetaDivisor);
                r = @min(r, depth);

                pos.play_null_move();
                var null_score = -self.negamax(pos, opp_color, depth - r, -beta, -beta + 1, true, NodeType.NonPV);
                pos.undo_null_move();

                if (self.time_stop) {
                    return 0;
                }

                if (null_score >= beta) {
                    if (null_score >= hce.MateScore - hce.MaxMate) {
                        null_score = beta;
                    }
                    return null_score;
                }
            }
        }

        // >> Step 4: Extensions/Reductions
        // Step 4.1: Reduce depth for non-tthits
        // http://talkchess.com/forum3/viewtopic.php?f=7&t=74769&sid=85d340ce4f4af0ed413fba3188189cd1
        if (!is_root and on_pv and depth >= 6 - 2 * @intCast(usize, @boolToInt(improving)) and !tthit) {
            depth -= 1;
        }

        // >> Step 5: Search

        // Step 5.1: Move Generation
        var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 32) catch unreachable;
        defer movelist.deinit();
        pos.generate_legal_moves(color, &movelist);
        var move_size = movelist.items.len;

        self.killer[self.ply + 1][0] = types.Move.empty();
        self.killer[self.ply + 1][1] = types.Move.empty();

        if (move_size == 0) {
            if (in_check) {
                // Checkmate
                return -hce.MateScore + @intCast(hce.Score, self.ply);
            } else {
                // Stalemate
                return 0;
            }
        }

        // Step 5.2: Move Ordering
        var evallist = movepick.scoreMoves(self, pos, &movelist, hashmove, is_null);
        defer evallist.deinit();

        // Step 5.3: Move Iteration
        var best_move = types.Move.empty();
        best_score = -hce.MateScore + @intCast(hce.Score, self.ply);

        var skip_quiet = false;

        var quiet_count: usize = 0;

        var index: usize = 0;
        while (index < move_size) : (index += 1) {
            var move = movepick.getNextBest(&movelist, &evallist, index);
            if (move.to_u16() == self.exclude_move[self.ply].to_u16()) {
                continue;
            }

            var is_capture = move.is_capture();

            if (!is_capture) {
                quiet_count += 1;
            }

            if (skip_quiet and !is_capture) {
                continue;
            }

            if (!is_root and index > 0) {
                // Step 5.4a: Late Move Pruning
                if (!is_capture and !in_check and !on_pv and !move.is_promotion() and depth <= 4 and quiet_count > (4 + depth * depth)) {
                    skip_quiet = true;
                    continue;
                }

                // Step 5.4b: SEE Pruning
                // if (depth < 4 and !see.see_threshold(pos, move, -(@intCast(i32, depth * (see.SeeWeight[0] - 1))))) {
                //    continue;
                // }
            }

            var new_depth = depth - 1;

            // Step 4.3: Singular extension
            // zig fmt: off
            if (self.ply > 0
                and depth >= 8
                and tthit
                and entry.?.flag != tt.Bound.Upper
                and !hce.is_near_mate(entry.?.eval)
                and hashmove.to_u16() == move.to_u16()
                and entry.?.depth >= depth - 3
            ) {
            // zig fmt: on
                var margin = @intCast(i32, depth) * 2;
                self.exclude_move[self.ply] = hashmove;
                var singular_score = self.negamax(pos, color, depth / 2 - 1, entry.?.eval - margin - 1, entry.?.eval - margin, true, NodeType.NonPV);
                self.exclude_move[self.ply] = types.Move.empty();
                if (singular_score >= entry.?.eval - margin) {
                    if (entry.?.eval - margin >= beta) {
                        return entry.?.eval - margin;
                    }
                } else {
                    new_depth += 1;
                }
            }

            self.move_history[self.ply] = move;
            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};

            var score: hce.Score = 0;
            if (index == 0) {
                score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV);
            } else if (depth >= 3 and !is_capture and index >= 1) {
                // Step 5.5: Late-Move Reduction
                var reduction: i32 = QuietLMR[@min(depth, 63)][@min(index, 63)];

                if (on_pv) {
                    reduction -= 1;
                }

                if (move.to_u16() == self.killer[self.ply][0].to_u16() or move.to_u16() == self.killer[self.ply][1].to_u16()) {
                    reduction -= 1;
                }

                var rd: usize = @intCast(usize, std.math.clamp(@intCast(i32, new_depth) - reduction, 1, new_depth + 1));

                // Step 5.6: Principal-Variation-Search (PVS)
                score = -self.negamax(pos, opp_color, rd, -alpha - 1, -alpha, false, NodeType.NonPV);

                if (score > alpha and rd < new_depth) {
                    score = -self.negamax(pos, opp_color, new_depth, -alpha - 1, -alpha, false, NodeType.NonPV);

                    if (score > alpha and score < beta) {
                        score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV);
                    }
                }
            } else {
                // Null-window search
                score = -self.negamax(pos, opp_color, new_depth, -alpha - 1, -alpha, false, NodeType.NonPV);
                if (score > alpha and score < beta) {
                    score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV);
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

                if (is_root) {
                    self.best_move = move;
                }

                if (!is_null) {
                    self.pv[self.ply][0] = move;
                    std.mem.copy(types.Move, self.pv[self.ply][1..(self.pv_size[self.ply + 1] + 1)], self.pv[self.ply + 1][0..(self.pv_size[self.ply + 1])]);
                    self.pv_size[self.ply] = self.pv_size[self.ply + 1] + 1;
                }

                if (score > alpha) {
                    alpha = score;

                    if (alpha >= beta) {
                        if (!is_capture) {
                            var temp = self.killer[self.ply][0];
                            if (temp.to_u16() != move.to_u16()) {
                                self.killer[self.ply][0] = move;
                                self.killer[self.ply][1] = temp;
                            }

                            self.history[@enumToInt(color)][move.from][move.to] += @intCast(u32, depth * depth);

                            if (self.history[@enumToInt(color)][move.from][move.to] >= 500000000) {
                                for (self.history) |*a| {
                                    for (a) |*b| {
                                        for (b) |*c| {
                                            c.* = @divFloor(c.*, 2);
                                        }
                                    }
                                }
                            }

                            if (!is_null and self.ply >= 1) {
                                var last = self.move_history[self.ply - 1];
                                self.counter_moves[last.from][last.to] = move;
                            }
                        }
                        break;
                    }
                }
            }
        }

        // >> Step 7: Transposition Table Update
        if (!skip_quiet and self.exclude_move[self.ply].to_u16() == 0) {
            var tt_flag = if (best_score >= beta) tt.Bound.Lower else if (alpha != alpha_) tt.Bound.Exact else tt.Bound.Upper;

            tt.GlobalTT.set(tt.Item{
                .eval = best_score,
                .bestmove = best_move,
                .flag = tt_flag,
                .depth = @intCast(u14, depth),
                .hash = pos.hash,
            });
        }

        return best_score;
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
        var static_eval = best_score;
        if (!in_check) {
            static_eval = hce.evaluate(pos);
            best_score = static_eval;

            // Step 2.1: Stand Pat pruning
            if (best_score >= beta) {
                return beta;
            }
            if (best_score > alpha) {
                alpha = best_score;
            }
        }

        // alpha = @maximum(alpha, static_eval);

        // >> Step 3: TT Probe
        var hashmove = types.Move.empty();
        var entry = tt.GlobalTT.get(pos.hash);

        if (entry != null) {
            hashmove = entry.?.bestmove;
            if (entry.?.flag == tt.Bound.Exact) {
                return entry.?.eval;
            } else if (entry.?.flag == tt.Bound.Lower and entry.?.eval >= beta) {
                return entry.?.eval;
            } else if (entry.?.flag == tt.Bound.Upper and entry.?.eval <= alpha) {
                return entry.?.eval;
            }
        }

        // >> Step 4: QSearch

        // Step 4.1: Q Move Generation
        var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 16) catch unreachable;
        defer movelist.deinit();
        if (in_check) {
            pos.generate_legal_moves(color, &movelist);
            if (movelist.items.len == 0) {
                // Checkmated
                return -hce.MateScore + @intCast(hce.Score, self.ply);
            }
        } else {
            pos.generate_q_moves(color, &movelist);
        }
        var move_size = movelist.items.len;

        // Step 4.2: Q Move Ordering
        var evallist = movepick.scoreMoves(self, pos, &movelist, hashmove, false);
        defer evallist.deinit();

        // Step 4.3: Q Move Iteration
        var index: usize = 0;

        while (index < move_size) : (index += 1) {
            var move = movepick.getNextBest(&movelist, &evallist, index);
            var is_capture = move.is_capture();

            // Step 4.4: SEE Pruning
            if (is_capture and index > 0) {
                var see_score = evallist.items[index];

                if (see_score < 0) {
                    continue;
                }
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
                    if (score >= beta) {
                        return beta;
                    }

                    alpha = score;
                }
            }
        }

        return best_score;
    }
};
