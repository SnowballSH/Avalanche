const std = @import("std");
const types = @import("../chess/types.zig");
const utils = @import("../chess/utils.zig");
const hce = @import("hce.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");
const tt = @import("tt.zig");

pub const FileLock = struct {
    file: std.Io.File,
    lock: std.Io.Mutex,
};

const MAX_DEPTH: ?u8 = 9;
const MAX_NODES: ?u64 = null;
const SOFT_MAX_NODES: ?u64 = null;

// Binary bulletformat ChessBoard record (32 bytes, matches bulletformat crate's repr(C) layout).
// All fields are stored relative to the side-to-move (STM).
const ChessBoard = extern struct {
    occ: u64,
    pcs: [16]u8,
    score: i16,
    result: u8,
    ksq: u8,
    opp_ksq: u8,
    extra: [3]u8,
};

comptime {
    if (@sizeOf(ChessBoard) != 32) @compileError("ChessBoard must be 32 bytes");
}

// Intermediate record before game result is known
const PendingRecord = struct {
    board: ChessBoard,
    white_was_stm: bool,
};

fn pos_to_chessboard(pos: *position.Position, white_relative_score: i32) PendingRecord {
    const stm = pos.turn;

    const w_pawn = pos.piece_bitboards[types.Piece.WHITE_PAWN.index()];
    const w_knight = pos.piece_bitboards[types.Piece.WHITE_KNIGHT.index()];
    const w_bishop = pos.piece_bitboards[types.Piece.WHITE_BISHOP.index()];
    const w_rook = pos.piece_bitboards[types.Piece.WHITE_ROOK.index()];
    const w_queen = pos.piece_bitboards[types.Piece.WHITE_QUEEN.index()];
    const w_king = pos.piece_bitboards[types.Piece.WHITE_KING.index()];
    const b_pawn = pos.piece_bitboards[types.Piece.BLACK_PAWN.index()];
    const b_knight = pos.piece_bitboards[types.Piece.BLACK_KNIGHT.index()];
    const b_bishop = pos.piece_bitboards[types.Piece.BLACK_BISHOP.index()];
    const b_rook = pos.piece_bitboards[types.Piece.BLACK_ROOK.index()];
    const b_queen = pos.piece_bitboards[types.Piece.BLACK_QUEEN.index()];
    const b_king = pos.piece_bitboards[types.Piece.BLACK_KING.index()];

    var white_occ = w_pawn | w_knight | w_bishop | w_rook | w_queen | w_king;
    var black_occ = b_pawn | b_knight | b_bishop | b_rook | b_queen | b_king;

    // Piece-type bitboards (0=Pawn, 1=Knight, 2=Bishop, 3=Rook, 4=Queen, 5=King)
    var piece_bbs: [6]u64 = .{
        w_pawn | b_pawn,
        w_knight | b_knight,
        w_bishop | b_bishop,
        w_rook | b_rook,
        w_queen | b_queen,
        w_king | b_king,
    };

    // If black to move, flip board vertically to make STM's back rank = rank 1
    if (stm == types.Color.Black) {
        white_occ = @byteSwap(white_occ);
        black_occ = @byteSwap(black_occ);
        for (&piece_bbs) |*bb| {
            bb.* = @byteSwap(bb.*);
        }
    }

    // friendly = STM's pieces, enemy = opponent's pieces
    const friendly_occ = if (stm == types.Color.White) white_occ else black_occ;
    const enemy_occ = if (stm == types.Color.White) black_occ else white_occ;
    const occ = friendly_occ | enemy_occ;

    // Pack pieces ordered by set bits in occ (LSB first)
    var pcs: [16]u8 = .{0} ** 16;
    var idx: usize = 0;
    var occ_iter = occ;
    while (occ_iter != 0) {
        const sq_bit = occ_iter & (~occ_iter +% 1);
        occ_iter &= occ_iter - 1;

        const color_bits: u8 = if ((sq_bit & enemy_occ) != 0) 8 else 0;

        var piece_type: u8 = 0;
        for (piece_bbs, 0..) |bb, pt| {
            if ((sq_bit & bb) != 0) {
                piece_type = @as(u8, @intCast(pt));
                break;
            }
        }

        const nibble = color_bits | piece_type;
        pcs[idx / 2] |= nibble << @as(u3, @intCast(4 * (idx & 1)));
        idx += 1;
    }

    // King squares in STM-relative coordinates
    const our_king_sq: u8 = blk: {
        const kb = if (stm == types.Color.White) w_king else @byteSwap(b_king);
        break :blk @as(u8, @intCast(@ctz(kb)));
    };
    const opp_king_sq: u8 = blk: {
        const kb = if (stm == types.Color.White) b_king else @byteSwap(w_king);
        break :blk @as(u8, @intCast(@ctz(kb))) ^ 56;
    };

    // Score: convert to STM-relative
    const clamped = std.math.clamp(white_relative_score, -32000, 32000);
    const score: i16 = if (stm == types.Color.White)
        @as(i16, @intCast(clamped))
    else
        @as(i16, @intCast(-clamped));

    return PendingRecord{
        .board = ChessBoard{
            .occ = occ,
            .pcs = pcs,
            .score = score,
            .result = 0, // filled in at game end
            .ksq = our_king_sq,
            .opp_ksq = opp_king_sq,
            .extra = .{ 0, 0, 0 },
        },
        .white_was_stm = (stm == types.Color.White),
    };
}

