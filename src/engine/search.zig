const std = @import("std");
const platform = @import("../platform.zig");

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
const strength_model = @import("strength.zig");
const thread_pool = @import("thread_pool.zig");

pub const line_ending = if (@import("builtin").os.tag == .windows) "\r\n" else "\n";

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
pub const MAX_MOVES = 256;
pub const MAX_MULTI_PV = MAX_MOVES;

/// One MultiPV line at the root, best first after each iteration.
pub const RootLine = struct {
    score: i32 = -hce.MateScore,
    depth: usize = 0,
    seldepth: u32 = 0,
    pv: [MAX_PLY]types.Move = undefined,
    pv_len: usize = 0,

    fn better_than(_: void, a: RootLine, b: RootLine) bool {
        return a.score > b.score;
    }
};

/// Searches shorter than this print only per-iteration lines; longer ones also
/// report the move being searched and aspiration fail-highs/-lows so GUIs do
/// not look frozen.
pub const LIVE_INFO_DELAY_MS: u64 = 3000;

pub const ScoreBound = enum { exact, lower, upper };

const InfoStats = struct {
    nodes: u64,
    nps: u64,
    hashfull: u64,
    tbhits: u64,
    time_ms: u64,
};

inline fn mate_distance(score: i32) i32 {
    return @divTrunc(hce.MateScore - @as(i32, @intCast(@abs(score))) + 1, 2);
}

// Field order follows Stockfish; some GUIs drop PVs from other orderings.
fn print_line(w: *std.Io.Writer, pos: *const position.Position, line: *const RootLine, multipv: usize, bound: ScoreBound, stats: InfoStats) void {
    const score = line.score;
    w.print("info depth {} seldepth {} multipv {} score ", .{ line.depth, line.seldepth, multipv }) catch {};
    const is_mate_score = @as(i32, @intCast(@abs(score))) >= hce.MateScore - hce.MaxMate;
    if (is_mate_score) {
        w.print("mate {}", .{mate_distance(score) * @as(i32, if (score > 0) 1 else -1)}) catch {};
    } else {
        w.print("cp {}", .{score}) catch {};
    }
    switch (bound) {
        .exact => {},
        .lower => w.writeAll(" lowerbound") catch {},
        .upper => w.writeAll(" upperbound") catch {},
    }
    if (wdl_model.show_wdl) {
        const p = if (@as(i32, @intCast(@abs(score))) >= SCORE_PLY_ADJ)
            wdl_model.decisive(score)
        else
            wdl_model.predict(score, pos.absolute_ply());
        w.print(" wdl {} {} {}", .{ p.win, p.draw, p.loss }) catch {};
    }
    w.print(" nodes {} nps {} hashfull {} tbhits {} time {} pv", .{ stats.nodes, stats.nps, stats.hashfull, stats.tbhits, stats.time_ms }) catch {};
    for (line.pv[0..line.pv_len]) |move| {
        w.writeByte(' ') catch {};
        move.uci_print(w, pos.chess960_notation());
    }
    w.writeAll(line_ending) catch {};
}

// Tablebase win/loss score band, kept just below the mate band
// (hce.MateScore - hce.MaxMate) so a TB result reads as a large cp score rather
// than "mate", and is never treated as a real mate by hce.is_near_mate. A TB win
// at ply p scores TB_WIN_SCORE - p (shallower wins preferred); a loss negates it.
pub const TB_WIN_SCORE: i32 = hce.MateScore - hce.MaxMate - MAX_PLY;

// Threshold for ply-normalizing scores stored in the TT. Covers both mate
// scores (above MateScore - MaxMate) and TB win/loss scores (above TB_WIN_SCORE - MAX_PLY).
const SCORE_PLY_ADJ: i32 = TB_WIN_SCORE - MAX_PLY;

// Pawn and non-pawn correction history, see docs/SEARCH.md. Entries are in 1/CORRHIST_GRAIN cp.
pub const CORRHIST_SIZE: usize = 16384;
pub const CORRHIST_GRAIN: i32 = 256;
pub const CORRHIST_LIMIT: i32 = 32 * CORRHIST_GRAIN;
const CORRHIST_MAX_BONUS: i32 = CORRHIST_LIMIT / 4;
const CORRHIST_WEIGHT_SCALE: i32 = 8;
const PAWN_CORRHIST_WEIGHT: i32 = 8;
const NONPAWN_CORRHIST_WEIGHT: i32 = 6;
// A large |correction| marks an unreliable static eval: LMR reduces one ply less per this many cp.
const CORRHIST_LMR_DIVISOR: i32 = 64;

