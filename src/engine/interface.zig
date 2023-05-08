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

pub const UciInterface = struct {
    position: position.Position,
    search_thread: ?std.Thread,
    searcher: search.Searcher,

    pub fn new() UciInterface {
        var p = position.Position.new();
        p.set_fen(types.DEFAULT_FEN[0..]);
        return UciInterface{
            .position = p,
            .search_thread = null,
            .searcher = search.Searcher.new(),
        };
    }

    pub fn main_loop(self: *UciInterface) !void {
        var stdin = std.io.getStdIn().reader();
        var stdout = std.io.getStdOut().writer();
        var command_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer command_arena.deinit();

        self.searcher = search.Searcher.new();

        self.position.set_fen(types.DEFAULT_FEN[0..]);

        try stdout.print("Avalanche {s} by Yinuo Huang (SnowballSH)\n", .{build_options.version});
        try stdout.print("Using NNUE {s}, architecture {}x{}x{}\n", .{ build_options.nnue, build_options.INPUT_SIZE, build_options.HIDDEN_SIZE, build_options.OUTPUT_SIZE });

        out: while (true) {
            // The command will probably be less than 8192 characters
            var line = try stdin.readUntilDelimiterOrEofAlloc(command_arena.allocator(), '\n', 8192);
            if (line == null) {
                break;
            }

            const tline = std.mem.trim(u8, line.?, "\r");

            var tokens = std.mem.split(u8, tline, " ");
            var token = tokens.next();
            if (token == null) {
                break;
            }

            if (std.mem.eql(u8, token.?, "stop")) {
                self.searcher.stop = true;
                self.searcher.is_searching = false;
                continue;
            } else if (std.mem.eql(u8, token.?, "isready")) {
                _ = try stdout.writeAll("readyok\n");
                continue;
            }

            if (self.searcher.is_searching) {
                continue;
            }

            if (std.mem.eql(u8, token.?, "quit")) {
                break :out;
            } else if (std.mem.eql(u8, token.?, "uci")) {
                _ = try stdout.write("id name Avalanche ");
                _ = try stdout.write(build_options.version);
                _ = try stdout.writeByte('\n');
                _ = try stdout.write("id author Yinuo Huang\n\n");
                _ = try stdout.write("option name Hash type spin default 16 min 1 max 4096\n");
                _ = try stdout.write("option name AspirationWindow type spin default 15 min 0 max 64\n");
                _ = try stdout.write("option name LMRWeight type spin default 600 min 1 max 999\n");
                _ = try stdout.write("option name LMRBias type spin default 1300 min 100 max 3000\n");
                _ = try stdout.writeAll("uciok\n");
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
                        tt.GlobalTT.reset(value);
                    } else if (std.mem.eql(u8, token.?, "AspirationWindow")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }

                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        const value = std.fmt.parseUnsigned(i32, token.?, 10) catch parameters.AspirationWindow;
                        parameters.AspirationWindow = value;
                    } else if (std.mem.eql(u8, token.?, "LMRWeight")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }

                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        const value = std.fmt.parseFloat(f64, token.?) catch parameters.LMRWeight;
                        parameters.LMRWeight = value / 1000.0;
                        search.init_lmr();
                    } else if (std.mem.eql(u8, token.?, "LMRBias")) {
                        token = tokens.next();
                        if (token == null or !std.mem.eql(u8, token.?, "value")) {
                            break;
                        }

                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        const value = std.fmt.parseFloat(f64, token.?) catch parameters.LMRBias;
                        parameters.LMRBias = value / 1000.0;
                        search.init_lmr();
                    }

                    break;
                }
            } else if (std.mem.eql(u8, token.?, "ucinewgame")) {
                self.searcher = search.Searcher.new();
                tt.GlobalTT.clear();
                self.position.set_fen(types.DEFAULT_FEN[0..]);
            } else if (std.mem.eql(u8, token.?, "d")) {
                self.position.debug_print();
            } else if (std.mem.eql(u8, token.?, "export_net")) {
                token = tokens.next();
                if (token != null) {
                    const file = std.fs.cwd().createFile(
                        token.?,
                        .{ .read = true },
                    ) catch {
                        std.debug.panic("Unable to open {s}", .{token.?});
                    };
                    defer file.close();

                    var writer = file.writer();
                    writer.writeByte('[') catch {};
                    std.json.stringify(nnue.weights.LAYER_1, std.json.StringifyOptions{}, writer) catch {};
                    writer.writeByte(',') catch {};
                    std.json.stringify(nnue.weights.BIAS_1, std.json.StringifyOptions{}, writer) catch {};
                    writer.writeByte(',') catch {};
                    std.json.stringify(nnue.weights.LAYER_2, std.json.StringifyOptions{}, writer) catch {};
                    writer.writeByte(',') catch {};
                    std.json.stringify(nnue.weights.BIAS_2, std.json.StringifyOptions{}, writer) catch {};
                    writer.writeByte(',') catch {};
                    std.json.stringify(nnue.weights.PSQT, std.json.StringifyOptions{}, writer) catch {};
                    writer.writeByte(']') catch {};

                    stdout.print("Done. Exported to {s}.\n", .{token.?}) catch {};
                }
            } else if (std.mem.eql(u8, token.?, "perft")) {
                var depth: u32 = 1;
                token = tokens.next();
                if (token != null) {
                    depth = std.fmt.parseUnsigned(u32, token.?, 10) catch 1;
                }

                depth = std.math.max(depth, 1);

                _ = perft.perft_test(&self.position, depth);
            } else if (std.mem.eql(u8, token.?, "perftdiv")) {
                var depth: u32 = 1;
                token = tokens.next();
                if (token != null) {
                    depth = std.fmt.parseUnsigned(u32, token.?, 10) catch 1;
                }

                depth = std.math.max(depth, 1);

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
                while (true) {
                    token = tokens.next();
                    if (token == null) {
                        break;
                    }
                    if (std.mem.eql(u8, token.?, "infinite")) {
                        movetime = 1 << 63;
                        movetime.? /= std.time.ns_per_ms;
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
                        movetime = std.math.max(movetime.? - 10, 10);
                        self.searcher.ideal_time = movetime.?;
                        self.searcher.force_thinking = true;

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
                            var t = @intCast(u64, mt);

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
                            var t = @intCast(u64, mt);

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
                    const overhead = 25;
                    if (mytime != null) {
                        var inc: u64 = 0;
                        if (myinc != null) {
                            inc = myinc.?;
                        }

                        if (mytime.? <= overhead) {
                            self.searcher.ideal_time = overhead - 5;
                            movetime = overhead - 5;
                        } else {
                            if (movestogo == null) {
                                self.searcher.ideal_time = inc + (mytime.? - overhead) / 28;
                                movetime = 2 * inc + (mytime.? - overhead) / 16;
                            } else {
                                self.searcher.ideal_time = inc + (2 * (mytime.? - overhead)) / (2 * movestogo.? + 1);
                                movetime = 2 * self.searcher.ideal_time;
                                movetime = @min(movetime.?, mytime.? - @min(mytime.? - overhead, overhead * @min(movestogo.?, 5)));
                            }
                            self.searcher.ideal_time = @min(self.searcher.ideal_time, mytime.? - overhead);
                            movetime = @min(movetime.?, mytime.? - overhead);
                        }
                    }
                } else {
                    movetime = 1000000;
                }

                self.searcher.stop = false;

                self.search_thread = std.Thread.spawn(
                    .{ .stack_size = 64 * 1024 * 1024 },
                    startSearch,
                    .{ &self.searcher, &self.position, movetime.?, max_depth },
                ) catch |e| {
                    std.debug.panic("Oh no, error on thread spawn!\n{}", .{e});
                    unreachable;
                };
                self.search_thread.?.detach();
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

                                    var move = types.Move.new_from_string(&self.position, token.?);

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
                        tokens = std.mem.split(u8, tokens.rest(), " moves ");
                        var fen = tokens.next();
                        if (fen != null) {
                            self.position.set_fen(fen.?);
                            self.searcher.hash_history.clearRetainingCapacity();
                            self.searcher.hash_history.append(self.position.hash) catch {};

                            var afterfen = tokens.next();
                            if (afterfen != null) {
                                tokens = std.mem.split(u8, afterfen.?, " ");
                                while (true) {
                                    token = tokens.next();
                                    if (token == null) {
                                        break;
                                    }

                                    var move = types.Move.new_from_string(&self.position, token.?);

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

            command_arena.allocator().free(line.?);
        }
    }
};

fn startSearch(searcher: *search.Searcher, pos: *position.Position, movetime: usize, max_depth: ?u8) void {
    searcher.max_millis = movetime;
    var depth = max_depth;

    var movelist = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 32) catch unreachable;
    if (pos.turn == types.Color.White) {
        pos.generate_legal_moves(types.Color.White, &movelist);
    } else {
        pos.generate_legal_moves(types.Color.Black, &movelist);
    }
    var move_size = movelist.items.len;
    if (move_size == 1) {
        depth = 1;
    }
    movelist.deinit();

    if (pos.turn == types.Color.White) {
        _ = searcher.iterative_deepening(pos, types.Color.White, depth);
    } else {
        _ = searcher.iterative_deepening(pos, types.Color.Black, depth);
    }
}
