const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const HCE = @import("../evaluation/hce.zig");
const Movegen = @import("../move/movegen.zig");

const std = @import("std");

pub const INF: i16 = 32767;

pub const Searcher = struct {
    ply: u8,

    pub fn negamax(self: *Searcher, position: *Position.Position, alpha_: i16, beta_: i16, depth: u8) i16 {
        var alpha = alpha_;
        var beta = beta_;
        if (depth == 0) {
            return self.*.quiescence_search(position, alpha, beta);
        }

        var moves = Movegen.generate_all_pseudo_legal_moves(position);
        defer moves.deinit();

        var legals: u16 = 0;

        for (moves.items) |m| {
            position.*.make_move(m);
            if (position.*.is_king_checked_for(position.*.turn.invert())) {
                position.*.undo_move(m);
                continue;
            }

            legals += 1;
            self.*.ply += 1;

            var score = -self.*.negamax(position, -beta, -alpha, depth - 1);
            position.*.undo_move(m);
            self.*.ply -= 1;

            if (score >= beta) {
                return beta;
            }
            if (score > alpha) {
                alpha = score;
            }
        }

        if (legals == 0) {
            if (position.*.is_king_checked_for(position.*.turn)) {
                return -INF;
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
        if (position.*.turn == Piece.Color.Black) {
            stand_pat *= -1;
        }
        if (stand_pat >= beta) {
            return beta;
        }
        if (alpha < stand_pat) {
            alpha = stand_pat;
        }

        var moves = Movegen.generate_all_pseudo_legal_capture_moves(position);
        defer moves.deinit();

        for (moves.items) |m| {
            position.*.make_move(m);
            if (position.*.is_king_checked_for(position.*.turn.invert())) {
                position.*.undo_move(m);
                continue;
            }

            self.*.ply += 1;

            var score = -self.*.quiescence_search(position, -beta, -alpha);
            position.*.undo_move(m);
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
    };
}
