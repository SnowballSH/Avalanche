const std = @import("std");
const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const Search = @import("../search/search.zig");
const Uci = @import("./uci.zig");
const Perft = @import("./perft.zig");
const Encode = @import("../move/encode.zig");
const HCE = @import("../evaluation/hce.zig");
const NNUE = @import("../evaluation/nnue.zig");

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

        _ = try stdout.writeAll("Avalanche 0.2 by SnowballSH\n");

        self.position = Position.new_position_by_fen(Position.STARTPOS);
        defer self.position.deinit();

        out: while (true) {
            // The command will probably be less than 1024 characters
            var line = try stdin.readUntilDelimiterOrEofAlloc(command_arena.allocator(), '\n', 1024);
            if (line == null) {
                break;
            }

            var tokens = std.mem.split(u8, line.?, " ");
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
                _ = try stdout.write("id name Avalanche 0.2\n");
                _ = try stdout.write("id author SnowballSH\n");
                _ = try stdout.writeAll("uciok\n");
            } else if (std.mem.eql(u8, token.?, "isready")) {
                _ = try stdout.writeAll("readyok\n");
            } else if (std.mem.eql(u8, token.?, "d")) {
                self.position.display();
            } else if (std.mem.eql(u8, token.?, "nnue")) {
                var arch = NNUE.NNUE.new();
                arch.re_evaluate(&self.position);
                var bucket = @minimum(@divFloor(self.position.phase() * NNUE.Weights.OUTPUT_SIZE, 24), NNUE.Weights.OUTPUT_SIZE - 1);
                _ = try stdout.writeAll("Bucket | PSQT  | Layer | Final\n");
                for (arch.result) |val, idx| {
                    var score = val;
                    if (self.position.turn == Piece.Color.Black) {
                        score = -score;
                    }

                    var psqt = @divFloor(arch.residual[@enumToInt(self.position.turn)][idx], 64);

                    if (idx == bucket) {
                        _ = try stdout.print("{:<6} | {:<5} | {:<5} | {:<5}  <-- this bucket is used\n", .{ idx, psqt, score - psqt, score });
                    } else {
                        _ = try stdout.print("{:<6} | {:<5} | {:<5} | {:<5}\n", .{ idx, psqt, score - psqt, score });
                    }
                }
            } else if (std.mem.eql(u8, token.?, "eval")) {
                token = tokens.next();
                if (token != null) {
                    var depth = std.fmt.parseUnsigned(u8, token.?, 10) catch 1;
                    depth = std.math.max(depth, 1);
                    self.searcher.max_nano = null;
                    self.searcher.nodes = 0;
                    var score = -self.searcher.negamax(&self.position, -Search.INF, Search.INF, depth);
                    if (self.position.turn == Piece.Color.Black) {
                        score = -score;
                    }

                    try stdout.print("{}\n", .{score});
                } else {
                    try stdout.print("{}\n", .{HCE.evaluate(&self.position)});
                }
            } else if (std.mem.eql(u8, token.?, "perft")) {
                var depth: usize = 1;
                token = tokens.next();
                if (token != null) {
                    depth = std.fmt.parseUnsigned(usize, token.?, 10) catch 1;
                }

                depth = std.math.max(depth, 1);

                _ = Perft.perft_root(&self.position, depth) catch unreachable;
            } else if (std.mem.eql(u8, token.?, "go")) {
                var movetime: ?u64 = 10 * std.time.ns_per_s;
                var max_depth: ?u8 = null;
                while (true) {
                    token = tokens.next();
                    if (token == null) {
                        break;
                    }
                    if (std.mem.eql(u8, token.?, "infinite")) {
                        movetime = 1 << 63;
                    }
                    if (std.mem.eql(u8, token.?, "depth")) {
                        max_depth = std.fmt.parseUnsigned(u8, tokens.next().?, 10) catch null;
                    }
                    if (std.mem.eql(u8, token.?, "movetime")) {
                        token = tokens.next();
                        if (token == null) {
                            break;
                        }

                        movetime = std.fmt.parseUnsigned(u64, token.?, 10) catch 10 * std.time.ms_per_s;
                        movetime.? = std.math.max(movetime.? - 50, 10);
                        movetime.? *= std.time.ns_per_ms;
                    }
                }

                self.searcher.stop = false;

                self.search_thread = std.Thread.spawn(
                    .{},
                    start_search,
                    .{ &self.searcher, &self.position, movetime.?, max_depth },
                ) catch |e| {
                    std.debug.panic("Oh no, error!\n{}", .{e});
                    unreachable;
                };

                self.search_thread.?.detach();
            } else if (std.mem.eql(u8, token.?, "position")) {
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
