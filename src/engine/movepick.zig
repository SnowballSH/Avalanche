const std = @import("std");
const builtin = @import("builtin");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");
const see = @import("see.zig");
const parameters = @import("parameters.zig");

pub const MVV_LVA = [6][6]i32{ .{ 205, 204, 203, 202, 201, 200 }, .{ 305, 304, 303, 302, 301, 300 }, .{ 405, 404, 403, 402, 401, 400 }, .{ 505, 504, 503, 502, 501, 500 }, .{ 605, 604, 603, 602, 601, 600 }, .{ 705, 704, 703, 702, 701, 700 } };

pub const SortHash: i32 = 6_000_000;
pub const SortWinningCapture: i32 = 1_000_000;
pub const SortLosingCapture: i32 = 0;
pub const SortWinningCaptureFloor: i32 = SortWinningCapture - 32768;
pub const CaptureVictimScale: i32 = 32;
pub const SortQuiet: i32 = 0;
pub const SortKiller1: i32 = 900_000;
pub const SortKiller2: i32 = 800_000;
pub const SortCounterMove: i32 = 600_000;

pub const ScoreKind = enum {
    exact,
    assumes_winning_exchange,
    hash_move,
};

pub const ScoredMove = struct {
    score: i32,
    kind: ScoreKind = .exact,
};

const max_block_len = 16;
const native_block_len = @min(std.simd.suggestVectorLength(i32) orelse 4, max_block_len);
const slot_word_bits = @bitSizeOf(usize);

comptime {
    std.debug.assert(types.MoveList.capacity % slot_word_bits == 0);
}

