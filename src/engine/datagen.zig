const std = @import("std");
const types = @import("../chess/types.zig");
const utils = @import("../chess/utils.zig");
const hce = @import("hce.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");

pub const FileLock = struct {
    file: std.fs.File,
    lock: std.Thread.Mutex,
};

const MAX_DEPTH: ?u8 = null;
const MAX_NODES: ?u64 = 70000;
const SOFT_MAX_NODES: ?u64 = 6000;

pub const DatagenSingle = struct {
    id: u64,
    timer: std.time.Timer,
    count: u64,
    searcher: search.Searcher,
    fileLock: *FileLock,
    prng: *utils.PRNG,

    pub fn new(lock: *FileLock, prng: *utils.PRNG, id: u64) DatagenSingle {
        var searcher = search.Searcher.new();
        searcher.max_millis = 1000;
        searcher.ideal_time = 500;
        searcher.max_nodes = MAX_NODES;
        searcher.soft_max_nodes = SOFT_MAX_NODES;
        searcher.silent_output = true;
        return DatagenSingle{
            .id = id,
            .timer = undefined,
            .count = 0,
            .searcher = searcher,
            .fileLock = lock,
            .prng = prng,
        };
    }

    pub fn deinit(self: *DatagenSingle) void {
        self.fileLock.file.close();
    }

    pub fn playGame(self: *DatagenSingle) !void {
        self.searcher.root_board = position.Position.new();
        var pos = &self.searcher.root_board;
        pos.set_fen(types.DEFAULT_FEN);

        self.searcher.reset_heuristics();
        self.searcher.stop = false;
        self.searcher.force_thinking = false;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var fens = try std.ArrayList([]u8).initCapacity(arena.allocator(), 128);
        var evals = try std.ArrayList(hce.Score).initCapacity(arena.allocator(), 128);
        defer fens.deinit();
        defer evals.deinit();

        var result: f32 = 0.5;
        var draw_count: usize = 0;
        var white_win_count: usize = 0;
        var black_win_count: usize = 0;
        var ply: usize = 0;
        var random_plies: u64 = 4 + (self.prng.rand64() % 7);
        while (true) : (ply += 1) {
            if (self.searcher.is_draw(pos)) {
                result = 0.5;
                break;
            }
            var movelist = try std.ArrayList(types.Move).initCapacity(arena.allocator(), 32);
            if (pos.turn == types.Color.White) {
                pos.generate_legal_moves(types.Color.White, &movelist);
            } else {
                pos.generate_legal_moves(types.Color.Black, &movelist);
            }
            var move_size = movelist.items.len;
            if (move_size == 0) {
                if (pos.turn == types.Color.White) {
                    if (pos.in_check(types.Color.White)) {
                        result = 0.0;
                    } else {
                        result = 0.5;
                    }
                } else {
                    if (pos.in_check(types.Color.Black)) {
                        result = 1.0;
                    } else {
                        result = 0.5;
                    }
                }
                movelist.deinit();
                break;
            }

            if (ply < random_plies) {
                var move = movelist.items[self.prng.rand64() % move_size];
                if (pos.turn == types.Color.White) {
                    pos.play_move(types.Color.White, move);
                } else {
                    pos.play_move(types.Color.Black, move);
                }
                movelist.deinit();
                continue;
            }
            movelist.deinit();

            var res: hce.Score = if (pos.turn == types.Color.White)
                self.searcher.iterative_deepening(pos, types.Color.White, MAX_DEPTH)
            else
                -self.searcher.iterative_deepening(pos, types.Color.Black, MAX_DEPTH);

            if (ply == random_plies and (res > 1000 or res < -1000)) {
                break;
            }

            var best_move = self.searcher.best_move;

            var fen = pos.basic_fen(arena.allocator());
            var in_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);

            if (pos.turn == types.Color.White) {
                pos.play_move(types.Color.White, best_move);
            } else {
                pos.play_move(types.Color.Black, best_move);
            }

            const limit: i32 = if (pos.phase() >= 6) 750 else 450;

            if (res > limit) {
                white_win_count += 1;

                if (white_win_count >= 8) {
                    result = 1.0;
                    break;
                }
            } else {
                white_win_count = 0;
            }

            if (res < -limit) {
                black_win_count += 1;

                if (black_win_count >= 8) {
                    result = 0.0;
                    break;
                }
            } else {
                black_win_count = 0;
            }

            if (ply >= 40 and -1 < res and res < 1) {
                draw_count += 1;
                if (draw_count >= 10) {
                    result = 0.5;
                    break;
                }
            } else {
                draw_count = 0;
            }

            if (res > 2000 or res < -2000) {
                continue;
            }

            var gave_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);
            if (!in_check and !gave_check and !best_move.is_capture() and !best_move.is_promotion()) {
                // pretty quiet
                try fens.append(fen);
                try evals.append(res);
            }
        }

        if (fens.items.len == 0) {
            return;
        }

        self.fileLock.lock.lock();
        var writer = self.fileLock.file.writer();
        var i: usize = 0;
        while (i < fens.items.len) : (i += 1) {
            try writer.print("{s}", .{fens.items[i]});
            var s = if (result == 0.0) "0.0" else if (result == 1.0) "1.0" else "0.5";
            try writer.print(" | {} | {s}\n", .{ evals.items[i], s });
        }
        self.count += fens.items.len;
        self.fileLock.lock.unlock();
    }

    pub fn startMany(self: *DatagenSingle) !void {
        self.timer = try std.time.Timer.start();
        var game_count: usize = 0;
        while (true) {
            try self.playGame();
            game_count += 1;
            if (game_count % 50 == 0) {
                var elapsed = @intToFloat(f64, self.timer.read()) / std.time.ns_per_s;
                var pps = @intToFloat(f64, self.count) / elapsed;
                var gps = @intToFloat(f64, game_count) / elapsed;

                std.debug.print("id {}: {} games, {} pos, {d:.4} pos/s, {d:.4} games/s\n", .{ self.id, game_count, self.count, pps, gps });
            }
        }
    }
};

