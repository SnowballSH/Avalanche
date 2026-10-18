//! The position a probe works on, and the move generation the probes need: captures, every
//! pseudo-legal move, legal moves, and a make-move that reports legality. Attacks come from the
//! engine's tables. See docs/SYZYGY.md.

const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");

pub const MAX_MOVES = 256;
pub const MAX_CAPTURES = 64;

pub const PieceType = enum(u3) { pawn = 1, knight, bishop, rook, queen, king };

pub const Promotion = enum(u4) { none = 0, queen = 1, rook = 2, bishop = 3, knight = 4 };

/// The packing of Pyrrhic's `PyrrhicMove`, which the root probes hand back.
pub const Move = packed struct(u16) {
    to: u6,
    from: u6,
    promotion: Promotion = .none,
};

pub fn MoveList(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]Move = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn slice(self: *const Self) []const Move {
            return self.buffer[0..self.len];
        }

        fn push(self: *Self, move: Move) void {
            self.buffer[self.len] = move;
            self.len += 1;
        }

        fn add(self: *Self, from: u6, to: u6, promotes: bool) void {
            if (promotes) {
                inline for (.{ Promotion.queen, .rook, .bishop, .knight }) |promotion| {
                    self.push(.{ .from = from, .to = to, .promotion = promotion });
                }
            } else {
                self.push(.{ .from = from, .to = to });
            }
        }
    };
}

const PROMOTION_SQUARES: u64 = 0xFF000000000000FF;

inline fn bit(sq: u6) u64 {
    return @as(u64, 1) << sq;
}

inline fn lsb(bb: u64) u6 {
    return @intCast(@ctz(bb));
}

inline fn pop_lsb(bb: *u64) u6 {
    const sq = lsb(bb.*);
    bb.* &= bb.* - 1;
    return sq;
}

inline fn moved_bit(bb: u64, from: u6, to: u6) u64 {
    return (((bb >> from) & 1) << to) | (bb & ~bit(from) & ~bit(to));
}

inline fn pawn_attacks(sq: u6, white: bool) u64 {
    return if (white) tables.WhitePawnAttacks[sq] else tables.BlackPawnAttacks[sq];
}

inline fn bishop_attacks(sq: u6, occupied: u64) u64 {
    return tables.get_bishop_attacks(@fromBackingInt(sq), occupied);
}

inline fn rook_attacks(sq: u6, occupied: u64) u64 {
    return tables.get_rook_attacks(@fromBackingInt(sq), occupied);
}

