const std = @import("std");
const builtin = @import("builtin");
pub const weights = @import("weights.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");

const QA: i32 = 255;
const QB: i32 = 64;
const QAB: i32 = QA * QB;
const SCALE: i32 = 400;

const FeaturePair = struct {
    white: usize,
    black: usize,
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

// Wide source vectors let LLVM unroll accumulator updates aggressively. Output
// inference separately uses the target's native vector width.
const UPDATE_LANES: usize = 32;
const OUTPUT_LANES = @min(std.simd.suggestVectorLength(i16) orelse 8, 32);
const OutputI16 = @Vector(OUTPUT_LANES, i16);
const OutputI32 = @Vector(OUTPUT_LANES / 2, i32);

comptime {
    std.debug.assert(weights.HIDDEN_SIZE % (OUTPUT_LANES * 4) == 0);
}

/// Pairwise signed i16 dot product. Optimized x86 builds use pmaddwd directly;
/// Debug and other architectures retain the portable expression. LLVM leaves
/// x86 intrinsics unresolved at -ODebug, hence the explicit mode guard.
inline fn madd_i16(a: OutputI16, b: OutputI16) OutputI32 {
    if (comptime builtin.mode != .Debug and builtin.cpu.arch.isX86()) {
        if (comptime OUTPUT_LANES == 32 and builtin.cpu.has(.x86, .avx512f) and builtin.cpu.has(.x86, .avx512bw)) {
            return @extern(*const fn (OutputI16, OutputI16) callconv(.c) OutputI32, .{ .name = "llvm.x86.avx512.pmaddw.d.512" }).*(a, b);
        }
        if (comptime OUTPUT_LANES == 16 and builtin.cpu.has(.x86, .avx2)) {
            return @extern(*const fn (OutputI16, OutputI16) callconv(.c) OutputI32, .{ .name = "llvm.x86.avx2.pmadd.wd" }).*(a, b);
        }
        if (comptime OUTPUT_LANES == 8 and builtin.cpu.has(.x86, .sse2)) {
            return @extern(*const fn (OutputI16, OutputI16) callconv(.c) OutputI32, .{ .name = "llvm.x86.sse2.pmadd.wd" }).*(a, b);
        }
    }

    const a_parts = std.simd.deinterlace(2, a);
    const b_parts = std.simd.deinterlace(2, b);
    const even = @as(OutputI32, @intCast(a_parts[0])) * @as(OutputI32, @intCast(b_parts[0]));
    const odd = @as(OutputI32, @intCast(a_parts[1])) * @as(OutputI32, @intCast(b_parts[1]));
    return even + odd;
}

pub const Accumulator = struct {
    white: [weights.HIDDEN_SIZE]i16 align(64),
    black: [weights.HIDDEN_SIZE]i16 align(64),

    pub inline fn clear(self: *Accumulator) void {
        self.white = weights.MODEL.layer_1_bias;
        self.black = weights.MODEL.layer_1_bias;
    }

    fn update_weights(self: *Accumulator, comptime on: bool, data: FeaturePair) void {
        const V = @Vector(UPDATE_LANES, i16);
        const m1 = &weights.MODEL.layer_1;
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
            const ww: V = self.white[i..][0..UPDATE_LANES].*;
            const wb: V = self.black[i..][0..UPDATE_LANES].*;
            const mw: V = m1[data.white + i ..][0..UPDATE_LANES].*;
            const mb: V = m1[data.black + i ..][0..UPDATE_LANES].*;
            if (on) {
                self.white[i..][0..UPDATE_LANES].* = ww + mw;
                self.black[i..][0..UPDATE_LANES].* = wb + mb;
            } else {
                self.white[i..][0..UPDATE_LANES].* = ww - mw;
                self.black[i..][0..UPDATE_LANES].* = wb - mb;
            }
        }
    }

    fn exchange_weights(self: *Accumulator, from: FeaturePair, to: FeaturePair) void {
        const V = @Vector(UPDATE_LANES, i16);
        const m1 = &weights.MODEL.layer_1;
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
            const fw: V = m1[from.white + i ..][0..UPDATE_LANES].*;
            const tw: V = m1[to.white + i ..][0..UPDATE_LANES].*;
            const fb: V = m1[from.black + i ..][0..UPDATE_LANES].*;
            const tb: V = m1[to.black + i ..][0..UPDATE_LANES].*;
            const ww: V = self.white[i..][0..UPDATE_LANES].*;
            const wb: V = self.black[i..][0..UPDATE_LANES].*;
            self.white[i..][0..UPDATE_LANES].* = ww + tw - fw;
            self.black[i..][0..UPDATE_LANES].* = wb + tb - fb;
        }
    }

    fn capture_weights(self: *Accumulator, captured: FeaturePair, from: FeaturePair, to: FeaturePair) void {
        const V = @Vector(UPDATE_LANES, i16);
        const m1 = &weights.MODEL.layer_1;
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
            const cw: V = m1[captured.white + i ..][0..UPDATE_LANES].*;
            const fw: V = m1[from.white + i ..][0..UPDATE_LANES].*;
            const tw: V = m1[to.white + i ..][0..UPDATE_LANES].*;
            const cb: V = m1[captured.black + i ..][0..UPDATE_LANES].*;
            const fb: V = m1[from.black + i ..][0..UPDATE_LANES].*;
            const tb: V = m1[to.black + i ..][0..UPDATE_LANES].*;
            const ww: V = self.white[i..][0..UPDATE_LANES].*;
            const wb: V = self.black[i..][0..UPDATE_LANES].*;
            self.white[i..][0..UPDATE_LANES].* = ww - cw - fw + tw;
            self.black[i..][0..UPDATE_LANES].* = wb - cb - fb + tb;
        }
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

