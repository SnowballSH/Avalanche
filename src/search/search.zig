const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const HCE = @import("../evaluation/hce.zig");
const Movegen = @import("../move/movegen.zig");

const std = @import("std");

pub const INF: i16 = 32767;
pub const MAX_PLY = 127;

const PVARRAY = [(MAX_PLY * MAX_PLY + MAX_PLY) / 2]u24;

pub const Searcher = struct {
    ply: u8,
    pv_array: PVARRAY,
    pv_index: u16,

    // copies PV lines
    fn movcpy(self: *Searcher, target_: usize, source_: usize, amount: usize) void {
        var n = amount;
        var target = target_;
        var source = source_;
        while (n != 0) {
            n -= 1;
            if (self.pv_array[source] == 0) {
                self.*.pv_array[target] = 0;
                break;
            }
            self.*.pv_array[target] = self.pv_array[source];
            target += 1;
            source += 1;
        }
    }

    pub fn negamax(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16, depth: u8) i16 {
        var alpha = alpha_;
        var beta = beta_;
        if (depth == 0) {
            return self.quiescence_search(position, alpha, beta);
        }

        self.*.pv_array[self.pv_index] = 0;
        const old_pv_index = self.pv_index;
        defer self.*.pv_index = old_pv_index;
        self.*.pv_index += MAX_PLY - self.ply;

        var moves = Movegen.generate_all_pseudo_legal_moves(position);
        defer moves.deinit();

        var legals: u16 = 0;

        for (moves.items) |m| {
            position.make_move(m);
            if (position.is_king_checked_for(position.*.turn.invert())) {
                position.undo_move(m);
                continue;
            }

            legals += 1;
            self.*.ply += 1;

            var score = -self.negamax(position, -beta, -alpha, depth - 1);
            position.undo_move(m);
            self.*.ply -= 1;

            if (score >= beta) {
                return beta;
            }
            if (score > alpha) {
                alpha = score;
                self.*.pv_array[old_pv_index] = m;
                self.*.movcpy(old_pv_index + 1, self.pv_index, MAX_PLY - self.ply - 1);
            }
        }

        if (legals == 0) {
            if (position.is_king_checked_for(position.*.turn)) {
                return -INF + self.ply;
            } else {
                return 0;
            }
        }

        return alpha;
    }

    pub fn quiescence_search(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16) i16 {
        var alpha = alpha_;
        var beta = beta_;

        var stand_pat = HCE.evaluate(position);
        if (position.turn == Piece.Color.Black) {
            stand_pat *= -1;
        }
        if (stand_pat >= beta) {
            return beta;
        }
        if (alpha < stand_pat) {
            alpha = stand_pat;
        }

        if (self.ply >= MAX_PLY) {
            return stand_pat;
        }

        var moves = Movegen.generate_all_pseudo_legal_capture_moves(position);
        defer moves.deinit();

        for (moves.items) |m| {
            position.make_move(m);
            if (position.is_king_checked_for(position.turn.invert())) {
                position.undo_move(m);
                continue;
            }

            self.*.ply += 1;

            var score = -self.quiescence_search(position, -beta, -alpha);
            position.undo_move(m);
            self.*.ply -= 1;

            if (score >= beta) {
                return beta;
            }
            if (score > alpha) {
                alpha = score;
            }
        }

        return alpha;
    }
};

pub fn new_searcher() Searcher {
    return Searcher{
        .ply = 0,
        .pv_array = std.mem.zeroes(PVARRAY),
        .pv_index = 0,
    };
}