pub const Datagen = struct {
    fileLock: FileLock,
    prng: utils.PRNG,
    datagens: std.ArrayList(DatagenSingle),

    pub fn new() Datagen {
        var prng = std.rand.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            break :blk seed;
        });
        const rand = prng.random();
        return Datagen{
            .fileLock = undefined,
            .prng = utils.PRNG.new(rand.int(u128)),
            .datagens = std.ArrayList(DatagenSingle).init(std.heap.c_allocator),
        };
    }

    pub fn deinit(self: *Datagen) void {
        var i: usize = 0;
        while (i < self.datagens.items.len) : (i += 1) {
            self.datagens.items[i].deinit();
        }
        self.datagens.deinit();
    }

    pub fn start(self: *Datagen, num_threads: usize) !void {
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "data_{}.txt", .{std.time.timestamp()});
        const file = std.fs.cwd().createFile(
            path,
            .{ .read = true },
        ) catch {
            std.debug.panic("Unable to open {s}", .{path});
        };
        var lock = std.Thread.Mutex{};
        self.fileLock = FileLock{ .file = file, .lock = lock };
        self.datagens.clearAndFree();

        var threads = std.ArrayList(std.Thread).init(std.heap.c_allocator);
        defer threads.deinit();

        var th: usize = 0;
        while (th < num_threads) : (th += 1) {
            var datagen = DatagenSingle.new(&self.fileLock, &self.prng, th);
            try self.datagens.append(datagen);
            var thread = std.Thread.spawn(
                .{ .stack_size = 64 * 1024 * 1024 },
                DatagenSingle.startMany,
                .{&self.datagens.items[th]},
            ) catch |e| {
                std.debug.panic("Could not spawn thread!\n{}", .{e});
                unreachable;
            };
            try threads.append(thread);
        }

        for (threads.items) |thread| {
            thread.join();
        }
    }

    pub fn startSingleThreaded(self: *Datagen) !void {
        var id: u64 = @intCast(u64, std.time.timestamp()) ^ (self.prng.rand64() >> 40);
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "data_{}.txt", .{id});
        const file = std.fs.cwd().createFile(
            path,
            .{ .read = true },
        ) catch {
            std.debug.panic("Unable to open {s}", .{path});
        };
        var lock = std.Thread.Mutex{};
        self.fileLock = FileLock{ .file = file, .lock = lock };
        self.datagens.clearAndFree();

        var datagen = DatagenSingle.new(&self.fileLock, &self.prng, id);
        try datagen.startMany();
    }
};
