const std = @import("std");
const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const Search = @import("../search/search.zig");
const Uci = @import("./uci.zig");
const Perft = @import("./perft.zig");
const Encode = @import("../move/encode.zig");
const HCE = @import("../evaluation/hce.zig");
const NNUE = @import("../evaluation/nnue.zig");
const Final = @import("../evaluation/final.zig");

pub const UciInterface = struct {
    position: Position.Position,
    search_thread: ?std.Thread,
    searcher: Search.Searcher,

    pub fn new() UciInterface {
        return UciInterface{
            .position = Position.new_position_by_fen(Position.STARTPOS),
            .search_thread = null,
            .searcher = Search.Searcher.new_searcher(),
        };
    }

    pub fn main_loop(self: *UciInterface) !void {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();
        var command_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer command_arena.deinit();

        self.searcher = Search.Searcher.new_searcher();

        _ = try stdout.writeAll("Avalanche 0.3a by SnowballSH\n");

        self.position = Position.new_position_by_fen(Position.STARTPOS);
        defer self.position.deinit();

        var arch = NNUE.NNUE.new();

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
            }

            if (self.searcher.is_searching) {
                continue;
            }

            if (std.mem.eql(u8, token.?, "quit")) {
                break :out;
            } else if (std.mem.eql(u8, token.?, "uci")) {
                _ = try stdout.write("id name Avalanche 0.3a\n");
                _ = try stdout.write("id author Yinuo Huang\n\n");
                _ = try stdout.write("option name Hash type spin default 32 min 1 max 4096\n");
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

                        const value = std.fmt.parseUnsigned(usize, token.?, 10) catch Search.TTSizeMB;
                        Search.TTSizeMB = value;
                        Search.init_tt();
                    }

                    break;
                }
            } else if (std.mem.eql(u8, token.?, "ucinewgame")) {
                self.position.deinit();
                self.position = Position.new_position_by_fen(Position.STARTPOS);
                defer self.position.deinit();
                self.searcher = Search.Searcher.new_searcher();
            } else if (std.mem.eql(u8, token.?, "isready")) {
                _ = try stdout.writeAll("readyok\n");
            } else if (std.mem.eql(u8, token.?, "d")) {
                self.position.display();
            } else if (std.mem.eql(u8, token.?, "see")) {
                Perft.see_perft(&self.position);
            } else if (std.mem.eql(u8, token.?, "eval")) {
                arch.re_evaluate(&self.position);
                var score = Final.evaluate(&self.position, &arch, 0);
                var bucket = @minimum(@divFloor(self.position.phase() * NNUE.Weights.OUTPUT_SIZE, 24), NNUE.Weights.OUTPUT_SIZE - 1);
                var nn = arch.result[bucket];
                if (self.position.turn == Piece.Color.Black) {
                    nn = -nn;
                    score = -score;
                }
                var hce = HCE.evaluate(&self.position);

                var tempo: i16 = 0;

                if (self.position.turn == Piece.Color.White) {
                    if (self.position.phase() <= 10) {
                        tempo = Final.TEMPO_EG;
                    } else {
                        tempo = Final.TEMPO_MG;
                    }
                } else {
                    if (self.position.phase() <= 10) {
                        tempo = -Final.TEMPO_EG;
                    } else {
                        tempo = -Final.TEMPO_MG;
                    }
                }

                _ = try stdout.writeAll("HCE  | NNUE | Tempo | Final (White Perspective)\n");
                _ = try stdout.print("{:<4} | {:<4} | {:<5} | {:<5}\n", .{ hce, nn, tempo, score });
            } else if (std.mem.eql(u8, token.?, "nnue")) {
                arch.re_evaluate(&self.position);
                var bucket = @minimum(@divFloor(self.position.phase() * NNUE.Weights.OUTPUT_SIZE, 24), NNUE.Weights.OUTPUT_SIZE - 1);
                _ = try stdout.writeAll("Bucket | PSQT  | Layer | Final (White Perspective)\n");
                for (arch.result) |val, idx| {
                    var score = val;

                    var psqt = @divFloor(arch.residual[@enumToInt(self.position.turn)][idx], 64);
                    if (self.position.turn == Piece.Color.Black) {
                        psqt = -psqt;
                        score = -score;
                    }

                    if (idx == bucket) {
                        _ = try stdout.print("{:<6} | {:<5} | {:<5} | {:<5}  <-- this bucket is used\n", .{ idx, psqt, score - psqt, score });
                    } else {
                        _ = try stdout.print("{:<6} | {:<5} | {:<5} | {:<5}\n", .{ idx, psqt, score - psqt, score });
                    }
                }
            } else if (std.mem.eql(u8, token.?, "nnue_plain")) {
                arch.re_evaluate(&self.position);
                for (arch.result) |val| {
                    var score = val;
                    if (self.position.turn == Piece.Color.Black) {
                        score = -score;
                    }

                    _ = try stdout.print("{}\n", .{score});
                }
            } else if (std.mem.eql(u8, token.?, "hce")) {
                try stdout.print("{}\n", .{HCE.evaluate(&self.position)});
            } else if (std.mem.eql(u8, token.?, "perft")) {
                var depth: usize = 1;
                token = tokens.next();
                if (token != null) {
                    depth = std.fmt.parseUnsigned(usize, token.?, 10) catch 1;
                }

                depth = std.math.max(depth, 1);

                _ = Perft.perft_root(&self.position, depth) catch unreachable;
            } else if (std.mem.eql(u8, token.?, "go")) {
                var movetime: ?u64 = null;
                var max_depth: ?u8 = null;
                var mytime: ?u64 = null;
                var myinc: ?u64 = null;
                var movestogo: ?u64 = null;
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
                        break;
                    }
                    if (std.mem.eql(u8, token.?, "movetime")) {
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        movetime = std.fmt.parseUnsigned(u64, token.?, 10) catch 10 * std.time.ms_per_s;
                        movetime = std.math.max(movetime.? - 10, 10);

                        break;
                    }

                    if (std.mem.eql(u8, token.?, "wtime")) {
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == Piece.Color.White) {
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
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == Piece.Color.Black) {
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
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == Piece.Color.White) {
                            if (movetime == null) {
                                movetime = 0;
                            }
                            myinc = std.fmt.parseUnsigned(u64, token.?, 10) catch 0;
                        }
                    } else if (std.mem.eql(u8, token.?, "binc")) {
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        if (self.position.turn == Piece.Color.Black) {
                            if (movetime == null) {
                                movetime = 0;
                            }
                            myinc = std.fmt.parseUnsigned(u64, token.?, 10) catch 0;
                        }
                    } else if (std.mem.eql(u8, token.?, "movestogo")) {
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
                    if (mytime != null) {
                        if (myinc != null) {
                            if (mytime.? > myinc.? + 500) {
                                movetime.? += myinc.?;
                            }
                        }

                        var t = mytime.?;
                        t = @maximum(t - 100, 100);
                        if (movestogo != null and movestogo.? <= 30 and movestogo.? >= 1) {
                            t /= movestogo.? + 1;
                        } else {
                            var phase = self.position.phase();

                            if (phase >= 21) {
                                // Opening
                                t /= 36;
                            } else if (phase >= 15) {
                                // Middle game
                                t /= 18;
                            } else if (phase >= 6) {
                                // Middle-end game
                                t /= 20;
                            } else {
                                // Endgame
                                t /= 30;
                            }
                        }
                        movetime.? += t;
                    }

                    if (movetime.? > 50) {
                        movetime.? -= 10;
                    } else if (movetime.? > 10) {
                        movetime.? -= 3;
                    } else {
                        movetime = 5;
                    }
                    movetime.? *= std.time.ns_per_ms;
                } else {
                    movetime = 10000 * std.time.ns_per_ms;
                }

                self.searcher.stop = false;

                self.search_thread = std.Thread.spawn(
                    .{ .stack_size = 64 * 1024 * 1024 },
                    start_search,
                    .{ &self.searcher, &self.position, movetime.?, max_depth },
                ) catch |e| {
                    std.debug.panic("Oh no, error!\n{}", .{e});
                    unreachable;
                };

                self.search_thread.?.detach();
            } else if (std.mem.eql(u8, token.?, "position")) {
                self.searcher.hash_history.clearAndFree();
                self.searcher.halfmoves = 0;
                token = tokens.next();
                if (token != null) {
                    self.searcher.halfmoves = 0;

                    if (std.mem.eql(u8, token.?, "startpos")) {
                        self.position.deinit();
                        self.position = Position.new_position_by_fen(Position.STARTPOS);
                        self.searcher.nnue.refresh_accumulator(&self.position);

                        token = tokens.next();
                        if (token != null) {
                            if (std.mem.eql(u8, token.?, "moves")) {
                                while (true) {
                                    token = tokens.next();
                                    if (token == null) {
                                        break;
                                    }

                                    var move = Uci.uci_to_move(token.?, &self.position);

                                    if (move == null) {
                                        std.debug.print("Invalid move!\n", .{});
                                        break;
                                    }

                                    self.position.make_move(move.?, &self.searcher.nnue);
                                    if (Encode.capture(move.?) != 0 or Encode.pt(move.?) % 6 == 0) {
                                        self.searcher.halfmoves = 0;
                                    } else {
                                        self.searcher.halfmoves += 1;
                                    }

                                    self.searcher.hash_history.append(self.position.hash) catch {};
                                    self.searcher.move_history.append(move.?) catch {};
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, token.?, "fen")) {
                        self.position.deinit();
                        tokens = std.mem.split(u8, tokens.rest(), " moves ");
                        var fen = tokens.next();
                        if (fen != null) {
                            self.position = Position.new_position_by_fen(fen.?);
                            self.searcher.nnue.refresh_accumulator(&self.position);

                            var afterfen = tokens.next();
                            if (afterfen != null) {
                                tokens = std.mem.split(u8, afterfen.?, " ");
                                while (true) {
                                    token = tokens.next();
                                    if (token == null) {
                                        break;
                                    }

                                    var move = Uci.uci_to_move(token.?, &self.position);

                                    if (move == null) {
                                        std.debug.print("Invalid move!\n", .{});
                                        break;
                                    }

                                    self.position.make_move(move.?, &self.searcher.nnue);
                                    if (Encode.capture(move.?) != 0 or Encode.pt(move.?) % 6 == 0) {
                                        self.searcher.halfmoves = 0;
                                    } else {
                                        self.searcher.halfmoves += 1;
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

fn start_search(searcher: *Search.Searcher, position: *Position.Position, movetime: usize, max_depth: ?u8) void {
    searcher.iterative_deepening(position, movetime, max_depth);
}
