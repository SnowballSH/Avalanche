//! Move ordering of the search. See docs/SEARCH.md ("Move picking").
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");
const see = @import("see.zig");
const parameters = @import("parameters.zig");

pub const MVV_LVA = [6][6]i32{ .{ 205, 204, 203, 202, 201, 200 }, .{ 305, 304, 303, 302, 301, 300 }, .{ 405, 404, 403, 402, 401, 400 }, .{ 505, 504, 503, 502, 501, 500 }, .{ 605, 604, 603, 602, 601, 600 }, .{ 705, 704, 703, 702, 701, 700 } };

pub const SORT_HASH: i32 = 6_000_000;
pub const SORT_WINNING_CAPTURE: i32 = 1_000_000;
pub const SORT_LOSING_CAPTURE: i32 = 0;
pub const SORT_WINNING_CAPTURE_FLOOR: i32 = SORT_WINNING_CAPTURE + std.math.minInt(CaptureHistoryEntry);
pub const CAPTURE_VICTIM_SCALE: i32 = 32;
pub const SORT_QUIET: i32 = 0;
pub const SORT_KILLER_1: i32 = 900_000;
pub const SORT_KILLER_2: i32 = 800_000;
pub const SORT_COUNTER_MOVE: i32 = 600_000;
pub const SORT_QUEEN_PROMOTION: i32 = 1_000_000;
pub const SORT_KNIGHT_PROMOTION: i32 = 650_000;
const CONT_HIST_WEIGHT_SCALE: i32 = 128;

const CaptureHistoryEntry = std.meta.Child(@typeInfo(@TypeOf(search.Searcher.capture_history_entry)).@"fn".return_type.?);

pub const ScoreKind = enum {
    exact,
    assumes_winning_exchange,
    hash_move,
};

pub const ScoredMove = struct {
    score: i32,
    kind: ScoreKind = .exact,
};

const MAX_BLOCK_LEN = 16;
const NATIVE_BLOCK_LEN = @min(std.simd.suggestVectorLength(i32) orelse 4, MAX_BLOCK_LEN);
const SLOT_WORD_BITS = @bitSizeOf(usize);

comptime {
    std.debug.assert(types.MoveList.CAPACITY % SLOT_WORD_BITS == 0);
}