// Hands out the moves of a list in the order specified in docs/SEARCH.md ("Move picking").
// `Context` scores a move (`score`) and decides a capture's exchange on demand (`exchange_wins`).
// A `.hash_move` score must exceed every other score of the list. `block_len` scores are compared
// at a time while exchanges are undecided.
pub fn PickerOver(comptime Context: type, comptime block_len: usize) type {
    comptime std.debug.assert(block_len >= 1 and block_len <= max_block_len);

    return struct {
        const Self = @This();
        const ScoreBlock = @Vector(block_len, i32);
        const BlockMask = @Int(.unsigned, block_len);

        context: Context,
        moves: []types.Move,
        scores: [types.MoveList.capacity + block_len - 1]i32,
        pending_slots: [types.MoveList.capacity / slot_word_bits]usize,
        pending_count: usize,
        deferred_hash_slot: ?usize,
        picked: usize,

        pub fn init(self: *Self, context: Context, list: *types.MoveList) void {
            self.context = context;
            self.moves = list.mutable_items();
            self.pending_slots = @splat(0);
            self.pending_count = 0;
            self.deferred_hash_slot = null;
            self.picked = 0;
            for (self.moves, 0..) |move, slot| {
                const scored: ScoredMove = self.context.score(move);
                self.scores[slot] = scored.score;
                switch (scored.kind) {
                    .exact => {},
                    .assumes_winning_exchange => {
                        self.pending_slots[slot / slot_word_bits] |= slot_bit(slot);
                        self.pending_count += 1;
                    },
                    .hash_move => self.deferred_hash_slot = slot,
                }
            }
            @memset(self.scores[self.moves.len..][0 .. block_len - 1], std.math.minInt(i32));
        }

        pub inline fn next(self: *Self) ?types.Move {
            const step = self.picked;
            if (step == self.moves.len) return null;
            self.picked = step + 1;
            if (self.deferred_hash_slot) |hash_slot| {
                if (step == 0) {
                    return self.moves[hash_slot];
                }
                self.replay_hash_step(hash_slot);
            }
            return self.select(step);
        }

        pub inline fn index(self: *const Self) usize {
            return self.picked - 1;
        }

        // Ask before playing the picked move: the answer may need the exchange evaluated on the board.
        pub inline fn current_is_winning_capture(self: *Self) bool {
            const slot = self.deferred_hash_slot orelse self.index();
            if (self.exchange_is_pending(slot)) self.settle_exchange(slot);
            return self.scores[slot] >= SortWinningCaptureFloor;
        }

        // The moves `next` has yet to return. Like `current_is_winning_capture`, ask before playing the picked move.
        pub inline fn unpicked(self: *Self) []const types.Move {
            if (self.deferred_hash_slot) |hash_slot| {
                if (self.picked != 0) self.replay_hash_step(hash_slot);
            }
            return self.moves[self.picked..];
        }

        inline fn slot_bit(slot: usize) usize {
            return @as(usize, 1) << @truncate(slot);
        }

        inline fn exchange_is_pending(self: *const Self, slot: usize) bool {
            return self.pending_slots[slot / slot_word_bits] & slot_bit(slot) != 0;
        }

        inline fn lanes_above(block: ScoreBlock, score: i32) BlockMask {
            comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
            return @bitCast(block > @as(ScoreBlock, @splat(score)));
        }

        noinline fn settle_exchange(self: *Self, slot: usize) void {
            self.pending_slots[slot / slot_word_bits] &= ~slot_bit(slot);
            self.pending_count -= 1;
            if (!self.context.exchange_wins(self.moves[slot])) {
                self.scores[slot] -= SortWinningCapture - SortLosingCapture;
            }
        }

        noinline fn replay_hash_step(self: *Self, hash_slot: usize) void {
            const hash_move = self.moves[hash_slot];
            self.deferred_hash_slot = null;
            const replayed = self.select(0);
            std.debug.assert(replayed.to_u16() == hash_move.to_u16());
        }

        inline fn select(self: *Self, step: usize) types.Move {
            if (step + 1 == self.moves.len) return self.moves[step];

            if (self.exchange_is_pending(step)) self.settle_exchange(step);
            return if (self.pending_count == 0) self.select_among_exact(step) else self.select_settling(step);
        }

        inline fn select_among_exact(self: *Self, step: usize) types.Move {
            const moves = self.moves;
            var cur_move = moves[step].to_u16();
            var cur_score = self.scores[step];
            for (moves[step + 1 ..], self.scores[step + 1 .. moves.len]) |*move, *score| {
                const swap_mask = -%@as(u16, @intFromBool(cur_score < score.*));
                const exchanged = (cur_move ^ move.to_u16()) & swap_mask;
                move.* = @bitCast(move.to_u16() ^ exchanged);
                cur_move ^= exchanged;
                const lower = @min(cur_score, score.*);
                cur_score = @max(cur_score, score.*);
                score.* = lower;
            }
            moves[step] = @bitCast(cur_move);
            self.scores[step] = cur_score;
            return @bitCast(cur_move);
        }

        inline fn select_settling(self: *Self, step: usize) types.Move {
            const moves = self.moves;
            var cur_move = moves[step];
            var cur_score = self.scores[step];
            var block_start = step + 1;
            while (block_start < moves.len) : (block_start += block_len) {
                const block: ScoreBlock = self.scores[block_start..][0..block_len].*;
                var candidates = lanes_above(block, cur_score);
                while (candidates != 0) {
                    const slot = block_start + @ctz(candidates);
                    candidates &= candidates - 1;
                    if (self.exchange_is_pending(slot)) self.settle_exchange(slot);
                    const slot_score = self.scores[slot];
                    if (cur_score < slot_score) {
                        self.scores[slot] = cur_score;
                        cur_score = slot_score;
                        std.mem.swap(types.Move, &moves[slot], &cur_move);
                        candidates &= lanes_above(block, cur_score);
                    }
                }
            }
            moves[step] = cur_move;
            self.scores[step] = cur_score;
            return cur_move;
        }
    };
}

pub fn MovePicker(comptime follows_null_move: bool) type {
    return PickerOver(SearchContext(follows_null_move), native_block_len);
}