pub const DatagenSingle = struct {
    id: u64,
    timer: types.Timer,
    count: u64,
    searcher: search.Searcher,
    fileLock: *FileLock,
    prng: utils.PRNG,
    openings: ?[]const []const u8,

    pub fn new(lock: *FileLock, seed: u128, id: u64, openings: ?[]const []const u8) DatagenSingle {
        var searcher = search.Searcher.new();
        searcher.max_millis = 1000;
        searcher.ideal_time = 500;
        searcher.max_nodes = MAX_NODES;
        searcher.soft_max_nodes = SOFT_MAX_NODES;
        searcher.min_depth = 2;
        searcher.silent_output = true;
        return DatagenSingle{
            .id = id,
            .timer = undefined,
            .count = 0,
            .searcher = searcher,
            .fileLock = lock,
            .prng = utils.PRNG.new(seed),
            .openings = openings,
        };
    }

    pub fn deinit(self: *DatagenSingle) void {
        self.searcher.deinit();
    }

    pub fn playGame(self: *DatagenSingle) !void {
        self.searcher.root_board = position.Position.new();
        var pos = &self.searcher.root_board;

        // Set starting position: EPD book line or default startpos
        const using_book = self.openings != null;
        if (self.openings) |book| {
            const line = book[self.prng.rand64() % book.len];
            pos.set_fen(line);
        } else {
            pos.set_fen(types.DEFAULT_FEN);
        }

        // Age the TT to deprecate stale entries (thread-safe, no reallocation)
        tt.GlobalTT.do_age();

        self.searcher.reset_heuristics(true);
        self.searcher.stop = false;
        self.searcher.force_thinking = false;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var records = try std.array_list.Managed(PendingRecord).initCapacity(arena.allocator(), 128);
        defer records.deinit();

        var white_result: u8 = 1; // 0=black wins, 1=draw, 2=white wins
        var draw_count: usize = 0;
        var white_win_count: usize = 0;
        var black_win_count: usize = 0;
        var ply: usize = 0;
        // Fewer random plies from book positions (already ~8 moves in) vs startpos
        const random_plies: u64 = if (using_book) 2 + (self.prng.rand64() % 3) else 9 + (self.prng.rand64() % 4);
        while (true) : (ply += 1) {
            if (self.searcher.is_draw(pos, true)) {
                white_result = 1;
                break;
            }
            var movelist = try std.array_list.Managed(types.Move).initCapacity(arena.allocator(), 32);
            if (pos.turn == types.Color.White) {
                pos.generate_legal_moves(types.Color.White, &movelist);
            } else {
                pos.generate_legal_moves(types.Color.Black, &movelist);
            }
            const move_size = movelist.items.len;
            if (move_size == 0) {
                if (pos.turn == types.Color.White) {
                    white_result = if (pos.in_check(types.Color.White)) 0 else 1;
                } else {
                    white_result = if (pos.in_check(types.Color.Black)) 2 else 1;
                }
                movelist.deinit();
                break;
            }

            // Random move during opening diversification
            if (ply < random_plies or self.prng.rand64() % 10000 == 0) {
                const move = movelist.items[self.prng.rand64() % move_size];
                if (pos.turn == types.Color.White) {
                    pos.play_move(types.Color.White, move);
                } else {
                    pos.play_move(types.Color.Black, move);
                }
                movelist.deinit();
                continue;
            }
            movelist.deinit();

            // Search: result is white-relative score
            const res: i32 = if (pos.turn == types.Color.White)
                self.searcher.iterative_deepening(pos, types.Color.White, MAX_DEPTH)
            else
                -self.searcher.iterative_deepening(pos, types.Color.Black, MAX_DEPTH);

            // Discard games where the random opening produced a large imbalance
            if (ply == random_plies and (res > 1000 or res < -1000)) {
                break;
            }

            const best_move = self.searcher.best_move;
            const in_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);

            // Capture position BEFORE playing the move (the eval applies to this position)
            const min_record_ply: usize = if (using_book) 8 else 16;
            const should_record = ply > min_record_ply and !in_check and
                !best_move.is_capture() and !best_move.is_promotion() and
                res > -2000 and res < 2000;

            var pending: ?PendingRecord = null;
            if (should_record) {
                pending = pos_to_chessboard(pos, res);
            }

            // Play the move
            if (pos.turn == types.Color.White) {
                pos.play_move(types.Color.White, best_move);
            } else {
                pos.play_move(types.Color.Black, best_move);
            }

            // Check if the move gave check (filter out non-quiet positions)
            const gave_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);
            if (pending != null and !gave_check) {
                try records.append(pending.?);
            }

            // Win/loss adjudication (phase-dependent threshold)
            const limit: i32 = if (pos.phase() >= 6) 850 else 500;

            if (res > limit) {
                white_win_count += 1;
                if (white_win_count >= 8) {
                    white_result = 2;
                    break;
                }
            } else {
                white_win_count = 0;
            }

            if (res < -limit) {
                black_win_count += 1;
                if (black_win_count >= 8) {
                    white_result = 0;
                    break;
                }
            } else {
                black_win_count = 0;
            }

            // Draw adjudication
            if (ply >= 40 and -1 < res and res < 1) {
                draw_count += 1;
                if (draw_count >= 10) {
                    white_result = 1;
                    break;
                }
            } else {
                draw_count = 0;
            }
        }

        if (records.items.len == 0) {
            return;
        }

        // Fill in the game result for each recorded position (convert white-relative → STM-relative)
        for (records.items) |*rec| {
            rec.board.result = if (rec.white_was_stm) white_result else 2 - white_result;
        }

        // Write binary records under the file lock
        self.fileLock.lock.lockUncancelable(types.GLOBAL_IO);
        var wbuf: [4096]u8 = undefined;
        var file_writer = self.fileLock.file.writerStreaming(types.GLOBAL_IO, &wbuf);
        const writer = &file_writer.interface;
        for (records.items) |*rec| {
            const bytes = std.mem.asBytes(&rec.board);
            try writer.writeAll(bytes);
        }
        try writer.flush();
        self.count += records.items.len;
        self.fileLock.lock.unlock(types.GLOBAL_IO);
    }

    pub fn startMany(self: *DatagenSingle) !void {
        self.timer = types.Timer.start();
        var game_count: usize = 0;
        while (true) {
            try self.playGame();
            game_count += 1;
            if (game_count % 50 == 0) {
                const elapsed = @as(f64, @floatFromInt(self.timer.read())) / std.time.ns_per_s;
                const pps = @as(f64, @floatFromInt(self.count)) / elapsed;
                const gps = @as(f64, @floatFromInt(game_count)) / elapsed;

                std.debug.print("id {}: {} games, {} pos, {d:.4} pos/s, {d:.4} games/s\n", .{ self.id, game_count, self.count, pps, gps });
            }
        }
    }
};

