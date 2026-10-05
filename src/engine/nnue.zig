const std = @import("std");
const platform = @import("../platform.zig");
const builtin = @import("builtin");
pub const weights = @import("weights.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const zobrist = @import("../chess/zobrist.zig");
const EvalCache = @import("nnue/eval_cache.zig").EvalCache;

const HALF_BUCKET_LAYOUT: [32]usize = .{
    0,  1,  2,  3,
    4,  5,  6,  7,
    8,  8,  9,  9,
    10, 10, 11, 11,
    12, 12, 13, 13,
    12, 12, 13, 13,
    14, 14, 15, 15,
    14, 14, 15, 15,
};

const FILE_MIRROR: [8]usize = .{ 0, 1, 2, 3, 3, 2, 1, 0 };

pub const INPUT_BUCKET_LAYOUT: [64]usize = blk: {
    var layout: [64]usize = undefined;
    for (0..64) |idx| {
        layout[idx] = HALF_BUCKET_LAYOUT[(idx / 8) * 4 + FILE_MIRROR[idx % 8]];
    }
    break :blk layout;
};

inline fn king_square(pos: *const position.Position, color: types.Color) types.Square {
    const king = types.Piece.new(color, types.PieceType.King);
    const king_bb = pos.piece_bitboards[king.index()];
    const index = if (king_bb == 0) 0 else types.lsb(king_bb);
    return @as(types.Square, @fromBackingInt(@intCast(index)));
}

inline fn pov_square(sq: types.Square, comptime perspective: types.Color) usize {
    return if (perspective == types.Color.White) sq.index() else sq.index() ^ 56;
}

inline fn perspective_king_sq(pos: *const position.Position, comptime perspective: types.Color) usize {
    return pov_square(king_square(pos, perspective), perspective);
}

inline fn king_bucket_state(pos: *const position.Position, comptime perspective: types.Color) KingBucketState {
    if (comptime weights.NUM_INPUT_BUCKETS == 1) return .{};
    return KingBucketState.from_king(perspective_king_sq(pos, perspective));
}

inline fn king_mirror(king_pov: usize) bool {
    return king_pov & 7 > 3;
}

inline fn king_input_bucket(king_pov: usize) usize {
    return INPUT_BUCKET_LAYOUT[king_pov];
}

const KingBucketState = struct {
    weight_offset: usize = 0,
    bucket: u8 = 0,
    flip: u8 = 0,

    inline fn from_king(king_pov: usize) KingBucketState {
        const bucket = king_input_bucket(king_pov);
        return .{
            .weight_offset = bucket * 768 * weights.HIDDEN_SIZE,
            .bucket = @intCast(bucket),
            .flip = if (king_mirror(king_pov)) 7 else 0,
        };
    }

    inline fn mirror_index(self: KingBucketState) usize {
        return @intFromBool(self.flip != 0);
    }

    inline fn same_slot(self: KingBucketState, other: KingBucketState) bool {
        return self.bucket == other.bucket and self.flip == other.flip;
    }
};

fn feature_index_pov(
    piece: types.Piece,
    sq: types.Square,
    comptime perspective: types.Color,
    state: KingBucketState,
) usize {
    const code: usize = @backingInt(piece);
    const piece_offset = (code & 7) * 64;
    const color_offset = ((code >> 3) ^ @backingInt(perspective)) * 384;
    const oriented_sq = sq.index() ^ (if (perspective == types.Color.White) 0 else 56);
    const feature = (color_offset + piece_offset + oriented_sq) ^ state.flip;
    return state.weight_offset + feature * weights.HIDDEN_SIZE;
}

// Wide source vectors let LLVM unroll accumulator updates aggressively. Each
// head picks its own vector width for inference.
const UPDATE_LANES: usize = 32;

const Perspective = [weights.HIDDEN_SIZE]i16;

/// `dst = src + the added feature rows - the removed ones`. The arithmetic
/// wraps: only the result has to fit, not every partial sum.
fn apply_rows(comptime added: usize, comptime removed: usize, dst: *align(64) Perspective, src: *align(64) const Perspective, add_rows: [added]usize, sub_rows: [removed]usize) void {
    const V = @Vector(UPDATE_LANES, i16);
    const m1 = &weights.MODEL.layer_1;
    var i: usize = 0;
    while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
        var lanes: V = src[i..][0..UPDATE_LANES].*;
        inline for (add_rows) |row| lanes +%= @as(V, m1[row + i ..][0..UPDATE_LANES].*);
        inline for (sub_rows) |row| lanes -%= @as(V, m1[row + i ..][0..UPDATE_LANES].*);
        dst[i..][0..UPDATE_LANES].* = lanes;
    }
}

