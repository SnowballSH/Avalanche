const std = @import("std");

const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const cuckoo = @import("../chess/cuckoo.zig");
const hce = @import("hce.zig");
const tt = @import("tt.zig");
const movepick = @import("movepick.zig");
const see = @import("see.zig");
const syzygy = @import("syzygy.zig");

const parameters = @import("parameters.zig");

const DATAGEN = false;

pub var QuietLMR: [64][64]i32 = undefined;

pub fn init_lmr() void {
    var depth: usize = 1;
    while (depth < 64) : (depth += 1) {
        var moves: usize = 1;
        while (moves < 64) : (moves += 1) {
            const a = parameters.LMRWeight * @log(@as(f32, @floatFromInt(depth))) * @log(@as(f32, @floatFromInt(moves))) + parameters.LMRBias;
            QuietLMR[depth][moves] = @as(i32, @intFromFloat(@floor(a)));
        }
    }
}

pub const MAX_PLY = 128;
pub const MAX_GAMEPLY = 1024;

// Tablebase win/loss score band, kept just below the mate band
// (hce.MateScore - hce.MaxMate) so a TB result reads as a large cp score rather
// than "mate", and is never treated as a real mate by hce.is_near_mate. A TB win
// at ply p scores TB_WIN_SCORE - p (shallower wins preferred); a loss negates it.
pub const TB_WIN_SCORE: i32 = hce.MateScore - hce.MaxMate - MAX_PLY;

// Threshold for ply-normalizing scores stored in the TT. Covers both mate
// scores (above MateScore - MaxMate) and TB win/loss scores (above TB_WIN_SCORE - MAX_PLY).
const SCORE_PLY_ADJ: i32 = TB_WIN_SCORE - MAX_PLY;

pub const NodeType = enum {
    Root,
    PV,
    NonPV,
};

pub const MAX_THREADS = 512;
pub var NUM_THREADS: usize = 0;

pub const STABILITY_MULTIPLIER = [5]f32{ 2.50, 1.20, 0.90, 0.80, 0.75 };

pub var helper_searchers: std.array_list.Managed(Searcher) = std.array_list.Managed(Searcher).init(std.heap.c_allocator);
pub var threads: std.array_list.Managed(?std.Thread) = std.array_list.Managed(?std.Thread).init(std.heap.c_allocator);

