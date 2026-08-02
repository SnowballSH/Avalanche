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
const wdl_model = @import("wdl.zig");
const nnue = @import("nnue.zig");

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

inline fn reserve_next_iteration(
    elapsed_ms: u64,
    max_millis: u64,
    depth: usize,
    stability: usize,
    score_delta: i32,
    factor: f32,
    iteration_cost: u64,
    previous_iteration_cost: u64,
    iteration_nodes: u64,
    previous_iteration_nodes: u64,
) bool {
    if (stability < 1 or score_delta > 24 or previous_iteration_cost == 0 or previous_iteration_nodes == 0) return false;
    const remaining = @max(@as(u64, 1), max_millis -| elapsed_ms);
    const time_growth = std.math.clamp(
        @as(f32, @floatFromInt(iteration_cost)) / @as(f32, @floatFromInt(previous_iteration_cost)),
        0.25,
        8.0,
    );
    const node_growth = std.math.clamp(
        @as(f32, @floatFromInt(iteration_nodes)) / @as(f32, @floatFromInt(previous_iteration_nodes)),
        0.25,
        8.0,
    );
    const efficiency_growth = std.math.clamp(time_growth / node_growth, 0.25, 4.0);
    const scale = @max(@as(f32, 1.0), @as(f32, @floatFromInt(iteration_cost)) * @sqrt(time_growth));
    const slack = std.math.clamp(@log(@as(f32, @floatFromInt(remaining)) / scale), -4.0, 4.0);
    const time_term = std.math.clamp(@log(time_growth), -2.0, 2.0);
    const node_term = std.math.clamp(@log(node_growth), -2.0, 2.0);
    const efficiency_term = std.math.clamp(@log(efficiency_growth), -1.4, 1.4);
    const depth_term = std.math.clamp((@as(f32, @floatFromInt(depth)) - 16.0) / 12.0, -1.0, 1.0);
    const stability_term = @as(f32, @floatFromInt(@min(stability, 8))) / 8.0;
    const score_term = @as(f32, @floatFromInt(@min(score_delta, 128))) / 128.0;
    const factor_term = std.math.clamp(factor, 0.5, 2.5) / 2.5;
    const completion_logit =
        0.831925 +
        1.278403 * slack +
        0.553568 * time_term +
        0.557034 * node_term -
        0.002354 * efficiency_term -
        0.398757 * depth_term -
        0.122777 * stability_term -
        0.073597 * score_term -
        1.064737 * factor_term;
    return completion_logit <= 0.0;
}

pub const MAX_PLY = 200;
pub const MAX_GAMEPLY = 1024;

// Tablebase win/loss score band, kept just below the mate band
// (hce.MateScore - hce.MaxMate) so a TB result reads as a large cp score rather
// than "mate", and is never treated as a real mate by hce.is_near_mate. A TB win
// at ply p scores TB_WIN_SCORE - p (shallower wins preferred); a loss negates it.
pub const TB_WIN_SCORE: i32 = hce.MateScore - hce.MaxMate - MAX_PLY;

// Threshold for ply-normalizing scores stored in the TT. Covers both mate
// scores (above MateScore - MaxMate) and TB win/loss scores (above TB_WIN_SCORE - MAX_PLY).
const SCORE_PLY_ADJ: i32 = TB_WIN_SCORE - MAX_PLY;

comptime {
    if (hce.MaxMate < 2 * @as(i32, MAX_PLY)) {
        @compileError("hce.MaxMate must be >= 2 * MAX_PLY: TT mate-score normalization adds ply on store and subtracts ply on probe, so a round-tripped mate loses up to two plies of magnitude and the mate band must cover twice the maximum ply");
    }
    if (MAX_PLY + 2 > nnue.STACK_CAP) {
        @compileError("nnue.STACK_CAP must exceed MAX_PLY: a search that rebased the accumulator stack would pop into the wrong frame");
    }
    if (MAX_PLY > 256) {
        @compileError("MAX_PLY must be <= 256: position.Position.history has exactly 256 entries of slack above MAX_HISTORY_PLY (src/chess/position.zig:9,62) for search play_move calls, and position.zig cannot import search.zig to enforce this locally");
    }
}

pub const NodeType = enum {
    Root,
    PV,
    NonPV,
};

pub const MAX_THREADS = 512;
pub var NUM_THREADS: usize = 0;
pub var THREADS_CONFIGURED: bool = false;

pub const DEFAULT_MOVE_OVERHEAD: u64 = 25;
pub const MAX_MOVE_OVERHEAD: u64 = 5000;
pub var MOVE_OVERHEAD: u64 = DEFAULT_MOVE_OVERHEAD;

pub var CONTEMPT: i32 = 0;
pub const MAX_CONTEMPT: i32 = 100;

