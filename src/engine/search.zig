const std = @import("std");

const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const tt = @import("tt.zig");
const movepick = @import("movepick.zig");
const see = @import("see.zig");

const parameters = @import("parameters.zig");

const DATAGEN = false;

pub var QuietLMR: [64][64]i32 = undefined;

pub fn init_lmr() void {
    var depth: usize = 1;
    while (depth < 64) : (depth += 1) {
        var moves: usize = 1;
        while (moves < 64) : (moves += 1) {
            const a = parameters.LMRWeight * std.math.ln(@intToFloat(f32, depth)) * std.math.ln(@intToFloat(f32, moves)) + parameters.LMRBias;
            QuietLMR[depth][moves] = @floatToInt(i32, @floor(a));
        }
    }
}

pub const MAX_PLY = 128;
pub const MAX_GAMEPLY = 1024;

pub const NodeType = enum {
    Root,
    PV,
    NonPV,
};

pub const MAX_THREADS = 16;
pub var NUM_THREADS: usize = 0;

pub var helper_searchers: [MAX_THREADS]Searcher = undefined;
pub var threads: [MAX_THREADS]?std.Thread = undefined;

pub const Searcher = struct {
    min_depth: usize = 1,
    max_millis: u64 = 0,
    ideal_time: u64 = 0,
    force_thinking: bool = false,
    iterative_deepening_depth: usize = 0,
    timer: std.time.Timer = undefined,

    soft_max_nodes: ?u64 = null,
    max_nodes: ?u64 = null,

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
    moved_piece_history: [MAX_PLY]types.Piece = undefined,

    best_move: types.Move = undefined,
    pv: [MAX_PLY][MAX_PLY]types.Move = undefined,
    pv_size: [MAX_PLY]usize = undefined,

    killer: [MAX_PLY][2]types.Move = undefined,
    history: [2][64][64]i32 = undefined,

    counter_moves: [2][64][64]types.Move = undefined,
    continuation: [12][64][12][64]i32 = undefined,

    root_board: position.Position = undefined,
    thread_id: usize = 0,
    silent_output: bool = false,

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
                        self.history[i][j][k] = @divTrunc(self.history[i][j][k], 2);
                        self.counter_moves[i][j][k] = types.Move.empty();
                    }
                    if (j < 12) {
                        i = 0;
                        while (i < 12) : (i += 1) {
                            var o: usize = 0;
                            while (o < 64) : (o += 1) {
                                self.continuation[j][k][i][o] = 0;
                            }
                        }
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
                self.move_history[j] = types.Move.empty();
                self.moved_piece_history[j] = types.Piece.NO_PIECE;
            }
        }
    }

    pub inline fn should_stop(self: *Searcher) bool {
        return self.stop or (self.thread_id == 0 and self.iterative_deepening_depth > self.min_depth and ((self.max_nodes != null and self.nodes >= self.max_nodes.?) or (!self.force_thinking and self.timer.read() / std.time.ns_per_ms >= self.max_millis)));
    }

    pub inline fn should_not_continue(self: *Searcher, factor: f32) bool {
        return self.stop or (self.thread_id == 0 and self.iterative_deepening_depth > self.min_depth and ((self.soft_max_nodes != null and self.nodes >= self.soft_max_nodes.?) or (!self.force_thinking and self.timer.read() / std.time.ns_per_ms >= @min(self.max_millis, @floatToInt(u64, @floor(@intToFloat(f32, self.ideal_time) * factor))))));
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

        var prev_score = -hce.MateScore;
        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var stability: usize = 0;

        var ti: usize = 0;
        while (ti < NUM_THREADS) : (ti += 1) {
            helper_searchers[ti] = Searcher.new();
        }

        var tdepth: usize = 1;
        var bound: usize = if (max_depth == null) MAX_PLY - 2 else max_depth.?;
        outer: while (tdepth <= bound) {
            self.ply = 0;
            self.seldepth = 0;

            var alpha = -hce.MateScore;
            var beta = hce.MateScore;
            var delta = hce.MateScore;

            var depth = tdepth;

            if (depth >= 6) {
                alpha = @max(score - parameters.AspirationWindow, -hce.MateScore);
                beta = @min(score + parameters.AspirationWindow, hce.MateScore);
                delta = parameters.AspirationWindow;
            }

            while (true) {
                self.iterative_deepening_depth = @max(self.iterative_deepening_depth, depth);
                if (depth > 1) {
                    self.helpers(pos, color, depth, alpha, beta);
                }

                var val = self.negamax(pos, color, depth, alpha, beta, false, NodeType.Root);

                if (depth > 1) {
                    self.stop_helpers();
                }

                if (self.time_stop or self.should_stop()) {
                    break :outer;
                }

                score = val;

                if (score <= alpha) {
                    beta = @divTrunc(alpha + beta, 2);
                    alpha = @max(alpha - delta, -hce.MateScore);
                } else if (score >= beta) {
                    beta = @min(beta + delta, hce.MateScore);
                    if (depth > 1 and (tdepth < 4 or depth > tdepth - 4)) {
                        depth -= 1;
                    }
                } else {
                    break;
                }

                delta += @divTrunc(delta, 4);
            }

            if (self.best_move.to_u16() != bm.to_u16()) {
                stability = 0;
            } else {
                stability += 1;
            }

            bm = self.best_move;

            var total_nodes: usize = self.nodes;

            if (depth > 1) {
                // outW.print("info string thread 0 nodes {}\n", .{
                //     self.nodes,
                // }) catch {};
                var thread_index: usize = 0;
                while (thread_index < NUM_THREADS) : (thread_index += 1) {
                    // outW.print("info string thread {} nodes {}\n", .{
                    //     thread_index + 1, helper_searchers[thread_index].nodes,
                    // }) catch {};
                    total_nodes += helper_searchers[thread_index].nodes;
                }
            }

            if (!self.silent_output) {
                outW.print("info depth {} seldepth {} nodes {} time {} score ", .{
                    tdepth,
                    self.seldepth,
                    total_nodes,
                    self.timer.read() / std.time.ns_per_ms,
                }) catch {};

                if ((std.math.absInt(score) catch 0) >= (hce.MateScore - hce.MaxMate)) {
                    outW.print("mate {} pv", .{
                        (@divTrunc(hce.MateScore - (std.math.absInt(score) catch 0), 2) + 1) * @as(hce.Score, if (score > 0) 1 else -1),
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

            // Time Management algorithm by BlackCore
            // https://github.com/SzilBalazs/BlackCore/blob/master/src/timeman.cpp

            var factor: f32 = @max(0.5, 1.1 - 0.03 * @intToFloat(f32, stability));

            if (score - prev_score > parameters.AspirationWindow) {
                factor *= 1.1;
            }

            prev_score = score;

            if (self.should_not_continue(factor)) {
                break;
            }

            tdepth += 1;
        }

        self.best_move = bm;

        if (!self.silent_output) {
            outW.writeAll("bestmove ") catch {};
            bm.uci_print(outW);
            outW.writeByte('\n') catch {};
            out.flush() catch {};
        }

        self.is_searching = false;

        tt.GlobalTT.do_age();

        return score;
    }

    pub fn is_draw(self: *Searcher, pos: *position.Position, threefold: bool) bool {
        if (pos.history[pos.game_ply].fifty >= 100) {
            return true;
        }

        if (hce.is_material_draw(pos)) {
            return true;
        }

        if (self.hash_history.items.len > 1) {
            var index: i16 = @intCast(i16, self.hash_history.items.len) - 3;
            const limit: i16 = index - @intCast(i16, pos.history[pos.game_ply].fifty) - 1;
            var count: u8 = 0;
            const threshold: u8 = if (threefold) 2 else 1;
            while (index >= limit and index >= 0) {
                if (self.hash_history.items[@intCast(usize, index)] == pos.hash) {
                    count += 1;
                    if (count >= threshold) {
                        return true;
                    }
                }
                index -= 2;
            }
        }

        return false;
    }

    pub fn helpers(self: *Searcher, pos: *position.Position, comptime color: types.Color, depth_: usize, alpha_: hce.Score, beta_: hce.Score) void {
        var i: usize = 0;
        while (i < NUM_THREADS) : (i += 1) {
            var id: usize = i + 1;
            if (threads[i] != null) {
                threads[i].?.join();
            }
            var depth: usize = depth_;
            if (id % 2 == 1) {
                depth += 1;
            }
            helper_searchers[i].max_millis = self.max_millis;
            helper_searchers[i].thread_id = id;
            helper_searchers[i].root_board = pos.*;
            threads[i] = std.Thread.spawn(
                .{ .stack_size = 64 * 1024 * 1024 },
                Searcher.start_helper,
                .{ &helper_searchers[i], color, depth, alpha_, beta_ },
            ) catch |e| {
                std.debug.panic("Could not spawn helper thread {}!\n{}", .{ i, e });
                unreachable;
            };
        }
    }

    pub fn start_helper(self: *Searcher, color: types.Color, depth_: usize, alpha_: hce.Score, beta_: hce.Score) void {
        self.stop = false;
        self.is_searching = true;
        self.time_stop = false;
        self.nodes = 0;
        self.best_move = types.Move.empty();
        self.timer = std.time.Timer.start() catch unreachable;
        self.force_thinking = true;
        self.ply = 0;
        self.seldepth = 0;
        if (color == types.Color.White) {
            _ = self.negamax(&self.root_board, types.Color.White, depth_, alpha_, beta_, false, NodeType.Root);
        } else {
            _ = self.negamax(&self.root_board, types.Color.Black, depth_, alpha_, beta_, false, NodeType.Root);
        }
    }

    pub fn stop_helpers(self: *Searcher) void {
        _ = self;
        var i: usize = 0;
        while (i < NUM_THREADS) : (i += 1) {
            helper_searchers[i].stop = true;
        }
        while (i < NUM_THREADS) : (i += 1) {
            threads[i].?.join();
        }
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

        // Step 1.3: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return hce.evaluate_comptime(pos, color);
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

        // Step 1.4: Mate-distance pruning
        if (!is_root) {
            var r_alpha = @max(-hce.MateScore + @intCast(hce.Score, self.ply), alpha);
            var r_beta = @min(hce.MateScore - @intCast(hce.Score, self.ply) - 1, beta);

            if (r_alpha >= r_beta) {
                return r_alpha;
            }
        }

        self.nodes += 1;

        // Step 1.6: Draw check
        if (!is_root and self.is_draw(pos, on_pv)) {
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

        var static_eval: hce.Score = if (in_check) -hce.MateScore + @intCast(i32, self.ply) else if (tthit) entry.?.eval else if (is_null) -self.eval_history[self.ply - 1] else if (self.exclude_move[self.ply].to_u16() != 0) self.eval_history[self.ply] else hce.evaluate_comptime(pos, color);
        var best_score: hce.Score = static_eval;

        var low_estimate: hce.Score = -hce.MateScore - 1;

        self.eval_history[self.ply] = static_eval;

        var improving = !in_check and self.ply >= 2 and static_eval > self.eval_history[self.ply - 2];

        var has_non_pawns = pos.has_non_pawns();

        var last_move = if (self.ply > 0) self.move_history[self.ply - 1] else types.Move.empty();
        var last_last_last_move = if (self.ply > 2) self.move_history[self.ply - 3] else types.Move.empty();

        // >> Step 3: Extensions/Reductions
        // Step 3.1: IIR
        // http://talkchess.com/forum3/viewtopic.php?f=7&t=74769&sid=85d340ce4f4af0ed413fba3188189cd1
        if (depth >= 3 and !tthit and self.exclude_move[self.ply].to_u16() == 0) {
            depth -= 1;
        }

        // >> Step 4: Prunings
        if (!in_check and !on_pv and self.exclude_move[self.ply].to_u16() == 0) {
            low_estimate = if (!tthit or entry.?.flag == tt.Bound.Lower) static_eval else entry.?.eval;

            // Step 4.1: Reverse Futility Pruning
            if (std.math.absInt(beta) catch 0 < hce.MateScore - hce.MaxMate and depth <= parameters.RFPDepth) {
                var n = @intCast(hce.Score, depth) * parameters.RFPMultiplier;
                if (improving) {
                    n -= parameters.RFPImprovingDeduction;
                }
                if (static_eval - n >= beta) {
                    return beta;
                }
            }

            var nmp_static_eval = static_eval;
            if (improving) {
                nmp_static_eval += parameters.NMPImprovingMargin;
            }

            // Step 4.2: Null move pruning
            if (!is_null and depth >= 3 and nmp_static_eval >= beta and has_non_pawns) {
                var r = parameters.NMPBase + depth / parameters.NMPDepthDivisor;
                r += @intCast(usize, @min(4, @divTrunc((static_eval - beta), parameters.NMPBetaDivisor)));
                r = @min(r, depth);

                self.ply += 1;
                pos.play_null_move();
                var null_score = -self.negamax(pos, opp_color, depth - r, -beta, -beta + 1, true, NodeType.NonPV);
                self.ply -= 1;
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

            // Step 4.3: Razoring
            if (depth <= 3 and static_eval - parameters.RazoringBase + parameters.RazoringMargin * @intCast(i32, depth) < alpha) {
                return self.quiescence_search(pos, color, alpha, beta);
            }
        }

        // >> Step 5: Search

        // Step 5.1: Move Generation
        var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 64) catch unreachable;
        defer movelist.deinit();
        pos.generate_legal_moves(color, &movelist);
        var move_size = movelist.items.len;

        var quiet_moves = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 32) catch unreachable;
        defer quiet_moves.deinit();

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
            var is_killer = move.to_u16() == self.killer[self.ply][0].to_u16() or move.to_u16() == self.killer[self.ply][1].to_u16();

            if (!is_capture) {
                quiet_moves.append(move) catch unreachable;
                quiet_count += 1;
            }

            var is_important = is_killer or move.is_promotion();

            if (skip_quiet and !is_capture and !is_important) {
                continue;
            }

            if (!DATAGEN and !is_root and index > 1 and !in_check and !on_pv and has_non_pawns) {
                if (!is_important and !is_capture and depth <= 5) {
                    // Step 5.4a: Late Move Pruning
                    var late = 4 + depth * depth;
                    if (improving) {
                        late += 1 + depth / 2;
                    }

                    if (quiet_count > late) {
                        skip_quiet = true;
                    }

                    // Step 5.4b: Futility Pruning
                    //if (static_eval + 135 * @intCast(i32, depth) <= alpha and std.math.absInt(alpha) catch 0 < hce.MateScore - hce.MaxMate) {
                    //    skip_quiet = true;
                    //    continue;
                    //}
                }
            }

            var extension: i32 = 0;

            // Step 5.5: Singular extension
            // zig fmt: off
            if (self.ply > 0
                and !is_root
                and self.ply < depth * 2
                and depth >= 7
                and tthit
                and entry.?.flag != tt.Bound.Upper
                and !hce.is_near_mate(entry.?.eval)
                and hashmove.to_u16() == move.to_u16()
                and entry.?.depth >= depth - 3
            ) {
            // zig fmt: on
                var margin = @intCast(i32, depth);
                var singular_beta = @max(tt_eval - margin, -hce.MateScore + hce.MaxMate);

                self.exclude_move[self.ply] = hashmove;
                var singular_score = self.negamax(pos, color, (depth - 1) / 2, singular_beta - 1, singular_beta, true, NodeType.NonPV);
                self.exclude_move[self.ply] = types.Move.empty();
                if (singular_score < singular_beta) {
                    extension = 1;
                } else if (singular_beta >= beta) {
                    return singular_beta;
                } else if (tt_eval >= beta) {
                    extension = -1;
                } else if (tt_eval <= alpha) {
                    extension = -1;
                }
            } else if (on_pv and !is_root and self.ply < depth * 2) {
                // Recapture Extension
                if (is_capture and ((last_move.is_capture() and move.to == last_move.to) or (last_last_last_move.is_capture() and move.to == last_last_last_move.to))) {
                    extension = 1;
                }
            }

            var new_depth = @intCast(usize, @intCast(i32, depth) + extension - 1);

            self.move_history[self.ply] = move;
            self.moved_piece_history[self.ply] = pos.mailbox[move.from];
            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};

            tt.GlobalTT.prefetch(pos.hash);

            var score: hce.Score = 0;
            var min_lmr_move: usize = if (on_pv) 5 else 3;
            var do_full_search = false;
            const is_winning_capture = is_capture and evallist.items[index] >= movepick.SortWinningCapture - 100;
            if (!in_check and depth >= 3 and index >= min_lmr_move and (!is_capture or !is_winning_capture)) {
                // Step 5.6: Late-Move Reduction
                var reduction: i32 = QuietLMR[@min(depth, 63)][@min(index, 63)];

                if (self.thread_id % 2 == 1) {
                    reduction -= 1;
                }

                if (improving) {
                    reduction += 1;
                }

                if (!on_pv) {
                    reduction += 1;
                }

                reduction -= @divTrunc(self.history[@enumToInt(color)][move.from][move.to], 6144);

                var rd: usize = @intCast(usize, std.math.clamp(@intCast(i32, new_depth) - reduction, 1, new_depth + 1));

                // Step 5.7: Principal-Variation-Search (PVS)
                score = -self.negamax(pos, opp_color, rd, -alpha - 1, -alpha, false, NodeType.NonPV);

                do_full_search = score > alpha and rd < new_depth;
            } else {
                do_full_search = !on_pv or index > 0;
            }

            if (do_full_search) {
                score = -self.negamax(pos, opp_color, new_depth, -alpha - 1, -alpha, false, NodeType.NonPV);
            }

            if (on_pv and ((score > alpha and score < beta) or index == 0)) {
                score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV);
            }

            self.ply -= 1;
            pos.undo_move(color, move);
            _ = self.hash_history.pop();

            if (self.time_stop) {
                return 0;
            }

            // Step 5.8: Alpha-Beta Pruning
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
                        break;
                    }
                }
            }
        }

        if (alpha >= beta and !best_move.is_capture() and !best_move.is_promotion()) {
            var temp = self.killer[self.ply][0];
            if (temp.to_u16() != best_move.to_u16()) {
                self.killer[self.ply][0] = best_move;
                self.killer[self.ply][1] = temp;
            }

            const bonus: i32 = @intCast(i32, @min(depth * depth, 512));
            const max: i32 = 32 * bonus;

            if (!is_null and self.ply >= 1) {
                var last = self.move_history[self.ply - 1];
                self.counter_moves[@enumToInt(color)][last.from][last.to] = best_move;
            }

            const b = best_move.to_u16();
            const max_history: i32 = 16384;
            for (quiet_moves.items) |m, i| {
                var hist = @divTrunc(self.history[@enumToInt(color)][best_move.from][best_move.to] * bonus, 512);
                const is_best = m.to_u16() == b;
                if (is_best) {
                    if (i > 6) {
                        hist = @divTrunc(hist, 2);
                    }
                    const adj = max - hist;
                    self.history[@enumToInt(color)][m.from][m.to] += adj - @divTrunc(self.history[@enumToInt(color)][m.from][m.to] * (std.math.absInt(adj) catch 0), max_history);
                } else {
                    if (i < 2) {
                        hist *= 2;
                    }
                    const adj = -max - hist;
                    self.history[@enumToInt(color)][m.from][m.to] += adj - @divTrunc(self.history[@enumToInt(color)][m.from][m.to] * (std.math.absInt(adj) catch 0), max_history);
                }

                // Continuation History
                if (!is_null and self.ply >= 1) {
                    const plies: [3]usize = .{ 0, 1, 3 };
                    for (plies) |plies_ago| {
                        if (self.ply >= plies_ago + 1) {
                            const prev = self.move_history[self.ply - plies_ago - 1];
                            if (prev.to_u16() == 0) continue;

                            const cont_hist = self.continuation[self.moved_piece_history[self.ply - plies_ago - 1].pure_index()][prev.to][pos.mailbox[m.from].pure_index()][m.to];
                            if (is_best) {
                                const adj = max;
                                self.continuation[self.moved_piece_history[self.ply - plies_ago - 1].pure_index()][prev.to][pos.mailbox[m.from].pure_index()][m.to] += adj - @divTrunc(cont_hist * max, max_history);
                            } else {
                                const adj = -max;
                                self.continuation[self.moved_piece_history[self.ply - plies_ago - 1].pure_index()][prev.to][pos.mailbox[m.from].pure_index()][m.to] += adj - @divTrunc(cont_hist * max, max_history);
                            }
                        }
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
                .depth = @intCast(u8, depth),
                .hash = pos.hash,
                .age = tt.GlobalTT.age,
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

        self.pv_size[self.ply] = 0;

        // Step 1.2: Material Draw Check
        if (hce.is_material_draw(pos)) {
            return 0;
        }

        // Step 1.4: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return hce.evaluate_comptime(pos, color);
        }

        self.nodes += 1;

        var in_check = pos.in_check(color);

        // >> Step 2: Prunings

        var best_score = -hce.MateScore + @intCast(hce.Score, self.ply);
        var static_eval = best_score;
        if (!in_check) {
            static_eval = hce.evaluate_comptime(pos, color);
            best_score = static_eval;

            // Step 2.1: Stand Pat pruning
            if (best_score >= beta) {
                return beta;
            }
            if (best_score > alpha) {
                alpha = best_score;
            }
        }

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
        var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 32) catch unreachable;
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

                if (see_score < movepick.SortWinningCapture - 2048) {
                    continue;
                }
            }

            self.move_history[self.ply] = move;
            self.moved_piece_history[self.ply] = pos.mailbox[move.from];
            self.ply += 1;
            pos.play_move(color, move);
            tt.GlobalTT.prefetch(pos.hash);
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