pub const NNUE = struct {
    accumulator: Accumulator = undefined,
    piece_count: u8 = 0,
    king_state: [2]KingBucketState = .{ .{}, .{} },
    king_state_ready: bool = weights.NUM_INPUT_BUCKETS == 1,
    finny: FinnyTable = if (weights.NUM_INPUT_BUCKETS > 1) undefined else {},
    finny_ready: bool = false,

    pub fn new() NNUE {
        return .{};
    }

    inline fn index_cached(self: *const NNUE, piece: types.Piece, sq: types.Square) FeaturePair {
        if (comptime weights.NUM_INPUT_BUCKETS == 1) {
            return nnue_index_flat(piece, sq);
        }
        const w = self.king_state[0];
        const b = self.king_state[1];
        return nnue_index_buckets(piece, sq, w, b);
    }

    pub inline fn toggle(self: *NNUE, comptime on: bool, piece: types.Piece, sq: types.Square) void {
        if (on) {
            self.piece_count += 1;
        } else {
            self.piece_count -= 1;
        }
        if (comptime weights.NUM_INPUT_BUCKETS > 1) {
            if (!self.king_state_ready) return;
        }
        self.accumulator.update_weights(on, self.index_cached(piece, sq));
    }

    pub fn refresh_accumulator(self: *NNUE, pos: *position.Position) void {
        self.piece_count = @intCast(types.popcount_usize(pos.all_all_pieces()));
        if (comptime weights.NUM_INPUT_BUCKETS == 1) {
            self.accumulator.clear();
            for (pos.mailbox, 0..) |pc, i| {
                if (pc == types.Piece.NO_PIECE) continue;
                self.accumulator.update_weights(true, nnue_index_flat(pc, @as(types.Square, @enumFromInt(i))));
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
        const current = KingBucketState.from_king(kp);
        const prev = self.king_state[@intFromEnum(color)];
        if (!prev.same_slot(current)) {
            self.refresh_perspective(pos, color);
            self.king_state[@intFromEnum(color)] = current;
        }
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

        const V = @Vector(UPDATE_LANES, i16);
        const m1 = &weights.MODEL.layer_1;
        const min_n = @min(add_n, sub_n);
        var n: usize = 0;
        while (n < min_n) : (n += 1) {
            const a = adds[n];
            const s = subs[n];
            var i: usize = 0;
            while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
                const av: V = m1[a + i ..][0..UPDATE_LANES].*;
                const sv: V = m1[s + i ..][0..UPDATE_LANES].*;
                const dv: V = entry.acc[i..][0..UPDATE_LANES].*;
                entry.acc[i..][0..UPDATE_LANES].* = dv + av - sv;
            }
        }
        while (n < add_n) : (n += 1) {
            const a = adds[n];
            var i: usize = 0;
            while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
                const av: V = m1[a + i ..][0..UPDATE_LANES].*;
                const dv: V = entry.acc[i..][0..UPDATE_LANES].*;
                entry.acc[i..][0..UPDATE_LANES].* = dv + av;
            }
        }
        n = min_n;
        while (n < sub_n) : (n += 1) {
            const s = subs[n];
            var i: usize = 0;
            while (i < weights.HIDDEN_SIZE) : (i += UPDATE_LANES) {
                const sv: V = m1[s + i ..][0..UPDATE_LANES].*;
                const dv: V = entry.acc[i..][0..UPDATE_LANES].*;
                entry.acc[i..][0..UPDATE_LANES].* = dv - sv;
            }
        }

        if (perspective == types.Color.White) {
            self.accumulator.white = entry.acc;
        } else {
            self.accumulator.black = entry.acc;
        }
    }

    pub inline fn move(self: *NNUE, pc: types.Piece, from: types.Square, to: types.Square) void {
        if (comptime weights.NUM_INPUT_BUCKETS > 1) {
            if (!self.king_state_ready) return;
        }
        self.accumulator.exchange_weights(self.index_cached(pc, from), self.index_cached(pc, to));
    }

    pub inline fn capture(self: *NNUE, captured: types.Piece, pc: types.Piece, from: types.Square, to: types.Square) void {
        self.piece_count -= 1;
        if (comptime weights.NUM_INPUT_BUCKETS > 1) {
            if (!self.king_state_ready) return;
        }
        self.accumulator.capture_weights(self.index_cached(captured, to), self.index_cached(pc, from), self.index_cached(pc, to));
    }

    pub inline fn evaluate(self: *const NNUE, turn: types.Color, pos: *const position.Position) i32 {
        return if (turn == types.Color.White) self.evaluate_comptime(types.Color.White, pos) else self.evaluate_comptime(types.Color.Black, pos);
    }

    pub inline fn evaluate_comptime(self: *const NNUE, comptime turn: types.Color, pos: *const position.Position) i32 {
        const acc = &self.accumulator;
        if (comptime builtin.mode == .Debug) {
            std.debug.assert(self.piece_count == types.popcount_usize(pos.all_all_pieces()));
        }
        const bucket = @min((self.piece_count -| 2) / 4, weights.OUTPUT_SIZE - 1);

        const w2 = &weights.MODEL.layer_2[bucket];
        const own = if (turn == types.Color.White) &acc.white else &acc.black;
        const opp = if (turn == types.Color.White) &acc.black else &acc.white;

        const zero: OutputI16 = @splat(0);
        const cap: OutputI16 = @splat(QA);

        var sums: [4]OutputI32 = @splat(@splat(0));
        var i: usize = 0;
        while (i < weights.HIDDEN_SIZE) {
            inline for (&sums) |*sum| {
                const own_activation = std.math.clamp(@as(OutputI16, own[i..][0..OUTPUT_LANES].*), zero, cap);
                const opp_activation = std.math.clamp(@as(OutputI16, opp[i..][0..OUTPUT_LANES].*), zero, cap);
                const own_weights: OutputI16 = w2[i..][0..OUTPUT_LANES].*;
                const opp_weights: OutputI16 = w2[weights.HIDDEN_SIZE + i ..][0..OUTPUT_LANES].*;

                sum.* += madd_i16(own_activation *% own_weights, own_activation) +
                    madd_i16(opp_activation *% opp_weights, opp_activation);
                i += OUTPUT_LANES;
            }
        }

        var sum = sums[0];
        inline for (sums[1..]) |partial| sum += partial;
        const result = @reduce(.Add, sum);
        return @divTrunc((@divTrunc(result, QA) + @as(i32, weights.MODEL.layer_2_bias[bucket])) * SCALE, QAB);
    }
};