pub const Accumulator = struct {
    white: Perspective align(64),
    black: Perspective align(64),

    inline fn perspective(self: anytype, comptime color: types.Color) @TypeOf(&self.white) {
        return if (color == types.Color.White) &self.white else &self.black;
    }
};

const FinnyEntry = struct {
    acc: [weights.HIDDEN_SIZE]i16 align(64) = undefined,
    pieces: [2][6]u64 = @splat(@splat(0)),

    fn clear(self: *FinnyEntry) void {
        self.acc = weights.MODEL.layer_1_bias;
        self.pieces = @splat(@splat(0));
    }
};

/// Finny table: [perspective_color][mirror][bucket]
const FinnyTable = if (weights.NUM_INPUT_BUCKETS > 1)
    [2][2][weights.NUM_INPUT_BUCKETS]FinnyEntry
else
    void;

pub const STACK_CAP = 256;

const Feature = struct {
    piece: types.Piece,
    square: types.Square,
};

const MAX_CHANGES = 2;

/// What the move that led to a frame changed, and which perspectives of the
/// frame hold their accumulator. See "Lazy updates" in docs/NNUE.md.
const FrameState = struct {
    adds: [MAX_CHANGES]Feature = undefined,
    subs: [MAX_CHANGES]Feature = undefined,
    add_count: u8 = 0,
    sub_count: u8 = 0,
    rebuild: [2]bool = .{ false, false },
    computed: [2]bool = .{ false, false },

    const stale: FrameState = .{ .rebuild = .{ true, true } };
    const fresh: FrameState = .{ .computed = .{ true, true } };

    fn record(self: *FrameState, comptime added: usize, comptime removed: usize, adds: [added]Feature, subs: [removed]Feature) void {
        if (self.add_count + added > MAX_CHANGES or self.sub_count + removed > MAX_CHANGES) {
            self.rebuild = .{ true, true };
            return;
        }
        inline for (adds) |feature| {
            self.adds[self.add_count] = feature;
            self.add_count += 1;
        }
        inline for (subs) |feature| {
            self.subs[self.sub_count] = feature;
            self.sub_count += 1;
        }
    }
};

/// The heap memory of an evaluator. It outlives `Position.reset`.
pub const Storage = struct {
    frames: [STACK_CAP]Accumulator,
    states: [STACK_CAP]FrameState,
    cache: EvalCache,
};

