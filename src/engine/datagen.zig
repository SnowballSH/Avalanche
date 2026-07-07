const std = @import("std");
const types = @import("../chess/types.zig");
const utils = @import("../chess/utils.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");
const see = @import("see.zig");
const tt = @import("tt.zig");

pub const FileLock = struct {
    file: std.Io.File,
    lock: std.Io.Mutex,
};

pub const Format = enum { bullet, viri };

pub const DatagenConfig = struct {
    format: Format = .viri,
    soft_nodes: u64 = 10000,
    hard_node_multiplier: u64 = 8,
    random_plies_min: u64 = 8,
    random_plies_range: u64 = 3,
    book_random_plies_min: u64 = 0,
    book_random_plies_range: u64 = 3,
    random_move_see_threshold: i32 = -200,
    datagen_tt_mb: u64 = 4,
    opening_reject_threshold: i32 = 600,
    win_adj_threshold: i32 = 2500,
    win_adj_count: usize = 4,
    draw_adj_threshold: i32 = 5,
    draw_adj_count: usize = 12,
    draw_adj_min_ply: usize = 50,
};

// Viriformat PackedBoard — 32 bytes, little-endian
// Piece encoding: bits 0-2 = type (0=P,1=N,2=B,3=R,4=Q,5=K,6=unmoved_rook), bit3 = color (0=white,1=black)
const ViriPackedBoard = extern struct {
    occ: u64,
    pcs: [16]u8,
    stm_ep: u8,
    halfmove: u8,
    fullmove: u16,
    eval: i16,
    wdl: u8,
    extra: u8,
};

comptime {
    if (@sizeOf(ViriPackedBoard) != 32) @compileError("ViriPackedBoard must be 32 bytes");
}

const MoveScorePair = extern struct {
    move: u16,
    score: i16,
};

comptime {
    if (@sizeOf(MoveScorePair) != 4) @compileError("MoveScorePair must be 4 bytes");
}

const VIRI_TERMINATOR: MoveScorePair = .{ .move = 0, .score = 0 };

fn encode_viri_move(move: types.Move) u16 {
    const from: u16 = @as(u16, move.from);
    const raw_flags: u4 = move.flags;

    var to: u16 = @as(u16, move.to);
    var promo: u16 = 0;
    var mtype: u16 = 0;

    if (raw_flags == 0b0010) {
        // OO: king-takes-rook on h-file
        to = (from & 0b111000) | 7;
        mtype = 2;
    } else if (raw_flags == 0b0011) {
        // OOO: king-takes-rook on a-file
        to = (from & 0b111000) | 0;
        mtype = 2;
    } else if (raw_flags == 0b1010) {
        // EN_PASSANT
        mtype = 1;
    } else if (raw_flags & 0b0100 != 0) {
        // Any promotion (bit 2 set in flags = promotion)
        mtype = 3;
        promo = @as(u16, raw_flags & 0b0011);
    }

    return from | (to << 6) | (promo << 12) | (mtype << 14);
}

