//! See docs/UCI.md.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const perft = @import("../chess/perft.zig");
const tt = @import("tt.zig");
const hce = @import("hce.zig");
const weights = @import("weights.zig");
const search = @import("search.zig");
const parameters = @import("parameters.zig");
const build_options = @import("build_options");
const genfens = @import("genfens.zig");
const syzygy = @import("syzygy.zig");
const options = @import("uci/options.zig");
const go = @import("uci/go.zig");
const numa = @import("numa.zig");

const Tokens = std.mem.TokenIterator(u8, .scalar);

const OVERHEAD_PER_HELPER_MS: u64 = 5;
const MAX_HELPER_OVERHEAD_MS: u64 = 25;

const AnytimeCommand = enum { quit, stop, ponderhit, isready };

const IdleCommand = enum { uci, setoption, ucinewgame, position, go, d, eval, perft, perftdiv, spsa, @"spsa++", genfens };

pub fn is_command(line: []const u8) bool {
    var tokens = tokenize(line);
    const word = tokens.next() orelse return false;
    return std.meta.stringToEnum(AnytimeCommand, word) != null or std.meta.stringToEnum(IdleCommand, word) != null;
}

pub const UciInterface = struct {
    position: position.Position,
    search_thread: ?std.Thread,
    searcher: search.Searcher,
    settings: options.Settings,

    pub fn init(self: *UciInterface) void {
        self.position.init();
        self.search_thread = null;
        self.searcher.init();
        self.settings = .{};
        self.set_root(types.DEFAULT_FEN);
    }

    pub fn deinit(self: *UciInterface) void {
        self.stop_search();
        self.searcher.deinit();
        self.position.deinit();
    }

    fn set_root(self: *UciInterface, fen: []const u8) void {
        self.position.set_fen(fen);
        self.searcher.hash_history.clear();
        self.searcher.hash_history.append(self.position.hash) catch unreachable;
    }

    fn join_search(self: *UciInterface) void {
        if (comptime platform.has_threads) {
            if (self.search_thread) |t| {
                t.join();
                self.search_thread = null;
            }
        }
        @atomicStore(bool, &self.searcher.shared.is_searching, false, .release);
    }

    fn stop_search(self: *UciInterface) void {
        @atomicStore(bool, &self.searcher.shared.stop, true, .monotonic);
        self.join_search();
    }

    pub fn main_loop(self: *UciInterface, startup_commands: []const []const u8) !void {
        var in_buf: [1 << 16]u8 = undefined;
        var in_file = std.Io.File.stdin().readerStreaming(platform.io, &in_buf);
        const stdin = &in_file.interface;
        var out_buf: [1 << 16]u8 = undefined;
        var out_file = platform.Stdout.init(&out_buf);
        const stdout = out_file.writer();

        defer {
            self.deinit();
            search.shutdown_helpers();
            syzygy.deinit();
        }

        try stdout.print("Avalanche {s} by Yinuo Huang (SnowballSH)" ++ search.LINE_ENDING, .{build_options.version});
        try stdout.flush();

        if (!try self.run_commands(startup_commands, stdout)) return;
        while (true) {
            const line = stdin.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream, error.StreamTooLong => break,
                else => return e,
            };
            if (!try self.run_commands(&.{line}, stdout)) break;
        }
    }

    pub fn run_commands(self: *UciInterface, lines: []const []const u8, out: *std.Io.Writer) !bool {
        for (lines) |line| {
            const keep_running = try self.handle_command(line, out);
            try out.flush();
            if (!keep_running) return false;
        }
        return true;
    }

    pub fn handle_command(self: *UciInterface, line: []const u8, out: *std.Io.Writer) !bool {
        var tokens = tokenize(line);
        const word = tokens.next() orelse return true;

        if (std.meta.stringToEnum(AnytimeCommand, word)) |command| {
            switch (command) {
                .quit => {
                    self.stop_search();
                    return false;
                },
                .stop => self.stop_search(),
                .ponderhit => self.searcher.ponderhit(),
                .isready => try out.writeAll("readyok" ++ search.LINE_ENDING),
            }
            return true;
        }

        if (@atomicLoad(bool, &self.searcher.shared.is_searching, .acquire)) {
            try out.print("info string ignored while searching: {s}" ++ search.LINE_ENDING, .{tokens.buffer});
            return true;
        }
        self.join_search();

        switch (std.meta.stringToEnum(IdleCommand, word) orelse return true) {
            .uci => {
                try out.writeAll("id name Avalanche " ++ build_options.version ++ search.LINE_ENDING);
                try out.writeAll("id author Yinuo Huang" ++ search.LINE_ENDING ++ search.LINE_ENDING);
                try options.print_all(out);
                try out.writeAll("uciok" ++ search.LINE_ENDING);
            },
            .setoption => options.set_option(tokens.rest(), .{ .settings = &self.settings, .position = &self.position, .out = out }) catch |err| {
                try out.print("info string setoption failed ({s}): {s}" ++ search.LINE_ENDING, .{ @errorName(err), tokens.rest() });
            },
            .ucinewgame => self.new_game(),
            .position => self.set_position(&tokens),
            .go => try self.start_search(&tokens, out),
            .d => self.position.debug_print(),
            .eval => try self.print_evaluation(out),
            .perft => self.run_perft(&tokens, .total),
            .perftdiv => self.run_perft(&tokens, .per_move),
            .spsa => try print_tunables(out, .all),
            .@"spsa++" => try print_tunables(out, .worth_tuning),
            .genfens => if (!platform.is_wasm) {
                try run_genfens(&tokens);
                return false;
            },
        }
        return true;
    }

    fn new_game(self: *UciInterface) void {
        self.searcher.deinit();
        self.searcher = search.Searcher.new();
        search.reset_helper_heuristics();
        tt.GlobalTT.clear();
        self.set_root(types.DEFAULT_FEN);
    }

    fn run_perft(self: *UciInterface, tokens: *Tokens, report: enum { total, per_move }) void {
        const depth = @max(std.fmt.parseUnsigned(u32, tokens.next() orelse "1", 10) catch 1, 1);
        self.position.evaluator.nnue_evaluator.reset_depth(&self.position);
        switch (report) {
            .total => perft.perft_test(&self.position, depth),
            .per_move => switch (self.position.turn) {
                .White => perft.perft_div(.White, &self.position, depth),
                .Black => perft.perft_div(.Black, &self.position, depth),
            },
        }
    }

    fn print_evaluation(self: *UciInterface, out: *std.Io.Writer) !void {
        const pos = &self.position;
        const white_sign: i32 = if (pos.turn == .White) 1 else -1;
        const final = switch (pos.turn) {
            .White => hce.evaluate_comptime(pos, .White),
            .Black => hce.evaluate_comptime(pos, .Black),
        };
        try print_network(out);
        try out.print("info string NNUE evaluation {d} cp (white side)" ++ search.LINE_ENDING, .{white_sign * hce.evaluate_nnue(pos)});
        try out.print("info string Final evaluation {d} cp (white side)" ++ search.LINE_ENDING, .{white_sign * final});
    }

    fn set_position(self: *UciInterface, tokens: *Tokens) void {
        const kind = tokens.next() orelse return;
        if (eql(kind, "startpos")) {
            self.set_root(types.DEFAULT_FEN);
        } else if (eql(kind, "fen")) {
            var fen_buf: [256]u8 = undefined;
            var fen = std.Io.Writer.fixed(&fen_buf);
            while (tokens.peek()) |tok| {
                if (eql(tok, "moves")) break;
                _ = tokens.next();
                if (fen.end > 0) fen.writeByte(' ') catch return;
                fen.writeAll(tok) catch return;
            }
            if (fen.end == 0) return;
            self.set_root(fen.buffered());
        } else {
            return;
        }

        if (!eql(tokens.next() orelse return, "moves")) return;
        while (tokens.next()) |tok| {
            if (self.position.game_ply >= position.MAX_HISTORY_PLY) break;
            const move = types.Move.parse(&self.position, tok) orelse break;
            switch (self.position.turn) {
                .White => self.position.play_move(.White, move),
                .Black => self.position.play_move(.Black, move),
            }
            self.searcher.hash_history.append(self.position.hash) catch unreachable;
        }
    }

    fn start_search(self: *UciInterface, tokens: *Tokens, out: *std.Io.Writer) !void {
        const cmd = go.GoCommand.parse(tokens, &self.position);
        const helper_overhead = @min(@as(u64, search.active_helpers) * OVERHEAD_PER_HELPER_MS, MAX_HELPER_OVERHEAD_MS);
        const budget = go.allocate_time(&cmd, self.position.turn, search.move_overhead + helper_overhead);

        try print_network(out);
        try out.flush();

        const s = &self.searcher;
        s.force_thinking = !budget.managed;
        s.max_millis = if (budget.managed) budget.maximum_ms else 0;
        s.ideal_time = budget.ideal_ms;
        s.max_nodes = cmd.nodes;
        s.soft_max_nodes = cmd.nodes;
        s.infinite = cmd.infinite;
        s.mate_in = cmd.mate;
        s.multi_pv = self.settings.multi_pv;
        s.strength = self.settings.playing_strength();
        s.search_move_count = cmd.search_move_count;
        @memcpy(s.search_moves[0..cmd.search_move_count], cmd.search_moves[0..cmd.search_move_count]);
        @atomicStore(bool, &s.shared.pondering, cmd.ponder, .release);

        const instant_single_reply = budget.managed and !cmd.ponder and !cmd.infinite;
        numa.init();

        @atomicStore(bool, &s.shared.stop, false, .monotonic);
        // Mark searching BEFORE spawning so a second `go` arriving before the
        // worker starts cannot pass the is_searching guard and double-spawn.
        @atomicStore(bool, &s.shared.is_searching, true, .release);

        if (comptime platform.has_threads) {
            self.search_thread = std.Thread.spawn(
                .{ .stack_size = search.SEARCH_STACK_SIZE },
                run_search,
                .{ s, &self.position, cmd.depth, instant_single_reply },
            ) catch |err| platform.fatal("cannot start the search thread: {s}", .{@errorName(err)});
        } else {
            run_search(s, &self.position, cmd.depth, instant_single_reply);
        }
    }
};

