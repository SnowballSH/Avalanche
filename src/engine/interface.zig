const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const perft = @import("../chess/perft.zig");
const tt = @import("tt.zig");
const hce = @import("hce.zig");
const search = @import("search.zig");
const parameters = @import("parameters.zig");
const build_options = @import("build_options");
const genfens = @import("genfens.zig");
const syzygy = @import("syzygy.zig");
const options = @import("uci/options.zig");
const go = @import("uci/go.zig");
const numa = @import("numa.zig");

const nl = search.line_ending;

const Tokens = std.mem.TokenIterator(u8, .scalar);

pub const UciInterface = struct {
    position: position.Position,
    search_thread: ?std.Thread,
    searcher: search.Searcher,
    settings: options.Settings,

    pub fn new() UciInterface {
        var ui: UciInterface = undefined;
        ui.init();
        return ui;
    }

    pub fn init(self: *UciInterface) void {
        self.position.init();
        self.position.set_fen(types.DEFAULT_FEN[0..]);
        self.search_thread = null;
        self.searcher.init();
        self.settings = .{};
    }

    fn join_search(self: *UciInterface) void {
        if (comptime platform.has_threads) {
            if (self.search_thread) |t| {
                t.join();
                self.search_thread = null;
            }
        }
        @atomicStore(bool, &self.searcher.is_searching, false, .release);
    }

    fn stop_search(self: *UciInterface) void {
        @atomicStore(bool, &self.searcher.stop, true, .monotonic);
        self.join_search();
    }

    pub fn main_loop(self: *UciInterface) !void {
        var in_buf: [1 << 16]u8 = undefined;
        var in_file = std.Io.File.stdin().readerStreaming(platform.io, &in_buf);
        const stdin = &in_file.interface;
        var out_buf: [1 << 16]u8 = undefined;
        var out_file = platform.Stdout.init(&out_buf);
        const stdout = out_file.writer();

        defer {
            self.stop_search();
            self.searcher.deinit();
            self.position.deinit();
            search.shutdown_helpers();
            syzygy.deinit();
        }

        try stdout.print("Avalanche {s} by Yinuo Huang (SnowballSH)" ++ nl, .{build_options.version});
        try stdout.flush();

        while (true) {
            const line = stdin.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream, error.StreamTooLong => break,
                else => return e,
            };
            if (!try self.handle_command(line, stdout)) break;
            try stdout.flush();
        }
    }

    /// Runs one UCI command line. Returns false when the engine should exit.
    pub fn handle_command(self: *UciInterface, line: []const u8, out: *std.Io.Writer) !bool {
        var tokens = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line, "\r\n"), ' ');
        const command = tokens.next() orelse return true;

        if (eql(command, "quit")) {
            self.stop_search();
            return false;
        } else if (eql(command, "stop")) {
            self.stop_search();
            return true;
        } else if (eql(command, "ponderhit")) {
            self.searcher.ponderhit();
            return true;
        } else if (eql(command, "isready")) {
            try out.writeAll("readyok" ++ nl);
            return true;
        }

        if (@atomicLoad(bool, &self.searcher.is_searching, .acquire)) {
            try out.print("info string ignored while searching: {s}" ++ nl, .{std.mem.trim(u8, line, "\r\n")});
            return true;
        }
        self.join_search();

        if (eql(command, "uci")) {
            try out.writeAll("id name Avalanche " ++ build_options.version ++ nl);
            try out.writeAll("id author Yinuo Huang" ++ nl ++ nl);
            try options.print_all(out);
            try out.writeAll("uciok" ++ nl);
        } else if (eql(command, "setoption")) {
            options.set_option(tokens.rest(), .{ .settings = &self.settings, .position = &self.position, .out = out }) catch |err| {
                try out.print("info string setoption failed ({s}): {s}" ++ nl, .{ @errorName(err), tokens.rest() });
            };
        } else if (eql(command, "ucinewgame")) {
            self.searcher.deinit();
            self.searcher = search.Searcher.new();
            search.reset_helper_heuristics();
            tt.GlobalTT.clear();
            self.position.set_fen(types.DEFAULT_FEN[0..]);
        } else if (eql(command, "position")) {
            self.set_position(&tokens);
        } else if (eql(command, "go")) {
            self.start_search(&tokens);
        } else if (eql(command, "d")) {
            self.position.debug_print();
        } else if (eql(command, "eval")) {
            try self.print_evaluation(out);
        } else if (eql(command, "perft") or eql(command, "perftdiv")) {
            const depth = @max(std.fmt.parseUnsigned(u32, tokens.next() orelse "1", 10) catch 1, 1);
            if (eql(command, "perft")) {
                perft.perft_test(&self.position, depth);
            } else switch (self.position.turn) {
                .White => perft.perft_div(.White, &self.position, depth),
                .Black => perft.perft_div(.Black, &self.position, depth),
            }
        } else if (eql(command, "spsa") or eql(command, "spsa++")) {
            const focused = eql(command, "spsa++");
            for (parameters.TunableParams) |tunable| {
                if (focused and !tunable.worth_tuning) continue;
                const live = parameters.live_uci_value(tunable.name) orelse tunable.value;
                try out.print("{s}, int, {d}, {d}, {d}, {d}, {d}" ++ nl, .{ tunable.name, live, tunable.min_value, tunable.max_value, tunable.c_end, tunable.r_end });
            }
        } else if (!platform.is_wasm and eql(command, "genfens")) {
            // OpenBench datagen: generate FENs for the rest of the line, then exit.
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var args = std.array_list.Managed([]const u8).init(arena.allocator());
            try args.append("genfens");
            while (tokens.next()) |tok| try args.append(tok);
            genfens.run(args.items) catch {};
            return false;
        }
        return true;
    }

    /// Static evaluation from White's point of view: the raw network output and
    /// the final score the search uses (after endgame handling and scaling).
    fn print_evaluation(self: *UciInterface, out: *std.Io.Writer) !void {
        const pos = &self.position;
        const white_sign: i32 = if (pos.turn == .White) 1 else -1;
        const final = switch (pos.turn) {
            .White => hce.evaluate_comptime(pos, .White),
            .Black => hce.evaluate_comptime(pos, .Black),
        };
        try out.print("info string NNUE evaluation {d} cp (white side)" ++ nl, .{white_sign * hce.evaluate_nnue(pos)});
        try out.print("info string Final evaluation {d} cp (white side)" ++ nl, .{white_sign * final});
    }

    fn set_position(self: *UciInterface, tokens: *Tokens) void {
        const kind = tokens.next() orelse return;
        if (eql(kind, "startpos")) {
            self.position.set_fen(types.DEFAULT_FEN[0..]);
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
            self.position.set_fen(fen.buffered());
        } else {
            return;
        }

        self.searcher.hash_history.clearRetainingCapacity();
        self.searcher.hash_history.append(self.position.hash) catch {};

        if (!eql(tokens.next() orelse return, "moves")) return;
        while (tokens.next()) |tok| {
            if (self.position.game_ply >= position.MAX_HISTORY_PLY) break;
            const move = types.Move.new_from_string(&self.position, tok);
            if (move.to_u16() == 0) break;
            switch (self.position.turn) {
                .White => self.position.play_move(.White, move),
                .Black => self.position.play_move(.Black, move),
            }
            self.searcher.hash_history.append(self.position.hash) catch {};
        }
    }

    fn start_search(self: *UciInterface, tokens: *Tokens) void {
        const cmd = go.GoCommand.parse(tokens, &self.position);
        const overhead = search.MOVE_OVERHEAD + @min(@as(u64, search.NUM_THREADS) * 5, 25);
        const budget = go.allocate_time(&cmd, self.position.turn, overhead);

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
        @atomicStore(bool, &s.pondering, cmd.ponder, .release);

        const instant_single_reply = budget.managed and !cmd.ponder and !cmd.infinite;
        numa.init();

        @atomicStore(bool, &s.stop, false, .monotonic);
        // Mark searching BEFORE spawning so a second `go` arriving before the
        // worker starts cannot pass the is_searching guard and double-spawn.
        @atomicStore(bool, &s.is_searching, true, .release);

        if (comptime platform.has_threads) {
            self.search_thread = std.Thread.spawn(
                .{ .stack_size = 64 * 1024 * 1024 },
                run_search,
                .{ s, &self.position, cmd.depth, instant_single_reply },
            ) catch |e| std.debug.panic("Could not spawn main thread!\n{}", .{e});
        } else {
            run_search(s, &self.position, cmd.depth, instant_single_reply);
        }
    }
};

fn run_search(searcher: *search.Searcher, pos: *position.Position, max_depth: ?u8, instant_single_reply: bool) void {
    numa.place_current_thread(0);
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
    var storage: [search.MAX_MOVES]types.Move = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&storage));
    var moves = std.array_list.Managed(types.Move).initCapacity(fba.allocator(), storage.len) catch unreachable;
    switch (pos.turn) {
        .White => pos.generate_legal_moves(.White, &moves),
        .Black => pos.generate_legal_moves(.Black, &moves),
    }
    return moves.items.len;
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