pub fn loadEpdFile(path: []const u8) ![]const []const u8 {
    const file = std.Io.Dir.cwd().openFile(types.GLOBAL_IO, path, .{}) catch {
        std.debug.panic("Unable to open EPD file: {s}", .{path});
    };
    const file_len = file.length(types.GLOBAL_IO) catch {
        std.debug.panic("Unable to get EPD file size: {s}", .{path});
    };
    const content = std.heap.page_allocator.alloc(u8, @as(usize, @intCast(file_len))) catch {
        std.debug.panic("Out of memory reading EPD file: {s}", .{path});
    };
    _ = file.readPositionalAll(types.GLOBAL_IO, content, 0) catch {
        std.debug.panic("Unable to read EPD file: {s}", .{path});
    };

    var lines = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            lines.append(trimmed) catch {
                std.debug.panic("Out of memory loading EPD file", .{});
            };
        }
    }

    if (lines.items.len == 0) {
        std.debug.panic("EPD file is empty: {s}", .{path});
    }

    std.debug.print("Loaded {} openings from {s}\n", .{ lines.items.len, path });
    return lines.items;
}

pub const Datagen = struct {
    fileLock: FileLock,
    seed: u128,
    datagens: std.array_list.Managed(DatagenSingle),
    openings: ?[]const []const u8,

    pub fn new() Datagen {
        var seed: u128 = undefined;
        std.Io.random(types.GLOBAL_IO, std.mem.asBytes(&seed));
        return Datagen{
            .fileLock = undefined,
            .seed = seed,
            .datagens = std.array_list.Managed(DatagenSingle).init(std.heap.c_allocator),
            .openings = null,
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
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "data_{}.bin", .{std.Io.Clock.real.now(types.GLOBAL_IO).toSeconds()});
        std.debug.print("Writing data to {s} with {} threads\n", .{ path, num_threads });
        const file = std.Io.Dir.cwd().createFile(
            types.GLOBAL_IO,
            path,
            .{ .read = true },
        ) catch {
            std.debug.panic("Unable to open {s}", .{path});
        };
        const lock = std.Io.Mutex.init;
        self.fileLock = FileLock{ .file = file, .lock = lock };
        self.datagens.clearAndFree();

        // Pre-allocate to avoid reallocation invalidating thread pointers
        try self.datagens.ensureTotalCapacity(num_threads);

        // Each thread gets its own PRNG with an independently derived seed
        var seed_prng = utils.PRNG.new(self.seed);

        var th: usize = 0;
        while (th < num_threads) : (th += 1) {
            const thread_seed: u128 = @as(u128, seed_prng.rand64()) | (@as(u128, seed_prng.rand64()) << 64);
            const datagen_inst = DatagenSingle.new(&self.fileLock, thread_seed, th, self.openings);
            self.datagens.appendAssumeCapacity(datagen_inst);
        }

        // Spawn threads only after all datagen instances are placed in stable memory
        var threads = std.array_list.Managed(std.Thread).init(std.heap.c_allocator);
        defer threads.deinit();

        th = 0;
        while (th < num_threads) : (th += 1) {
            const thread = std.Thread.spawn(
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
        const id: u64 = @as(u64, @intCast(std.Io.Clock.real.now(types.GLOBAL_IO).toSeconds()));
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "data_{}.bin", .{id});
        std.debug.print("Writing data to {s} (single-threaded)\n", .{path});
        const file = std.Io.Dir.cwd().createFile(
            types.GLOBAL_IO,
            path,
            .{ .read = true },
        ) catch {
            std.debug.panic("Unable to open {s}", .{path});
        };
        const lock = std.Io.Mutex.init;
        self.fileLock = FileLock{ .file = file, .lock = lock };
        self.datagens.clearAndFree();

        var seed_prng = utils.PRNG.new(self.seed);
        const thread_seed: u128 = @as(u128, seed_prng.rand64()) | (@as(u128, seed_prng.rand64()) << 64);

        var datagen_inst = DatagenSingle.new(&self.fileLock, thread_seed, id, self.openings);
        try datagen_inst.startMany();
    }
};