fn tokenize(line: []const u8) Tokens {
    return std.mem.tokenizeScalar(u8, std.mem.trim(u8, line, "\r\n"), ' ');
}

fn print_tunables(out: *std.Io.Writer, selection: enum { all, worth_tuning }) !void {
    for (parameters.TunableParams) |tunable| {
        if (selection == .worth_tuning and !tunable.worth_tuning) continue;
        const live = parameters.live_uci_value(tunable.name) orelse tunable.value;
        try out.print("{s}, int, {d}, {d}, {d}, {d}, {d}" ++ search.LINE_ENDING, .{ tunable.name, live, tunable.min_value, tunable.max_value, tunable.c_end, tunable.r_end });
    }
}

fn run_genfens(tokens: *Tokens) !void {
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(platform.allocator);
    try arguments.append(platform.allocator, "genfens");
    while (tokens.next()) |token| try arguments.append(platform.allocator, token);
    genfens.run(arguments.items) catch std.process.exit(1);
}

fn print_network(out: *std.Io.Writer) !void {
    try out.print("info string NNUE evaluation using {s} ({s}, {d} MiB)" ++ search.LINE_ENDING, .{
        weights.active_network(),
        weights.ARCHITECTURE,
        @sizeOf(weights.NNUEWeights) >> 20,
    });
}

fn run_search(searcher: *search.Searcher, pos: *position.Position, max_depth: ?u8, instant_single_reply: bool) void {
    numa.place_current_thread(0, search.thread_count());
    var depth = max_depth;
    if (instant_single_reply and legal_move_count(pos) == 1) {
        depth = 1;
    }
    switch (pos.turn) {
        .White => _ = searcher.iterative_deepening(pos, .White, depth),
        .Black => _ = searcher.iterative_deepening(pos, .Black, depth),
    }
}

fn legal_move_count(pos: *position.Position) usize {
    return pos.legal_moves().len;
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
