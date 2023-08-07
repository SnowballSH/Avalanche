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

const MAX_DEPTH: usize = 8;

pub const DatagenSingle = struct {
    data: std.ArrayList(u8),
    searcher: search.Searcher,
    fileLock: *FileLock,
    prng: *utils.PRNG,

    pub fn new(lock: *FileLock, prng: *utils.PRNG) DatagenSingle {
        var searcher = search.Searcher.new();
        searcher.max_millis = 500;
        searcher.ideal_time = 500;
        searcher.silent_output = true;
        return DatagenSingle{
            .data = std.ArrayList(u8).init(std.heap.c_allocator),
            .searcher = searcher,
            .fileLock = lock,
            .prng = prng,
        };
    }

    pub fn deinit(self: *DatagenSingle) void {
        self.data.deinit();
        self.fileLock.file.close();
    }

    pub fn playGame(self: *DatagenSingle) !void {
        var pos_ = position.Position.new();
        var pos = &pos_;
        pos.set_fen(types.DEFAULT_FEN);

        self.searcher.reset_heuristics();
        self.searcher.stop = false;
        self.searcher.force_thinking = false;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var fens = std.ArrayList([]u8).init(arena.allocator());
        var evals = std.ArrayList(hce.Score).init(arena.allocator());
        defer fens.deinit();
        defer evals.deinit();

        var result: f32 = 0.5;
        var draw_count: usize = 0;
        var ply: usize = 0;
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
                break;
            }

            var random_plies: u64 = 4 + (self.prng.rand64() % 7);

            if (ply < @intCast(usize, random_plies)) {
                var move = movelist.items[self.prng.rand64() % move_size];
                if (pos.turn == types.Color.White) {
                    pos.play_move(types.Color.White, move);
                } else {
                    pos.play_move(types.Color.Black, move);
                }
                continue;
            }
            movelist.deinit();

            var res: hce.Score = if (pos.turn == types.Color.White)
                self.searcher.iterative_deepening(pos, types.Color.White, MAX_DEPTH)
            else
                -self.searcher.iterative_deepening(pos, types.Color.Black, MAX_DEPTH);

            var best_move = self.searcher.best_move;

            var fen = pos.basic_fen(arena.allocator());
            var in_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);

            if (pos.turn == types.Color.White) {
                pos.play_move(types.Color.White, best_move);
            } else {
                pos.play_move(types.Color.Black, best_move);
            }

            if (res > 1500) {
                continue;
            }
            if (res < -1500) {
                continue;
            }

            var gave_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);
            if (!in_check and !gave_check and !best_move.is_capture() and !best_move.is_promotion()) {
                // pretty quiet
                try fens.append(fen);
                try evals.append(res);
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
        }

        self.fileLock.lock.lock();
        var writer = self.fileLock.file.writer();
        var i: usize = 0;
        while (i < fens.items.len) : (i += 1) {
            var j: usize = 0;
            while (j < fens.items[i].len) : (j += 1) {
                try writer.writeByte(fens.items[i][j]);
            }
            var s = if (result == 0.0) "0.0" else if (result == 1.0) "1.0" else "0.5";
            try writer.print(" | {} | {s}\n", .{ evals.items[i], s });
        }
        self.fileLock.lock.unlock();
    }

    pub fn startMany(self: *DatagenSingle) !void {
        while (true) {
            try self.playGame();
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
        const file = std.fs.cwd().createFile(
            "data.txt",
            .{ .read = true },
        ) catch {
            std.debug.panic("Unable to open data.txt", .{});
        };
        var lock = std.Thread.Mutex{};
        self.fileLock = FileLock{ .file = file, .lock = lock };
        self.datagens.clearAndFree();

        var threads = std.ArrayList(std.Thread).init(std.heap.c_allocator);
        defer threads.deinit();

        var th: usize = 0;
        while (th < num_threads) : (th += 1) {
            var datagen = DatagenSingle.new(&self.fileLock, &self.prng);
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
};