pub fn weighted_correction(pawn: i32, nonpawn_white: i32, nonpawn_black: i32) i32 {
    return @divTrunc(PAWN_CORRHIST_WEIGHT * pawn + NONPAWN_CORRHIST_WEIGHT * (nonpawn_white + nonpawn_black), CORRHIST_GRAIN * CORRHIST_WEIGHT_SCALE);
}

pub fn update_correction(entry: *i16, best_score: i32, static_eval: i32, depth: usize) void {
    const diff = std.math.clamp(best_score - static_eval, -CORRHIST_LIMIT, CORRHIST_LIMIT);
    const bonus = std.math.clamp(diff * @as(i32, @intCast(depth)), -CORRHIST_MAX_BONUS, CORRHIST_MAX_BONUS);
    const value: i32 = entry.*;
    entry.* = @intCast(value + bonus - @divTrunc(value * @as(i32, @intCast(@abs(bonus))), CORRHIST_LIMIT));
}

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
pub const MAX_SEARCH_THREADS: usize = if (platform.has_threads) MAX_THREADS else 1;
pub var NUM_THREADS: usize = 0;
pub var THREADS_CONFIGURED: bool = false;

pub const DEFAULT_MOVE_OVERHEAD: u64 = 25;
pub const MAX_MOVE_OVERHEAD: u64 = 5000;
pub var MOVE_OVERHEAD: u64 = DEFAULT_MOVE_OVERHEAD;

pub var CONTEMPT: i32 = 0;
pub const MAX_CONTEMPT: i32 = 100;

pub var helper_pool: thread_pool.ThreadPool = .{};
pub var helpers_live: bool = false;

pub fn helpers_are_live() bool {
    return @atomicLoad(bool, &helpers_live, .acquire);
}

inline fn helper(index: usize) *Searcher {
    return helper_pool.worker(index).searcher;
}

/// Sets the number of helper threads, releasing surplus threads and their tables.
pub fn set_helper_count(n: usize) void {
    std.debug.assert(!helpers_are_live());
    helper_pool.resize(n);
    NUM_THREADS = helper_pool.count();
}

pub fn helper_count() usize {
    return helper_pool.count();
}

pub fn reset_helper_heuristics() void {
    helper_pool.reset_heuristics();
}

/// Required after the network weights change: helpers keep their own Finny tables.
pub fn discard_helper_evaluation_caches() void {
    std.debug.assert(!helpers_are_live());
    for (0..helper_pool.count()) |i| helper(i).root_board.evaluator.nnue_evaluator.finny_ready = false;
}