pub const NNUE = struct {
    storage: ?*Storage = null,
    depth: u16 = 0,
    /// Between `push` and `commit`: piece changes belong to the move being played.
    recording: bool = false,
    in_undo: bool = false,
    piece_count: u8 = 0,
    finny: FinnyTable = if (weights.NUM_INPUT_BUCKETS > 1) undefined else {},
    finny_ready: bool = false,

    pub fn new() NNUE {
        return .{};
    }

    pub fn ensure_storage(self: *NNUE) void {
        if (self.storage != null) return;
        const storage = platform.allocator.create(Storage) catch unreachable;
        storage.cache.clear();
        self.adopt_storage(storage);
    }

    pub fn release_storage(self: *NNUE) void {
        if (self.storage) |storage| platform.allocator.destroy(storage);
        self.storage = null;
    }

    /// Takes over the storage of an evaluator that was reset; the board is empty.
    pub fn adopt_storage(self: *NNUE, storage: ?*Storage) void {
        self.storage = storage;
        self.depth = 0;
        if (storage) |s| s.states[0] = .stale;
    }

    /// Required after the network weights change.
    pub fn discard_caches(self: *NNUE) void {
        self.finny_ready = false;
        if (self.storage) |storage| storage.cache.clear();
    }

    inline fn current(self: *const NNUE) *Accumulator {
        return &self.storage.?.frames[self.depth];
    }

    inline fn frame_state(self: *const NNUE) *FrameState {
        return &self.storage.?.states[self.depth];
    }

    /// The accumulators of the current position, brought up to date.
    pub fn accumulator(self: *NNUE, pos: *const position.Position) *const Accumulator {
        self.materialize(pos);
        return self.current();
    }

    /// Opens the frame of a move; `pos` is still the position before it.
    pub inline fn push(self: *NNUE, pos: *const position.Position) void {
        if (self.depth + 1 == STACK_CAP) self.rebase(pos);
        self.depth += 1;
        self.frame_state().* = .{};
        self.recording = true;
    }

    /// Closes the frame of a move; `pos` is the position after it.
    pub inline fn commit(self: *NNUE, pos: *const position.Position, comptime mover: types.Color, king_moved: bool) void {
        self.recording = false;
        if (comptime weights.NUM_INPUT_BUCKETS == 1) return;
        if (king_moved) self.flag_king_bucket_change(pos, mover);
    }

    pub inline fn pop(self: *NNUE) void {
        self.depth -= 1;
    }

    fn rebase(self: *NNUE, pos: *const position.Position) void {
        self.materialize(pos);
        const storage = self.storage.?;
        storage.frames[0] = storage.frames[self.depth];
        storage.states[0] = .fresh;
        self.depth = 0;
    }

    pub fn reset_depth(self: *NNUE, pos: *const position.Position) void {
        if (self.depth != 0) self.rebase(pos);
    }

    fn flag_king_bucket_change(self: *NNUE, pos: *const position.Position, comptime mover: types.Color) void {
        const frame = self.frame_state();
        const king = types.Piece.new_comptime(mover, types.PieceType.King);
        const now = KingBucketState.from_king(perspective_king_sq(pos, mover));
        for (frame.subs[0..frame.sub_count]) |feature| {
            if (feature.piece != king) continue;
            const before = KingBucketState.from_king(pov_square(feature.square, mover));
            if (!before.same_slot(now)) frame.rebuild[@backingInt(mover)] = true;
            return;
        }
    }

    inline fn change(self: *NNUE, comptime added: usize, comptime removed: usize, adds: [added]Feature, subs: [removed]Feature) void {
        if (self.in_undo) return;
        if (self.recording) self.frame_state().record(added, removed, adds, subs) else self.frame_state().* = .stale;
    }

    pub inline fn toggle(self: *NNUE, comptime on: bool, piece: types.Piece, sq: types.Square) void {
        if (on) {
            self.piece_count += 1;
        } else {
            self.piece_count -= 1;
        }
        const feature: Feature = .{ .piece = piece, .square = sq };
        if (on) self.change(1, 0, .{feature}, .{}) else self.change(0, 1, .{}, .{feature});
    }

    pub inline fn move(self: *NNUE, pc: types.Piece, from: types.Square, to: types.Square) void {
        self.change(1, 1, .{.{ .piece = pc, .square = to }}, .{.{ .piece = pc, .square = from }});
    }

    pub inline fn capture(self: *NNUE, captured: types.Piece, pc: types.Piece, from: types.Square, to: types.Square) void {
        self.piece_count -= 1;
        self.change(1, 2, .{.{ .piece = pc, .square = to }}, .{ .{ .piece = pc, .square = from }, .{ .piece = captured, .square = to } });
    }

    fn materialize(self: *NNUE, pos: *const position.Position) void {
        inline for (.{ types.Color.White, types.Color.Black }) |perspective| self.materialize_perspective(pos, perspective);
    }

    /// Frame 0 is always computed or marked for a rebuild, which ends the walk down.
    fn materialize_perspective(self: *NNUE, pos: *const position.Position, comptime perspective: types.Color) void {
        const p = @backingInt(perspective);
        const states = &self.storage.?.states;
        var base: usize = self.depth;
        while (!states[base].computed[p]) : (base -= 1) {
            if (states[base].rebuild[p]) {
                self.rebuild_perspective(pos, perspective);
                states[self.depth].computed[p] = true;
                return;
            }
        }
        if (base == self.depth) return;
        const king = king_bucket_state(pos, perspective);
        for (base + 1..@as(usize, self.depth) + 1) |frame| self.apply_frame(frame, perspective, king);
    }

    fn apply_frame(self: *NNUE, frame: usize, comptime perspective: types.Color, king: KingBucketState) void {
        const storage = self.storage.?;
        const changes = &storage.states[frame];
        const dst = storage.frames[frame].perspective(perspective);
        const src = storage.frames[frame - 1].perspective(perspective);
        const SHAPES = MAX_CHANGES + 1;
        switch (@as(usize, changes.add_count) * SHAPES + changes.sub_count) {
            inline 0...SHAPES * SHAPES - 1 => |shape| {
                const added = shape / SHAPES;
                const removed = shape % SHAPES;
                var add_rows: [added]usize = undefined;
                var sub_rows: [removed]usize = undefined;
                inline for (&add_rows, changes.adds[0..added]) |*row, feature| row.* = feature_index_pov(feature.piece, feature.square, perspective, king);
                inline for (&sub_rows, changes.subs[0..removed]) |*row, feature| row.* = feature_index_pov(feature.piece, feature.square, perspective, king);
                apply_rows(added, removed, dst, src, add_rows, sub_rows);
            },
            else => unreachable,
        }
        changes.computed[@backingInt(perspective)] = true;
    }

    fn rebuild_perspective(self: *NNUE, pos: *const position.Position, comptime perspective: types.Color) void {
        if (comptime weights.NUM_INPUT_BUCKETS > 1) return self.refresh_perspective(pos, perspective);
        const dst = self.current().perspective(perspective);
        dst.* = weights.MODEL.layer_1_bias;
        for (pos.mailbox, 0..) |pc, i| {
            if (pc == types.Piece.NO_PIECE) continue;
            const row = feature_index_pov(pc, @as(types.Square, @fromBackingInt(@intCast(i))), perspective, .{});
            apply_rows(1, 0, dst, dst, .{row}, .{});
        }
    }

    /// Rebuilds both accumulators of the current frame from the pieces on the board.
    pub fn refresh_accumulator(self: *NNUE, pos: *const position.Position) void {
        self.recording = false;
        self.piece_count = @intCast(types.popcount_usize(pos.all_all_pieces()));
        inline for (.{ types.Color.White, types.Color.Black }) |perspective| self.rebuild_perspective(pos, perspective);
        self.frame_state().* = .fresh;
    }

    fn ensure_finny(self: *NNUE) void {
        if (self.finny_ready) return;
        for (&self.finny) |*color_tbl| {
            for (color_tbl) |*mirror_tbl| {
                for (mirror_tbl) |*entry| {
                    entry.clear();
                }
            }
        }
        self.finny_ready = true;
    }

    fn refresh_perspective(self: *NNUE, pos: *const position.Position, comptime perspective: types.Color) void {
        self.ensure_finny();

        const king_pov = perspective_king_sq(pos, perspective);
        const state = KingBucketState.from_king(king_pov);
        const entry = &self.finny[@backingInt(perspective)][state.mirror_index()][state.bucket];

        var adds: [64]usize = undefined;
        var subs: [64]usize = undefined;
        var add_n: usize = 0;
        var sub_n: usize = 0;

        inline for ([_]types.Color{ types.Color.White, types.Color.Black }) |pc_color| {
            inline for (0..6) |pt| {
                const piece = types.Piece.new(pc_color, @as(types.PieceType, @fromBackingInt(@intCast(pt))));
                const cur = pos.piece_bitboards[piece.index()];
                const cached = entry.pieces[@backingInt(pc_color)][pt];

                var added = cur & ~cached;
                while (added != 0) {
                    const sq_i: usize = @intCast(types.lsb(added));
                    added &= added - 1;
                    adds[add_n] = feature_index_pov(piece, @as(types.Square, @fromBackingInt(@intCast(sq_i))), perspective, state);
                    add_n += 1;
                }

                var removed = cached & ~cur;
                while (removed != 0) {
                    const sq_i: usize = @intCast(types.lsb(removed));
                    removed &= removed - 1;
                    subs[sub_n] = feature_index_pov(piece, @as(types.Square, @fromBackingInt(@intCast(sq_i))), perspective, state);
                    sub_n += 1;
                }

                entry.pieces[@backingInt(pc_color)][pt] = cur;
            }
        }

        // One pass brings the cached accumulator up to date and copies it.
        const V = @Vector(UPDATE_LANES, i16);
        const m1 = &weights.MODEL.layer_1;
        const dst = self.current().perspective(perspective);
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
            var lanes: V = entry.acc[i..][0..UPDATE_LANES].*;
            // The removed rows are summed and subtracted once, see "Refresh loop" in docs/NNUE.md.
            var removed: V = @splat(0);
            for (adds[0..add_n]) |row| lanes +%= @as(V, m1[row + i ..][0..UPDATE_LANES].*);
            for (subs[0..sub_n]) |row| removed +%= @as(V, m1[row + i ..][0..UPDATE_LANES].*);
            lanes -%= removed;
            entry.acc[i..][0..UPDATE_LANES].* = lanes;
            dst[i..][0..UPDATE_LANES].* = lanes;
        }
    }

    pub inline fn evaluate(self: *NNUE, turn: types.Color, pos: *const position.Position) i32 {
        return if (turn == types.Color.White) self.evaluate_comptime(types.Color.White, pos) else self.evaluate_comptime(types.Color.Black, pos);
    }

    /// The network's output for `turn`, which need not be the side to move.
    pub inline fn evaluate_comptime(self: *NNUE, comptime turn: types.Color, pos: *const position.Position) i32 {
        const key = if (pos.turn == turn) pos.hash else pos.hash ^ zobrist.TurnHash;
        const cache = &self.storage.?.cache;
        if (cache.get(key)) |output| return output;
        const output = self.evaluate_uncached(turn, pos);
        cache.put(key, output);
        return output;
    }

    pub fn evaluate_uncached(self: *NNUE, comptime turn: types.Color, pos: *const position.Position) i32 {
        const acc = self.accumulator(pos);
        if (comptime builtin.mode == .debug) {
            std.debug.assert(self.piece_count == types.popcount_usize(pos.all_all_pieces()));
        }
        const bucket = @min((self.piece_count -| 2) / 4, weights.OUTPUT_SIZE - 1);

        const own = if (turn == types.Color.White) &acc.white else &acc.black;
        const opp = if (turn == types.Color.White) &acc.black else &acc.white;
        return weights.evaluate(own, opp, bucket);
    }
};