pub var helper_searchers: std.array_list.Managed(Searcher) = std.array_list.Managed(Searcher).init(std.heap.c_allocator);
pub var threads: std.array_list.Managed(?std.Thread) = std.array_list.Managed(?std.Thread).init(std.heap.c_allocator);
pub var helpers_live: bool = false;

pub fn helpers_are_live() bool {
    return @atomicLoad(bool, &helpers_live, .acquire);
}

fn parallel_range(start: usize, end: usize, comptime f: fn (usize, usize) void) void {
    if (end <= start) return;
    const count = end - start;
    const cpus = std.Thread.getCpuCount() catch 1;
    const workers = @max(1, @min(count, @min(cpus, MAX_THREADS)));
    if (workers == 1) {
        f(start, end);
        return;
    }

    var handles: [MAX_THREADS]?std.Thread = undefined;
    const chunk = count / workers;
    for (0..workers) |w| {
        const s = start + w * chunk;
        const e = if (w == workers - 1) end else start + (w + 1) * chunk;
        handles[w] = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, f, .{ s, e }) catch null;
        if (handles[w] == null) f(s, e);
    }
    for (0..workers) |w| {
        if (handles[w]) |t| t.join();
    }
}

fn init_helper_range(start: usize, end: usize) void {
    var i = start;
    while (i < end) : (i += 1) {
        helper_searchers.items[i].init();
    }
}

fn reset_helper_range(start: usize, end: usize) void {
    var i = start;
    while (i < end) : (i += 1) {
        helper_searchers.items[i].age_pending = false;
        helper_searchers.items[i].has_searched = false;
        helper_searchers.items[i].reset_heuristics(true);
    }
}

pub fn ensure_helpers(n: usize) void {
    if (helpers_are_live()) return;
    const old_len = helper_searchers.items.len;
    if (n <= old_len) return;

    helper_searchers.ensureTotalCapacity(n) catch {
        NUM_THREADS = @min(NUM_THREADS, old_len);
        return;
    };
    threads.ensureTotalCapacity(n) catch {
        NUM_THREADS = @min(NUM_THREADS, old_len);
        return;
    };
    helper_searchers.appendNTimesAssumeCapacity(undefined, n - old_len);
    threads.appendNTimesAssumeCapacity(null, n - old_len);

    parallel_range(old_len, n, init_helper_range);
}

pub fn helper_count() usize {
    return helper_searchers.items.len;
}