pub fn shutdown_helpers() void {
    helper_pool.deinit();
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
    shared_nodes: platform.AtomicValue(u64) = platform.AtomicValue(u64).init(0),
    parent_nodes: ?*platform.AtomicValue(u64) = null,
    root_history_len: usize = 0,

    exclude_move: [MAX_PLY]types.Move = undefined,
    nmp_min_ply: u32 = 0,

    hash_history: std.array_list.Managed(u64) = undefined,
    eval_history: [MAX_PLY]i32 = undefined,
    raw_eval_history: [MAX_PLY]i32 = undefined,
    move_history: [MAX_PLY]types.Move = undefined,
    moved_piece_history: [MAX_PLY]types.Piece = undefined,

    best_move: types.Move = undefined,
    pv: [MAX_PLY + 1][MAX_PLY]types.Move = undefined,
    pv_size: [MAX_PLY + 1]usize = undefined,

    killer: [MAX_PLY + 1][2]types.Move = undefined,
    history: [2][64][64]i32 = undefined,

    counter_moves: [2][64][64]types.Move = undefined,
    continuation: *[12][64][64][64]i16,
    pawn_correction: [2][CORRHIST_SIZE]i16 = undefined,
    nonpawn_correction: [2][2][CORRHIST_SIZE]i16 = undefined,

    root_board: *position.Position,
    ttable: *tt.TranspositionTable = &tt.GlobalTT,
    thread_id: usize = 0,
    silent_output: bool = false,
    age_pending: bool = false,
    root_evaluation_pending: bool = false,
    has_searched: bool = false,

    node_spent_table: [64][64]u64 = undefined,

    tbhits: u64 = 0,
    syzygy_root_active: bool = false,
    syzygy_root: syzygy.RootResult = undefined,

    multi_pv: usize = 1,
    strength: strength_model.Strength = .{},
    infinite: bool = false,
    pondering: bool = false,
    mate_in: ?i32 = null,
    search_moves: [MAX_MOVES]types.Move = undefined,
    search_move_count: usize = 0,

    root_moves: [MAX_MOVES]types.Move = undefined,
    root_move_count: usize = 0,
    root_restricted: bool = false,
    root_excluded: [MAX_MULTI_PV]types.Move = undefined,
    root_excluded_count: usize = 0,
    lines: [MAX_MULTI_PV]RootLine = undefined,
    line_count: usize = 0,
    ponder_move: types.Move = types.Move.empty(),
    // The main thread's UCI output for the running search; live info shares it
    // so every line of one search goes through one ordered channel.
    info_out: ?*std.Io.Writer = null,
    // Iteration depth reported to GUIs; aspiration re-searches may search shallower.
    root_depth: usize = 0,
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    rng_seeded: bool = false,

    pub fn init(self: *Searcher) void {
        const board = platform.allocator.create(position.Position) catch unreachable;
        board.init();
        self.* = .{
            .continuation = platform.allocator.create([12][64][64][64]i16) catch unreachable,
            .root_board = board,
        };
        self.hash_history = std.array_list.Managed(u64).initCapacity(platform.allocator, MAX_GAMEPLY) catch unreachable;
        self.reset_heuristics(true);
    }

    pub fn new() Searcher {
        var s: Searcher = undefined;
        s.init();
        return s;
    }

    pub fn deinit(self: *Searcher) void {
        self.hash_history.deinit();
        platform.allocator.destroy(self.continuation);
        self.root_board.deinit();
        platform.allocator.destroy(self.root_board);
    }

    inline fn pack_static_eval(value: i32) i16 {
        return @as(i16, @intCast(@min(@as(i32, 32767), @max(@as(i32, tt.EVAL_NONE) + 1, value))));
    }

    inline fn pawn_correction_entry(self: *Searcher, pos: *const position.Position, comptime color: types.Color) *i16 {
        return &self.pawn_correction[@intFromEnum(color)][@as(usize, @intCast(pos.pawn_hash % CORRHIST_SIZE))];
    }

    inline fn nonpawn_correction_entry(self: *Searcher, pos: *const position.Position, comptime color: types.Color, comptime key_color: types.Color) *i16 {
        return &self.nonpawn_correction[@intFromEnum(color)][@intFromEnum(key_color)][@as(usize, @intCast(pos.nonpawn_hash[@intFromEnum(key_color)] % CORRHIST_SIZE))];
    }

    inline fn eval_correction(self: *Searcher, pos: *const position.Position, comptime color: types.Color) i32 {
        return weighted_correction(
            self.pawn_correction_entry(pos, color).*,
            self.nonpawn_correction_entry(pos, color, .White).*,
            self.nonpawn_correction_entry(pos, color, .Black).*,
        );
    }

    inline fn corrected_eval(raw_eval: i32, correction: i32) i32 {
        return std.math.clamp(raw_eval + correction, -SCORE_PLY_ADJ + 1, SCORE_PLY_ADJ - 1);
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

        if (total_reset) {
            @memset(std.mem.asBytes(&self.pawn_correction), 0);
            @memset(std.mem.asBytes(&self.nonpawn_correction), 0);
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
                self.raw_eval_history[j] = 0;
                self.move_history[j] = types.Move.empty();
                self.moved_piece_history[j] = types.Piece.NO_PIECE;
            }
        }
    }

    inline fn stop_requested(self: *Searcher) bool {
        if (@atomicLoad(bool, &self.stop, .monotonic)) return true;
        if (platform.hostStopRequested()) {
            @atomicStore(bool, &self.stop, true, .monotonic);
            return true;
        }
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
        if (self.uses_clock() and self.max_millis > 0 and self.timer.read() / std.time.ns_per_ms >= self.max_millis) return true;
        return false;
    }

    pub inline fn should_not_continue(self: *Searcher, factor: f32) bool {
        if (self.stop_requested()) return true;
        if (self.thread_id != 0) return false;
        if (self.iterative_deepening_depth <= self.min_depth) return false;
        if (self.soft_max_nodes != null and self.total_nodes() >= self.soft_max_nodes.?) return true;
        if (self.uses_clock() and self.timer.read() / std.time.ns_per_ms >= @min(self.max_millis, @as(u64, @intFromFloat(@floor(@as(f32, @floatFromInt(self.ideal_time)) * factor))))) return true;
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
        return self.iterative_deepening_mode(pos, color, .scaled, max_depth);
    }

    pub fn iterative_deepening_mode(self: *Searcher, pos: *position.Position, comptime color: types.Color, comptime mode: hce.EvalMode, max_depth: ?u8) i32 {
        var out_buf: [4096]u8 = undefined;
        var out_file = platform.Stdout.init(&out_buf);
        const outW = out_file.writer();
        self.info_out = outW;
        defer self.info_out = null;
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
        self.ponder_move = types.Move.empty();
        self.line_count = 0;
        self.root_excluded_count = 0;

        if (self.thread_id == 0) {
            for (&self.node_spent_table) |*row| {
                @memset(row, 0);
            }
        }

        self.timer = types.Timer.start();

        self.probe_root_tablebase(pos);
        self.build_root_moves(pos, color);

        if (self.root_move_count == 0) {
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
                outW.writeAll(line_ending) catch {};
                outW.flush() catch {};
            }
            self.wait_for_release();
            self.ttable.do_age();
            @atomicStore(bool, &self.is_searching, false, .release);
            if (!self.silent_output) {
                outW.writeAll("bestmove 0000" ++ line_ending) catch {};
                outW.flush() catch {};
            }
            return terminal;
        }

        var prev_score = -hce.MateScore;
        var score = -hce.MateScore;
        var bm = types.Move.empty();

        var stability: usize = 0;
        var previous_iteration_end_ms: u64 = 0;
        var previous_iteration_cost: u64 = 0;
        var previous_iteration_nodes: u64 = 0;
        var previous_iteration_node_cost: u64 = 0;

        // Threads are only ever changed through set_helper_count.
        std.debug.assert(NUM_THREADS <= helper_pool.count());
        var ti: usize = 0;
        while (ti < NUM_THREADS) : (ti += 1) {
            helper(ti).nodes = 0;
            helper(ti).tbhits = 0;
            helper(ti).age_pending = helper(ti).has_searched;
            helper(ti).adopt_root(self, pos);
        }

        const limited = self.strength.is_limited();
        const pv_target = @min(
            if (limited) @max(self.multi_pv, self.strength.candidate_count()) else self.multi_pv,
            self.root_move_count,
        );

        var tdepth: usize = 1;
        var bound: usize = if (max_depth == null) MAX_PLY - 2 else max_depth.?;
        if (limited) {
            bound = @min(bound, self.strength.max_depth());
        }
        outer: while (tdepth <= bound) {
            var pv_index: usize = 0;
            var interrupted = false;
            while (pv_index < pv_target) : (pv_index += 1) {
                self.root_excluded_count = pv_index;
                const line_seed = if (pv_index < self.line_count) self.lines[pv_index].score else score;
                const line_score = self.search_root_line(pos, color, mode, tdepth, line_seed) orelse {
                    interrupted = true;
                    break;
                };
                self.record_line(pv_index, line_score, tdepth);
                self.root_excluded[pv_index] = self.lines[pv_index].pv[0];
            }
            self.root_excluded_count = 0;
            if (interrupted) {
                if (pv_index == 0) break :outer;
                // Lines not re-searched at this depth carry incomparable scores.
                self.line_count = pv_index;
            }
            self.sort_lines();

            score = self.lines[0].score;
            if (self.lines[0].pv[0].to_u16() != bm.to_u16()) {
                stability = 0;
            } else {
                stability += 1;
            }

            bm = self.lines[0].pv[0];

            const is_mate_score = @as(i32, @intCast(@abs(score))) >= hce.MateScore - hce.MaxMate;
            if (is_mate_score and !self.force_thinking and max_depth == null and bound == MAX_PLY - 2) {
                bound = tdepth + 2;
            }

            if (!self.silent_output) {
                const stats = self.collect_stats();
                for (self.lines[0..self.line_count], 1..) |*line, multipv| {
                    print_line(outW, pos, line, multipv, .exact, stats);
                }
                outW.flush() catch {};
            }

            if (interrupted) break;

            if (self.mate_in) |moves| {
                if (score > 0 and is_mate_score and mate_distance(score) <= moves) break;
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
            const reserve_stop = !normal_stop and self.uses_clock() and self.ideal_time < self.max_millis and
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

        var chosen_line: ?*const RootLine = if (self.line_count > 0 and self.lines[0].pv[0].to_u16() == bm.to_u16()) &self.lines[0] else null;
        if (limited and self.line_count > 0) {
            chosen_line = &self.lines[self.pick_weakened_line()];
            bm = chosen_line.?.pv[0];
        }

        const searched = bm.to_u16() != 0;
        if (!searched) {
            bm = self.root_moves[0];
        }

        self.best_move = bm;
        if (searched and !self.silent_output) {
            self.ponder_move = self.find_ponder_move(pos, color, bm, chosen_line);
        }

        self.wait_for_release();
        self.ttable.do_age();
        @atomicStore(bool, &self.is_searching, false, .release);

        if (!self.silent_output) {
            outW.writeAll("bestmove ") catch {};
            bm.uci_print(outW, pos.chess960_notation());
            if (self.ponder_move.to_u16() != 0) {
                outW.writeAll(" ponder ") catch {};
                self.ponder_move.uci_print(outW, pos.chess960_notation());
            }
            outW.writeAll(line_ending) catch {};
            outW.flush() catch {};
        }

        return score;
    }

    // Aspiration-window search of one MultiPV line; null when the search was stopped.
    fn search_root_line(self: *Searcher, pos: *position.Position, comptime color: types.Color, comptime mode: hce.EvalMode, tdepth: usize, previous_score: i32) ?i32 {
        self.ply = 0;
        self.seldepth = 0;
        self.root_depth = tdepth;

        var alpha = -hce.MateScore;
        var beta = hce.MateScore;
        var delta = hce.MateScore;
        var depth = tdepth;

        if (depth >= parameters.AspirationDepth) {
            const window = @max(parameters.AspirationWindow, 1);
            if (@as(i32, @intCast(@abs(previous_score))) < hce.MateScore - hce.MaxMate) {
                alpha = @max(previous_score - window, -hce.MateScore);
                beta = @min(previous_score + window, hce.MateScore);
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
            if (platform.has_threads and depth > 1) {
                self.helpers(pos, color, mode, depth, alpha, beta);
            }

            self.nmp_min_ply = 0;

            const score = self.negamax(pos, color, mode, depth, alpha, beta, false, NodeType.Root, false);

            if (platform.has_threads and depth > 1) {
                self.stop_helpers();
            }

            if (self.time_stop or self.should_stop()) {
                return null;
            }

            if (score <= alpha or score >= beta) {
                self.report_aspiration_failure(pos, score, tdepth, if (score <= alpha) .upper else .lower);
            }

            if (score <= alpha) {
                beta = @divTrunc(alpha + beta, 2);
                alpha = @max(alpha - delta, -hce.MateScore);
            } else if (score >= beta) {
                beta = @min(beta + delta, hce.MateScore);
                if (depth > 1 and (tdepth < 4 or depth > tdepth - 4)) {
                    depth -= 1;
                }
            } else {
                return score;
            }

            delta += @max(@divTrunc(delta * parameters.AspirationDeltaPercent, 100), 1);
        }
    }

    fn record_line(self: *Searcher, index: usize, score: i32, depth: usize) void {
        self.capture_root_line(&self.lines[index], score, depth);
        self.line_count = @max(self.line_count, index + 1);
    }

    fn capture_root_line(self: *const Searcher, line: *RootLine, score: i32, depth: usize) void {
        line.score = score;
        line.depth = depth;
        line.seldepth = self.seldepth;
        if (self.pv_size[0] > 0 and self.pv[0][0].to_u16() == self.best_move.to_u16()) {
            line.pv_len = self.pv_size[0];
            @memcpy(line.pv[0..line.pv_len], self.pv[0][0..line.pv_len]);
        } else {
            line.pv_len = 1;
            line.pv[0] = self.best_move;
        }
    }

    /// Node and tablebase counts summed over the main thread and all helpers.
    fn collect_stats(self: *Searcher) InfoStats {
        var nodes: u64 = self.nodes;
        var tbhits: u64 = self.tbhits;
        for (0..NUM_THREADS) |i| {
            nodes += helper(i).nodes;
            tbhits += helper(i).tbhits;
        }
        const elapsed_ms = self.timer.read() / std.time.ns_per_ms;
        return .{
            .nodes = nodes,
            .nps = nodes * 1000 / @max(@as(u64, 1), elapsed_ms),
            .hashfull = self.ttable.hashfull(),
            .tbhits = tbhits,
            .time_ms = elapsed_ms,
        };
    }

    inline fn reports_live_info(self: *const Searcher) bool {
        return self.thread_id == 0 and !self.silent_output and
            self.timer.read() / std.time.ns_per_ms >= LIVE_INFO_DELAY_MS;
    }

    // Like Stockfish, bounds are only reported with a single PV line, where the
    // bounded score unambiguously refers to the line GUIs are displaying.
    fn report_aspiration_failure(self: *Searcher, pos: *const position.Position, score: i32, depth: usize, bound: ScoreBound) void {
        if (self.root_excluded_count > 0 or self.multi_pv > 1 or self.strength.is_limited() or !self.reports_live_info()) return;
        const w = self.info_out orelse return;
        var line: RootLine = .{};
        self.capture_root_line(&line, score, depth);
        print_line(w, pos, &line, 1, bound, self.collect_stats());
        w.flush() catch {};
    }

    fn report_current_move(self: *const Searcher, pos: *const position.Position, move: types.Move, number: usize, depth: usize) void {
        const w = self.info_out orelse return;
        w.print("info depth {} currmove ", .{depth}) catch {};
        move.uci_print(w, pos.chess960_notation());
        w.print(" currmovenumber {}" ++ line_ending, .{number + self.root_excluded_count}) catch {};
        w.flush() catch {};
    }

    fn sort_lines(self: *Searcher) void {
        std.sort.insertion(RootLine, self.lines[0..self.line_count], {}, RootLine.better_than);
    }

    fn pick_weakened_line(self: *Searcher) usize {
        const count = @min(self.line_count, self.strength.candidate_count());
        var scores: [MAX_MOVES]i32 = undefined;
        for (self.lines[0..count], scores[0..count]) |line, *s| s.* = line.score;
        if (!self.rng_seeded) {
            const seed: u96 = @bitCast(self.timer.start_ns);
            self.rng = std.Random.DefaultPrng.init(@truncate(seed));
            self.rng_seeded = true;
        }
        return self.strength.pick(scores[0..count], self.rng.random());
    }

    fn find_ponder_move(self: *Searcher, pos: *position.Position, comptime color: types.Color, bm: types.Move, line: ?*const RootLine) types.Move {
        if (line) |l| {
            if (l.pv_len >= 2 and l.pv[0].to_u16() == bm.to_u16()) return l.pv[1];
        }
        if (bm.to_u16() == 0) return types.Move.empty();

        pos.play_move(color, bm);
        defer pos.undo_move(color, bm);
        const entry = self.ttable.get(pos.hash) orelse return types.Move.empty();
        var storage: [MAX_MOVES]types.Move = undefined;
        var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&storage));
        var replies = std.array_list.Managed(types.Move).initCapacity(fba.allocator(), storage.len) catch unreachable;
        pos.generate_legal_moves(comptime color.invert(), &replies);
        for (replies.items) |reply| {
            if (reply.to_u16() == entry.bestmove.to_u16()) return reply;
        }
        return types.Move.empty();
    }

    // UCI forbids `bestmove` during `go infinite` or `go ponder` until stop/ponderhit.
    fn wait_for_release(self: *Searcher) void {
        while (!self.stop_requested() and (self.infinite or self.is_pondering())) {
            platform.sleepMs(1);
        }
    }

    pub inline fn is_pondering(self: *Searcher) bool {
        if (platform.hostPonderhitRequested()) self.ponderhit();
        return @atomicLoad(bool, &self.pondering, .acquire);
    }

    pub fn ponderhit(self: *Searcher) void {
        @atomicStore(bool, &self.pondering, false, .release);
    }

    inline fn uses_clock(self: *Searcher) bool {
        return !self.force_thinking and !self.is_pondering();
    }

    fn probe_root_tablebase(self: *Searcher, pos: *position.Position) void {
        self.syzygy_root_active = false;
        if (syzygy.active() and syzygy.no_castling_rights(pos) and
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
    }

    // Root candidates: legal moves, narrowed to `searchmoves` and to the
    // tablebase-optimal set. Falls back to the wider set if a filter empties it.
    fn build_root_moves(self: *Searcher, pos: *position.Position, comptime color: types.Color) void {
        var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&self.root_moves));
        var legal = std.array_list.Managed(types.Move).initCapacity(fba.allocator(), MAX_MOVES) catch unreachable;
        pos.generate_legal_moves(color, &legal);
        const legal_count = legal.items.len;

        if (self.search_move_count > 0) {
            keep_moves(&legal, self.search_moves[0..self.search_move_count]);
        }
        if (self.syzygy_root_active) {
            self.filter_tb_optimal(&legal);
        }
        self.root_move_count = legal.items.len;
        self.root_restricted = self.root_move_count < legal_count;
    }

    fn keep_moves(list: *std.array_list.Managed(types.Move), allowed: []const types.Move) void {
        var kept: usize = 0;
        for (list.items) |m| {
            if (contains_move(allowed, m)) {
                list.items[kept] = m;
                kept += 1;
            }
        }
        if (kept > 0) list.shrinkRetainingCapacity(kept);
    }

    inline fn contains_move(moves: []const types.Move, move: types.Move) bool {
        for (moves) |m| {
            if (m.to_u16() == move.to_u16()) return true;
        }
        return false;
    }

    inline fn is_root_excluded(self: *const Searcher, move: types.Move) bool {
        return contains_move(self.root_excluded[0..self.root_excluded_count], move);
    }

    // Narrows a root move list to the root candidates minus lines already reported.
    fn filter_root_moves(self: *Searcher, list: *std.array_list.Managed(types.Move)) void {
        var kept: usize = 0;
        for (list.items) |m| {
            if (self.root_restricted and !contains_move(self.root_moves[0..self.root_move_count], m)) continue;
            if (self.is_root_excluded(m)) continue;
            list.items[kept] = m;
            kept += 1;
        }
        list.shrinkRetainingCapacity(kept);
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

    fn filter_tb_optimal(self: *Searcher, list: *std.array_list.Managed(types.Move)) void {
        var kept: usize = 0;
        for (list.items) |m| {
            if (self.root_move_is_tb_optimal(m)) {
                list.items[kept] = m;
                kept += 1;
            }
        }
        if (kept > 0) list.shrinkRetainingCapacity(kept);
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

    pub fn helpers(self: *Searcher, pos: *position.Position, comptime color: types.Color, comptime mode: hce.EvalMode, depth_: usize, alpha_: i32, beta_: i32) void {
        @atomicStore(bool, &helpers_live, true, .release);
        for (0..NUM_THREADS) |i| {
            const id: usize = i + 1;
            const h = helper(i);
            h.max_millis = self.max_millis;
            h.max_nodes = self.max_nodes;
            h.soft_max_nodes = self.soft_max_nodes;
            h.ttable = self.ttable;
            h.thread_id = id;
            h.parent_stop = &self.stop;
            h.parent_nodes = if (self.max_nodes != null or self.soft_max_nodes != null) &self.shared_nodes else null;
            h.root_history_len = self.root_history_len;
            h.copy_root_candidates(self);
            std.debug.assert(h.root_board.hash == pos.hash and h.hash_history.items.len == self.hash_history.items.len);
            @atomicStore(bool, &h.stop, false, .monotonic);
            helper_pool.start_search(i, .{
                .color = color,
                .mode = mode,
                .depth = if (id % 2 == 1) depth_ + 1 else depth_,
                .alpha = alpha_,
                .beta = beta_,
            });
        }
    }

    /// Takes over the main thread's root once per search; every job unwinds
    /// back to it, so aspiration attempts need no further copying. The
    /// evaluator is rebuilt later on the helper's own thread.
    pub fn adopt_root(self: *Searcher, main: *const Searcher, pos: *const position.Position) void {
        self.root_board.copy_game_state(pos);
        self.root_evaluation_pending = true;
        self.hash_history.clearRetainingCapacity();
        self.hash_history.appendSlice(main.hash_history.items) catch {};
    }

    fn copy_root_candidates(self: *Searcher, main: *const Searcher) void {
        self.root_move_count = main.root_move_count;
        self.root_restricted = main.root_restricted;
        @memcpy(self.root_moves[0..main.root_move_count], main.root_moves[0..main.root_move_count]);
        self.root_excluded_count = main.root_excluded_count;
        @memcpy(self.root_excluded[0..main.root_excluded_count], main.root_excluded[0..main.root_excluded_count]);
    }

    pub fn start_helper(self: *Searcher, color: types.Color, mode: hce.EvalMode, depth_: usize, alpha_: i32, beta_: i32) void {
        @atomicStore(bool, &self.is_searching, true, .release);
        self.has_searched = true;
        if (self.age_pending) {
            self.age_pending = false;
            self.reset_heuristics(false);
        }
        if (self.root_evaluation_pending) {
            self.root_evaluation_pending = false;
            self.root_board.rebuild_evaluation();
        }
        self.time_stop = false;
        self.best_move = types.Move.empty();
        self.timer = types.Timer.start();
        self.force_thinking = true;
        self.ply = 0;
        self.seldepth = 0;

        switch (color) {
            inline else => |c| switch (mode) {
                inline else => |m| _ = self.negamax(self.root_board, c, m, depth_, alpha_, beta_, false, NodeType.Root, false),
            },
        }
        @atomicStore(bool, &self.is_searching, false, .release);
    }

    pub fn stop_helpers(_: *Searcher) void {
        defer @atomicStore(bool, &helpers_live, false, .release);
        for (0..NUM_THREADS) |i| @atomicStore(bool, &helper(i).stop, true, .monotonic);
        for (0..NUM_THREADS) |i| helper_pool.worker(i).wait_idle();
    }

    pub fn negamax(self: *Searcher, pos: *position.Position, comptime color: types.Color, comptime mode: hce.EvalMode, depth_: usize, alpha_: i32, beta_: i32, comptime is_null: bool, comptime node: NodeType, comptime cutnode: bool) i32 {
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
            return if (in_check) self.contempt_score() else hce.evaluate_mode(pos, color, mode);
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
            return self.quiescence_search(pos, color, mode, alpha, beta);
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
            if (is_root and !self.is_root_excluded(hashmove)) {
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
        if (syzygy.active() and !is_root and !is_null and
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

        const raw_eval: i32 = if (in_check) -hce.MateScore + @as(i32, @intCast(self.ply)) else if (tthit and entry.?.static_eval != tt.EVAL_NONE) entry.?.static_eval else if (is_null) -self.raw_eval_history[self.ply - 1] else if (self.exclude_move[self.ply].to_u16() != 0) self.raw_eval_history[self.ply] else hce.evaluate_mode(pos, color, mode);
        const correction: i32 = if (in_check) 0 else self.eval_correction(pos, color);
        const static_eval: i32 = if (in_check) raw_eval else corrected_eval(raw_eval, correction);

        var best_score: i32 = static_eval;

        self.eval_history[self.ply] = static_eval;
        self.raw_eval_history[self.ply] = raw_eval;

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
                var null_score = -self.negamax(pos, opp_color, mode, depth - r, -beta, -beta + 1, true, NodeType.NonPV, !cutnode);
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

                    const verif_score = self.negamax(pos, color, mode, depth - r, beta - 1, beta, false, NodeType.NonPV, false);

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
                return self.quiescence_search(pos, color, mode, alpha, beta);
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
                        var qscore = -self.quiescence_search(pos, opp_color, mode, -probcut_beta, -probcut_beta + 1);

                        // Full shallow verification if qsearch passes
                        if (qscore >= probcut_beta) {
                            qscore = -self.negamax(pos, opp_color, mode, depth - parameters.ProbCutReduction, -probcut_beta, -probcut_beta + 1, false, NodeType.NonPV, !cutnode);
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
                                    .static_eval = pack_static_eval(raw_eval),
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
        if (is_root and (self.root_restricted or self.root_excluded_count > 0)) {
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
            if (is_root and self.reports_live_info()) {
                self.report_current_move(pos, move, legals, self.root_depth);
            }

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
                const singular_score = self.negamax(pos, color, mode, (depth - 1) / 2, singular_beta - 1, singular_beta, true, NodeType.NonPV, cutnode);
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
                score = -self.negamax(pos, opp_color, mode, new_depth, -beta, -alpha, false, NodeType.PV, false);
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

                    reduction -= @divTrunc(@as(i32, @intCast(@abs(correction))), CORRHIST_LMR_DIVISOR);

                    const rd: usize = @as(usize, @intCast(std.math.clamp(@as(i32, @intCast(new_depth)) - reduction, 1, new_depth + 1)));

                    // Step 5.7: Principal-Variation-Search (PVS)
                    score = -self.negamax(pos, opp_color, mode, rd, -alpha - 1, -alpha, false, NodeType.NonPV, true);

                    do_full_search = score > alpha and rd < new_depth;
                }

                if (do_full_search) {
                    score = -self.negamax(pos, opp_color, mode, new_depth, -alpha - 1, -alpha, false, NodeType.NonPV, !cutnode);
                }

                if (on_pv and score > alpha and score < beta) {
                    score = -self.negamax(pos, opp_color, mode, new_depth, -beta, -alpha, false, NodeType.PV, false);
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

        if (self.exclude_move[self.ply].to_u16() == 0 and !(is_root and self.root_excluded_count > 0)) {
            if (!in_check and
                !(is_root and self.root_restricted) and
                !(best_score > alpha_ and (best_move.is_capture() or best_move.is_promotion())) and
                !(best_score >= beta_ and best_score <= static_eval) and
                !(best_score <= alpha_ and best_score >= static_eval))
            {
                update_correction(self.pawn_correction_entry(pos, color), best_score, static_eval, depth);
                update_correction(self.nonpawn_correction_entry(pos, color, .White), best_score, static_eval, depth);
                update_correction(self.nonpawn_correction_entry(pos, color, .Black), best_score, static_eval, depth);
            }

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
                .static_eval = pack_static_eval(raw_eval),
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

    pub fn quiescence_search(self: *Searcher, pos: *position.Position, comptime color: types.Color, comptime mode: hce.EvalMode, alpha_: i32, beta_: i32) i32 {
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
            return if (in_check) self.contempt_score() else hce.evaluate_mode(pos, color, mode);
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
        var raw_eval = best_score;
        if (!in_check) {
            raw_eval = hce.evaluate_mode(pos, color, mode);
            best_score = corrected_eval(raw_eval, self.eval_correction(pos, color));

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
            const score = -self.quiescence_search(pos, opp_color, mode, -beta, -alpha);
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
                        self.qsearch_store(pos, best_score, raw_eval, best_move, tt.Bound.Lower);
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
            self.qsearch_store(pos, best_score, raw_eval, best_move, tt.Bound.Upper);
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

test "info line: bound annotation follows the score in Stockfish order" {
    var pos: position.Position = undefined;
    pos.uci_chess960 = false;
    pos.castling = .{};
    var line: RootLine = .{ .score = 42, .depth = 9, .seldepth = 12, .pv_len = 1 };
    line.pv[0] = types.Move.new_from_to(.e2, .e4);
    const stats = InfoStats{ .nodes = 10, .nps = 20, .hashfull = 3, .tbhits = 0, .time_ms = 500 };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    print_line(&w, &pos, &line, 1, .lower, stats);
    try std.testing.expectEqualStrings(
        "info depth 9 seldepth 12 multipv 1 score cp 42 lowerbound nodes 10 nps 20 hashfull 3 tbhits 0 time 500 pv e2e4" ++ line_ending,
        w.buffered(),
    );

    w = std.Io.Writer.fixed(&buf);
    print_line(&w, &pos, &line, 2, .exact, stats);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "multipv 2 score cp 42 nodes") != null);
}