fn pos_to_viri_packed_board(pos: *position.Position, white_relative_score: i32) ViriPackedBoard {
    const all_occ = pos.all_all_pieces();

    const castling_entry = pos.history[pos.game_ply].entry;
    const h1_rook_can_castle = (castling_entry & types.WhiteOOMask) == 0;
    const a1_rook_can_castle = (castling_entry & types.WhiteOOOMask) == 0;
    const h8_rook_can_castle = (castling_entry & types.BlackOOMask) == 0;
    const a8_rook_can_castle = (castling_entry & types.BlackOOOMask) == 0;

    // Pack pieces in occupancy order (LSB first)
    var pcs: [16]u8 = .{0} ** 16;
    var idx: usize = 0;
    var occ_iter = all_occ;
    while (occ_iter != 0) {
        const sq_idx = @ctz(occ_iter);
        const sq_bit: u64 = @as(u64, 1) << @as(u6, @intCast(sq_idx));
        occ_iter &= occ_iter - 1;

        const piece = pos.mailbox[sq_idx];
        if (piece == types.Piece.NO_PIECE) continue;

        const pt = piece.piece_type();
        const color = piece.color();
        var piece_nibble: u8 = @as(u8, pt.index());

        // Mark unmoved rooks as type 6 (castling rights indicator in viriformat)
        if (pt == types.PieceType.Rook) {
            const is_castling_rook = blk: {
                if (color == types.Color.White) {
                    if (sq_idx == 0 and a1_rook_can_castle) break :blk true;
                    if (sq_idx == 7 and h1_rook_can_castle) break :blk true;
                } else {
                    if (sq_idx == 56 and a8_rook_can_castle) break :blk true;
                    if (sq_idx == 63 and h8_rook_can_castle) break :blk true;
                }
                break :blk false;
            };
            if (is_castling_rook) piece_nibble = 6;
        }

        // Color bit: 0=white, 1=black (bit 3)
        if (color == types.Color.Black) piece_nibble |= 8;

        _ = sq_bit;
        pcs[idx / 2] |= piece_nibble << @as(u3, @intCast(4 * (idx & 1)));
        idx += 1;
    }

    // Side-to-move + en-passant byte
    const ep_sq = pos.history[pos.game_ply].ep_sq;
    const ep_val: u8 = if (ep_sq == types.Square.NO_SQUARE) 64 else @as(u8, @intCast(ep_sq.index()));
    const stm_bit: u8 = if (pos.turn == types.Color.Black) 0x80 else 0;
    const stm_ep: u8 = stm_bit | (ep_val & 0x7F);

    // Halfmove clock
    const halfmove: u8 = @as(u8, @intCast(@min(pos.history[pos.game_ply].fifty, 255)));

    // Fullmove counter
    const fullmove: u16 = @as(u16, @intCast(pos.game_ply / 2 + 1));

    // Eval: white-relative, clamped
    const clamped = std.math.clamp(white_relative_score, -32000, 32000);

    return ViriPackedBoard{
        .occ = all_occ,
        .pcs = pcs,
        .stm_ep = stm_ep,
        .halfmove = halfmove,
        .fullmove = fullmove,
        .eval = @as(i16, @intCast(clamped)),
        .wdl = 1, // filled at game end
        .extra = 0,
    };
}

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

    var piece_bbs: [6]u64 = .{
        w_pawn | b_pawn,
        w_knight | b_knight,
        w_bishop | b_bishop,
        w_rook | b_rook,
        w_queen | b_queen,
        w_king | b_king,
    };

    if (stm == types.Color.Black) {
        white_occ = @byteSwap(white_occ);
        black_occ = @byteSwap(black_occ);
        for (&piece_bbs) |*bb| {
            bb.* = @byteSwap(bb.*);
        }
    }

    const friendly_occ = if (stm == types.Color.White) white_occ else black_occ;
    const enemy_occ = if (stm == types.Color.White) black_occ else white_occ;
    const occ = friendly_occ | enemy_occ;

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

    const our_king_sq: u8 = blk: {
        const kb = if (stm == types.Color.White) w_king else @byteSwap(b_king);
        break :blk @as(u8, @intCast(@ctz(kb)));
    };
    const opp_king_sq: u8 = blk: {
        const kb = if (stm == types.Color.White) b_king else @byteSwap(w_king);
        break :blk @as(u8, @intCast(@ctz(kb))) ^ 56;
    };

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
            .result = 0,
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
    game_count: u64,
    searchers: [2]search.Searcher,
    ttables: [2]*tt.TranspositionTable,
    fileLock: *FileLock,
    prng: utils.PRNG,
    openings: ?[]const []const u8,
    config: DatagenConfig,

    pub fn new(lock: *FileLock, seed: u128, id: u64, openings: ?[]const []const u8, config: DatagenConfig) DatagenSingle {
        const white_tt = newDatagenTT(config.datagen_tt_mb);
        const black_tt = newDatagenTT(config.datagen_tt_mb);

        return DatagenSingle{
            .id = id,
            .timer = undefined,
            .count = 0,
            .game_count = 0,
            .searchers = .{
                newDatagenSearcher(config, white_tt),
                newDatagenSearcher(config, black_tt),
            },
            .ttables = .{ white_tt, black_tt },
            .fileLock = lock,
            .prng = utils.PRNG.new(seed),
            .openings = openings,
            .config = config,
        };
    }

    pub fn deinit(self: *DatagenSingle) void {
        for (&self.searchers) |*s| {
            s.deinit();
        }
        for (self.ttables) |table| {
            table.data.deinit();
            std.heap.c_allocator.destroy(table);
        }
    }

    fn newDatagenTT(mb: u64) *tt.TranspositionTable {
        const table = std.heap.c_allocator.create(tt.TranspositionTable) catch unreachable;
        table.* = tt.TranspositionTable.new();
        table.reset(mb);
        return table;
    }

    fn newDatagenSearcher(config: DatagenConfig, table: *tt.TranspositionTable) search.Searcher {
        var s = search.Searcher.new();
        s.max_millis = 999999999;
        s.ideal_time = 999999999;
        s.max_nodes = config.soft_nodes * config.hard_node_multiplier;
        s.soft_max_nodes = config.soft_nodes;
        s.min_depth = 1;
        s.silent_output = true;
        s.ttable = table;
        return s;
    }

    const SearchResult = struct {
        score: i32,
        best_move: types.Move,
    };

    fn activeSearcher(self: *DatagenSingle, turn: types.Color) *search.Searcher {
        return &self.searchers[@as(usize, @intFromEnum(turn))];
    }

    fn resetSearchStateForGame(self: *DatagenSingle, pos: *position.Position) void {
        for (&self.searchers) |*s| {
            s.root_board = pos.*;
            s.reset_heuristics(true);
            @atomicStore(bool, &s.stop, false, .monotonic);
            s.time_stop = false;
            s.force_thinking = false;
            s.hash_history.clearRetainingCapacity();
            s.hash_history.append(pos.hash) catch {};
            s.ttable.do_age();
        }
    }

    fn noteGamePosition(self: *DatagenSingle, pos: *position.Position) void {
        for (&self.searchers) |*s| {
            s.hash_history.append(pos.hash) catch {};
        }
    }

    fn isCurrentPositionDraw(self: *DatagenSingle, pos: *position.Position) bool {
        return self.activeSearcher(pos.turn).is_draw(pos, true);
    }

    fn searchPosition(self: *DatagenSingle, pos: *position.Position) SearchResult {
        var s = self.activeSearcher(pos.turn);
        s.root_board = pos.*;
        s.time_stop = false;
        s.force_thinking = false;
        @atomicStore(bool, &s.stop, false, .monotonic);

        const score: i32 = if (pos.turn == types.Color.White)
            s.iterative_deepening(pos, types.Color.White, null)
        else
            -s.iterative_deepening(pos, types.Color.Black, null);

        @atomicStore(bool, &s.stop, false, .monotonic);
        s.time_stop = false;
        s.force_thinking = false;

        return .{
            .score = score,
            .best_move = s.best_move,
        };
    }

    fn generateLegalMoves(pos: *position.Position, movelist: *std.array_list.Managed(types.Move)) void {
        if (pos.turn == types.Color.White) {
            pos.generate_legal_moves(types.Color.White, movelist);
        } else {
            pos.generate_legal_moves(types.Color.Black, movelist);
        }
    }

    fn playMove(pos: *position.Position, move: types.Move) void {
        if (pos.turn == types.Color.White) {
            pos.play_move(types.Color.White, move);
        } else {
            pos.play_move(types.Color.Black, move);
        }
    }

    fn randomPlyCount(self: *DatagenSingle, using_book: bool) usize {
        const min = if (using_book) self.config.book_random_plies_min else self.config.random_plies_min;
        const range = if (using_book) self.config.book_random_plies_range else self.config.random_plies_range;
        const extra = if (range == 0) 0 else self.prng.rand64() % range;
        return @as(usize, @intCast(min + extra));
    }

    fn randomMovePasses(self: *DatagenSingle, pos: *position.Position, move: types.Move) bool {
        const flags = move.get_flags();
        if (flags == types.MoveFlags.OO or flags == types.MoveFlags.OOO or flags == types.MoveFlags.EN_PASSANT or move.is_promotion()) {
            return true;
        }
        return see.see_threshold(pos, move, self.config.random_move_see_threshold);
    }

    fn pickRandomOpeningMove(self: *DatagenSingle, pos: *position.Position, moves: []const types.Move) types.Move {
        const fallback_index = @as(usize, @intCast(self.prng.rand64() % @as(u64, @intCast(moves.len))));
        const fallback = moves[fallback_index];

        var accepted: u64 = 0;
        var chosen = types.Move.empty();
        for (moves) |move| {
            if (!self.randomMovePasses(pos, move)) continue;
            accepted += 1;
            if (self.prng.rand64() % accepted == 0) {
                chosen = move;
            }
        }

        return if (chosen.to_u16() != 0) chosen else fallback;
    }

    pub fn playGameViri(self: *DatagenSingle) !void {
        var pos = position.Position.new();

        const using_book = self.openings != null;
        if (self.openings) |book| {
            const line = book[self.prng.rand64() % book.len];
            pos.set_fen(line);
        } else {
            pos.set_fen(types.DEFAULT_FEN);
        }

        self.resetSearchStateForGame(&pos);

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var move_scores = try std.array_list.Managed(MoveScorePair).initCapacity(arena.allocator(), 256);
        defer move_scores.deinit();

        var white_result: u8 = 1; // 0=black win, 1=draw, 2=white win
        var draw_count: usize = 0;
        var white_win_count: usize = 0;
        var black_win_count: usize = 0;
        var ply: usize = 0;
        const cfg = self.config;

        const random_plies = self.randomPlyCount(using_book);

        var initial_board: ?ViriPackedBoard = null;

        while (true) : (ply += 1) {
            if (self.isCurrentPositionDraw(&pos)) {
                white_result = 1;
                break;
            }

            var movelist = try std.array_list.Managed(types.Move).initCapacity(arena.allocator(), 32);
            generateLegalMoves(&pos, &movelist);
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

            // Random opening moves
            if (ply < random_plies) {
                const move = self.pickRandomOpeningMove(&pos, movelist.items);
                playMove(&pos, move);
                self.noteGamePosition(&pos);
                movelist.deinit();
                continue;
            }
            movelist.deinit();

            // Capture initial board state (once, after random moves)
            if (initial_board == null) {
                // Do a quick search to check if position is playable
                const initial_search = self.searchPosition(&pos);
                const init_score = initial_search.score;

                if (init_score > cfg.opening_reject_threshold or init_score < -cfg.opening_reject_threshold) {
                    return; // discard unbalanced opening
                }
                initial_board = pos_to_viri_packed_board(&pos, init_score);
            }

            // Search
            const result = self.searchPosition(&pos);
            const res = result.score;
            const best_move = result.best_move;

            // Record move+score pair
            const viri_move = encode_viri_move(best_move);
            try move_scores.append(MoveScorePair{
                .move = viri_move,
                .score = @as(i16, @intCast(std.math.clamp(res, -32000, 32000))),
            });

            // Play the move
            playMove(&pos, best_move);
            self.noteGamePosition(&pos);

            // Win/loss adjudication
            if (res > cfg.win_adj_threshold) {
                white_win_count += 1;
                if (white_win_count >= cfg.win_adj_count) {
                    white_result = 2;
                    break;
                }
            } else {
                white_win_count = 0;
            }

            if (res < -cfg.win_adj_threshold) {
                black_win_count += 1;
                if (black_win_count >= cfg.win_adj_count) {
                    white_result = 0;
                    break;
                }
            } else {
                black_win_count = 0;
            }

            // Draw adjudication
            if (ply >= cfg.draw_adj_min_ply and res > -cfg.draw_adj_threshold and res < cfg.draw_adj_threshold) {
                draw_count += 1;
                if (draw_count >= cfg.draw_adj_count) {
                    white_result = 1;
                    break;
                }
            } else {
                draw_count = 0;
            }

            // Safety: max game length
            if (ply > 500) {
                white_result = 1;
                break;
            }
        }

        if (initial_board == null or move_scores.items.len == 0) return;

        // Set game result in the initial board
        var board = initial_board.?;
        board.wdl = white_result;

        // Write game under file lock: PackedBoard + MoveScorePairs + Terminator
        self.fileLock.lock.lockUncancelable(types.GLOBAL_IO);
        defer self.fileLock.lock.unlock(types.GLOBAL_IO);
        var wbuf: [8192]u8 = undefined;
        var file_writer = self.fileLock.file.writerStreaming(types.GLOBAL_IO, &wbuf);
        const writer = &file_writer.interface;
        try writer.writeAll(std.mem.asBytes(&board));
        for (move_scores.items) |*ms| {
            try writer.writeAll(std.mem.asBytes(ms));
        }
        try writer.writeAll(std.mem.asBytes(&VIRI_TERMINATOR));
        try writer.flush();
        self.count += move_scores.items.len;
        self.game_count += 1;
    }

    pub fn playGame(self: *DatagenSingle) !void {
        var pos = position.Position.new();

        const using_book = self.openings != null;
        if (self.openings) |book| {
            const line = book[self.prng.rand64() % book.len];
            pos.set_fen(line);
        } else {
            pos.set_fen(types.DEFAULT_FEN);
        }

        self.resetSearchStateForGame(&pos);

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var records = try std.array_list.Managed(PendingRecord).initCapacity(arena.allocator(), 128);
        defer records.deinit();

        var white_result: u8 = 1;
        var draw_count: usize = 0;
        var white_win_count: usize = 0;
        var black_win_count: usize = 0;
        var ply: usize = 0;
        const cfg = self.config;
        const random_plies = self.randomPlyCount(using_book);

        while (true) : (ply += 1) {
            if (self.isCurrentPositionDraw(&pos)) {
                white_result = 1;
                break;
            }
            var movelist = try std.array_list.Managed(types.Move).initCapacity(arena.allocator(), 32);
            generateLegalMoves(&pos, &movelist);
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

            if (ply < random_plies) {
                const move = self.pickRandomOpeningMove(&pos, movelist.items);
                playMove(&pos, move);
                self.noteGamePosition(&pos);
                movelist.deinit();
                continue;
            }
            movelist.deinit();

            const result = self.searchPosition(&pos);
            const res = result.score;

            if (ply == random_plies and (res > cfg.opening_reject_threshold or res < -cfg.opening_reject_threshold)) {
                break;
            }

            const best_move = result.best_move;
            const in_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);

            const min_record_ply: usize = if (using_book) 8 else 16;
            const should_record = ply > min_record_ply and !in_check and
                !best_move.is_capture() and !best_move.is_promotion() and
                res > -2000 and res < 2000;

            var pending: ?PendingRecord = null;
            if (should_record) {
                pending = pos_to_chessboard(&pos, res);
            }

            playMove(&pos, best_move);
            self.noteGamePosition(&pos);

            const gave_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);
            if (pending != null and !gave_check) {
                try records.append(pending.?);
            }

            // Adjudication
            if (res > cfg.win_adj_threshold) {
                white_win_count += 1;
                if (white_win_count >= cfg.win_adj_count) {
                    white_result = 2;
                    break;
                }
            } else {
                white_win_count = 0;
            }

            if (res < -cfg.win_adj_threshold) {
                black_win_count += 1;
                if (black_win_count >= cfg.win_adj_count) {
                    white_result = 0;
                    break;
                }
            } else {
                black_win_count = 0;
            }

            if (ply >= cfg.draw_adj_min_ply and res > -cfg.draw_adj_threshold and res < cfg.draw_adj_threshold) {
                draw_count += 1;
                if (draw_count >= cfg.draw_adj_count) {
                    white_result = 1;
                    break;
                }
            } else {
                draw_count = 0;
            }

            if (ply > 500) {
                white_result = 1;
                break;
            }
        }

        if (records.items.len == 0) return;

        for (records.items) |*rec| {
            rec.board.result = if (rec.white_was_stm) white_result else 2 - white_result;
        }

        self.fileLock.lock.lockUncancelable(types.GLOBAL_IO);
        defer self.fileLock.lock.unlock(types.GLOBAL_IO);
        var wbuf: [4096]u8 = undefined;
        var file_writer = self.fileLock.file.writerStreaming(types.GLOBAL_IO, &wbuf);
        const writer = &file_writer.interface;
        for (records.items) |*rec| {
            const bytes = std.mem.asBytes(&rec.board);
            try writer.writeAll(bytes);
        }
        try writer.flush();
        self.count += records.items.len;
        self.game_count += 1;
    }

    pub fn startMany(self: *DatagenSingle) !void {
        self.timer = types.Timer.start();
        while (true) {
            if (self.config.format == .viri) {
                try self.playGameViri();
            } else {
                try self.playGame();
            }
            if (self.game_count % 50 == 0 and self.game_count > 0) {
                const elapsed = @as(f64, @floatFromInt(self.timer.read())) / std.time.ns_per_s;
                const pps = @as(f64, @floatFromInt(self.count)) / elapsed;
                const gps = @as(f64, @floatFromInt(self.game_count)) / elapsed;

                std.debug.print("id {}: {} games, {} pos, {d:.0} pos/s, {d:.2} games/s\n", .{ self.id, self.game_count, self.count, pps, gps });
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
    config: DatagenConfig,

    pub fn new(config: DatagenConfig) Datagen {
        var seed: u128 = undefined;
        std.Io.random(types.GLOBAL_IO, std.mem.asBytes(&seed));
        return Datagen{
            .fileLock = undefined,
            .seed = seed,
            .datagens = std.array_list.Managed(DatagenSingle).init(std.heap.c_allocator),
            .openings = null,
            .config = config,
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
        const ext = if (self.config.format == .viri) ".viribin" else ".bin";
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "data_{}{s}", .{ std.Io.Clock.real.now(types.GLOBAL_IO).toSeconds(), ext });
        const random_plies_max = self.config.random_plies_min + if (self.config.random_plies_range == 0) 0 else self.config.random_plies_range - 1;
        const book_random_plies_max = self.config.book_random_plies_min + if (self.config.book_random_plies_range == 0) 0 else self.config.book_random_plies_range - 1;

        std.debug.print("=== Avalanche Datagen ===\n", .{});
        std.debug.print("Format:  {s}\n", .{if (self.config.format == .viri) "viriformat binpack" else "bulletformat"});
        std.debug.print("Nodes:   {} soft, {} hard\n", .{ self.config.soft_nodes, self.config.soft_nodes * self.config.hard_node_multiplier });
        std.debug.print("Opening: {}-{} plies, book {}-{} plies, SEE >= {}\n", .{ self.config.random_plies_min, random_plies_max, self.config.book_random_plies_min, book_random_plies_max, self.config.random_move_see_threshold });
        std.debug.print("TT:      {} MB per side per worker\n", .{self.config.datagen_tt_mb});
        std.debug.print("Threads: {}\n", .{num_threads});
        std.debug.print("Output:  {s}\n", .{path});
        std.debug.print("=========================\n\n", .{});

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

        try self.datagens.ensureTotalCapacity(num_threads);

        var seed_prng = utils.PRNG.new(self.seed);

        var th: usize = 0;
        while (th < num_threads) : (th += 1) {
            const thread_seed: u128 = @as(u128, seed_prng.rand64()) | (@as(u128, seed_prng.rand64()) << 64);
            const datagen_inst = DatagenSingle.new(&self.fileLock, thread_seed, th, self.openings, self.config);
            self.datagens.appendAssumeCapacity(datagen_inst);
        }

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
        const ext = if (self.config.format == .viri) ".viribin" else ".bin";
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "data_{}{s}", .{ id, ext });
        std.debug.print("Writing data to {s} (single-threaded, {s})\n", .{ path, if (self.config.format == .viri) "viriformat" else "bulletformat" });
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

        var datagen_inst = DatagenSingle.new(&self.fileLock, thread_seed, id, self.openings, self.config);
        try datagen_inst.startMany();
    }
};