pub fn reset_helper_heuristics() void {
    parallel_range(0, helper_searchers.items.len, reset_helper_range);
}

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
    continuation: *[12][64][64][64]i16,

    root_board: *position.Position,
    ttable: *tt.TranspositionTable = &tt.GlobalTT,
    thread_id: usize = 0,
    silent_output: bool = false,
    age_pending: bool = false,
    has_searched: bool = false,

    node_spent_table: [64][64]u64 = undefined,

    tbhits: u64 = 0,
    syzygy_root_active: bool = false,
    syzygy_root: syzygy.RootResult = undefined,

    pub fn init(self: *Searcher) void {
        const board = std.heap.c_allocator.create(position.Position) catch unreachable;
        board.init();
        self.* = .{
            .continuation = std.heap.c_allocator.create([12][64][64][64]i16) catch unreachable,
            .root_board = board,
        };
        self.hash_history = std.array_list.Managed(u64).initCapacity(std.heap.c_allocator, MAX_GAMEPLY) catch unreachable;
        self.reset_heuristics(true);
    }

    pub fn new() Searcher {
        var s: Searcher = undefined;
        s.init();
        return s;
    }

    pub fn deinit(self: *Searcher) void {
        self.hash_history.deinit();
        std.heap.c_allocator.destroy(self.continuation);
        self.root_board.deinit();
        std.heap.c_allocator.destroy(self.root_board);
    }

    inline fn pack_static_eval(value: i32) i16 {
        return @as(i16, @intCast(@min(@as(i32, 32767), @max(@as(i32, tt.EVAL_NONE) + 1, value))));
    }

    inline fn qsearch_store(self: *Searcher, pos: *position.Position, score: i32, static_eval_val: i32, move: types.Move, flag: tt.Bound) void {
        if (self.tt_store_is_ambiguous(score, flag)) return;

        var stored = score;
        if (stored > SCORE_PLY_ADJ and stored <= hce.MateScore) {
            stored += @as(i32, @intCast(self.ply));
        } else if (stored < -SCORE_PLY_ADJ and stored >= -hce.MateScore) {
            stored -= @as(i32, @intCast(self.ply));
        }
        self.ttable.set(pos.hash, tt.Item{
            .eval = stored,
            .static_eval = pack_static_eval(static_eval_val),
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

    // Root-relative: negate on even plies. Store draws as 0 in the TT and
    // re-apply on Exact-0 probe — the live value is ply-parity dependent.
    inline fn contempt_score(self: *Searcher) i32 {
        return if (self.ply % 2 == 0) -CONTEMPT else CONTEMPT;
    }

    inline fn tt_score(self: *Searcher, eval: i32, flag: tt.Bound) i32 {
        if (CONTEMPT != 0 and flag == tt.Bound.Exact and eval == 0) {
            return self.contempt_score();
        }
        return eval;
    }

    inline fn tt_draw_store(_: *Searcher) i32 {
        return 0;
    }

    // Skip TT stores that could be a live draw value or Exact 0 under contempt.
    inline fn tt_store_is_ambiguous(self: *Searcher, score: i32, flag: tt.Bound) bool {
        return CONTEMPT != 0 and
            (score == self.contempt_score() or (flag == tt.Bound.Exact and score == 0));
    }

    fn draw_score(self: *Searcher, pos: *position.Position, comptime color: types.Color, in_check: bool, threefold: bool) ?i32 {
        if (!self.is_draw(pos, threefold)) return null;

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

        return self.contempt_score();
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
        pos.evaluator.nnue_evaluator.reset_depth();
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

        {
            var root_moves = std.array_list.Managed(types.Move).initCapacity(std.heap.c_allocator, 64) catch unreachable;
            defer root_moves.deinit();
            pos.generate_legal_moves(color, &root_moves);
            if (self.syzygy_root_active) {
                self.filter_root_moves(&root_moves);
            }
            if (root_moves.items.len == 0) {
                const in_check = pos.in_check(color);
                const terminal: i32 = if (in_check)
                    -hce.MateScore
                else
                    self.contempt_score();
                if (!self.silent_output) {
                    outW.print("info depth 0 score ", .{}) catch {};
                    if (in_check) {
                        outW.writeAll("mate 0") catch {};
                    } else {
                        outW.print("cp {}", .{terminal}) catch {};
                    }
                    if (wdl_model.show_wdl) {
                        const p = if (in_check)
                            wdl_model.decisive(terminal)
                        else
                            wdl_model.Prediction{ .win = 0, .draw = 1000, .loss = 0 };
                        outW.print(" wdl {} {} {}", .{ p.win, p.draw, p.loss }) catch {};
                    }
                }
                self.best_move = types.Move.empty();
                self.ttable.do_age();
                @atomicStore(bool, &self.is_searching, false, .release);
                if (!self.silent_output) {
                    outW.writeAll("\nbestmove 0000\n") catch {};
                    outW.flush() catch {};
                }
                return terminal;
            }
        }

        var prev_score = -hce.MateScore;
        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var stability: usize = 0;
        var previous_iteration_end_ms: u64 = 0;
        var previous_iteration_cost: u64 = 0;
        var previous_iteration_nodes: u64 = 0;
        var previous_iteration_node_cost: u64 = 0;

        ensure_helpers(NUM_THREADS);
        var ti: usize = 0;
        while (ti < NUM_THREADS) : (ti += 1) {
            helper_searchers.items[ti].nodes = 0;
            helper_searchers.items[ti].tbhits = 0;
            helper_searchers.items[ti].age_pending = helper_searchers.items[ti].has_searched;
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

            if (depth >= parameters.AspirationDepth) {
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

                delta += @max(@divTrunc(delta * parameters.AspirationDeltaPercent, 100), 1);
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
                var thread_index: usize = 0;
                while (thread_index < NUM_THREADS) : (thread_index += 1) {
                    total_nodes_all += helper_searchers.items[thread_index].nodes;
                    total_tbhits += helper_searchers.items[thread_index].tbhits;
                }
            }

            const is_mate_score = @as(i32, @intCast(@abs(score))) >= hce.MateScore - hce.MaxMate;
            const is_decisive_score = @as(i32, @intCast(@abs(score))) >= SCORE_PLY_ADJ;
            if (is_mate_score and !self.force_thinking and max_depth == null and bound == MAX_PLY - 2) {
                bound = depth + 2;
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

                if (is_mate_score) {
                    outW.print("mate {}", .{
                        (@divTrunc(hce.MateScore - (@as(i32, @intCast(@abs(score)))) + 1, 2)) * @as(i32, if (score > 0) 1 else -1),
                    }) catch {};
                } else {
                    outW.print("cp {}", .{
                        score,
                    }) catch {};
                }

                if (wdl_model.show_wdl) {
                    const p = if (is_decisive_score)
                        wdl_model.decisive(score)
                    else
                        wdl_model.predict(score, pos.absolute_ply());
                    outW.print(" wdl {} {} {}", .{ p.win, p.draw, p.loss }) catch {};
                }

                outW.writeAll(" pv") catch {};

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

            var factor: f32 = @max(
                @as(f32, @floatFromInt(parameters.TmStabilityMin)) / 100.0,
                @as(f32, @floatFromInt(parameters.TmStabilityBase)) / 100.0 -
                    (@as(f32, @floatFromInt(parameters.TmStabilityMultiplier)) / 100.0) * @as(f32, @floatFromInt(stability)),
            );

            if (score - prev_score > parameters.TmScoreJumpThreshold) {
                factor *= @as(f32, @floatFromInt(parameters.TmScoreJumpMultiplier)) / 100.0;
            }

            if (tdepth >= parameters.NodeTmDepth and self.nodes > 0) {
                const bm_nodes = self.node_spent_table[bm.from][bm.to];
                const frac = @as(f32, @floatFromInt(bm_nodes)) / @as(f32, @floatFromInt(self.nodes));
                const node_base = @as(f32, @floatFromInt(parameters.NodeTmBase)) / 100.0;
                const node_mult = @as(f32, @floatFromInt(parameters.NodeTmMultiplier)) / 100.0;
                const node_scale = std.math.clamp(
                    (node_base - frac) * node_mult,
                    @as(f32, @floatFromInt(parameters.NodeTmMin)) / 100.0,
                    @as(f32, @floatFromInt(parameters.NodeTmMax)) / 100.0,
                );
                factor *= node_scale;
            }

            const elapsed_ms = self.timer.read() / std.time.ns_per_ms;
            const iteration_cost = @max(@as(u64, 1), elapsed_ms -| previous_iteration_end_ms);
            const iteration_nodes = @max(@as(u64, 1), self.nodes -| previous_iteration_nodes);
            const normal_stop = self.should_not_continue(factor);
            const score_delta: i32 = @intCast(@abs(score - prev_score));
            const reserve_stop = !normal_stop and !self.force_thinking and self.ideal_time < self.max_millis and
                reserve_next_iteration(
                    elapsed_ms,
                    self.max_millis,
                    tdepth,
                    stability,
                    score_delta,
                    factor,
                    iteration_cost,
                    previous_iteration_cost,
                    iteration_nodes,
                    previous_iteration_node_cost,
                );
            previous_iteration_end_ms = elapsed_ms;
            previous_iteration_cost = iteration_cost;
            previous_iteration_nodes = self.nodes;
            previous_iteration_node_cost = iteration_nodes;
            prev_score = score;

            if (normal_stop or reserve_stop) {
                break;
            }

            tdepth += 1;
        }

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

        self.ttable.do_age();
        @atomicStore(bool, &self.is_searching, false, .release);

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
        @atomicStore(bool, &helpers_live, true, .release);
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
            helper_searchers.items[i].syzygy_root_active = self.syzygy_root_active;
            if (self.syzygy_root_active) {
                helper_searchers.items[i].syzygy_root = self.syzygy_root;
            }
            const helper_board = helper_searchers.items[i].root_board;
            const helper_stack = helper_board.evaluator.nnue_evaluator.stack;
            const root_accumulator = pos.evaluator.nnue_evaluator.current().*;
            helper_board.* = pos.*;
            const helper_nnue = &helper_board.evaluator.nnue_evaluator;
            helper_nnue.stack = helper_stack;
            helper_nnue.depth = 0;
            helper_nnue.frame_written = true;
            helper_nnue.current().* = root_accumulator;
            helper_searchers.items[i].hash_history.clearRetainingCapacity();
            helper_searchers.items[i].hash_history.appendSlice(self.hash_history.items) catch {};
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
        @atomicStore(bool, &self.is_searching, true, .release);
        self.has_searched = true;
        if (self.age_pending) {
            self.age_pending = false;
            self.reset_heuristics(false);
        }
        self.time_stop = false;
        self.best_move = types.Move.empty();
        self.timer = types.Timer.start();
        self.force_thinking = true;
        self.ply = 0;
        self.seldepth = 0;

        if (color == types.Color.White) {
            _ = self.negamax(self.root_board, types.Color.White, depth_, alpha_, beta_, false, NodeType.Root, false);
        } else {
            _ = self.negamax(self.root_board, types.Color.Black, depth_, alpha_, beta_, false, NodeType.Root, false);
        }
        @atomicStore(bool, &self.is_searching, false, .release);
    }

    pub fn stop_helpers(self: *Searcher) void {
        _ = self;
        defer @atomicStore(bool, &helpers_live, false, .release);
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

        const in_check = pos.in_check(color);

        // Step 1.3: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return if (in_check) self.contempt_score() else hce.evaluate_comptime(pos, color);
        }

        // Step 4.1: Check Extension (moved up)
        if (in_check) {
            depth += 1;
        }

        if (!is_root) {
            if (self.draw_score(pos, color, in_check, on_pv)) |draw| {
                return draw;
            }
        }

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
        const upcoming_draw = self.contempt_score();
        if (!is_root and alpha < upcoming_draw and
            cuckoo.has_upcoming_repetition(pos, self.hash_history.items, @as(u32, @intCast(repetition_ply))))
        {
            alpha = upcoming_draw;
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
            tt_eval = self.tt_score(tt_eval, entry.?.flag);
            hashmove = entry.?.bestmove;
            if (is_root) {
                self.best_move = hashmove;
            }

            if (!is_null and !on_pv and !is_root and entry.?.depth >= depth) {
                if (pos.history[pos.game_ply].fifty < 90) {
                    switch (entry.?.flag) {
                        .Exact => return tt_eval,
                        .Lower => if (tt_eval >= beta) return tt_eval,
                        .Upper => if (tt_eval <= alpha) return tt_eval,
                        else => {},
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
                    .draw => .{ tt.Bound.Exact, self.contempt_score() },
                };
                const cutoff = switch (tb_flag) {
                    tt.Bound.Exact => true,
                    tt.Bound.Lower => tb_score >= beta,
                    tt.Bound.Upper => tb_score <= alpha,
                    else => false,
                };
                if (cutoff) {
                    var stored_tb = if (wdl == .draw) self.tt_draw_store() else tb_score;
                    if (stored_tb > SCORE_PLY_ADJ) {
                        stored_tb += @as(i32, @intCast(self.ply));
                    } else if (stored_tb < -SCORE_PLY_ADJ) {
                        stored_tb -= @as(i32, @intCast(self.ply));
                    }
                    self.ttable.set(pos.hash, tt.Item{
                        .eval = stored_tb,
                        .static_eval = tt.EVAL_NONE,
                        .bestmove = types.Move.empty(),
                        .flag = tb_flag,
                        .depth = @as(u8, @intCast(@min(depth, 255))),
                        .was_pv = 0,
                        .key = @as(u32, @truncate(pos.hash)),
                        .age = self.ttable.age,
                    });
                    return tb_score;
                }
                if (tb_flag == tt.Bound.Lower) {
                    alpha = @max(alpha, tb_score);
                    tb_min = @max(tb_min, tb_score);
                } else if (tb_flag == tt.Bound.Upper) {
                    beta = @min(beta, tb_score);
                    tb_max = @min(tb_max, tb_score);
                }
            }
        }

        const static_eval: i32 = if (in_check) -hce.MateScore + @as(i32, @intCast(self.ply)) else if (tthit and entry.?.static_eval != tt.EVAL_NONE) entry.?.static_eval else if (is_null) -self.eval_history[self.ply - 1] else if (self.exclude_move[self.ply].to_u16() != 0) self.eval_history[self.ply] else hce.evaluate_comptime(pos, color);

        var best_score: i32 = static_eval;

        self.eval_history[self.ply] = static_eval;

        const improving = !in_check and self.ply >= 2 and static_eval > self.eval_history[self.ply - 2];

        const has_non_pawns = pos.has_non_pawns_color(color);

        const last_move = if (self.ply > 0) self.move_history[self.ply - 1] else types.Move.empty();
        const last_last_last_move = if (self.ply > 2) self.move_history[self.ply - 3] else types.Move.empty();

        // >> Step 3: Extensions/Reductions
        // Step 3.1: IIR
        // http://talkchess.com/forum3/viewtopic.php?f=7&t=74769&sid=85d340ce4f4af0ed413fba3188189cd1
        if (depth >= parameters.IIRDepth and !in_check and !tthit and self.exclude_move[self.ply].to_u16() == 0 and (on_pv or cutnode)) {
            depth -= 1;
        }

        // >> Step 4: Prunings
        if (!in_check and !on_pv and self.exclude_move[self.ply].to_u16() == 0) {
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
            if (!is_null and depth >= parameters.NMPDepth and self.ply >= self.nmp_min_ply and nmp_static_eval >= beta and has_non_pawns) {
                var r = parameters.NMPBase + ((depth * parameters.NMPDepthFactor) >> 8);
                r += @as(usize, @intCast(@max(@as(i32, 0), @min(parameters.NMPBetaMax, @divTrunc((static_eval - beta), parameters.NMPBetaDivisor)))));
                r = @min(r, depth);

                self.move_history[self.ply] = types.Move.empty();
                self.moved_piece_history[self.ply] = types.Piece.NO_PIECE;
                self.ply += 1;
                pos.play_null_move();
                self.ttable.prefetch(pos.hash);
                var null_score = -self.negamax(pos, opp_color, depth - r, -beta, -beta + 1, true, NodeType.NonPV, !cutnode);
                self.ply -= 1;
                pos.undo_null_move();

                if (self.time_stop) {
                    return 0;
                }

                if (null_score >= beta) {
                    if (null_score >= SCORE_PLY_ADJ) {
                        null_score = beta;
                    }

                    if (depth < parameters.NMPVerifyDepth or self.nmp_min_ply > 0) {
                        return null_score;
                    }

                    self.nmp_min_ply = self.ply + @as(u32, @intCast((depth - r) * parameters.NMPVerifyPlyFactor / 100));

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
            if (depth <= parameters.RazoringDepth and static_eval - parameters.RazoringBase + parameters.RazoringMargin * @as(i32, @intCast(depth)) < alpha) {
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
                if (!(tthit and entry.?.depth >= depth -| parameters.ProbCutTTDepthMargin and
                    tt_eval < probcut_beta))
                {
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
                            if (!self.tt_store_is_ambiguous(qscore, tt.Bound.Lower)) {
                                var stored = qscore;
                                if (stored > SCORE_PLY_ADJ and stored <= hce.MateScore) {
                                    stored += @as(i32, @intCast(self.ply));
                                } else if (stored < -SCORE_PLY_ADJ and stored >= -hce.MateScore) {
                                    stored -= @as(i32, @intCast(self.ply));
                                }
                                self.ttable.set(pos.hash, tt.Item{
                                    .eval = stored,
                                    .static_eval = pack_static_eval(static_eval),
                                    .bestmove = move,
                                    .flag = tt.Bound.Lower,
                                    .depth = @as(u8, @intCast(@min(depth - parameters.ProbCutReduction + 1, 255))),
                                    .was_pv = 0,
                                    .key = @as(u32, @truncate(pos.hash)),
                                    .age = self.ttable.age,
                                });
                            }
                            return qscore;
                        }
                    }
                }
            }
        }

        // >> Step 5: Search

        // Step 5.1: Move Generation
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
                return self.contempt_score();
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
                quiet_count += 1;
            }

            const is_important = is_killer or move.is_promotion();

            if (skip_quiet and !is_capture and !is_important) {
                continue;
            }

            if (!DATAGEN and !is_root and index > 1 and !in_check and !on_pv and has_non_pawns) {
                // Step 5.4d: SEE Pruning
                if (!is_important and depth <= parameters.SEEPruningDepth) {
                    const see_margin = if (is_capture)
                        -parameters.SEENoisyMargin * @as(i32, @intCast(depth)) * @as(i32, @intCast(depth))
                    else
                        -parameters.SEEQuietMargin * @as(i32, @intCast(depth));
                    if (!see.see_threshold(pos, move, see_margin)) {
                        continue;
                    }
                }

                if (!is_important and !is_capture and depth <= parameters.LMPDepth) {
                    // Step 5.4a: Late Move Pruning
                    var late = parameters.LMPBase + parameters.LMPMultiplier * depth * depth / 100;
                    if (improving) {
                        late += parameters.LMPImprovingBase + depth * parameters.LMPImprovingPercent / 100;
                    }

                    if (quiet_count > late) {
                        skip_quiet = true;
                    }

                    // Step 5.4c: History Pruning
                    if (depth <= parameters.HistPruningDepth and
                        self.history[@intFromEnum(color)][move.from][move.to] < -parameters.HistPruningMargin * @as(i32, @intCast(depth)))
                    {
                        skip_quiet = true;
                    }
                }

                // Step 5.4b: Futility Pruning
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
                and depth >= parameters.SEDepth
                and tthit
                and entry.?.flag != tt.Bound.Upper
                and @as(i32, @intCast(@abs(tt_eval))) < SCORE_PLY_ADJ
                and hashmove.to_u16() == move.to_u16()
                and entry.?.depth >= depth -| parameters.SETTDepthMargin
            ) {
            // zig fmt: on
                const margin = @as(i32, @intCast(depth * parameters.SEBetaMultiplier / 100));
                const singular_beta = @max(tt_eval - margin, -hce.MateScore + hce.MaxMate);

                self.exclude_move[self.ply] = hashmove;
                const singular_score = self.negamax(pos, color, (depth - 1) / 2, singular_beta - 1, singular_beta, true, NodeType.NonPV, cutnode);
                self.exclude_move[self.ply] = types.Move.empty();
                if (singular_score < singular_beta) {
                    extension = 1;
                    // Double / triple extension
                    if (singular_score < singular_beta - parameters.SEDoubleMargin) {
                        extension = 2;
                        if (!move.is_capture() and singular_score < singular_beta - parameters.SETripleMargin) {
                            extension = 3;
                        }
                    }
                } else if (singular_beta >= beta) {
                    return singular_beta;
                } else if (tt_eval >= beta) {
                    extension = -parameters.SEFailHighReduction;
                } else if (cutnode) {
                    extension = -parameters.SECutnodeReduction;
                }
            } else if (on_pv and !is_root and self.ply < depth * 2) {
                // Recapture Extension
                if (is_capture and ((last_move.is_capture() and move.to == last_move.to) or (last_last_last_move.is_capture() and move.to == last_last_last_move.to))) {
                    extension = 1;
                }
            }

            const new_depth = @as(usize, @intCast(@as(i32, @intCast(depth)) + extension - 1));

            const nodes_before = self.nodes;

            self.ttable.prefetch(pos.prefetch_key_after(move));

            self.move_history[self.ply] = move;
            self.moved_piece_history[self.ply] = pos.mailbox[move.from];
            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};

            var score: i32 = 0;
            const min_lmr_move: usize = if (on_pv) parameters.LMRMinMovePV else parameters.LMRMinMoveNonPV;
            const is_winning_capture = is_capture and evallist.items[index] >= movepick.SortWinningCapture - 200;
            if (on_pv and legals == 1) {
                score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV, false);
            } else {
                var do_full_search = true;
                if (!in_check and depth >= parameters.LMRDepth and index >= min_lmr_move and !is_winning_capture) {
                    // Step 5.6: Late-Move Reduction
                    var reduction: i32 = QuietLMR[@min(depth, 63)][@min(index, 63)];

                    if (self.thread_id % 2 == 1) {
                        reduction -= 1;
                    }

                    if (improving) {
                        reduction -= parameters.LMRImproving;
                    }

                    if (!on_pv) {
                        reduction += parameters.LMRNonPV;
                    }

                    // Expected fail-high (cut) nodes: reduce more.
                    if (cutnode) {
                        reduction += parameters.LMRCutnode;
                    }

                    // A deep TT entry already vetted this subtree; reduce less.
                    if (tthit and @as(usize, @intCast(entry.?.depth)) >= depth) {
                        reduction -= parameters.LMRTTDepth;
                    }

                    // Moves that give check are forcing; reduce less.
                    if (pos.in_check(opp_color)) {
                        reduction -= parameters.LMRCheck;
                    }

                    reduction -= @divTrunc(self.history[@intFromEnum(color)][move.from][move.to], parameters.LMRHistoryDivisor);

                    const rd: usize = @as(usize, @intCast(std.math.clamp(@as(i32, @intCast(new_depth)) - reduction, 1, new_depth + 1)));

                    // Step 5.7: Principal-Variation-Search (PVS)
                    score = -self.negamax(pos, opp_color, rd, -alpha - 1, -alpha, false, NodeType.NonPV, true);

                    do_full_search = score > alpha and rd < new_depth;
                }

                if (do_full_search) {
                    score = -self.negamax(pos, opp_color, new_depth, -alpha - 1, -alpha, false, NodeType.NonPV, !cutnode);
                }

                if (on_pv and score > alpha and score < beta) {
                    score = -self.negamax(pos, opp_color, new_depth, -beta, -alpha, false, NodeType.PV, false);
                }
            }

            self.ply -= 1;
            pos.undo_move(color, move);
            _ = self.hash_history.pop();

            if (!is_capture) {
                quiet_moves.append(move) catch unreachable;
            }

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

            const adj: i32 = @max(@as(i32, 0), @min(parameters.HistoryBonusMax, @as(i32, @intCast(if (static_eval <= alpha) depth + 1 else depth)) * parameters.HistoryBonusMultiplier - parameters.HistoryBonusOffset));

            if (!is_null and self.ply >= 1) {
                const last = self.move_history[self.ply - 1];
                self.counter_moves[@intFromEnum(color)][last.from][last.to] = best_move;
            }

            const b = best_move.to_u16();
            const max_history: i32 = parameters.HistoryGravityMax;
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

                            const slot = &self.continuation[self.moved_piece_history[self.ply - plies_ago - 1].pure_index()][prev.to][m.from][m.to];
                            const cont_hist = @as(i32, slot.*) * adj;
                            const bonus = if (is_best) adj else -adj;
                            slot.* += @intCast(bonus - @divTrunc(cont_hist, max_history));
                        }
                    }
                }
            }
        }

        // >> Step 7: Transposition Table Update
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

            if (self.tt_store_is_ambiguous(best_score, tt_flag)) {
                return best_score;
            }

            var stored_eval = best_score;
            if (stored_eval > SCORE_PLY_ADJ and stored_eval <= hce.MateScore) {
                stored_eval += @as(i32, @intCast(self.ply));
            } else if (stored_eval < -SCORE_PLY_ADJ and stored_eval >= -hce.MateScore) {
                stored_eval -= @as(i32, @intCast(self.ply));
            }

            self.ttable.set(pos.hash, tt.Item{
                .eval = stored_eval,
                .static_eval = pack_static_eval(static_eval),
                .bestmove = best_move,
                .flag = tt_flag,
                .depth = @as(u8, @intCast(@min(depth, 255))),
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

        const in_check = pos.in_check(color);

        // Step 1.4: Ply Overflow Check
        if (self.ply == MAX_PLY) {
            return if (in_check) self.contempt_score() else hce.evaluate_comptime(pos, color);
        }

        if (self.draw_score(pos, color, in_check, true)) |draw| {
            return draw;
        }

        self.record_node();

        var qml_bytes: [256 * @sizeOf(types.Move)]u8 = undefined;
        var qml_fba = std.heap.FixedBufferAllocator.init(&qml_bytes);
        var movelist = std.array_list.Managed(types.Move).init(qml_fba.allocator());
        defer movelist.deinit();
        if (CONTEMPT != 0) {
            movelist.ensureTotalCapacityPrecise(218) catch unreachable;
            if (in_check) {
                pos.generate_legal_moves(color, &movelist);
                if (movelist.items.len == 0) {
                    return -hce.MateScore + @as(i32, @intCast(self.ply));
                }
            } else {
                pos.generate_q_moves(color, &movelist);
                if (movelist.items.len == 0) {
                    var legal_storage: [1]types.Move = undefined;
                    var legal_fba = std.heap.FixedBufferAllocator.init(std.mem.asBytes(&legal_storage));
                    var legal = std.array_list.Managed(types.Move).initCapacity(legal_fba.allocator(), 1) catch unreachable;
                    defer legal.deinit();
                    pos.generate_legal_moves(color, &legal);
                    if (legal.items.len == 0) {
                        return self.contempt_score();
                    }
                }
            }
        }

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
            var tt_eval = entry.?.eval;
            if (tt_eval > SCORE_PLY_ADJ and tt_eval <= hce.MateScore) {
                tt_eval -= @as(i32, @intCast(self.ply));
            } else if (tt_eval < -SCORE_PLY_ADJ and tt_eval >= -hce.MateScore) {
                tt_eval += @as(i32, @intCast(self.ply));
            }
            const scored = self.tt_score(tt_eval, entry.?.flag);
            if (entry.?.flag == tt.Bound.Exact) {
                return scored;
            } else if (entry.?.flag == tt.Bound.Lower and scored >= beta) {
                return scored;
            } else if (entry.?.flag == tt.Bound.Upper and scored <= alpha) {
                return scored;
            }
        }

        // >> Step 4: QSearch

        // Step 4.1: Q Move Generation
        if (CONTEMPT == 0) {
            movelist.ensureTotalCapacityPrecise(218) catch unreachable;
            if (in_check) {
                pos.generate_legal_moves(color, &movelist);
                if (movelist.items.len == 0) {
                    return -hce.MateScore + @as(i32, @intCast(self.ply));
                }
            } else {
                pos.generate_q_moves(color, &movelist);
            }
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

            if (!in_check and is_capture and index > 0) {
                const see_score = evallist.items[index];
                if (see_score < movepick.SortWinningCapture - 2048) {
                    continue;
                }
                if (!see.see_threshold(pos, move, -parameters.QSSEEMargin)) {
                    continue;
                }
            }

            self.ttable.prefetch(pos.prefetch_key_after(move));

            self.move_history[self.ply] = move;
            self.moved_piece_history[self.ply] = pos.mailbox[move.from];
            self.ply += 1;
            pos.play_move(color, move);
            self.hash_history.append(pos.hash) catch {};
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
                        return if (self.tt_store_is_ambiguous(best_score, tt.Bound.Lower))
                            best_score
                        else
                            beta;
                    }

                    alpha = score;
                }
            }
        }

        if (best_move.to_u16() != 0) {
            self.qsearch_store(pos, best_score, static_eval, best_move, tt.Bound.Upper);
        }

        return best_score;
    }
};

