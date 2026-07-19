const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const perft = @import("../chess/perft.zig");
const hce = @import("hce.zig");
const nnue = @import("nnue.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");
const parameters = @import("parameters.zig");
const build_options = @import("build_options");
const genfens = @import("genfens.zig");
const syzygy = @import("syzygy.zig");

pub const UciInterface = struct {
    position: position.Position,
    search_thread: ?std.Thread,
    searcher: search.Searcher,

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
    }

    fn join_search(self: *UciInterface) void {
        if (self.search_thread) |t| {
            t.join();
            self.search_thread = null;
        }
        @atomicStore(bool, &self.searcher.is_searching, false, .release);
    }

    pub fn main_loop(self: *UciInterface) !void {
        var in_buf: [1 << 16]u8 = undefined;
        var in_file = std.Io.File.stdin().readerStreaming(types.GLOBAL_IO, &in_buf);
        const stdin = &in_file.interface;
        var out_buf: [1 << 16]u8 = undefined;
        var out_file = std.Io.File.stdout().writerStreaming(types.GLOBAL_IO, &out_buf);
        const stdout = &out_file.interface;

        defer {
            @atomicStore(bool, &self.searcher.stop, true, .monotonic);
            self.join_search();
            self.searcher.deinit();
            search.helper_searchers.deinit();
            search.threads.deinit();
            syzygy.deinit();
        }

        self.position.set_fen(types.DEFAULT_FEN[0..]);

        try stdout.print("Avalanche {s} by Yinuo Huang (SnowballSH)\n", .{build_options.version});
        try stdout.flush();

        out: while (true) {
            // The command will probably be less than 65536 characters
            const line = stdin.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => break,
                error.StreamTooLong => break,
                else => return e,
            };

            const tline = std.mem.trim(u8, line, "\r\n");

            var tokens = std.mem.splitScalar(u8, tline, ' ');
            var token = tokens.next();
            if (token == null) {
                break;
            }

            if (std.mem.eql(u8, token.?, "stop")) {
                @atomicStore(bool, &self.searcher.stop, true, .monotonic);
                self.join_search();
                continue;
            } else if (std.mem.eql(u8, token.?, "isready")) {
                try stdout.writeAll("readyok\n");
                try stdout.flush();
                continue;
            } else if (std.mem.eql(u8, token.?, "quit")) {
                @atomicStore(bool, &self.searcher.stop, true, .monotonic);
                self.join_search();
                break :out;
            }

            if (@atomicLoad(bool, &self.searcher.is_searching, .acquire)) {
                continue;
            }

            if (std.mem.eql(u8, token.?, "genfens")) {
                // OpenBench datagen: tokenize the rest of the line and generate FENs
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                var toks_list = std.array_list.Managed([]const u8).init(arena.allocator());
                toks_list.append("genfens") catch {};
                while (tokens.next()) |tok| {
                    if (tok.len > 0) toks_list.append(tok) catch {};
                }
                genfens.run(toks_list.items) catch {};
                break :out;
            } else if (std.mem.eql(u8, token.?, "uci")) {
                try stdout.writeAll("id name Avalanche ");
                try stdout.writeAll(build_options.version);
                try stdout.writeByte('\n');
                try stdout.writeAll("id author Yinuo Huang\n\n");
                try stdout.writeAll("option name Hash type spin default 16 min 1 max 65536\n");
                try stdout.print("option name Threads type spin default 1 min 1 max {}\n", .{search.MAX_THREADS});
                try stdout.writeAll("option name SyzygyPath type string default <empty>\n");
                try stdout.writeAll("option name SyzygyProbeDepth type spin default 1 min 1 max 100\n");
                try stdout.writeAll("option name SyzygyProbeLimit type spin default 7 min 1 max 7\n");
                try stdout.writeAll("option name Syzygy50MoveRule type check default true\n");
                for (parameters.TunableParams) |tunable| {
                    try stdout.print("option name {s} type spin default {s} min {s} max {s}\n", .{ tunable.name, tunable.value, tunable.min_value, tunable.max_value });
                }
                try stdout.writeAll("uciok\n");
                try stdout.flush();
            } else if (std.mem.eql(u8, token.?, "spsa")) {
                // Print tunables in OpenBench's SPSA input format:
                // name, int, value, min, max, c_end, r_end
                for (parameters.TunableParams) |tunable| {
                    try stdout.print("{s}, int, {s}, {s}, {s}, {s}, {s}\n", .{ tunable.name, tunable.value, tunable.min_value, tunable.max_value, tunable.c_end, tunable.r_end });
                }
                try stdout.flush();
            } else if (std.mem.eql(u8, token.?, "setoption")) {
                while (true) {
                    token = tokens.next();
                    if (token == null or !std.mem.eql(u8, token.?, "name")) {
                        break;
                    }

                    token = tokens.next();
                    if (token == null) {
                        break;
                    }
                    if (std.mem.eql(u8, token.?, "Hash")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }

                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        const value = std.fmt.parseUnsigned(usize, token.?, 10) catch 16;
                        const clamped = std.math.clamp(value, 1, 65536);
                        tt.GlobalTT.reset(clamped);
                    } else if (std.mem.eql(u8, token.?, "Threads")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }

                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        const value = std.fmt.parseUnsigned(usize, token.?, 10) catch 1;
                        const total = std.math.clamp(value, 1, search.MAX_THREADS);
                        search.NUM_THREADS = total - 1;
                    } else if (std.mem.eql(u8, token.?, "SyzygyPath")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }
                        const path = std.mem.trim(u8, tokens.rest(), " ");
                        if (path.len == 0 or std.mem.eql(u8, path, "<empty>")) {
                            syzygy.deinit();
                        } else {
                            const cpath = std.heap.c_allocator.dupeZ(u8, path) catch break;
                            defer std.heap.c_allocator.free(cpath);
                            if (syzygy.init(cpath.ptr)) {
                                try stdout.print("info string Syzygy: loaded tablebases up to {}-men from '{s}'\n", .{ syzygy.max_pieces(), path });
                            } else {
                                try stdout.print("info string Syzygy: failed to load tablebases from '{s}'\n", .{path});
                            }
                            try stdout.flush();
                        }
                    } else if (std.mem.eql(u8, token.?, "SyzygyProbeDepth")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }
                        syzygy.probe_depth = std.fmt.parseInt(i32, token.?, 10) catch 1;
                    } else if (std.mem.eql(u8, token.?, "SyzygyProbeLimit")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }
                        syzygy.probe_limit = std.fmt.parseInt(i32, token.?, 10) catch 7;
                    } else if (std.mem.eql(u8, token.?, "Syzygy50MoveRule")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }
                        syzygy.use_rule50 = std.ascii.eqlIgnoreCase(token.?, "true");
                    } else {
                        for (parameters.TunableParams) |tunable| {
                            if (std.mem.eql(u8, token.?, tunable.name)) {
                                token = tokens.next();
                                if (token == null or !std.mem.eql(u8, token.?, "value")) {
                                    break;
                                }

                                token = tokens.next();
                                if (token == null) {
                                    break;
                                }

                                const raw = std.fmt.parseUnsigned(usize, token.?, 10) catch continue;
                                const min_v = std.fmt.parseUnsigned(usize, tunable.min_value, 10) catch 0;
                                const max_v = std.fmt.parseUnsigned(usize, tunable.max_value, 10) catch raw;
                                const value = std.math.clamp(raw, min_v, max_v);
                                switch (tunable.id) {
                                    0 => {
                                        parameters.LMRWeight = @as(f64, @floatFromInt(value)) / 1000.0;
                                        search.init_lmr();
                                    },
                                    1 => {
                                        parameters.LMRBias = @as(f64, @floatFromInt(value)) / 1000.0;
                                        search.init_lmr();
                                    },
                                    2 => {
                                        parameters.RFPDepth = @as(i32, @intCast(value));
                                    },
                                    3 => {
                                        parameters.RFPMultiplier = @as(i32, @intCast(value));
                                    },
                                    4 => {
                                        parameters.RFPImprovingDeduction = @as(i32, @intCast(value));
                                    },
                                    5 => {
                                        parameters.NMPImprovingMargin = @as(i32, @intCast(value));
                                    },
                                    6 => {
                                        parameters.NMPBase = @as(usize, @intCast(value));
                                    },
                                    7 => {
                                        parameters.NMPDepthDivisor = @as(usize, @intCast(value));
                                    },
                                    8 => {
                                        parameters.NMPBetaDivisor = @as(i32, @intCast(value));
                                    },
                                    9 => {
                                        parameters.RazoringBase = @as(i32, @intCast(value));
                                    },
                                    10 => {
                                        parameters.RazoringMargin = @as(i32, @intCast(value));
                                    },
                                    11 => {
                                        parameters.AspirationWindow = @as(i32, @intCast(value));
                                    },
                                    12 => {
                                        parameters.NodeTmBase = @as(i32, @intCast(value));
                                    },
                                    13 => {
                                        parameters.NodeTmMultiplier = @as(i32, @intCast(value));
                                    },
                                    14 => {
                                        parameters.HistPruningDepth = @as(i32, @intCast(value));
                                    },
                                    15 => {
                                        parameters.HistPruningMargin = @as(i32, @intCast(value));
                                    },
                                    16 => {
                                        parameters.FPDepth = @as(i32, @intCast(value));
                                    },
                                    17 => {
                                        parameters.FPBase = @as(i32, @intCast(value));
                                    },
                                    18 => {
                                        parameters.FPMargin = @as(i32, @intCast(value));
                                    },
                                    19 => {
                                        parameters.SEEPruningDepth = @as(i32, @intCast(value));
                                    },
                                    20 => {
                                        parameters.SEEQuietMargin = @as(i32, @intCast(value));
                                    },
                                    21 => {
                                        parameters.SEENoisyMargin = @as(i32, @intCast(value));
                                    },
                                    22 => {
                                        parameters.LMRCutnode = @as(i32, @intCast(value));
                                    },
                                    23 => {
                                        parameters.SEDoubleMargin = @as(i32, @intCast(value));
                                    },
                                    24 => {
                                        parameters.SETripleMargin = @as(i32, @intCast(value));
                                    },
                                    25 => {
                                        parameters.ProbCutMargin = @as(i32, @intCast(value));
                                    },
                                    26 => {
                                        parameters.ProbCutDepth = value;
                                    },
                                    27 => {
                                        parameters.ProbCutReduction = value;
                                    },
                                    else => unreachable,
                                }
                                // std.debug.print("info string {s} set to {d}\n", .{ tunable.name, value });
                                break;
                            }
                        }
                    }

                    break;
                }
            } else if (std.mem.eql(u8, token.?, "ucinewgame")) {
                @atomicStore(bool, &self.searcher.stop, true, .monotonic);
                self.join_search();
                self.searcher.deinit();
                self.searcher = search.Searcher.new();
                tt.GlobalTT.clear();
                self.position.set_fen(types.DEFAULT_FEN[0..]);
            } else if (std.mem.eql(u8, token.?, "d")) {
                self.position.debug_print();
            } else if (std.mem.eql(u8, token.?, "perft")) {
                var depth: u32 = 1;
                token = tokens.next();
                if (token != null) {
                    depth = std.fmt.parseUnsigned(u32, token.?, 10) catch 1;
                }

                depth = @max(depth, 1);

                _ = perft.perft_test(&self.position, depth);
            } else if (std.mem.eql(u8, token.?, "perftdiv")) {
                var depth: u32 = 1;
                token = tokens.next();
                if (token != null) {
                    depth = std.fmt.parseUnsigned(u32, token.?, 10) catch 1;
                }

                depth = @max(depth, 1);

                if (self.position.turn == types.Color.White) {
                    perft.perft_div(types.Color.White, &self.position, depth);
                } else {
                    perft.perft_div(types.Color.Black, &self.position, depth);
                }
            } else if (std.mem.eql(u8, token.?, "go")) {
                var movetime: ?u64 = null;
                var max_depth: ?u8 = null;
                var mytime: ?u64 = null;
                var myinc: ?u64 = null;
                var movestogo: ?u64 = null;
                self.searcher.force_thinking = true;
                self.searcher.max_nodes = null;
                self.searcher.soft_max_nodes = null;
                while (true) {
                    token = tokens.next();
                    if (token == null) {
                        break;
                    }
                    if (std.mem.eql(u8, token.?, "infinite")) {
                        movetime = 1 << 63;
                        movetime.? /= std.time.ns_per_ms;
                        self.searcher.force_thinking = true;
                        break;
                    }
                    if (std.mem.eql(u8, token.?, "depth")) {
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }
                        max_depth = std.fmt.parseUnsigned(u8, token.?, 10) catch null;
                        movetime = 1 << 60;
                        self.searcher.ideal_time = movetime.?;
                        self.searcher.force_thinking = true;
                        break;
                    }
                    if (std.mem.eql(u8, token.?, "movetime")) {
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        movetime = std.fmt.parseUnsigned(u64, token.?, 10) catch 10 * std.time.ms_per_s;
                        self.searcher.ideal_time = 1 << 60;
                        self.searcher.force_thinking = false;

                        break;
                    }
                    if (std.mem.eql(u8, token.?, "nodes")) {
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        self.searcher.max_nodes = std.fmt.parseUnsigned(u64, token.?, 10) catch null;
                        self.searcher.soft_max_nodes = self.searcher.max_nodes;

                        break;
                    }
                    if (std.mem.eql(u8, token.?, "wtime")) {
                        self.searcher.force_thinking = false;
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == types.Color.White) {
                            if (movetime == null) {
                                movetime = 0;
                            }

                            var mt = std.fmt.parseInt(i64, token.?, 10) catch 0;
                            if (mt <= 0) {
                                mt = 1;
                            }
                            const t = @as(u64, @intCast(mt));

                            mytime = t;
                        }
                    } else if (std.mem.eql(u8, token.?, "btime")) {
                        self.searcher.force_thinking = false;
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == types.Color.Black) {
                            if (movetime == null) {
                                movetime = 0;
                            }

                            var mt = std.fmt.parseInt(i64, token.?, 10) catch 0;
                            if (mt <= 0) {
                                mt = 1;
                            }
                            const t = @as(u64, @intCast(mt));

                            mytime = t;
                        }
                    } else if (std.mem.eql(u8, token.?, "winc")) {
                        self.searcher.force_thinking = false;
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == types.Color.White) {
                            if (movetime == null) {
                                movetime = 0;
                            }
                            myinc = std.fmt.parseUnsigned(u64, token.?, 10) catch 0;
                        }
                    } else if (std.mem.eql(u8, token.?, "binc")) {
                        self.searcher.force_thinking = false;
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == types.Color.Black) {
                            if (movetime == null) {
                                movetime = 0;
                            }
                            myinc = std.fmt.parseUnsigned(u64, token.?, 10) catch 0;
                        }
                    } else if (std.mem.eql(u8, token.?, "movestogo")) {
                        self.searcher.force_thinking = false;
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }
                        movestogo = std.fmt.parseUnsigned(u64, token.?, 10) catch 0;
                        if (movestogo != null and movestogo.? == 0) {
                            movestogo = null;
                        }
                    }
                }

                if (movetime != null) {
                    const overhead: u64 = 25 + @min(@as(u64, search.NUM_THREADS) * 5, 25);
                    if (mytime != null) {
                        var inc: u64 = 0;
                        if (myinc != null) {
                            inc = myinc.?;
                        }

                        if (mytime.? <= overhead) {
                            const budget = @max(@as(u64, 1), mytime.?);
                            self.searcher.ideal_time = budget;
                            movetime = budget;
                        } else {
                            if (movestogo == null) {
                                self.searcher.ideal_time = inc + (mytime.? - overhead) / 28;
                                movetime = 2 * inc + (mytime.? - overhead) / 16;
                            } else {
                                self.searcher.ideal_time = inc + (2 * (mytime.? - overhead)) / (2 * movestogo.? + 1);
                                movetime = 2 * self.searcher.ideal_time;
                                movetime = @min(movetime.?, mytime.? - @min(mytime.? - overhead, overhead * @as(u64, @min(movestogo.?, 5))));
                            }
                            self.searcher.ideal_time = @min(self.searcher.ideal_time, mytime.? - overhead);
                            movetime = @min(movetime.?, mytime.? - overhead);
                        }
                    }
                } else {
                    movetime = 1000000;
                }

                // Reap any finished search thread before starting a new one.
                self.join_search();
                @atomicStore(bool, &self.searcher.stop, false, .monotonic);
                // Mark searching BEFORE spawning so a second `go` arriving before
                // the worker starts cannot pass the is_searching guard and
                // double-spawn onto the same searcher/position.
                @atomicStore(bool, &self.searcher.is_searching, true, .release);

                self.search_thread = std.Thread.spawn(
                    .{ .stack_size = 64 * 1024 * 1024 },
                    startSearch,
                    .{ &self.searcher, &self.position, movetime.?, max_depth },
                ) catch |e| {
                    std.debug.panic("Could not spawn main thread!\n{}", .{e});
                    unreachable;
                };
            } else if (std.mem.eql(u8, token.?, "position")) {
                token = tokens.next();
                if (token != null) {
                    if (std.mem.eql(u8, token.?, "startpos")) {
                        self.position.set_fen(types.DEFAULT_FEN[0..]);
                        self.searcher.hash_history.clearRetainingCapacity();
                        self.searcher.hash_history.append(self.position.hash) catch {};

                        token = tokens.next();
                        if (token != null) {
                            if (std.mem.eql(u8, token.?, "moves")) {
                                while (true) {
                                    token = tokens.next();
                                    if (token == null) {
                                        break;
                                    }
                                    if (self.position.game_ply >= position.MAX_HISTORY_PLY) break;

                                    const move = types.Move.new_from_string(&self.position, token.?);
                                    if (move.to_u16() == 0) {
                                        break;
                                    }

                                    if (self.position.turn == types.Color.White) {
                                        self.position.play_move(types.Color.White, move);
                                    } else {
                                        self.position.play_move(types.Color.Black, move);
                                    }

                                    self.searcher.hash_history.append(self.position.hash) catch {};
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, token.?, "fen")) {
                        var fen_tokens = std.mem.splitSequence(u8, tokens.rest(), " moves ");
                        const fen = fen_tokens.next();
                        if (fen != null) {
                            self.position.set_fen(fen.?);
                            self.searcher.hash_history.clearRetainingCapacity();
                            self.searcher.hash_history.append(self.position.hash) catch {};

                            const afterfen = fen_tokens.next();
                            if (afterfen != null) {
                                tokens = std.mem.splitScalar(u8, afterfen.?, ' ');
                                while (true) {
                                    token = tokens.next();
                                    if (token == null) {
                                        break;
                                    }
                                    if (self.position.game_ply >= position.MAX_HISTORY_PLY) break;

                                    const move = types.Move.new_from_string(&self.position, token.?);
                                    if (move.to_u16() == 0) {
                                        break;
                                    }

                                    if (self.position.turn == types.Color.White) {
                                        self.position.play_move(types.Color.White, move);
                                    } else {
                                        self.position.play_move(types.Color.Black, move);
                                    }

                                    self.searcher.hash_history.append(self.position.hash) catch {};
                                }
                            }
                        }
                    }
                }
            }
        }
    }
};

fn startSearch(searcher: *search.Searcher, pos: *position.Position, movetime: usize, max_depth: ?u8) void {
    searcher.max_millis = movetime;
    var depth = max_depth;

    var movelist = std.array_list.Managed(types.Move).initCapacity(std.heap.c_allocator, 32) catch unreachable;
    if (pos.turn == types.Color.White) {
        pos.generate_legal_moves(types.Color.White, &movelist);
    } else {
        pos.generate_legal_moves(types.Color.Black, &movelist);
    }
    const move_size = movelist.items.len;
    if (move_size == 1 and !searcher.force_thinking) {
        depth = 1;
    }
    movelist.deinit();

    if (pos.turn == types.Color.White) {
        _ = searcher.iterative_deepening(pos, types.Color.White, depth);
    } else {
        _ = searcher.iterative_deepening(pos, types.Color.Black, depth);
    }
}
