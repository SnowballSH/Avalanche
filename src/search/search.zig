const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const NNUE = @import("../evaluation/nnue.zig");
const Eval = @import("../evaluation/final.zig");
const Movegen = @import("../move/movegen.zig");
const Uci = @import("../uci/uci.zig");
const Ordering = @import("./ordering.zig");
const Encode = @import("../move/encode.zig");
const TT = @import("../cache/tt.zig");
const LMR = @import("./lmr.zig");

const std = @import("std");

pub const INF: i16 = 32767;

pub const DRAW: i16 = 0;

pub const TIME_UP: i16 = INF - 500;

pub const MAX_PLY = 127;

const PVARRAY = [(MAX_PLY * MAX_PLY + MAX_PLY) / 2]u24;
const KILLER = [2][MAX_PLY]u24;
const HISTORY = [64][64]u32;

pub var GlobalTT: TT.TT = undefined;

pub fn init_tt() void {
    GlobalTT = TT.TT.new(16);
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

    // game
    hash_history: std.ArrayList(u64),
    halfmoves: u8,
    hm_stack: std.ArrayList(u8),

    // Search
    pv_array: PVARRAY,
    pv_index: u16,

    killers: KILLER,
    history: HISTORY,
    in_null: bool,

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

            .hash_history = std.ArrayList(u64).init(std.heap.page_allocator),
            .halfmoves = 0,
            .hm_stack = std.ArrayList(u8).init(std.heap.page_allocator),

            .pv_array = std.mem.zeroes(PVARRAY),
            .pv_index = 0,
            .killers = std.mem.zeroes(KILLER),
            .history = std.mem.zeroes(HISTORY),
            .in_null = false,

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

    pub fn iterative_deepening(self: *Searcher, position: *Position.Position, movetime_nano: usize, force_max_depth: ?u8) void {
        const stdout = std.io.getStdOut().writer();
        self.timer = std.time.Timer.start() catch undefined;
        self.nodes = 0;

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

        var alpha = -INF;
        var beta = INF;

        var max_depth: u8 = MAX_PLY;

        if (Eval.is_material_drawn(position)) {
            max_depth = 2;
        }

        if (force_max_depth != null) {
            max_depth = @minimum(force_max_depth.?, max_depth);
        }

        self.nnue.refresh_accumulator(position);

        var dp: u8 = 1;
        var score: i16 = 0;
        while (dp <= max_depth) {
            self.seldepth = 0;
            for (self.pv_array) |*ptr| {
                ptr.* = 0;
            }

            var score_ = self.negamax(position, alpha, beta, dp);
            if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
                break;
            }
            score = score_;

            if (score > 0 and INF - score < 50) {
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
            } else if (score < 0 and INF + score < 50) {
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

        stdout.writeByte('\n') catch {};

        stdout.print("bestmove {s}\n", .{Uci.move_to_uci(bestmove)}) catch {};

        GlobalTT.reset();
    }

    // Negamax alpha-beta tree search with prunings
    pub fn negamax(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16, depth_: u8) i16 {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;

        if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
            return TIME_UP;
        }

        self.nodes += 1;

        if (self.ply == MAX_PLY) {
            return Eval.evaluate(position, &self.nnue);
        }

        if (self.ply > self.seldepth) {
            self.seldepth = self.ply;
        }

        if (self.halfmoves >= 100) {
            return DRAW;
        }

        if (Eval.is_material_drawn(position)) {
            return DRAW;
        }

        // set up PV
        self.pv_array[self.pv_index] = 0;
        const old_pv_index = self.pv_index;
        defer self.pv_index = old_pv_index;
        self.pv_index += MAX_PLY - self.ply;

        if (std.mem.len(self.hash_history.items) > 1) {
            var index: i16 = @intCast(i16, std.mem.len(self.hash_history.items)) - 3;
            var limit: i16 = index - self.halfmoves - 1;
            var count: u8 = 0;
            while (index >= limit and index >= 0) {
                if (self.hash_history.items[@intCast(usize, index)] == position.hash) {
                    count += 1;
                }
                if (count >= 2) {
                    return DRAW;
                }
                index -= 2;
            }
        }

        var in_check = position.is_king_checked_for(position.turn);

        if (!in_check and depth <= 127) {
            var entry = GlobalTT.probe(position.hash);

            if (entry != null) {
                if (entry.?.depth >= depth) {
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

        if (depth == 0) {
            // At horizon, go to quiescence search
            return self.quiescence_search(position, alpha, beta);
        }

        if (in_check) {
            // Check extension
            depth += 1;
        }

        if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
            return TIME_UP;
        }

        var eval = Eval.evaluate(position, &self.nnue);

        // Pruning
        var is_pruning_allowed = !in_check;

        if (is_pruning_allowed) {
            // Razoring
            const RazoringMargin: i16 = 375;
            if (depth < 2 and eval + RazoringMargin < beta) {
                return self.quiescence_search(position, alpha, beta);
            }

            // Reversed futility pruning
            const RFPMargin: i16 = 50;
            var reversed_futility_pruning_margin = RFPMargin * depth;
            if (depth < 7 and eval - reversed_futility_pruning_margin >= beta) {
                return eval - reversed_futility_pruning_margin;
            }

            // Null move pruning
            var is_null_move_allowed = position.phase() >= 6 and !self.in_null;
            if (is_null_move_allowed and depth >= 2 and eval > beta) {
                var r = 4 + @minimum(depth / 4, 3);
                if (eval > beta + 95) {
                    r += 1;
                }
                r = @minimum(depth, r);
                position.make_null_move();
                self.ply += 1;
                self.in_null = true;

                var score = -self.negamax(position, -beta, -beta + 1, depth - r);

                self.in_null = false;
                self.ply -= 1;
                position.undo_null_move();

                if (score >= beta) {
                    return score;
                }
            }
        }

        if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
            return TIME_UP;
        }

        // generate moves
        var moves = Movegen.generate_all_pseudo_legal_moves(position);
        defer moves.deinit();

        std.sort.sort(
            u24,
            moves.items,
            Ordering.OrderInfo{
                .pos = position,
                .searcher = self,
            },
            Ordering.order,
        );

        var legals: u16 = 0;
        var bm: u24 = 0;
        var bs: i16 = -INF;
        var count: usize = 0;
        var length = std.mem.len(moves.items);

        while (count < length) {
            var m = moves.items[count];
            count += 1;

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

            var is_quiet = Encode.capture(m) == 0;
            var is_killer = self.killers[0][self.ply] == m or self.killers[1][self.ply] == m;

            // LMR
            var lmr_depth: i16 = 0;

            if (depth >= 2 and legals >= 3 and m != self.pv_array[self.ply - 1] and is_quiet) {
                // TODO include captures after implementing SEE

                lmr_depth = LMR.QuietLMR[@minimum(31, depth)][@minimum(31, legals)];
                if (in_check) {
                    lmr_depth -= 1;
                }
                if (is_killer) {
                    lmr_depth -= 1;
                }

                lmr_depth = @minimum(depth - 2, @maximum(1, lmr_depth));
            }

            // recursive call to negamax
            var score = -self.negamax(position, -beta, -alpha, depth - 1 - @intCast(u8, lmr_depth));

            position.undo_move(m, &self.nnue);
            self.halfmoves = self.hm_stack.pop();
            _ = self.hash_history.pop();
            self.ply -= 1;

            if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
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
                    self.history[Encode.source(m)][Encode.target(m)] += depth;
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

    // Quiescence search for non-quiet moves
    pub fn quiescence_search(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16) i16 {
        var alpha = alpha_;
        var beta = beta_;

        if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
            return TIME_UP;
        }

        if (Eval.is_material_drawn(position)) {
            return DRAW;
        }

        // Static eval
        var stand_pat = Eval.evaluate(position, &self.nnue);

        // *** Static evaluation pruning ***
        if (stand_pat >= beta) {
            return beta;
        }

        if (alpha < stand_pat) {
            alpha = stand_pat;
        }

        // we don't want to overflow plies...
        if (self.ply == MAX_PLY) {
            return stand_pat;
        }

        if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
            return TIME_UP;
        }

        // generate capture moves
        var moves = Movegen.generate_all_pseudo_legal_capture_moves(position);
        defer moves.deinit();

        var count: usize = 0;
        var length = std.mem.len(moves.items);

        std.sort.sort(
            u24,
            moves.items,
            Ordering.OrderInfo{
                .pos = position,
                .searcher = self,
            },
            Ordering.order,
        );

        var bm: u24 = 0;
        var bs: i16 = -INF;

        while (count < length) {
            var m = moves.items[count];

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

            if (self.stop or (self.max_nano != null and self.timer.read() >= self.max_nano.?)) {
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
        }

        return alpha;
    }
};
