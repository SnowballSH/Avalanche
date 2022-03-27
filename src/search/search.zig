const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const NNUE = @import("../evaluation/nnue.zig");
const HCE = @import("../evaluation/hce.zig");
const Eval = @import("../evaluation/final.zig");
const Movegen = @import("../move/movegen.zig");
const Uci = @import("../uci/uci.zig");
const Ordering = @import("./ordering.zig");
const Encode = @import("../move/encode.zig");
const TT = @import("../cache/tt.zig");
const LMR = @import("./lmr.zig");
const SEE = @import("./see.zig");

const std = @import("std");

pub const INF: i16 = 32000;

pub const DRAW: i16 = 0;

pub const TIME_UP: i16 = INF + 500;

pub const MAX_PLY = 122;

const PVARRAY = [(MAX_PLY * MAX_PLY + MAX_PLY) / 2]u24;
const KILLER = [2][MAX_PLY]u24;
const HISTORY = [64][64]u32;

pub var GlobalTT: TT.TT = undefined;

pub fn init_tt() void {
    GlobalTT = TT.TT.new(24);
    GlobalTT.reset();
}

pub const Searcher = struct {
    // info
    ply: u8,
    nodes: u64,
    timer: std.time.Timer,
    max_nano: ?u64,
    seldepth: u8,
    is_searching: bool,

    // communication
    stop: bool,
    force_nostop: bool,

    // game
    hash_history: std.ArrayList(u64),
    halfmoves: u8,
    hm_stack: std.ArrayList(u8),

    // Search
    pv_array: PVARRAY,
    pv_index: u16,

    killers: KILLER,
    history: HISTORY,

    // NNUE
    nnue: NNUE.NNUE,

    pub fn new_searcher() Searcher {
        return Searcher{
            .ply = 0,
            .nodes = 0,
            .timer = undefined,
            .max_nano = null,
            .seldepth = 0,
            .is_searching = false,

            .stop = false,
            .force_nostop = false,

            .hash_history = std.ArrayList(u64).init(std.heap.page_allocator),
            .halfmoves = 0,
            .hm_stack = std.ArrayList(u8).init(std.heap.page_allocator),

            .pv_array = std.mem.zeroes(PVARRAY),
            .pv_index = 0,
            .killers = std.mem.zeroes(KILLER),
            .history = std.mem.zeroes(HISTORY),

            .nnue = NNUE.NNUE.new(),
        };
    }

    // copies PV lines
    fn movcpy(self: *Searcher, target_: usize, source_: usize, amount: usize) void {
        var n = amount;
        var target = target_;
        var source = source_;
        while (n != 0) {
            n -= 1;
            if (self.pv_array[source] == 0) {
                self.pv_array[target] = 0;
                break;
            }
            self.pv_array[target] = self.pv_array[source];
            target += 1;
            source += 1;
        }
    }

    fn stop_search(self: *Searcher) bool {
        return !self.force_nostop and (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?));
    }

    //
    // Iterative Deepening
    // Searches to the given depth until time runs out.
    //
    pub fn iterative_deepening(self: *Searcher, position: *Position.Position, movetime_nano: usize, force_max_depth: ?u8) void {
        const stdout = std.io.getStdOut().writer();
        self.timer = std.time.Timer.start() catch undefined;
        self.nodes = 0;
        self.seldepth = 0;

        self.max_nano = movetime_nano;
        if (self.max_nano.? < 30) {
            self.max_nano = 30;
        }
        self.max_nano.? -= 20;

        self.is_searching = true;
        defer self.is_searching = false;

        for (self.killers) |*k| {
            for (k) |*p| {
                p.* = 0;
            }
        }

        for (self.history) |*h| {
            for (h) |*p| {
                p.* = 0;
            }
        }

        for (self.pv_array) |*p| {
            p.* = 0;
        }

        self.pv_index = 0;

        var bestmove: u24 = 0;

        var max_depth: u8 = MAX_PLY;

        // Material drawn? This should never happen
        // if (Eval.is_material_drawn(position)) {
        //     max_depth = 2;
        // }

        if (force_max_depth != null) {
            max_depth = @minimum(force_max_depth.?, max_depth);
        }

        self.nnue.refresh_accumulator(position);

        self.force_nostop = true;

        var time_last_iter: u64 = 0;
        var dp: u8 = 1;
        var score: i16 = 0;
        while (dp <= max_depth) {
            const start = self.timer.read();
            self.seldepth = 0;

            // Not enough time to run next depth
            if (self.max_nano != null and self.timer.read() < self.max_nano.? and self.max_nano.? - self.timer.read() < time_last_iter / 2) {
                break;
            }

            const alpha: i16 = -INF;
            const beta: i16 = INF;

            const score_ = self.negamax(position, alpha, beta, dp);

            if (self.stop_search()) {
                break;
            }
            score = score_;

            if (self.stop_search()) {
                break;
            }

            // print stats
            if (score > 0 and INF - score < 100) {
                stdout.print(
                    "info depth {} seldepth {} nodes {} time {} score mate {} pv",
                    .{
                        dp,
                        self.seldepth,
                        self.nodes,
                        self.timer.read() / std.time.ns_per_ms,
                        INF - score,
                    },
                ) catch {};
                if (dp < max_depth - 3) {
                    max_depth = dp + 3;
                }
            } else if (score < 0 and INF + score < 100) {
                stdout.print(
                    "info depth {} seldepth {} nodes {} time {} score mate -{} pv",
                    .{
                        dp,
                        self.seldepth,
                        self.nodes,
                        self.timer.read() / std.time.ns_per_ms,
                        INF + score,
                    },
                ) catch {};
                if (dp < max_depth - 8) {
                    max_depth = dp + 8;
                }
            } else {
                stdout.print(
                    "info depth {} seldepth {} nodes {} time {} score cp {} pv",
                    .{
                        dp,
                        self.seldepth,
                        self.nodes,
                        self.timer.read() / std.time.ns_per_ms,
                        score,
                    },
                ) catch {};
            }

            var i: usize = 0;
            while (i < dp) {
                if (self.pv_array[i] == 0) {
                    break;
                }
                stdout.print(" {s}", .{Uci.move_to_uci(self.pv_array[i])}) catch {};

                i += 1;
            }
            stdout.writeByte('\n') catch {};
            dp += 1;

            bestmove = self.pv_array[0];

            self.force_nostop = false;
            time_last_iter = self.timer.read() - start;
        }

        dp -= 1;

        if (score > 0 and INF - score < 50) {
            stdout.print(
                "info depth {} seldepth {} nodes {} time {} score mate {}",
                .{
                    dp,
                    self.seldepth,
                    self.nodes,
                    self.timer.read() / std.time.ns_per_ms,
                    INF - score,
                },
            ) catch {};
            if (dp < max_depth - 3) {
                max_depth = dp + 3;
            }
        } else if (score < 0 and INF + score < 50) {
            stdout.print(
                "info depth {} seldepth {} nodes {} time {} score mate -{}",
                .{
                    dp,
                    self.seldepth,
                    self.nodes,
                    self.timer.read() / std.time.ns_per_ms,
                    INF + score,
                },
            ) catch {};
            if (dp < max_depth - 8) {
                max_depth = dp + 8;
            }
        } else {
            stdout.print(
                "info depth {} seldepth {} nodes {} time {} score cp {}",
                .{
                    dp,
                    self.seldepth,
                    self.nodes,
                    self.timer.read() / std.time.ns_per_ms,
                    score,
                },
            ) catch {};
        }

        stdout.print("\nbestmove {s}\n", .{Uci.move_to_uci(bestmove)}) catch {};

        GlobalTT.reset();
    }

    //
    // Negamax alpha-beta tree search with prunings
    //
    pub fn negamax(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16, depth_: u8) i16 {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;

        self.nodes += 1;

        // Variables
        const is_root = self.ply == 0;
        const is_pv = alpha != beta - 1;

        // Too deep = return eval
        if (self.ply == MAX_PLY) {
            return Eval.evaluate(position, &self.nnue, self.halfmoves);
        }

        // update seldepth
        if (self.ply > self.seldepth) {
            self.seldepth = self.ply;
        }

        // Fifty-move rule
        if (self.halfmoves >= 100) {
            return DRAW;
        }

        // Material drawn game
        if (Eval.is_material_drawn(position)) {
            return DRAW;
        }

        // PV
        const old_pv = self.pv_array[self.pv_index];
        self.pv_array[self.pv_index] = 0;
        const old_pv_index = self.pv_index;
        defer self.pv_index = old_pv_index;
        self.pv_index += MAX_PLY - self.ply;

        if (!is_root) {
            // Repetition
            if (std.mem.len(self.hash_history.items) > 1) {
                var index: i16 = @intCast(i16, std.mem.len(self.hash_history.items)) - 3;
                var limit: i16 = index - self.halfmoves - 1;
                var count: u8 = 0;
                while (index >= limit and index >= 0) {
                    if (self.hash_history.items[@intCast(usize, index)] == position.hash) {
                        count += 1;
                        if (self.ply > 1) {
                            return DRAW;
                        }
                    }
                    if (count >= 2) {
                        return DRAW;
                    }
                    index -= 2;
                }
            }
        }

        if (!is_root) {
            // Mate-distance pruning
            alpha = @maximum(alpha, -INF + self.ply);
            beta = @minimum(beta, INF - self.ply - 1);
            if (alpha >= beta) {
                return alpha;
            }
        }

        const in_check = position.is_king_checked_for(position.turn);

        if (in_check) {
            // Check extension
            depth += 1;
        }

        if (depth == 0) {
            // At horizon, go to quiescence search
            return self.quiescence_search(position, alpha, beta);
        }

        var tthit = false;

        // TT Probe
        if (!is_pv and !in_check and depth <= 127) {
            var entry = GlobalTT.probe(position.hash);

            if (entry != null) {
                if (entry.?.depth >= depth) {
                    tthit = true;

                    self.pv_array[old_pv_index] = entry.?.bm;

                    if (entry.?.flag == TT.TTFlag.Exact) {
                        return entry.?.score;
                    } else if (entry.?.flag == TT.TTFlag.Lower) {
                        alpha = std.math.max(alpha, entry.?.score);
                    } else {
                        beta = std.math.max(beta, entry.?.score);
                    }

                    if (alpha >= beta) {
                        return entry.?.score;
                    }
                }
            }
        }

        // TT can be time-consuming
        if (self.stop_search()) {
            return TIME_UP;
        }

        // Static eval
        const eval = Eval.evaluate(position, &self.nnue, self.halfmoves);

        // Pruning
        const is_pruning_allowed = !is_pv and !in_check;

        if (is_pruning_allowed) {
            // Razoring
            const RazoringMargin: i16 = 339;
            if (depth < 2 and eval + RazoringMargin < alpha) {
                return self.quiescence_search(position, alpha, beta);
            }

            // Reversed futility pruning
            const RFPMargin: i16 = 64;
            var reversed_futility_pruning_margin = RFPMargin * depth;
            if (depth < 9 and eval - reversed_futility_pruning_margin >= beta) {
                return eval - reversed_futility_pruning_margin;
            }

            // Null move pruning
            var is_null_move_allowed = position.phase() >= 5;
            if (is_null_move_allowed and depth >= 2 and eval > beta) {
                var r = 4 + @minimum(depth / 4, 3);
                if (eval > beta + 100) {
                    r += 1;
                }
                r = @minimum(depth, r);
                position.make_null_move();
                self.ply += 1;

                var score = -self.negamax(position, -beta, -beta + 1, depth - r);

                self.ply -= 1;
                position.undo_null_move();

                if (score >= beta) {
                    return score;
                }
            }
        }

        // var pruning_threashold: i16 = 6 + depth * depth;

        var lmr_threashold: u8 = 3;
        if (is_pv) {
            lmr_threashold += 1;
        }

        const FP_MARGIN: i16 = 97;
        var fp_margin = eval + FP_MARGIN * @intCast(i16, depth);

        if (self.stop_search()) {
            return TIME_UP;
        }

        // generate moves
        var moves = Movegen.generate_all_pseudo_legal_moves(position);
        defer moves.deinit();

        // Order and sort
        var oi = Ordering.OrderInfo{
            .pos = position,
            .searcher = self,
            .old_pv = old_pv,
        };

        for (moves.items) |*k| {
            k.score = Ordering.score_move(k.m, oi);
        }

        std.sort.sort(
            Movegen.Move,
            moves.items,
            oi,
            Ordering.order,
        );

        var legals: u16 = 0;
        var bm: u24 = 0;
        var bs: i16 = -INF;
        var count: usize = 0;
        const length = std.mem.len(moves.items);
        var skip_quiet = false;

        while (count < length) {
            var m = moves.items[count].m;
            count += 1;

            var is_quiet = Encode.capture(m) == 0;
            if (is_quiet and skip_quiet) {
                continue;
            }

            var is_killer = self.killers[0][self.ply] == m or self.killers[1][self.ply] == m;

            if (!is_root and bs > -INF) {
                if (depth < 8 and is_quiet and !is_killer and fp_margin <= alpha and std.math.absInt(alpha) catch 0 < INF - 100) {
                    skip_quiet = true;
                    continue;
                }
            }

            // MAKE MOVES

            position.make_move(m, &self.nnue);

            // illegal?
            if (position.is_king_checked_for(position.turn.invert())) {
                position.undo_move(m, &self.nnue);
                continue;
            }

            self.hm_stack.append(self.halfmoves) catch {};
            if (Encode.capture(m) != 0 or Encode.pt(m) % 6 == 0) {
                self.halfmoves = 0;
            } else {
                self.halfmoves += 1;
            }
            self.hash_history.append(position.hash) catch {};

            legals += 1;
            self.ply += 1;

            // DONE MAKING MOVES

            var lmr_depth: i16 = 0;

            // Reductions
            if (bs > -INF) {
                // LMR
                if (depth > 2 and legals >= lmr_threashold and (is_quiet or (moves.items[count - 1].score - Ordering.CAPTURE_SCORE < 0))) {
                    if (is_quiet) {
                        lmr_depth = LMR.QuietLMR[@minimum(31, depth)][@minimum(31, legals)];
                    } else {
                        lmr_depth = LMR.NoisyLMR[@minimum(31, depth)][@minimum(31, legals)];
                        const captured = position.mailbox[Position.fen_sq_to_sq(Encode.target(m))].?;
                        const LMRCaptureMargin: i16 = 86;
                        if (eval + HCE.PieceValues[@enumToInt(captured) % 6] + LMRCaptureMargin < beta) {
                            lmr_depth += 1;
                        }
                    }

                    if (in_check) {
                        lmr_depth -= 1;
                    }
                    if (is_killer) {
                        lmr_depth -= 1;
                    }
                    if (is_pv) {
                        lmr_depth -= 1;
                    }

                    lmr_depth = @minimum(depth - 2, @maximum(1, lmr_depth));
                }
            }

            var score: i16 = 0;

            // PVS
            score = -self.negamax(position, -alpha - 1, -alpha, depth - 1 - @intCast(u8, lmr_depth));
            if (score > alpha and score < beta) {
                score = -self.negamax(position, -beta, -alpha, depth - 1 - @intCast(u8, lmr_depth));
            }

            // UNDO MOVES
            position.undo_move(m, &self.nnue);
            self.halfmoves = self.hm_stack.pop();
            _ = self.hash_history.pop();
            self.ply -= 1;

            if (self.stop_search()) {
                return TIME_UP;
            }

            // *** Alpha-beta pruning ***

            // fail hard
            if (score >= beta) {
                // Killer
                if (is_quiet) {
                    self.killers[1][self.ply] = self.killers[0][self.ply];
                    self.killers[0][self.ply] = m;
                }

                // store in PV
                self.pv_array[old_pv_index] = m;
                self.movcpy(old_pv_index + 1, self.pv_index, MAX_PLY - self.ply - 1);

                return beta;
            }

            if (score > bs) {
                bs = score;
            }

            // better move
            if (score > alpha) {
                alpha = score;
                bs = score;
                bm = m;

                // History
                if (is_quiet) {
                    self.history[Encode.source(m)][Encode.target(m)] += depth + (depth / 2);
                }

                // store in PV
                self.pv_array[old_pv_index] = m;
                self.movcpy(old_pv_index + 1, self.pv_index, MAX_PLY - self.ply - 1);
            }

            if (alpha >= beta) {
                break;
            }
        }

        // checkmate or stalemate
        if (legals == 0) {
            if (position.is_king_checked_for(position.turn)) {
                // add bonus for closer checkmates
                // so we prefer M2 over M9
                return -INF + self.ply;
            } else {
                return 0;
            }
        }

        // Store in TT
        if (depth <= 127) {
            var flag = if (bs <= alpha_)
                TT.TTFlag.Upper
            else if (bs >= beta)
                TT.TTFlag.Lower
            else
                TT.TTFlag.Exact;

            GlobalTT.insert(position.hash, @intCast(u8, depth), bs, flag, bm);
        }

        return alpha;
    }

    //
    // Quiescence search for non-quiet moves
    //
    pub fn quiescence_search(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16) i16 {
        var alpha = alpha_;
        var beta = beta_;

        self.nodes += 1;

        if (Eval.is_material_drawn(position)) {
            return DRAW;
        }

        // Static eval
        var stand_pat = Eval.evaluate(position, &self.nnue, self.halfmoves);

        // *** Static evaluation pruning ***
        if (stand_pat >= beta) {
            return stand_pat;
        }

        if (alpha < stand_pat) {
            alpha = stand_pat;
        }

        // we don't want to overflow plies...
        if (self.ply == MAX_PLY) {
            return stand_pat;
        }

        if (self.stop_search()) {
            return TIME_UP;
        }

        // generate capture moves
        var moves = Movegen.generate_all_pseudo_legal_capture_moves(position);
        defer moves.deinit();

        var count: usize = 0;
        var length = std.mem.len(moves.items);

        var oi = Ordering.OrderInfo{
            .pos = position,
            .searcher = self,
            .old_pv = 0,
        };

        for (moves.items) |*k| {
            k.score = Ordering.score_move(k.m, oi);
        }

        std.sort.sort(
            Movegen.Move,
            moves.items,
            oi,
            Ordering.order,
        );

        var bm: u24 = 0;
        var bs: i16 = -INF;

        while (count < length) {
            var m = moves.items[count].m;

            // losing too much material? Search them during negamax, not here.
            if (moves.items[count].score - Ordering.CAPTURE_SCORE < 0) {
                break;
            }

            count += 1;

            position.make_move(m, &self.nnue);
            // illegal?
            if (position.is_king_checked_for(position.turn.invert())) {
                position.undo_move(m, &self.nnue);
                continue;
            }

            self.ply += 1;

            var score = -self.quiescence_search(position, -beta, -alpha);
            position.undo_move(m, &self.nnue);
            self.ply -= 1;

            if (self.stop_search()) {
                return TIME_UP;
            }

            // *** Alpha-beta pruning ***

            if (score > bs) {
                bs = score;
            }
            // fail hard
            if (score >= beta) {
                return beta;
            }
            // better move
            if (score > alpha) {
                bm = m;
                bs = score;
                alpha = score;
            }
            if (alpha >= beta) {
                break;
            }
        }

        return alpha;
    }
};
