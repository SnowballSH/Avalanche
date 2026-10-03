const std = @import("std");
const platform = @import("../platform.zig");
const builtin = @import("builtin");
pub const weights = @import("weights.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");

const FeaturePair = struct {
    white: usize,
    black: usize,

    inline fn row(self: FeaturePair, comptime color: types.Color) usize {
        return if (color == types.Color.White) self.white else self.black;
    }
};

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
    return @as(types.Square, @enumFromInt(index));
}

inline fn perspective_king_sq(pos: *const position.Position, comptime perspective: types.Color) usize {
    const k = king_square(pos, perspective).index();
    return if (perspective == types.Color.White) k else k ^ 56;
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

inline fn nnue_index_flat(piece: types.Piece, sq: types.Square) FeaturePair {
    const code: usize = @intFromEnum(piece);
    const piece_offset = (code & 7) * 64;
    const color_offset = (code >> 3) * 384;
    const white = color_offset + piece_offset + sq.index();
    const black = (color_offset ^ 384) + piece_offset + (sq.index() ^ 56);
    return .{
        .white = white * weights.HIDDEN_SIZE,
        .black = black * weights.HIDDEN_SIZE,
    };
}

inline fn nnue_index_buckets(
    piece: types.Piece,
    sq: types.Square,
    white_state: KingBucketState,
    black_state: KingBucketState,
) FeaturePair {
    const code: usize = @intFromEnum(piece);
    const piece_offset = (code & 7) * 64;
    const color_offset = (code >> 3) * 384;
    const white = (color_offset + piece_offset + sq.index()) ^ white_state.flip;
    const black = ((color_offset ^ 384) + piece_offset + (sq.index() ^ 56)) ^ black_state.flip;
    return .{
        .white = white_state.weight_offset + white * weights.HIDDEN_SIZE,
        .black = black_state.weight_offset + black * weights.HIDDEN_SIZE,
    };
}

fn feature_index_pov(
    piece: types.Piece,
    sq: types.Square,
    comptime perspective: types.Color,
    state: KingBucketState,
) usize {
    const code: usize = @intFromEnum(piece);
    const piece_offset = (code & 7) * 64;
    const color_offset = ((code >> 3) ^ @intFromEnum(perspective)) * 384;
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

    pub inline fn clear(self: *Accumulator) void {
        self.white = weights.MODEL.layer_1_bias;
        self.black = weights.MODEL.layer_1_bias;
    }

    inline fn perspective(self: anytype, comptime color: types.Color) @TypeOf(&self.white) {
        return if (color == types.Color.White) &self.white else &self.black;
    }
};

const FinnyEntry = struct {
    acc: [weights.HIDDEN_SIZE]i16 align(64) = undefined,
    pieces: [2][6]u64 = .{.{0} ** 6} ** 2,

    fn clear(self: *FinnyEntry) void {
        self.acc = weights.MODEL.layer_1_bias;
        self.pieces = .{.{0} ** 6} ** 2;
    }
};

/// Finny table: [perspective_color][mirror][bucket]
const FinnyTable = if (weights.NUM_INPUT_BUCKETS > 1)
    [2][2][weights.NUM_INPUT_BUCKETS]FinnyEntry
else
    void;

pub const STACK_CAP = 256;

pub const Stack = struct {
    frames: [STACK_CAP]Accumulator,
    kings: [STACK_CAP][2]KingBucketState,
};

const UpdateTarget = struct { dst: *Accumulator, src: *const Accumulator };

pub const NNUE = struct {
    stack: ?*Stack = null,
    depth: u16 = 0,
    frame_written: bool = true,
    in_undo: bool = false,
    piece_count: u8 = 0,
    king_state: [2]KingBucketState = .{ .{}, .{} },
    king_state_ready: bool = weights.NUM_INPUT_BUCKETS == 1,
    /// Set for a perspective whose king left its bucket in the move being
    /// played: `reconcile_king_buckets` rebuilds it, so updates skip it.
    refresh_pending: [2]bool = .{ false, false },
    finny: FinnyTable = if (weights.NUM_INPUT_BUCKETS > 1) undefined else {},
    finny_ready: bool = false,

    pub fn new() NNUE {
        return .{};
    }

    pub fn ensure_stack(self: *NNUE) void {
        if (self.stack == null) {
            self.stack = platform.allocator.create(Stack) catch unreachable;
        }
    }

    pub fn release_stack(self: *NNUE) void {
        if (self.stack) |s| platform.allocator.destroy(s);
        self.stack = null;
    }

    pub inline fn current(self: *const NNUE) *Accumulator {
        return &self.stack.?.frames[self.depth];
    }

    inline fn update_target(self: *NNUE) UpdateTarget {
        const stack = self.stack.?;
        const dst = &stack.frames[self.depth];
        if (self.frame_written) return .{ .dst = dst, .src = dst };
        self.frame_written = true;
        return .{ .dst = dst, .src = &stack.frames[self.depth - 1] };
    }

    pub inline fn push(self: *NNUE) void {
        if (self.depth + 1 == STACK_CAP) self.rebase();
        self.stack.?.kings[self.depth] = self.king_state;
        self.depth += 1;
        self.frame_written = false;
    }

    pub inline fn pop(self: *NNUE) void {
        self.depth -= 1;
        self.king_state = self.stack.?.kings[self.depth];
        self.frame_written = true;
    }

    fn rebase(self: *NNUE) void {
        const stack = self.stack.?;
        stack.frames[0] = stack.frames[self.depth];
        self.depth = 0;
    }

    pub fn reset_depth(self: *NNUE) void {
        if (self.depth != 0) self.rebase();
        self.frame_written = true;
    }

    inline fn index_cached(self: *const NNUE, piece: types.Piece, sq: types.Square) FeaturePair {
        if (comptime weights.NUM_INPUT_BUCKETS == 1) {
            return nnue_index_flat(piece, sq);
        }
        const w = self.king_state[0];
        const b = self.king_state[1];
        return nnue_index_buckets(piece, sq, w, b);
    }

    /// Applies one piece change of the move being played to both perspectives.
    fn update(self: *NNUE, comptime added: usize, comptime removed: usize, adds: [added]FeaturePair, subs: [removed]FeaturePair) void {
        const t = self.update_target();
        inline for (.{ types.Color.White, types.Color.Black }) |color| {
            if (!self.refresh_pending[@intFromEnum(color)]) {
                var add_rows: [added]usize = undefined;
                var sub_rows: [removed]usize = undefined;
                inline for (&add_rows, adds) |*row, feature| row.* = feature.row(color);
                inline for (&sub_rows, subs) |*row, feature| row.* = feature.row(color);
                apply_rows(added, removed, t.dst.perspective(color), t.src.perspective(color), add_rows, sub_rows);
            }
        }
    }

    inline fn note_king_move(self: *NNUE, pc: types.Piece, to: types.Square) void {
        if (comptime weights.NUM_INPUT_BUCKETS == 1) return;
        if (pc.piece_type() != types.PieceType.King) return;
        const color = @intFromEnum(pc.color());
        const king_pov = if (pc.color() == types.Color.White) to.index() else to.index() ^ 56;
        if (!self.king_state[color].same_slot(KingBucketState.from_king(king_pov))) self.refresh_pending[color] = true;
    }

    pub inline fn toggle(self: *NNUE, comptime on: bool, piece: types.Piece, sq: types.Square) void {
        if (on) {
            self.piece_count += 1;
        } else {
            self.piece_count -= 1;
        }
        if (self.in_undo) return;
        if (comptime weights.NUM_INPUT_BUCKETS > 1) {
            if (!self.king_state_ready) return;
        }
        const feature = self.index_cached(piece, sq);
        if (on) self.update(1, 0, .{feature}, .{}) else self.update(0, 1, .{}, .{feature});
    }

    pub fn refresh_accumulator(self: *NNUE, pos: *position.Position) void {
        self.frame_written = true;
        self.refresh_pending = .{ false, false };
        self.piece_count = @intCast(types.popcount_usize(pos.all_all_pieces()));
        if (comptime weights.NUM_INPUT_BUCKETS == 1) {
            const acc = self.current();
            acc.clear();
            for (pos.mailbox, 0..) |pc, i| {
                if (pc == types.Piece.NO_PIECE) continue;
                const feature = nnue_index_flat(pc, @as(types.Square, @enumFromInt(i)));
                inline for (.{ types.Color.White, types.Color.Black }) |color| {
                    apply_rows(1, 0, acc.perspective(color), acc.perspective(color), .{feature.row(color)}, .{});
                }
            }
        } else {
            self.ensure_finny();
            self.refresh_perspective(pos, types.Color.White);
            self.refresh_perspective(pos, types.Color.Black);
            self.sync_king_state(pos);
        }
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

    fn sync_king_state(self: *NNUE, pos: *const position.Position) void {
        inline for ([_]types.Color{ types.Color.White, types.Color.Black }) |color| {
            const kp = perspective_king_sq(pos, color);
            self.king_state[@intFromEnum(color)] = KingBucketState.from_king(kp);
        }
        self.king_state_ready = true;
    }

    pub fn reconcile_king_buckets(self: *NNUE, pos: *position.Position, comptime color: types.Color) void {
        if (comptime weights.NUM_INPUT_BUCKETS == 1) return;
        self.ensure_finny();
        const kp = perspective_king_sq(pos, color);
        const now = KingBucketState.from_king(kp);
        const prev = self.king_state[@intFromEnum(color)];
        if (!prev.same_slot(now)) {
            self.refresh_perspective(pos, color);
            self.king_state[@intFromEnum(color)] = now;
        }
        self.refresh_pending[@intFromEnum(color)] = false;
    }

    fn refresh_perspective(self: *NNUE, pos: *const position.Position, comptime perspective: types.Color) void {
        self.ensure_finny();

        const king_pov = perspective_king_sq(pos, perspective);
        const state = KingBucketState.from_king(king_pov);
        const entry = &self.finny[@intFromEnum(perspective)][state.mirror_index()][state.bucket];

        var adds: [64]usize = undefined;
        var subs: [64]usize = undefined;
        var add_n: usize = 0;
        var sub_n: usize = 0;

        inline for ([_]types.Color{ types.Color.White, types.Color.Black }) |pc_color| {
            inline for (0..6) |pt| {
                const piece = types.Piece.new(pc_color, @as(types.PieceType, @enumFromInt(pt)));
                const cur = pos.piece_bitboards[piece.index()];
                const cached = entry.pieces[@intFromEnum(pc_color)][pt];

                var added = cur & ~cached;
                while (added != 0) {
                    const sq_i: usize = @intCast(types.lsb(added));
                    added &= added - 1;
                    adds[add_n] = feature_index_pov(piece, @as(types.Square, @enumFromInt(sq_i)), perspective, state);
                    add_n += 1;
                }

                var removed = cached & ~cur;
                while (removed != 0) {
                    const sq_i: usize = @intCast(types.lsb(removed));
                    removed &= removed - 1;
                    subs[sub_n] = feature_index_pov(piece, @as(types.Square, @enumFromInt(sq_i)), perspective, state);
                    sub_n += 1;
                }

                entry.pieces[@intFromEnum(pc_color)][pt] = cur;
            }
        }

        // One pass brings the cached accumulator up to date and copies it.
        const V = @Vector(UPDATE_LANES, i16);
        const m1 = &weights.MODEL.layer_1;
        const dst = self.current().perspective(perspective);
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
            var lanes: V = entry.acc[i..][0..UPDATE_LANES].*;
            for (adds[0..add_n]) |row| lanes +%= @as(V, m1[row + i ..][0..UPDATE_LANES].*);
            for (subs[0..sub_n]) |row| lanes -%= @as(V, m1[row + i ..][0..UPDATE_LANES].*);
            entry.acc[i..][0..UPDATE_LANES].* = lanes;
            dst[i..][0..UPDATE_LANES].* = lanes;
        }
    }

    pub inline fn move(self: *NNUE, pc: types.Piece, from: types.Square, to: types.Square) void {
        if (self.in_undo) return;
        if (comptime weights.NUM_INPUT_BUCKETS > 1) {
            if (!self.king_state_ready) return;
        }
        self.note_king_move(pc, to);
        self.update(1, 1, .{self.index_cached(pc, to)}, .{self.index_cached(pc, from)});
    }

    pub inline fn capture(self: *NNUE, captured: types.Piece, pc: types.Piece, from: types.Square, to: types.Square) void {
        self.piece_count -= 1;
        if (self.in_undo) return;
        if (comptime weights.NUM_INPUT_BUCKETS > 1) {
            if (!self.king_state_ready) return;
        }
        self.note_king_move(pc, to);
        self.update(1, 2, .{self.index_cached(pc, to)}, .{ self.index_cached(pc, from), self.index_cached(captured, to) });
    }

    pub inline fn evaluate(self: *const NNUE, turn: types.Color, pos: *const position.Position) i32 {
        return if (turn == types.Color.White) self.evaluate_comptime(types.Color.White, pos) else self.evaluate_comptime(types.Color.Black, pos);
    }

    pub inline fn evaluate_comptime(self: *const NNUE, comptime turn: types.Color, pos: *const position.Position) i32 {
        const acc = self.current();
        if (comptime builtin.mode == .Debug) {
            std.debug.assert(self.piece_count == types.popcount_usize(pos.all_all_pieces()));
        }
        const bucket = @min((self.piece_count -| 2) / 4, weights.OUTPUT_SIZE - 1);

        const own = if (turn == types.Color.White) &acc.white else &acc.black;
        const opp = if (turn == types.Color.White) &acc.black else &acc.white;
        return weights.evaluate(own, opp, bucket);
    }
};