pub const Searcher = struct {
    min_depth: usize = 1,
    max_millis: u64 = 0,
    ideal_time: u64 = 0,
    force_thinking: bool = false,
    iterative_deepening_depth: usize = 0,
    timer: types.Timer = undefined,

    soft_max_nodes: ?u64 = null,
    max_nodes: ?u64 = null,

    time_stop: bool = false,

    nodes: u64 = 0,
    ply: u32 = 0,
    seldepth: u32 = 0,
    stop: bool = false,
    is_searching: bool = false,
    parent_stop: ?*bool = null,
    shared_nodes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parent_nodes: ?*std.atomic.Value(u64) = null,
    root_history_len: usize = 0,

    exclude_move: [MAX_PLY]types.Move = undefined,
    nmp_min_ply: u32 = 0,

    hash_history: std.array_list.Managed(u64) = undefined,
    eval_history: [MAX_PLY]i32 = undefined,
    move_history: [MAX_PLY]types.Move = undefined,
    moved_piece_history: [MAX_PLY]types.Piece = undefined,

    best_move: types.Move = undefined,
    pv: [MAX_PLY + 1][MAX_PLY]types.Move = undefined,
    pv_size: [MAX_PLY + 1]usize = undefined,

    killer: [MAX_PLY + 1][2]types.Move = undefined,
    history: [2][64][64]i32 = undefined,

    counter_moves: [2][64][64]types.Move = undefined,
    continuation: *[12][64][64][64]i32,

    root_board: position.Position = undefined,
    ttable: *tt.TranspositionTable = &tt.GlobalTT,
    thread_id: usize = 0,
    silent_output: bool = false,

    node_spent_table: [64][64]u64 = undefined,

    tbhits: u64 = 0,
    syzygy_root_active: bool = false,
    syzygy_root: syzygy.RootResult = undefined,

    pub fn new() Searcher {
        var s = Searcher{
            .continuation = std.heap.c_allocator.create([12][64][64][64]i32) catch unreachable,
        };

        s.hash_history = std.array_list.Managed(u64).initCapacity(std.heap.c_allocator, MAX_GAMEPLY) catch unreachable;
        s.reset_heuristics(true);

        return s;
    }

    pub fn deinit(self: *Searcher) void {
        self.hash_history.deinit();
        std.heap.c_allocator.destroy(self.continuation);
    }

    // Store a quiescence-search result in the TT at depth 0, ply-normalizing mate
    // scores the same way the main search does.
    inline fn qsearch_store(self: *Searcher, pos: *position.Position, score: i32, static_eval_val: i32, move: types.Move, flag: tt.Bound) void {
        var stored = score;
        if (stored > SCORE_PLY_ADJ and stored <= hce.MateScore) {
            stored += @as(i32, @intCast(self.ply));
        } else if (stored < -SCORE_PLY_ADJ and stored >= -hce.MateScore) {
            stored -= @as(i32, @intCast(self.ply));
        }
        self.ttable.set(pos.hash, tt.Item{
            .eval = stored,
            .static_eval = @as(i16, @intCast(@min(@as(i32, 32767), @max(@as(i32, -32768), static_eval_val)))),
            .bestmove = move,
            .flag = flag,
            .depth = 0,
            .was_pv = 0,
            .key = @as(u32, @truncate(pos.hash)),
            .age = self.ttable.age,
        });
    }

    pub fn reset_heuristics(self: *Searcher, comptime total_reset: bool) void {
        self.nmp_min_ply = 0;

        {
            var i: usize = 0;
            while (i < MAX_PLY) : (i += 1) {
                self.killer[i][0] = types.Move.empty();
                self.killer[i][1] = types.Move.empty();

                self.exclude_move[i] = types.Move.empty();
            }
        }

        {
            var j: usize = 0;
            while (j < 64) : (j += 1) {
                var k: usize = 0;
                while (k < 64) : (k += 1) {
                    var i: usize = 0;
                    while (i < 2) : (i += 1) {
                        if (total_reset) {
                            self.history[i][j][k] = 0;
                        } else {
                            self.history[i][j][k] = @divTrunc(self.history[i][j][k], 2);
                        }
                        self.counter_moves[i][j][k] = types.Move.empty();
                    }
                    if (j < 12) {
                        i = 0;
                        while (i < 64) : (i += 1) {
                            var o: usize = 0;
                            while (o < 64) : (o += 1) {
                                if (total_reset) {
                                    self.continuation[j][k][i][o] = 0;
                                } else {
                                    // Decay across iterative searches instead of a 12MiB wipe
                                    // every go — preserves history and avoids stalling UCI
                                    // before the first node (stdin EOF race).
                                    self.continuation[j][k][i][o] = @divTrunc(self.continuation[j][k][i][o], 2);
                                }
                            }
                        }
                    }
                }
            }
        }

        {
            var j: usize = 0;
            while (j < MAX_PLY) : (j += 1) {
                var k: usize = 0;
                while (k < MAX_PLY) : (k += 1) {
                    self.pv[j][k] = types.Move.empty();
                }
                self.pv_size[j] = 0;
                self.eval_history[j] = 0;
                self.move_history[j] = types.Move.empty();
                self.moved_piece_history[j] = types.Piece.NO_PIECE;
            }
        }
    }

    inline fn stop_requested(self: *Searcher) bool {
        if (@atomicLoad(bool, &self.stop, .monotonic)) return true;
        if (self.parent_stop) |parent| {
            if (@atomicLoad(bool, parent, .monotonic)) return true;
        }
        return false;
    }

    inline fn record_node(self: *Searcher) void {
        self.nodes += 1;
        if (self.parent_nodes) |counter| {
            _ = counter.fetchAdd(1, .monotonic);
        } else if (self.thread_id == 0 and (self.max_nodes != null or self.soft_max_nodes != null)) {
            _ = self.shared_nodes.fetchAdd(1, .monotonic);
        }
    }

    pub inline fn total_nodes(self: *Searcher) u64 {
        if (self.parent_nodes) |counter| {
            return counter.load(.monotonic);
        }
        if (self.thread_id == 0 and (self.max_nodes != null or self.soft_max_nodes != null)) {
            return self.shared_nodes.load(.monotonic);
        }
        return self.nodes;
    }

    pub inline fn should_stop(self: *Searcher) bool {
        if (self.stop_requested()) return true;
        // Hard limits: always enforced (no min_depth gate).
        if (self.max_nodes != null and self.total_nodes() >= self.max_nodes.?) return true;
        if (self.thread_id != 0) return false;
        if (!self.force_thinking and self.max_millis > 0 and self.timer.read() / std.time.ns_per_ms >= self.max_millis) return true;
        return false;
    }

    pub inline fn should_not_continue(self: *Searcher, factor: f32) bool {
        if (self.stop_requested()) return true;
        if (self.thread_id != 0) return false;
        if (self.iterative_deepening_depth <= self.min_depth) return false;
        if (self.soft_max_nodes != null and self.total_nodes() >= self.soft_max_nodes.?) return true;
        if (!self.force_thinking and self.timer.read() / std.time.ns_per_ms >= @min(self.max_millis, @as(u64, @intFromFloat(@floor(@as(f32, @floatFromInt(self.ideal_time)) * factor))))) return true;
        return false;
    }

    fn draw_score(self: *Searcher, pos: *position.Position, comptime color: types.Color, in_check: bool, threefold: bool) ?i32 {
        if (!self.is_draw(pos, threefold)) return null;

        // Checkmate takes precedence over a fifty-move/repetition claim.
        if (in_check) {
            var move_bytes: [256 * @sizeOf(types.Move)]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&move_bytes);
            var moves = std.array_list.Managed(types.Move).initCapacity(fba.allocator(), 218) catch unreachable;
            defer moves.deinit();
            pos.generate_legal_moves(color, &moves);
            if (moves.items.len == 0) {
                return -hce.MateScore + @as(i32, @intCast(self.ply));
            }
        }

        return 0;
    }

    pub fn iterative_deepening(self: *Searcher, pos: *position.Position, comptime color: types.Color, max_depth: ?u8) i32 {
        var out_buf: [4096]u8 = undefined;
        var out_file = std.Io.File.stdout().writerStreaming(types.GLOBAL_IO, &out_buf);
        const outW = &out_file.interface;
        @atomicStore(bool, &self.is_searching, true, .release);
        self.parent_stop = null;
        self.parent_nodes = null;
        self.shared_nodes.store(0, .monotonic);
        self.root_history_len = self.hash_history.items.len;
        self.time_stop = false;
        self.reset_heuristics(false);
        self.nodes = 0;
        self.tbhits = 0;
        self.best_move = types.Move.empty();

        if (self.thread_id == 0) {
            for (&self.node_spent_table) |*row| {
                @memset(row, 0);
            }
        }

        self.timer = types.Timer.start();

        self.syzygy_root_active = false;
        if (syzygy.enabled and syzygy.no_castling_rights(pos) and
            syzygy.piece_count(pos) <= syzygy.max_pieces())
        {
            const repeated = self.count_repetitions(pos) > 1;
            if (syzygy.probe_root(pos, repeated)) |rr| {
                if (rr.count > 0) {
                    self.tbhits += 1;
                    self.syzygy_root = rr;
                    self.syzygy_root_active = true;
                }
            }
        }

        // Terminal root: no legal moves → emit null bestmove and skip search.
        {
            var root_moves = std.array_list.Managed(types.Move).initCapacity(std.heap.c_allocator, 64) catch unreachable;
            defer root_moves.deinit();
            pos.generate_legal_moves(color, &root_moves);
            if (self.syzygy_root_active) {
                self.filter_root_moves(&root_moves);
            }
            if (root_moves.items.len == 0) {
                const terminal = if (pos.in_check(color))
                    -hce.MateScore
                else
                    @as(i32, 0);
                if (!self.silent_output) {
                    outW.print("info depth 0 score ", .{}) catch {};
                    if (terminal < 0) {
                        outW.writeAll("mate 0") catch {};
                    } else {
                        outW.writeAll("cp 0") catch {};
                    }
                    outW.writeAll("\nbestmove 0000\n") catch {};
                    outW.flush() catch {};
                }
                self.best_move = types.Move.empty();
                self.ttable.do_age();
                @atomicStore(bool, &self.is_searching, false, .release);
                return terminal;
            }
        }

        var prev_score = -hce.MateScore;
        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var stability: usize = 0;

        const extra = if (NUM_THREADS > helper_searchers.items.len) NUM_THREADS - helper_searchers.items.len else 0;
        helper_searchers.ensureTotalCapacity(NUM_THREADS) catch unreachable;
        helper_searchers.appendNTimesAssumeCapacity(undefined, extra);
        threads.ensureTotalCapacity(NUM_THREADS) catch unreachable;
        threads.appendNTimesAssumeCapacity(null, extra);
        var ti: usize = NUM_THREADS - extra;
        while (ti < NUM_THREADS) : (ti += 1) {
            helper_searchers.items[ti] = Searcher.new();
        }

        ti = 0;
        while (ti < NUM_THREADS) : (ti += 1) {
            helper_searchers.items[ti].nodes = 0;
        }

        var tdepth: usize = 1;
        var bound: usize = if (max_depth == null) MAX_PLY - 2 else max_depth.?;
        outer: while (tdepth <= bound) {
            self.ply = 0;
            self.seldepth = 0;

            var alpha = -hce.MateScore;
            var beta = hce.MateScore;
            var delta = hce.MateScore;

            var depth = tdepth;

            if (depth >= 6) {
                // Avoid zero-width / saturated aspiration that cannot fail-low/high.
                const window = @max(parameters.AspirationWindow, 1);
                if (@as(i32, @intCast(@abs(score))) < hce.MateScore - hce.MaxMate) {
                    alpha = @max(score - window, -hce.MateScore);
                    beta = @min(score + window, hce.MateScore);
                    delta = window;
                }
            }

            var asp_iters: u32 = 0;
            while (true) {
                asp_iters += 1;
                if (asp_iters > 64) {
                    alpha = -hce.MateScore;
                    beta = hce.MateScore;
                }
                self.iterative_deepening_depth = @max(self.iterative_deepening_depth, depth);
                if (depth > 1) {
                    self.helpers(pos, color, depth, alpha, beta);
                }

                self.nmp_min_ply = 0;

                const val = self.negamax(pos, color, depth, alpha, beta, false, NodeType.Root, false);

                if (depth > 1) {
                    self.stop_helpers();
                }

                if (self.time_stop or self.should_stop()) {
                    break :outer;
                }

                score = val;

                if (score <= alpha) {
                    beta = @divTrunc(alpha + beta, 2);
                    alpha = @max(alpha - delta, -hce.MateScore);
                } else if (score >= beta) {
                    beta = @min(beta + delta, hce.MateScore);
                    if (depth > 1 and (tdepth < 4 or depth > tdepth - 4)) {
                        depth -= 1;
                    }
                } else {
                    break;
                }

                delta += @max(@divTrunc(delta, 4), 1);
            }

            if (self.best_move.to_u16() != bm.to_u16()) {
                stability = 0;
            } else {
                stability += 1;
            }

            bm = self.best_move;

            var total_nodes_all: usize = self.nodes;
            var total_tbhits: u64 = self.tbhits;

            if (depth > 1) {
                outW.print("info string thread 0 nodes {}\n", .{
                    self.nodes,
                }) catch {};
                var thread_index: usize = 0;
                while (thread_index < NUM_THREADS) : (thread_index += 1) {
                    outW.print("info string thread {} nodes {}\n", .{
                        thread_index + 1, helper_searchers.items[thread_index].nodes,
                    }) catch {};
                    total_nodes_all += helper_searchers.items[thread_index].nodes;
                    total_tbhits += helper_searchers.items[thread_index].tbhits;
                }
            }

            if (!self.silent_output) {
                const elapsed_ms = self.timer.read() / std.time.ns_per_ms;
                const nps = total_nodes_all * 1000 / @max(@as(u64, 1), elapsed_ms);
                outW.print("info depth {} seldepth {} nodes {} nps {} hashfull {} tbhits {} time {} score ", .{
                    tdepth,
                    self.seldepth,
                    total_nodes_all,
                    nps,
                    self.ttable.hashfull(),
                    total_tbhits,
                    elapsed_ms,
                }) catch {};

                if ((@as(i32, @intCast(@abs(score)))) >= (hce.MateScore - hce.MaxMate)) {
                    outW.print("mate {} pv", .{
                        (@divTrunc(hce.MateScore - (@as(i32, @intCast(@abs(score)))) + 1, 2)) * @as(i32, if (score > 0) 1 else -1),
                    }) catch {};
                    if (max_depth == null and bound == MAX_PLY - 2) {
                        bound = depth + 2;
                    }
                } else {
                    outW.print("cp {} pv", .{
                        score,
                    }) catch {};
                }

                if (self.pv_size[0] > 0) {
                    var i: usize = 0;
                    while (i < self.pv_size[0]) : (i += 1) {
                        outW.writeByte(' ') catch {};
                        self.pv[0][i].uci_print(outW);
                    }
                } else {
                    outW.writeByte(' ') catch {};
                    bm.uci_print(outW);
                }

                outW.writeByte('\n') catch {};
                outW.flush() catch {};
            }

            var factor: f32 = @max(0.5, 1.1 - 0.03 * @as(f32, @floatFromInt(stability)));

            if (score - prev_score > parameters.AspirationWindow) {
                factor *= 1.1;
            }

            if (tdepth >= 4 and self.nodes > 0) {
                const bm_nodes = self.node_spent_table[bm.from][bm.to];
                const frac = @as(f32, @floatFromInt(bm_nodes)) / @as(f32, @floatFromInt(self.nodes));
                const node_base = @as(f32, @floatFromInt(parameters.NodeTmBase)) / 100.0;
                const node_mult = @as(f32, @floatFromInt(parameters.NodeTmMultiplier)) / 100.0;
                const node_scale = std.math.clamp((node_base - frac) * node_mult, 0.5, 2.0);
                factor *= node_scale;
            }

            prev_score = score;

            if (self.should_not_continue(factor)) {
                break;
            }

            tdepth += 1;
        }

        // If `stop` arrived before even depth 1 completed, `bm` is still empty.
        // Fall back to the first legal move so we always emit a legal bestmove
        // rather than the null `a1a1`. Only reachable on an immediate stop — the
        // depth-limited callers (bench/datagen/tests) always finish depth 1.
        if (bm.to_u16() == 0) {
            var fallback = std.array_list.Managed(types.Move).initCapacity(std.heap.c_allocator, 32) catch unreachable;
            defer fallback.deinit();
            pos.generate_legal_moves(color, &fallback);
            if (self.syzygy_root_active) {
                self.filter_root_moves(&fallback);
            }
            if (fallback.items.len > 0) {
                bm = fallback.items[0];
            }
        }

        self.best_move = bm;

        if (!self.silent_output) {
            outW.writeAll("bestmove ") catch {};
            if (bm.to_u16() == 0) {
                outW.writeAll("0000") catch {};
            } else {
                bm.uci_print(outW);
            }
            outW.writeByte('\n') catch {};
            outW.flush() catch {};
        }

        self.ttable.do_age();
        @atomicStore(bool, &self.is_searching, false, .release);

        return score;
    }

    pub fn is_draw(self: *Searcher, pos: *position.Position, threefold: bool) bool {
        if (pos.history[pos.game_ply].fifty >= 100) {
            return true;
        }

        if (hce.is_material_draw(pos)) {
            return true;
        }

        if (self.hash_history.items.len > 1) {
            var index: i16 = @as(i16, @intCast(self.hash_history.items.len)) - 3;
            const limit: i16 = index - @as(i16, @intCast(pos.history[pos.game_ply].fifty)) - 1;
            var count: u8 = 0;
            const threshold: u8 = if (threefold) 2 else 1;
            while (index >= limit and index >= 0) {
                if (self.hash_history.items[@as(usize, @intCast(index))] == pos.hash) {
                    count += 1;
                    if (count >= threshold) {
                        return true;
                    }
                }
                index -= 2;
            }
        }

        return false;
    }

    // Counts occurrences of the current position's hash in the game history (the
    // current position included) so the root DTZ probe knows whether the line has
    // already repeated.
    fn count_repetitions(self: *Searcher, pos: *position.Position) usize {
        var n: usize = 0;
        for (self.hash_history.items) |h| {
            if (h == pos.hash) n += 1;
        }
        return n;
    }

    // Restricts the root move list to the Syzygy DTZ-optimal set.
    fn filter_root_moves(self: *Searcher, list: *std.array_list.Managed(types.Move)) void {
        var w: usize = 0;
        for (list.items) |m| {
            if (self.root_move_is_tb_optimal(m)) {
                list.items[w] = m;
                w += 1;
            }
        }
        if (w > 0) {
            list.shrinkRetainingCapacity(w);
        }
    }

    fn root_move_is_tb_optimal(self: *Searcher, m: types.Move) bool {
        // Promotion piece from the move flags (PR_*/PC_* low two bits: 0=N,1=B,2=R,3=Q).
        const promo: syzygy.PromoKind = if (!m.is_promotion()) .none else switch (@as(u2, @intCast(m.flags & 0b0011))) {
            0 => syzygy.PromoKind.knight,
            1 => syzygy.PromoKind.bishop,
            2 => syzygy.PromoKind.rook,
            3 => syzygy.PromoKind.queen,
        };
        const from: u8 = m.from;
        const to: u8 = m.to;
        var i: usize = 0;
        while (i < self.syzygy_root.count) : (i += 1) {
            const rm = self.syzygy_root.moves[i];
            if (rm.from == from and rm.to == to and rm.promo == promo) {
                return true;
            }
        }
        return false;
    }

    pub fn helpers(self: *Searcher, pos: *position.Position, comptime color: types.Color, depth_: usize, alpha_: i32, beta_: i32) void {
        var i: usize = 0;
        while (i < NUM_THREADS) : (i += 1) {
            const id: usize = i + 1;
            if (threads.items[i] != null) {
                threads.items[i].?.join();
            }
            var depth: usize = depth_;
            if (id % 2 == 1) {
                depth += 1;
            }
            helper_searchers.items[i].max_millis = self.max_millis;
            helper_searchers.items[i].max_nodes = self.max_nodes;
            helper_searchers.items[i].soft_max_nodes = self.soft_max_nodes;
            helper_searchers.items[i].ttable = self.ttable;
            helper_searchers.items[i].thread_id = id;
            helper_searchers.items[i].parent_stop = &self.stop;
            helper_searchers.items[i].parent_nodes = if (self.max_nodes != null or self.soft_max_nodes != null) &self.shared_nodes else null;
            helper_searchers.items[i].root_history_len = self.root_history_len;
            helper_searchers.items[i].root_board = pos.*;
            helper_searchers.items[i].hash_history.clearRetainingCapacity();
            helper_searchers.items[i].hash_history.appendSlice(self.hash_history.items) catch {};
            // Clear stop before spawn so a late-starting helper cannot overwrite a
            // cancellation published between spawn and thread entry.
            @atomicStore(bool, &helper_searchers.items[i].stop, false, .monotonic);
            threads.items[i] = std.Thread.spawn(
                .{ .stack_size = 64 * 1024 * 1024 },
                Searcher.start_helper,
                .{ &helper_searchers.items[i], color, depth, alpha_, beta_ },
            ) catch |e| {
                std.debug.panic("Could not spawn helper thread {}!\n{}", .{ i, e });
                unreachable;
            };
        }
    }

    pub fn start_helper(self: *Searcher, color: types.Color, depth_: usize, alpha_: i32, beta_: i32) void {
        // Do not clear stop here — cancellation may already be published.
        @atomicStore(bool, &self.is_searching, true, .release);
        self.time_stop = false;
        self.best_move = types.Move.empty();
        self.timer = types.Timer.start();
        self.force_thinking = true;
        self.ply = 0;
        self.seldepth = 0;
        if (color == types.Color.White) {
            _ = self.negamax(&self.root_board, types.Color.White, depth_, alpha_, beta_, false, NodeType.Root, false);
        } else {
            _ = self.negamax(&self.root_board, types.Color.Black, depth_, alpha_, beta_, false, NodeType.Root, false);
        }
        @atomicStore(bool, &self.is_searching, false, .release);
    }

    pub fn stop_helpers(self: *Searcher) void {
        _ = self;
        var i: usize = 0;
        while (i < NUM_THREADS) : (i += 1) {
            @atomicStore(bool, &helper_searchers.items[i].stop, true, .monotonic);
        }
        i = 0;
        while (i < NUM_THREADS) : (i += 1) {
            // Clear the slot after joining: a reaped std.Thread handle must never
            // be joined twice (pthread_join returns ESRCH -> `unreachable`). The
            // next `helpers()` call re-checks this slot for a still-running thread,
            // so leaving the dead handle here would crash it on the very next depth.
            if (threads.items[i]) |t| {
                t.join();
                threads.items[i] = null;
            }
        }
    }

    pub fn negamax(self: *Searcher, pos: *position.Position, comptime color: types.Color, depth_: usize, alpha_: i32, beta_: i32, comptime is_null: bool, comptime node: NodeType, comptime cutnode: bool) i32 {
        var alpha = alpha_;
        var beta = beta_;
        var depth = depth_;
        const opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        self.pv_size[self.ply] = 0;

        // >> Step 1: Preparations

        // Step 1.1: Stop if time is up
        if (self.nodes & 1023 == 0 and self.should_stop()) {
            self.time_stop = true;
            return 0;
        }

        self.seldepth = @max(self.seldepth, self.ply);

        const is_root = node == NodeType.Root;
        const on_pv: bool = node != NodeType.NonPV;

        // Step 1.3: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return hce.evaluate_comptime(pos, color);
        }

        const in_check = pos.in_check(color);

        // Step 4.1: Check Extension (moved up)
        if (in_check) {
            depth += 1;
        }

        // Step 1.5: Draw check before horizon (qsearch must not miss fifty/repetition).
        // Checkmate still takes precedence over a draw claim.
        if (!is_root) {
            if (self.draw_score(pos, color, in_check, on_pv)) |draw| {
                return draw;
            }
        }

        // Step 1.6: Go to Quiescence Search at Horizon
        if (depth == 0) {
            return self.quiescence_search(pos, color, alpha, beta);
        }

        // Step 1.4: Mate-distance pruning
        if (!is_root) {
            const r_alpha = @max(-hce.MateScore + @as(i32, @intCast(self.ply)), alpha);
            const r_beta = @min(hce.MateScore - @as(i32, @intCast(self.ply)) - 1, beta);

            if (r_alpha >= r_beta) {
                return r_alpha;
            }
        }

        self.record_node();

        // Step 1.7: Upcoming repetition detection (cuckoo)
        const repetition_ply = self.hash_history.items.len -| self.root_history_len;
        if (!is_root and alpha < 0 and cuckoo.has_upcoming_repetition(pos, self.hash_history.items, @as(u32, @intCast(repetition_ply)))) {
            alpha = 0;
            if (alpha >= beta) {
                return alpha;
            }
        }

        // >> Step 2: TT Probe
        var hashmove = types.Move.empty();
        var tthit = false;
        var tt_eval: i32 = 0;
        const entry = self.ttable.get(pos.hash);

        if (entry != null) {
            tthit = true;
            tt_eval = entry.?.eval;
            if (tt_eval > SCORE_PLY_ADJ and tt_eval <= hce.MateScore) {
                tt_eval -= @as(i32, @intCast(self.ply));
            } else if (tt_eval < -SCORE_PLY_ADJ and tt_eval >= -hce.MateScore) {
                tt_eval += @as(i32, @intCast(self.ply));
            }
            hashmove = entry.?.bestmove;
            if (is_root) {
                self.best_move = hashmove;
            }

            if (!is_null and !on_pv and !is_root and entry.?.depth >= depth) {
                if (pos.history[pos.game_ply].fifty < 90 and (depth == 0 or !on_pv)) {
                    switch (entry.?.flag) {
                        .Exact => {
                            return tt_eval;
                        },
                        .Lower => {
                            alpha = @max(alpha, tt_eval);
                        },
                        .Upper => {
                            beta = @min(beta, tt_eval);
                        },
                        else => {},
                    }
                    if (alpha >= beta) {
                        return tt_eval;
                    }
                }
            }
        }

        // >> Step 2.5: Syzygy tablebase WDL probe
        var tb_min: i32 = -hce.MateScore;
        var tb_max: i32 = hce.MateScore;
        if (syzygy.enabled and !is_root and !is_null and
            self.exclude_move[self.ply].to_u16() == 0 and
            @as(i32, @intCast(depth)) >= syzygy.probe_depth and
            pos.history[pos.game_ply].fifty == 0 and
            syzygy.no_castling_rights(pos) and
            syzygy.piece_count(pos) <= syzygy.max_pieces())
        {
            if (syzygy.probe_wdl(pos)) |wdl| {
                self.tbhits += 1;
                const tb_flag: tt.Bound, const tb_score: i32 = switch (wdl) {
                    .win => .{ tt.Bound.Lower, TB_WIN_SCORE - @as(i32, @intCast(self.ply)) },
                    .loss => .{ tt.Bound.Upper, @as(i32, @intCast(self.ply)) - TB_WIN_SCORE },
                    .draw => .{ tt.Bound.Exact, @as(i32, 0) },
                };
                const cutoff = switch (tb_flag) {
                    tt.Bound.Exact => true,
                    tt.Bound.Lower => tb_score >= beta,
                    tt.Bound.Upper => tb_score <= alpha,
                    else => false,
                };
                if (cutoff) {
                    // Store ply-normalized (same convention as mate scores in Step 7).
                    var stored_tb = tb_score;
                    if (stored_tb > SCORE_PLY_ADJ) {
                        stored_tb += @as(i32, @intCast(self.ply));
                    } else if (stored_tb < -SCORE_PLY_ADJ) {
                        stored_tb -= @as(i32, @intCast(self.ply));
                    }
                    self.ttable.set(pos.hash, tt.Item{
                        .eval = stored_tb,
                        .static_eval = 0,
                        .bestmove = types.Move.empty(),
                        .flag = tb_flag,
                        .depth = @as(u8, @intCast(depth)),
                        .was_pv = 0,
                        .key = @as(u32, @truncate(pos.hash)),
                        .age = self.ttable.age,
                    });
                    return tb_score;
                }
                // Narrow the search window and retain proven TB bounds for clamping.
                if (tb_flag == tt.Bound.Lower) {
                    alpha = @max(alpha, tb_score);
                    tb_min = @max(tb_min, tb_score);
                } else if (tb_flag == tt.Bound.Upper) {
                    beta = @min(beta, tb_score);
                    tb_max = @min(tb_max, tb_score);
                }
            }
        }

        const static_eval: i32 = if (in_check) -hce.MateScore + @as(i32, @intCast(self.ply)) else if (tthit) entry.?.static_eval else if (is_null) -self.eval_history[self.ply - 1] else if (self.exclude_move[self.ply].to_u16() != 0) self.eval_history[self.ply] else hce.evaluate_comptime(pos, color);

        var best_score: i32 = static_eval;

        var low_estimate: i32 = -hce.MateScore - 1;

        self.eval_history[self.ply] = static_eval;

        const improving = !in_check and self.ply >= 2 and static_eval > self.eval_history[self.ply - 2];

        const has_non_pawns = pos.has_non_pawns_color(color);

        var last_move = if (self.ply > 0) self.move_history[self.ply - 1] else types.Move.empty();
        var last_last_last_move = if (self.ply > 2) self.move_history[self.ply - 3] else types.Move.empty();

        // >> Step 3: Extensions/Reductions
        // Step 3.1: IIR
        // http://talkchess.com/forum3/viewtopic.php?f=7&t=74769&sid=85d340ce4f4af0ed413fba3188189cd1
        if (depth >= 3 and !in_check and !tthit and self.exclude_move[self.ply].to_u16() == 0 and (on_pv or cutnode)) {
            depth -= 1;
        }

        // >> Step 4: Prunings
        if (!in_check and !on_pv and self.exclude_move[self.ply].to_u16() == 0) {
            low_estimate = if (!tthit or entry.?.flag == tt.Bound.Lower) static_eval else tt_eval;

            // Step 4.1: Reverse Futility Pruning
            if (@as(i32, @intCast(@abs(beta))) < hce.MateScore - hce.MaxMate and depth <= parameters.RFPDepth) {
                var n = @as(i32, @intCast(depth)) * parameters.RFPMultiplier;
                if (improving) {
                    n -= parameters.RFPImprovingDeduction;
                }
                if (static_eval - n >= beta) {
                    return beta;
                }
            }

            var nmp_static_eval = static_eval;
            if (improving) {
                nmp_static_eval += parameters.NMPImprovingMargin;
            }

            // Step 4.2: Null move pruning
            if (!is_null and depth >= 3 and self.ply >= self.nmp_min_ply and nmp_static_eval >= beta and has_non_pawns) {
                var r = parameters.NMPBase + depth / parameters.NMPDepthDivisor;
                r += @as(usize, @intCast(@min(4, @divTrunc((static_eval - beta), parameters.NMPBetaDivisor))));
                r = @min(r, depth);

                self.ply += 1;
                pos.play_null_move();
                var null_score = -self.negamax(pos, opp_color, depth - r, -beta, -beta + 1, true, NodeType.NonPV, !cutnode);
                self.ply -= 1;
                pos.undo_null_move();

                if (self.time_stop) {
                    return 0;
                }

                if (null_score >= beta) {
                    if (null_score >= hce.MateScore - hce.MaxMate) {
                        null_score = beta;
                    }

                    if (depth < 12 or self.nmp_min_ply > 0) {
                        return null_score;
                    }

                    self.nmp_min_ply = self.ply + @as(u32, @intCast((depth - r) * 3 / 4));

                    const verif_score = self.negamax(pos, color, depth - r, beta - 1, beta, false, NodeType.NonPV, false);

                    self.nmp_min_ply = 0;

                    if (self.time_stop) {
                        return 0;
                    }

                    if (verif_score >= beta) {
                        return verif_score;
                    }
                }
            }

            // Step 4.3: Razoring
            if (depth <= 3 and static_eval - parameters.RazoringBase + parameters.RazoringMargin * @as(i32, @intCast(depth)) < alpha) {
                return self.quiescence_search(pos, color, alpha, beta);
            }

            // Step 4.4: ProbCut
            // On non-PV nodes with a high eval, if a capture can beat a raised beta
            // under a shallow verification search, prune the entire subtree.
            if (!is_null and depth >= parameters.ProbCutDepth and
                depth > parameters.ProbCutReduction and
                @as(i32, @intCast(@abs(beta))) < hce.MateScore - hce.MaxMate)
            {
                const probcut_beta = beta + parameters.ProbCutMargin;

                // Skip if TT already refutes at sufficient depth
                if (!(tthit and entry.?.depth >= depth - 3 and entry.?.eval < probcut_beta)) {
                    // Generate captures only
                    var pc_bytes: [256 * @sizeOf(types.Move)]u8 = undefined;
                    var pc_fba = std.heap.FixedBufferAllocator.init(&pc_bytes);
                    var pc_movelist = std.array_list.Managed(types.Move).initCapacity(pc_fba.allocator(), 218) catch unreachable;
                    defer pc_movelist.deinit();
                    pos.generate_q_moves(color, &pc_movelist);

                    for (pc_movelist.items) |move| {
                        // SEE filter: only try captures that could plausibly gain enough
                        if (!see.see_threshold(pos, move, probcut_beta - static_eval)) {
                            continue;
                        }

                        self.move_history[self.ply] = move;
                        self.moved_piece_history[self.ply] = pos.mailbox[move.from];
                        self.ply += 1;
                        pos.play_move(color, move);
                        self.hash_history.append(pos.hash) catch {};
                        self.ttable.prefetch(pos.hash);

                        // Quick qsearch verification
                        var qscore = -self.quiescence_search(pos, opp_color, -probcut_beta, -probcut_beta + 1);

                        // Full shallow verification if qsearch passes
                        if (qscore >= probcut_beta) {
                            qscore = -self.negamax(pos, opp_color, depth - parameters.ProbCutReduction, -probcut_beta, -probcut_beta + 1, false, NodeType.NonPV, !cutnode);
                        }

                        self.ply -= 1;
                        pos.undo_move(color, move);
                        _ = self.hash_history.pop();

                        if (self.time_stop) {
                            return 0;
                        }

                        if (qscore >= probcut_beta) {
                            var stored = qscore;
                            if (stored > SCORE_PLY_ADJ and stored <= hce.MateScore) {
                                stored += @as(i32, @intCast(self.ply));
                            } else if (stored < -SCORE_PLY_ADJ and stored >= -hce.MateScore) {
                                stored -= @as(i32, @intCast(self.ply));
                            }
                            self.ttable.set(pos.hash, tt.Item{
                                .eval = stored,
                                .static_eval = @as(i16, @intCast(@min(@as(i32, 32767), @max(@as(i32, -32768), static_eval)))),
                                .bestmove = move,
                                .flag = tt.Bound.Lower,
                                .depth = @as(u8, @intCast(depth - parameters.ProbCutReduction + 1)),
                                .was_pv = 0,
                                .key = @as(u32, @truncate(pos.hash)),
                                .age = self.ttable.age,
                            });
                            return qscore;
                        }
                    }
                }
            }
        }

        // >> Step 5: Search

        // Step 5.1: Move Generation (stack-backed — no per-node heap traffic)
        var ml_bytes: [256 * @sizeOf(types.Move)]u8 = undefined;
        var ml_fba = std.heap.FixedBufferAllocator.init(&ml_bytes);
        var movelist = std.array_list.Managed(types.Move).initCapacity(ml_fba.allocator(), 218) catch unreachable;
        defer movelist.deinit();
        pos.generate_legal_moves(color, &movelist);
        if (is_root and self.syzygy_root_active) {
            self.filter_root_moves(&movelist);
        }
        const move_size = movelist.items.len;

        var quiet_bytes: [256 * @sizeOf(types.Move)]u8 = undefined;
        var quiet_fba = std.heap.FixedBufferAllocator.init(&quiet_bytes);
        var quiet_moves = std.array_list.Managed(types.Move).initCapacity(quiet_fba.allocator(), 218) catch unreachable;
        defer quiet_moves.deinit();

        self.killer[self.ply + 1][0] = types.Move.empty();
        self.killer[self.ply + 1][1] = types.Move.empty();

        if (move_size == 0) {
            if (in_check) {
                // Checkmate
                return -hce.MateScore + @as(i32, @intCast(self.ply));
            } else {
                // Stalemate
                return 0;
            }
        }

        // Step 5.2: Move Ordering
        var score_bytes: [256 * @sizeOf(i32)]u8 = undefined;
        var score_fba = std.heap.FixedBufferAllocator.init(&score_bytes);
        var evallist = movepick.scoreMoves(self, pos, &movelist, hashmove, is_null, score_fba.allocator());
        defer evallist.deinit();

        // Step 5.3: Move Iteration
        var best_move = types.Move.empty();
        best_score = -hce.MateScore + @as(i32, @intCast(self.ply));

        var skip_quiet = false;

        var quiet_count: usize = 0;
        var legals: usize = 0;

        var index: usize = 0;
        while (index < move_size) : (index += 1) {
            var move = movepick.getNextBest(&movelist, &evallist, index);
            if (move.to_u16() == self.exclude_move[self.ply].to_u16()) {
                continue;
            }

            const is_capture = move.is_capture();
            const is_killer = move.to_u16() == self.killer[self.ply][0].to_u16() or move.to_u16() == self.killer[self.ply][1].to_u16();

            if (!is_capture) {
                quiet_moves.append(move) catch unreachable;
                quiet_count += 1;
            }

            const is_important = is_killer or move.is_promotion();

            if (skip_quiet and !is_capture and !is_important) {
                continue;
            }

            if (!DATAGEN and !is_root and index > 1 and !in_check and !on_pv and has_non_pawns) {
                // Step 5.4d: SEE Pruning (main search). Skip moves that lose too
                // much material by static exchange evaluation; quiets get a margin
                // linear in depth, captures a more lenient quadratic margin.
                if (!is_important and depth <= parameters.SEEPruningDepth) {
                    const see_margin = if (is_capture)
                        -parameters.SEENoisyMargin * @as(i32, @intCast(depth)) * @as(i32, @intCast(depth))
                    else
                        -parameters.SEEQuietMargin * @as(i32, @intCast(depth));
                    if (!see.see_threshold(pos, move, see_margin)) {
                        continue;
                    }
                }

                if (!is_important and !is_capture and depth <= 5) {
                    // Step 5.4a: Late Move Pruning
                    var late = 4 + depth * depth;
                    if (improving) {
                        late += 1 + depth / 2;
                    }

                    if (quiet_count > late) {
                        skip_quiet = true;
                    }

                    // Step 5.4c: History Pruning: late quiets with strongly
                    // negative history are skipped.
                    if (depth <= parameters.HistPruningDepth and self.history[@intFromEnum(color)][move.from][move.to] < -parameters.HistPruningMargin * @as(i32, @intCast(depth))) {
                        skip_quiet = true;
                    }
                }

                // Step 5.4b: Futility Pruning: if even a generous margin over the
                // static eval cannot reach alpha, the remaining quiets are hopeless.
                if (!is_important and !is_capture and depth <= parameters.FPDepth and
                    @as(i32, @intCast(@abs(alpha))) < hce.MateScore - hce.MaxMate and
                    static_eval + parameters.FPBase + parameters.FPMargin * @as(i32, @intCast(depth)) <= alpha)
                {
                    skip_quiet = true;
                }
            }

            legals += 1;

            var extension: i32 = 0;

            // Step 5.5: Singular extension
            // zig fmt: off
            if (self.ply > 0
                and !is_root
                and self.ply < depth * 2
                and depth >= 7
                and tthit
                and entry.?.flag != tt.Bound.Upper
                and !hce.is_near_mate(entry.?.eval)
                and hashmove.to_u16() == move.to_u16()
                and entry.?.depth >= depth - 3
            ) {
            // zig fmt: on
                const margin = @as(i32, @intCast(depth));
                const singular_beta = @max(tt_eval - margin, -hce.MateScore + hce.MaxMate);

                self.exclude_move[self.ply] = hashmove;
                const singular_score = self.negamax(pos, color, (depth - 1) / 2, singular_beta - 1, singular_beta, true, NodeType.NonPV, cutnode);
                self.exclude_move[self.ply] = types.Move.empty();
                if (singular_score < singular_beta) {
                    extension = 1;
                    // Double / triple extension: the more the TT move's score beats
                    // the rest, the more singular it is. Triple is reserved for
                    // quiet TT moves.
                    if (singular_score < singular_beta - parameters.SEDoubleMargin) {
                        extension = 2;
                        if (!move.is_capture() and singular_score < singular_beta - parameters.SETripleMargin) {
                            extension = 3;
                        }
                    }
                } else if (singular_beta >= beta) {
                    return singular_beta;
                } else if (tt_eval >= beta) {
                    extension = -2;
                } else if (cutnode) {
                    extension = -1;
                }
            } else if (on_pv and !is_root and self.ply < depth * 2) {
                // Recapture Extension
                if (is_capture and ((last_move.is_capture() and move.to == last_move.to) or (last_last_last_move.is_capture() and move.to == last_last_last_move.to))) {
                    extension = 1;
                }
            }

            const new_depth = @as(usize, @intCast(@as(i32, @intCast(depth)) + extension - 1));

            const nodes_before = self.nodes;

            self.move_history[self.ply] = move;
            self.moved_piece_history[self.ply] = pos.mailbox[move.from];
            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};

            self.ttable.prefetch(pos.hash);

            var score: i32 = 0;
            const min_lmr_move: usize = if (on_pv) 5 else 3;
            const is_winning_capture = is_capture and evallist.items[index] >= movepick.SortWinningCapture - 200;
            var do_full_search = false;
            if (on_pv and legals == 1) {
                score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV, false);
            } else {
                if (!in_check and depth >= 3 and index >= min_lmr_move and (!is_capture or !is_winning_capture)) {
                    // Step 5.6: Late-Move Reduction
                    var reduction: i32 = QuietLMR[@min(depth, 63)][@min(index, 63)];

                    if (self.thread_id % 2 == 1) {
                        reduction -= 1;
                    }

                    if (improving) {
                        reduction -= 1;
                    }

                    if (!on_pv) {
                        reduction += 1;
                    }

                    // Expected fail-high (cut) nodes: reduce more.
                    if (cutnode) {
                        reduction += parameters.LMRCutnode;
                    }

                    // A deep TT entry already vetted this subtree; reduce less.
                    if (tthit and @as(usize, @intCast(entry.?.depth)) >= depth) {
                        reduction -= 1;
                    }

                    // Moves that give check are forcing; reduce less.
                    if (pos.in_check(opp_color)) {
                        reduction -= 1;
                    }

                    reduction -= @divTrunc(self.history[@intFromEnum(color)][move.from][move.to], 6144);

                    const rd: usize = @as(usize, @intCast(std.math.clamp(@as(i32, @intCast(new_depth)) - reduction, 1, new_depth + 1)));

                    // Step 5.7: Principal-Variation-Search (PVS)
                    score = -self.negamax(pos, opp_color, rd, -alpha - 1, -alpha, false, NodeType.NonPV, true);

                    do_full_search = score > alpha and rd < new_depth;
                } else {
                    do_full_search = !on_pv or index > 0;
                }

                if (do_full_search) {
                    score = -self.negamax(pos, opp_color, new_depth, -alpha - 1, -alpha, false, NodeType.NonPV, !cutnode);
                }

                if (on_pv and ((score > alpha and score < beta) or index == 0)) {
                    score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV, false);
                }
            }

            self.ply -= 1;
            pos.undo_move(color, move);
            _ = self.hash_history.pop();

            if (is_root and self.thread_id == 0) {
                self.node_spent_table[move.from][move.to] += self.nodes - nodes_before;
            }

            if (self.time_stop) {
                return 0;
            }

            // Step 5.8: Alpha-Beta Pruning
            if (score > best_score) {
                best_score = score;
                best_move = move;

                if (is_root) {
                    self.best_move = move;
                }

                if (!is_null) {
                    self.pv[self.ply][0] = move;
                    std.mem.copyForwards(types.Move, self.pv[self.ply][1..(self.pv_size[self.ply + 1] + 1)], self.pv[self.ply + 1][0..(self.pv_size[self.ply + 1])]);
                    self.pv_size[self.ply] = self.pv_size[self.ply + 1] + 1;
                }

                if (score > alpha) {
                    alpha = score;

                    if (alpha >= beta) {
                        break;
                    }
                }
            }
        }

        if (alpha >= beta and !best_move.is_capture() and !best_move.is_promotion()) {
            var temp = self.killer[self.ply][0];
            if (temp.to_u16() != best_move.to_u16()) {
                self.killer[self.ply][0] = best_move;
                self.killer[self.ply][1] = temp;
            }

            const adj = @min(1536, @as(i32, @intCast(if (static_eval <= alpha) depth + 1 else depth)) * 384 - 384);

            if (!is_null and self.ply >= 1) {
                const last = self.move_history[self.ply - 1];
                self.counter_moves[@intFromEnum(color)][last.from][last.to] = best_move;
            }

            const b = best_move.to_u16();
            const max_history: i32 = 16384;
            for (quiet_moves.items) |m| {
                const is_best = m.to_u16() == b;
                const hist = self.history[@intFromEnum(color)][m.from][m.to] * adj;
                if (is_best) {
                    self.history[@intFromEnum(color)][m.from][m.to] += adj - @divTrunc(hist, max_history);
                } else {
                    self.history[@intFromEnum(color)][m.from][m.to] += -adj - @divTrunc(hist, max_history);
                }

                // Continuation History
                if (!is_null and self.ply >= 1) {
                    const plies: [3]usize = .{ 0, 1, 3 };
                    for (plies) |plies_ago| {
                        if (self.ply >= plies_ago + 1) {
                            const prev = self.move_history[self.ply - plies_ago - 1];
                            if (prev.to_u16() == 0) continue;

                            const cont_hist = self.continuation[self.moved_piece_history[self.ply - plies_ago - 1].pure_index()][prev.to][m.from][m.to] * adj;
                            if (is_best) {
                                self.continuation[self.moved_piece_history[self.ply - plies_ago - 1].pure_index()][prev.to][m.from][m.to] += adj - @divTrunc(cont_hist, max_history);
                            } else {
                                self.continuation[self.moved_piece_history[self.ply - plies_ago - 1].pure_index()][prev.to][m.from][m.to] += -adj - @divTrunc(cont_hist, max_history);
                            }
                        }
                    }
                }
            }
        }

        // >> Step 7: Transposition Table Update
        // Clamp to any non-cutting Syzygy bound so a quieter child cannot replace
        // a proven TB win/loss with a weaker centipawn score.
        best_score = std.math.clamp(best_score, tb_min, tb_max);

        if (self.exclude_move[self.ply].to_u16() == 0) {
            const tt_flag = if (tb_min != -hce.MateScore and best_score == tb_min)
                tt.Bound.Lower
            else if (tb_max != hce.MateScore and best_score == tb_max)
                tt.Bound.Upper
            else if (best_score >= beta_)
                tt.Bound.Lower
            else if (best_score <= alpha_)
                tt.Bound.Upper
            else
                tt.Bound.Exact;

            // Store mate/TB scores node-relative (the exact inverse of the probe
            // adjustment above), so a score found at one ply reads back correctly
            // when the entry is probed at a different ply. best_score itself stays
            // root-relative for the return value below.
            var stored_eval = best_score;
            if (stored_eval > SCORE_PLY_ADJ and stored_eval <= hce.MateScore) {
                stored_eval += @as(i32, @intCast(self.ply));
            } else if (stored_eval < -SCORE_PLY_ADJ and stored_eval >= -hce.MateScore) {
                stored_eval -= @as(i32, @intCast(self.ply));
            }

            self.ttable.set(pos.hash, tt.Item{
                .eval = stored_eval,
                .static_eval = @as(i16, @intCast(@min(@as(i32, 32767), @max(@as(i32, -32768), static_eval)))),
                .bestmove = best_move,
                .flag = tt_flag,
                .depth = @as(u8, @intCast(depth)),
                .was_pv = if (on_pv) @as(u1, 1) else @as(u1, 0),
                .key = @as(u32, @truncate(pos.hash)),
                .age = self.ttable.age,
            });
        }

        return best_score;
    }

    pub fn quiescence_search(self: *Searcher, pos: *position.Position, comptime color: types.Color, alpha_: i32, beta_: i32) i32 {
        var alpha = alpha_;
        const beta = beta_;
        const opp_color = if (color == types.Color.White) types.Color.Black else types.Color.White;

        // >> Step 1: Preparation

        // Step 1.1: Stop if time is up
        if (self.nodes & 1023 == 0 and self.should_stop()) {
            self.time_stop = true;
            return 0;
        }

        self.pv_size[self.ply] = 0;

        // Step 1.4: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return hce.evaluate_comptime(pos, color);
        }

        const in_check = pos.in_check(color);

        // Full draw detection inside qsearch, with checkmate precedence.
        if (self.draw_score(pos, color, in_check, true)) |draw| {
            return draw;
        }

        self.record_node();

        // >> Step 2: Prunings

        var best_score = -hce.MateScore + @as(i32, @intCast(self.ply));
        var static_eval = best_score;
        if (!in_check) {
            static_eval = hce.evaluate_comptime(pos, color);
            best_score = static_eval;

            // Step 2.1: Stand Pat pruning
            if (best_score >= beta) {
                return beta;
            }
            if (best_score > alpha) {
                alpha = best_score;
            }
        }

        // >> Step 3: TT Probe
        var hashmove = types.Move.empty();
        var best_move = types.Move.empty();
        const entry = self.ttable.get(pos.hash);

        if (entry != null) {
            hashmove = entry.?.bestmove;
            // Convert a node-relative stored mate/TB score back to root-relative
            var tt_eval = entry.?.eval;
            if (tt_eval > SCORE_PLY_ADJ and tt_eval <= hce.MateScore) {
                tt_eval -= @as(i32, @intCast(self.ply));
            } else if (tt_eval < -SCORE_PLY_ADJ and tt_eval >= -hce.MateScore) {
                tt_eval += @as(i32, @intCast(self.ply));
            }
            if (entry.?.flag == tt.Bound.Exact) {
                return tt_eval;
            } else if (entry.?.flag == tt.Bound.Lower and tt_eval >= beta) {
                return tt_eval;
            } else if (entry.?.flag == tt.Bound.Upper and tt_eval <= alpha) {
                return tt_eval;
            }
        }

        // >> Step 4: QSearch

        // Step 4.1: Q Move Generation
        var qml_bytes: [256 * @sizeOf(types.Move)]u8 = undefined;
        var qml_fba = std.heap.FixedBufferAllocator.init(&qml_bytes);
        var movelist = std.array_list.Managed(types.Move).initCapacity(qml_fba.allocator(), 218) catch unreachable;
        defer movelist.deinit();
        if (in_check) {
            pos.generate_legal_moves(color, &movelist);
            if (movelist.items.len == 0) {
                // Checkmated
                return -hce.MateScore + @as(i32, @intCast(self.ply));
            }
        } else {
            pos.generate_q_moves(color, &movelist);
        }
        const move_size = movelist.items.len;

        // Step 4.2: Q Move Ordering
        var qscore_bytes: [256 * @sizeOf(i32)]u8 = undefined;
        var qscore_fba = std.heap.FixedBufferAllocator.init(&qscore_bytes);
        var evallist = movepick.scoreMoves(self, pos, &movelist, hashmove, false, qscore_fba.allocator());
        defer evallist.deinit();

        // Step 4.3: Q Move Iteration
        var index: usize = 0;

        while (index < move_size) : (index += 1) {
            var move = movepick.getNextBest(&movelist, &evallist, index);
            const is_capture = move.is_capture();

            // SEE pruning of losing captures — never for check evasions.
            if (!in_check and is_capture and index > 0) {
                const see_score = evallist.items[index];
                if (see_score < movepick.SortWinningCapture - 2048) {
                    continue;
                }
                if (!see.see_threshold(pos, move, -parameters.SEENoisyMargin)) {
                    continue;
                }
            }

            self.move_history[self.ply] = move;
            self.moved_piece_history[self.ply] = pos.mailbox[move.from];
            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};
            self.ttable.prefetch(pos.hash);
            const score = -self.quiescence_search(pos, opp_color, -beta, -alpha);
            self.ply -= 1;
            pos.undo_move(color, move);
            _ = self.hash_history.pop();

            if (self.time_stop) {
                return 0;
            }

            // Step 4.5: Alpha-Beta Pruning
            if (score > best_score) {
                best_score = score;
                if (score > alpha) {
                    best_move = move;
                    if (score >= beta) {
                        self.qsearch_store(pos, best_score, static_eval, best_move, tt.Bound.Lower);
                        return beta;
                    }

                    alpha = score;
                }
            }
        }

        // No tactical moves and not in check: if generate_q_moves found nothing,
        // verify it is not a quiet stalemate (no legal moves at all).
        if (move_size == 0 and !in_check) {
            // One retained move is enough to disprove stalemate. The move
            // generator safely ignores later appends once this tiny FBA is full.
            var legal_bytes: [@sizeOf(types.Move)]u8 = undefined;
            var legal_fba = std.heap.FixedBufferAllocator.init(&legal_bytes);
            var legal = std.array_list.Managed(types.Move).initCapacity(legal_fba.allocator(), 1) catch unreachable;
            defer legal.deinit();
            pos.generate_legal_moves(color, &legal);
            if (legal.items.len == 0) {
                return 0;
            }
        }

        if (best_move.to_u16() != 0) {
            self.qsearch_store(pos, best_score, static_eval, best_move, tt.Bound.Exact);
        }

        return best_score;
    }
};