fn SearchContext(comptime follows_null_move: bool) type {
    return struct {
        const Self = @This();
        const continuation_plies_ago = [_]usize{ 0, 1, 3 };
        const ContinuationTable = [64][64]i16;

        searcher: *search.Searcher,
        pos: *position.Position,
        hashmove: types.Move,
        killers: [2]types.Move,
        // Empty when there is none: no legal move encodes as 0.
        counter_move: types.Move,
        history: *const [64][64]i32,
        continuations: [continuation_plies_ago.len]?*const ContinuationTable,
        continuation_weights: [continuation_plies_ago.len]i32,

        pub fn at(searcher: *search.Searcher, pos: *position.Position, hashmove: types.Move) Self {
            const ply = searcher.ply;
            var continuations: [continuation_plies_ago.len]?*const ContinuationTable = @splat(null);
            if (!follows_null_move) {
                for (continuation_plies_ago, &continuations) |plies_ago, *table| {
                    if (ply < plies_ago + 1) continue;
                    const prev = searcher.move_history[ply - plies_ago - 1];
                    if (prev.to_u16() == 0) continue;
                    table.* = &searcher.continuation[searcher.moved_piece_history[ply - plies_ago - 1].pure_index()][prev.to];
                }
            }
            const last = if (ply > 0) searcher.move_history[ply - 1] else types.Move.empty();
            return .{
                .searcher = searcher,
                .pos = pos,
                .hashmove = hashmove,
                .killers = searcher.killer[ply],
                .counter_move = if (ply >= 1) searcher.counter_moves[@backingInt(pos.turn)][last.from][last.to] else types.Move.empty(),
                .history = &searcher.history[@backingInt(pos.turn)],
                .continuations = continuations,
                .continuation_weights = .{ parameters.ContHistWeight1, parameters.ContHistWeight2, parameters.ContHistWeight4 },
            };
        }

        pub fn exchange_wins(self: *const Self, move: types.Move) bool {
            return see.see_threshold(self.pos, move, -parameters.MovepickSEEMargin);
        }

        pub inline fn score(self: *const Self, move: types.Move) ScoredMove {
            const pos = self.pos;
            var bonus: i32 = 0;
            if (move.is_promotion()) {
                if (move.get_flags().promote_type() == types.PieceType.Queen) {
                    bonus = 1_000_000;
                } else if (move.get_flags().promote_type() == types.PieceType.Knight) {
                    bonus = 650_000;
                }
            }
            if (self.hashmove.to_u16() == move.to_u16()) {
                return .{ .score = bonus + SortHash, .kind = .hash_move };
            }
            if (move.is_capture()) {
                const capture_history: i32 = self.searcher.capture_history_entry(pos, move).*;
                if (pos.mailbox[move.to] == types.Piece.NO_PIECE) {
                    return .{ .score = bonus + SortWinningCapture + MVV_LVA[0][0] * CaptureVictimScale + capture_history };
                }
                const victim_attacker = MVV_LVA[pos.mailbox[move.to].piece_type().index()][pos.mailbox[move.from].piece_type().index()];
                return .{
                    .score = bonus + SortWinningCapture + victim_attacker * CaptureVictimScale + capture_history,
                    .kind = .assumes_winning_exchange,
                };
            }

            if (self.killers[0].to_u16() == move.to_u16()) {
                return .{ .score = bonus + SortKiller1 };
            }
            if (self.killers[1].to_u16() == move.to_u16()) {
                return .{ .score = bonus + SortKiller2 };
            }
            if (self.counter_move.to_u16() == move.to_u16()) {
                return .{ .score = bonus + SortCounterMove };
            }

            var quiet_score = bonus + SortQuiet + self.history[move.from][move.to];
            for (self.continuations, self.continuation_weights) |continuation, weight| {
                const table = continuation orelse continue;
                quiet_score += @divTrunc(@as(i32, table[move.from][move.to]) * weight, 128);
            }
            return .{ .score = quiet_score };
        }
    };
}
