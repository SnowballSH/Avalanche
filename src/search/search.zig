const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const HCE = @import("../evaluation/hce.zig");
const Movegen = @import("../move/movegen.zig");
const Uci = @import("../uci/uci.zig");
const Ordering = @import("./ordering.zig");
const Encode = @import("../move/encode.zig");
const TT = @import("../cache/tt.zig");

const std = @import("std");

pub const INF: i16 = 32767;

pub const DRAW: i16 = 0;

pub const TIME_UP: i16 = INF - 500;

pub const MAX_PLY = 127;

const PVARRAY = [(MAX_PLY * MAX_PLY + MAX_PLY) / 2]u24;

pub var GlobalTT: TT.TT = undefined;

pub fn init_tt() void {
    GlobalTT = TT.TT.new(16);
    GlobalTT.reset();
}

pub const Searcher = struct {
    ply: u8,
    nodes: u64,
    pv_array: PVARRAY,
    pv_index: u16,
    timer: std.time.Timer,
    max_nano: ?u64,
    seldepth: u8,
    hash_history: std.ArrayList(u64),
    halfmoves: u8,
    hm_stack: std.ArrayList(u8),

    pub fn new_searcher() Searcher {
        return Searcher{
            .ply = 0,
            .nodes = 0,
            .pv_array = std.mem.zeroes(PVARRAY),
            .pv_index = 0,
            .timer = undefined,
            .max_nano = null,
            .seldepth = 0,
            .hash_history = std.ArrayList(u64).init(std.heap.page_allocator),
            .halfmoves = 0,
            .hm_stack = std.ArrayList(u8).init(std.heap.page_allocator),
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

    pub fn iterative_deepening(self: *Searcher, position: *Position.Position, movetime_nano: usize) void {
        const stdout = std.io.getStdOut().writer();
        self.timer = std.time.Timer.start() catch undefined;
        self.nodes = 0;

        self.max_nano = movetime_nano;
        if (self.max_nano.? < 30) {
            self.max_nano = 30;
        }
        self.max_nano.? -= 20;

        var bestmove: u24 = 0;

        var dp: u8 = 1;
        while (dp <= 127) {
            self.seldepth = 0;
            for (self.pv_array) |*ptr| {
                ptr.* = 0;
            }

            var score = self.negamax(position, -INF, INF, dp);
            if (self.max_nano != null and self.timer.read() >= self.max_nano.?) {
                break;
            }
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

        stdout.print("bestmove {s}\n", .{Uci.move_to_uci(bestmove)}) catch {};

        GlobalTT.reset();
    }

    // Negamax alpha-beta tree search with prunings
    pub fn negamax(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16, depth_: u8) i16 {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;

        if (self.max_nano != null and self.timer.read() >= self.max_nano.?) {
            return TIME_UP;
        }

        self.nodes += 1;

        if (self.ply > self.seldepth) {
            self.seldepth = self.ply;
        }

        if (self.halfmoves >= 100) {
            return DRAW;
        }

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

        if (depth <= 127) {
            var entry = GlobalTT.probe(position.hash);

            if (entry != null) {
                if (entry.?.depth >= depth) {
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

        // set up PV
        self.pv_array[self.pv_index] = 0;
        const old_pv_index = self.pv_index;
        defer self.pv_index = old_pv_index;
        self.pv_index += MAX_PLY - self.ply;

        var in_check = position.is_king_checked_for(position.turn);

        if (in_check) {
            // Check extension
            depth += 1;
        }

        // generate moves
        var moves = Movegen.generate_all_pseudo_legal_moves(position);
        defer moves.deinit();

        std.sort.sort(
            u24,
            moves.items,
            Ordering.OrderInfo{
                .pos = position,
            },
            Ordering.order,
        );

        var legals: u16 = 0;
        var bm: u24 = 0;

        for (moves.items) |m| {
            position.make_move(m);

            // illegal?
            if (position.is_king_checked_for(position.turn.invert())) {
                position.undo_move(m);
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

            // recursive call to negamax

            // LMR
            var lmr_depth = depth - 1;

            if (!in_check and depth >= 3 and legals >= 3 and m != self.pv_array[self.ply - 1] and Encode.capture(m) == 0) {
                if (legals <= 7) {
                    lmr_depth -= 1;
                } else {
                    lmr_depth /= 2;
                }
            }

            var score = -self.negamax(position, -beta, -alpha, lmr_depth);

            position.undo_move(m);
            self.halfmoves = self.hm_stack.pop();
            _ = self.hash_history.pop();
            self.ply -= 1;

            if (self.max_nano != null and self.timer.read() >= self.max_nano.?) {
                return TIME_UP;
            }

            // *** Alpha-beta pruning ***

            // fail hard
            if (score >= beta) {
                return beta;
            }
            // better move
            if (score > alpha) {
                alpha = score;
                bm = m;

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
            var flag = if (alpha <= alpha_)
                TT.TTFlag.Upper
            else if (alpha >= beta)
                TT.TTFlag.Lower
            else
                TT.TTFlag.Exact;

            GlobalTT.insert(position.hash, @intCast(u8, depth), alpha, flag, bm);
        }

        return alpha;
    }

    // Quiescence search for non-quiet moves
    pub fn quiescence_search(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16) i16 {
        var alpha = alpha_;
        var beta = beta_;

        if (self.max_nano != null and self.timer.read() >= self.max_nano.?) {
            return TIME_UP;
        }

        // if (self.ply > self.seldepth) {
        //     self.seldepth = self.ply;
        // }

        // Static eval
        var stand_pat = HCE.evaluate(position);
        if (position.turn == Piece.Color.Black) {
            stand_pat *= -1;
        }

        // *** Static evaluation pruning ***
        if (stand_pat >= beta) {
            return beta;
        }

        if (alpha < stand_pat) {
            alpha = stand_pat;
        }

        // we don't want to overflow plies...
        if (self.ply >= MAX_PLY) {
            return stand_pat;
        }

        // generate capture moves
        var moves = Movegen.generate_all_pseudo_legal_capture_moves(position);
        defer moves.deinit();

        std.sort.sort(
            u24,
            moves.items,
            Ordering.OrderInfo{
                .pos = position,
            },
            Ordering.order,
        );

        for (moves.items) |m| {
            position.make_move(m);
            // illegal?
            if (position.is_king_checked_for(position.turn.invert())) {
                position.undo_move(m);
                continue;
            }

            self.ply += 1;

            var score = -self.quiescence_search(position, -beta, -alpha);
            position.undo_move(m);
            self.ply -= 1;

            if (self.max_nano != null and self.timer.read() >= self.max_nano.?) {
                return TIME_UP;
            }

            // *** Alpha-beta pruning ***

            // fail hard
            if (score >= beta) {
                return beta;
            }
            // better move
            if (score > alpha) {
                alpha = score;
            }
        }

        return alpha;
    }
};