pub fn PickerOver(comptime Context: type, comptime block_len: usize) type {
    comptime std.debug.assert(block_len >= 1 and block_len <= MAX_BLOCK_LEN);

    return struct {
        const Self = @This();
        const ScoreBlock = @Vector(block_len, i32);
        const BlockMask = @Int(.unsigned, block_len);

        context: Context,
        moves: []types.Move,
        scores: [types.MoveList.CAPACITY + block_len - 1]i32,
        pending_slots: [types.MoveList.CAPACITY / SLOT_WORD_BITS]usize,
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
                        self.pending_slots[slot / SLOT_WORD_BITS] |= slot_bit(slot);
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
            return self.scores[slot] >= SORT_WINNING_CAPTURE_FLOOR;
        }

        // Ask before playing the picked move: the deferred scan of pick 0 may evaluate exchanges on the board.
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
            return self.pending_slots[slot / SLOT_WORD_BITS] & slot_bit(slot) != 0;
        }

        inline fn lanes_above(block: ScoreBlock, score: i32) BlockMask {
            comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
            return @bitCast(block > @as(ScoreBlock, @splat(score)));
        }

        noinline fn settle_exchange(self: *Self, slot: usize) void {
            self.pending_slots[slot / SLOT_WORD_BITS] &= ~slot_bit(slot);
            self.pending_count -= 1;
            if (!self.context.exchange_wins(self.moves[slot])) {
                self.scores[slot] -= SORT_WINNING_CAPTURE - SORT_LOSING_CAPTURE;
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

pub const MovePicker = PickerOver(SearchContext, NATIVE_BLOCK_LEN);

const SearchContext = struct {
    const Self = @This();
    const ContinuationEntry = i16;
    const ContinuationTable = [64][64]ContinuationEntry;
    const CONTINUATION_WEIGHT_NAMES = [search.CONTINUATION_PLIES_AGO.len][]const u8{ "ContHistWeight1", "ContHistWeight2", "ContHistWeight4" };

    searcher: *search.Searcher,
    pos: *position.Position,
    hashmove: types.Move,
    killers: [2]types.Move,
    counter_move: types.Move,
    history: *const [64][64]i32,
    continuations: [search.CONTINUATION_PLIES_AGO.len]?*const ContinuationTable,
    continuation_weights: [search.CONTINUATION_PLIES_AGO.len]i32,

    pub fn at(searcher: *search.Searcher, pos: *position.Position, hashmove: types.Move, without_continuation_history: bool) Self {
        const ply = searcher.ply;
        var continuations: [search.CONTINUATION_PLIES_AGO.len]?*const ContinuationTable = @splat(null);
        if (!without_continuation_history) {
            for (search.CONTINUATION_PLIES_AGO, &continuations) |plies_ago, *table| {
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
                bonus = SORT_QUEEN_PROMOTION;
            } else if (move.get_flags().promote_type() == types.PieceType.Knight) {
                bonus = SORT_KNIGHT_PROMOTION;
            }
        }
        if (self.hashmove.to_u16() == move.to_u16()) {
            return .{ .score = bonus + SORT_HASH, .kind = .hash_move };
        }
        if (move.is_capture()) {
            const capture_history: i32 = self.searcher.capture_history_entry(pos, move).*;
            if (pos.mailbox[move.to] == types.Piece.NO_PIECE) {
                return .{ .score = bonus + SORT_WINNING_CAPTURE + MVV_LVA[0][0] * CAPTURE_VICTIM_SCALE + capture_history };
            }
            const victim_attacker = MVV_LVA[pos.mailbox[move.to].piece_type().index()][pos.mailbox[move.from].piece_type().index()];
            return .{
                .score = bonus + SORT_WINNING_CAPTURE + victim_attacker * CAPTURE_VICTIM_SCALE + capture_history,
                .kind = .assumes_winning_exchange,
            };
        }

        if (self.killers[0].to_u16() == move.to_u16()) {
            return .{ .score = bonus + SORT_KILLER_1 };
        }
        if (self.killers[1].to_u16() == move.to_u16()) {
            return .{ .score = bonus + SORT_KILLER_2 };
        }
        if (self.counter_move.to_u16() == move.to_u16()) {
            return .{ .score = bonus + SORT_COUNTER_MOVE };
        }

        var quiet_score = bonus + SORT_QUIET + self.history[move.from][move.to];
        for (self.continuations, self.continuation_weights) |continuation, weight| {
            const table = continuation orelse continue;
            quiet_score += @divTrunc(@as(i32, table[move.from][move.to]) * weight, CONT_HIST_WEIGHT_SCALE);
        }
        return .{ .score = quiet_score };
    }

    fn greatest_setting(comptime tunable_name: []const u8) i32 {
        @setEvalBranchQuota(1 << 20);
        for (parameters.TunableParams) |tunable| {
            if (std.mem.eql(u8, tunable.name, tunable_name)) return tunable.max_value;
        }
        @compileError("no tunable named " ++ tunable_name);
    }

    comptime {
        const least_bonus = @min(0, SORT_KNIGHT_PROMOTION, SORT_QUEEN_PROMOTION);
        const greatest_bonus = @max(0, SORT_KNIGHT_PROMOTION, SORT_QUEEN_PROMOTION);
        const greatest_bonus_short_of_queen = @max(0, SORT_KNIGHT_PROMOTION);

        var least_victim_attacker: i32 = std.math.maxInt(i32);
        var greatest_victim_attacker: i32 = std.math.minInt(i32);
        for (MVV_LVA) |by_attacker| {
            least_victim_attacker = @min(least_victim_attacker, std.mem.min(i32, &by_attacker));
            greatest_victim_attacker = @max(greatest_victim_attacker, std.mem.max(i32, &by_attacker));
        }
        const least_capture = least_victim_attacker * CAPTURE_VICTIM_SCALE + std.math.minInt(CaptureHistoryEntry);
        const greatest_capture = greatest_victim_attacker * CAPTURE_VICTIM_SCALE + std.math.maxInt(CaptureHistoryEntry);

        if (least_bonus + SORT_WINNING_CAPTURE + least_capture < SORT_WINNING_CAPTURE_FLOOR) {
            @compileError("a capture whose exchange wins can score below SORT_WINNING_CAPTURE_FLOOR");
        }
        if (greatest_bonus_short_of_queen + SORT_LOSING_CAPTURE + greatest_capture >= SORT_WINNING_CAPTURE_FLOOR) {
            @compileError("a capture whose exchange loses can reach SORT_WINNING_CAPTURE_FLOOR without promoting to a queen");
        }

        const greatest_history = greatest_setting("HistoryGravityMax");
        var greatest_continuation: i32 = 0;
        for (CONTINUATION_WEIGHT_NAMES) |weight_name| {
            greatest_continuation += @divTrunc(-std.math.minInt(ContinuationEntry) * greatest_setting(weight_name), CONT_HIST_WEIGHT_SCALE);
        }
        const greatest_quiet = SORT_QUIET + greatest_history + greatest_continuation;
        const greatest_before_bonus = @max(SORT_WINNING_CAPTURE + greatest_capture, SORT_KILLER_1, SORT_KILLER_2, SORT_COUNTER_MOVE, greatest_quiet);
        if (least_bonus + SORT_HASH <= greatest_bonus + greatest_before_bonus) {
            @compileError("a move can score as high as the hash move, which the picker returns first without comparing scores");
        }
    }
};