test "contempt only reinterprets exact TT zero" {
    const old_contempt = CONTEMPT;
    defer CONTEMPT = old_contempt;

    var s: Searcher = undefined;
    s.ply = 0;

    CONTEMPT = 0;
    try std.testing.expectEqual(@as(i32, 0), s.tt_score(0, tt.Bound.Exact));

    CONTEMPT = 100;
    try std.testing.expectEqual(@as(i32, -100), s.tt_score(0, tt.Bound.Exact));
    try std.testing.expectEqual(@as(i32, 0), s.tt_score(0, tt.Bound.Lower));
    try std.testing.expectEqual(@as(i32, 0), s.tt_score(0, tt.Bound.Upper));
    try std.testing.expectEqual(@as(i32, 23), s.tt_score(23, tt.Bound.Exact));

    s.ply = 1;
    try std.testing.expectEqual(@as(i32, 100), s.tt_score(0, tt.Bound.Exact));
}

test "contempt skips numerically ambiguous generic TT stores" {
    const old_contempt = CONTEMPT;
    defer CONTEMPT = old_contempt;

    var s: Searcher = undefined;
    s.ply = 0;

    CONTEMPT = 0;
    try std.testing.expect(!s.tt_store_is_ambiguous(-100, tt.Bound.Exact));
    try std.testing.expect(!s.tt_store_is_ambiguous(0, tt.Bound.Exact));

    CONTEMPT = 100;
    try std.testing.expect(s.tt_store_is_ambiguous(-100, tt.Bound.Exact));
    try std.testing.expect(s.tt_store_is_ambiguous(-100, tt.Bound.Lower));
    try std.testing.expect(s.tt_store_is_ambiguous(0, tt.Bound.Exact));
    try std.testing.expect(!s.tt_store_is_ambiguous(0, tt.Bound.Lower));
    try std.testing.expect(!s.tt_store_is_ambiguous(23, tt.Bound.Exact));
}