pub const Board = struct {
    white: u64,
    black: u64,
    kings: u64,
    queens: u64,
    rooks: u64,
    bishops: u64,
    knights: u64,
    pawns: u64,
    /// Saturates at 255; only whether it is zero after a move matters to the probes.
    rule50: u8 = 0,
    /// The en-passant square, 0 when there is none.
    ep: u6 = 0,
    white_to_move: bool,

    pub inline fn us(self: *const Board) u64 {
        return if (self.white_to_move) self.white else self.black;
    }

    pub inline fn them(self: *const Board) u64 {
        return if (self.white_to_move) self.black else self.white;
    }

    pub inline fn occupied(self: *const Board) u64 {
        return self.white | self.black;
    }

    pub fn pieces(self: *const Board, white: bool, piece_type: PieceType) u64 {
        const side = if (white) self.white else self.black;
        return side & switch (piece_type) {
            .pawn => self.pawns,
            .knight => self.knights,
            .bishop => self.bishops,
            .rook => self.rooks,
            .queen => self.queens,
            .king => self.kings,
        };
    }

    pub fn is_pawn_move(self: *const Board, move: Move) bool {
        return self.us() & self.pawns & bit(move.from) != 0;
    }

    pub fn is_en_passant(self: *const Board, move: Move) bool {
        return self.ep != 0 and move.to == self.ep and self.is_pawn_move(move);
    }

    pub fn is_capture(self: *const Board, move: Move) bool {
        return self.them() & bit(move.to) != 0 or self.is_en_passant(move);
    }

    /// Kings never give check, so they are not tested.
    pub fn is_check(self: *const Board) bool {
        const enemy = self.them();
        const occ = self.occupied();
        const sq = lsb(self.kings & self.us());
        return rook_attacks(sq, occ) & (self.rooks | self.queens) & enemy != 0 or
            bishop_attacks(sq, occ) & (self.bishops | self.queens) & enemy != 0 or
            tables.KnightAttacks[sq] & self.knights & enemy != 0 or
            pawn_attacks(sq, self.white_to_move) & self.pawns & enemy != 0;
    }

    pub fn is_mate(self: *const Board) bool {
        if (!self.is_check()) return false;
        var moves: MoveList(MAX_MOVES) = .{};
        self.generate_moves(&moves);
        for (moves.slice()) |move| {
            if (self.play(move) != null) return false;
        }
        return true;
    }

    /// The side that has just moved is not in check.
    fn is_legal(self: *const Board) bool {
        const mover = self.them();
        const enemy = self.us();
        const occ = self.occupied();
        const sq = lsb(self.kings & mover);
        return tables.KingAttacks[sq] & self.kings & enemy == 0 and
            rook_attacks(sq, occ) & (self.rooks | self.queens) & enemy == 0 and
            bishop_attacks(sq, occ) & (self.bishops | self.queens) & enemy == 0 and
            tables.KnightAttacks[sq] & self.knights & enemy == 0 and
            pawn_attacks(sq, !self.white_to_move) & self.pawns & enemy == 0;
    }

    /// The position after `move`, or null when the move leaves the mover in check.
    pub fn play(self: *const Board, move: Move) ?Board {
        const from = move.from;
        const to = move.to;
        var next: Board = .{
            .white = moved_bit(self.white, from, to),
            .black = moved_bit(self.black, from, to),
            .kings = moved_bit(self.kings, from, to),
            .queens = moved_bit(self.queens, from, to),
            .rooks = moved_bit(self.rooks, from, to),
            .bishops = moved_bit(self.bishops, from, to),
            .knights = moved_bit(self.knights, from, to),
            .pawns = moved_bit(self.pawns, from, to),
            .rule50 = 0,
            .ep = 0,
            .white_to_move = !self.white_to_move,
        };

        if (move.promotion != .none) {
            next.pawns &= ~bit(to);
            switch (move.promotion) {
                .queen => next.queens |= bit(to),
                .rook => next.rooks |= bit(to),
                .bishop => next.bishops |= bit(to),
                .knight => next.knights |= bit(to),
                .none => unreachable,
            }
        } else if (self.pawns & bit(from) != 0) {
            if (from ^ to == 16) {
                const passed: u6 = if (self.white_to_move) from + 8 else from - 8;
                const enemy_pawns = self.pawns & self.them();
                if (pawn_attacks(passed, self.white_to_move) & enemy_pawns != 0) next.ep = passed;
            } else if (self.ep != 0 and to == self.ep) {
                const captured = ~bit(if (self.white_to_move) to - 8 else to + 8);
                next.white &= captured;
                next.black &= captured;
                next.pawns &= captured;
            }
        } else if (self.occupied() & bit(to) == 0) {
            next.rule50 = self.rule50 +| 1;
        }

        return if (next.is_legal()) next else null;
    }

    /// At least every legal capture, promotions included.
    pub fn generate_captures(self: *const Board, moves: anytype) void {
        const own = self.us();
        const enemy = self.them();
        const occ = own | enemy;

        var b = own & self.kings;
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = tables.KingAttacks[from] & enemy;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & (self.rooks | self.queens);
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = rook_attacks(from, occ) & enemy;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & (self.bishops | self.queens);
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = bishop_attacks(from, occ) & enemy;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & self.knights;
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = tables.KnightAttacks[from] & enemy;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & self.pawns;
        while (b != 0) {
            const from = pop_lsb(&b);
            const attacks = pawn_attacks(from, self.white_to_move);
            if (self.ep != 0 and attacks & bit(self.ep) != 0) moves.add(from, self.ep, false);
            var targets = attacks & enemy;
            while (targets != 0) {
                const to = pop_lsb(&targets);
                moves.add(from, to, PROMOTION_SQUARES & bit(to) != 0);
            }
        }
    }

    /// Every pseudo-legal move.
    pub fn generate_moves(self: *const Board, moves: *MoveList(MAX_MOVES)) void {
        const own = self.us();
        const enemy = self.them();
        const occ = own | enemy;

        var b = own & self.kings;
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = tables.KingAttacks[from] & ~own;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & (self.rooks | self.queens);
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = rook_attacks(from, occ) & ~own;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & (self.bishops | self.queens);
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = bishop_attacks(from, occ) & ~own;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & self.knights;
        while (b != 0) {
            const from = pop_lsb(&b);
            var targets = tables.KnightAttacks[from] & ~own;
            while (targets != 0) moves.add(from, pop_lsb(&targets), false);
        }
        b = own & self.pawns;
        const start_rank: u3 = if (self.white_to_move) 1 else 6;
        while (b != 0) {
            const from = pop_lsb(&b);
            const attacks = pawn_attacks(from, self.white_to_move);
            if (self.ep != 0 and attacks & bit(self.ep) != 0) moves.add(from, self.ep, false);

            const single: u6 = if (self.white_to_move) from + 8 else from - 8;
            if (occ & bit(single) == 0) {
                moves.add(from, single, PROMOTION_SQUARES & bit(single) != 0);
                if (from >> 3 == start_rank) {
                    const double: u6 = if (self.white_to_move) single + 8 else single - 8;
                    if (occ & bit(double) == 0) moves.add(from, double, false);
                }
            }

            var targets = attacks & enemy;
            while (targets != 0) {
                const to = pop_lsb(&targets);
                moves.add(from, to, PROMOTION_SQUARES & bit(to) != 0);
            }
        }
    }

    pub fn generate_legal(self: *const Board, moves: *MoveList(MAX_MOVES)) void {
        var pseudo: MoveList(MAX_MOVES) = .{};
        self.generate_moves(&pseudo);
        for (pseudo.slice()) |move| {
            if (self.play(move) != null) moves.push(move);
        }
    }
};
