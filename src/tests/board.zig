const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const utils = @import("../chess/utils.zig");
const hce = @import("../engine/hce.zig");
const search = @import("../engine/search.zig");
const see = @import("../engine/see.zig");
const support = @import("support.zig");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const MoveList = std.array_list.Managed(types.Move);

const WALK_FENS = [_][]const u8{
    types.DEFAULT_FEN,
    types.KIWIPETE_FEN,
    types.ENDGAME_FEN,
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "4k3/1p1p1p1p/8/P1P1P1P1/1p1p1p1p/8/P1P1P1P1/4K3 w - - 0 1",
    "3rr1k1/pp3pp1/1qn2np1/8/3p4/PP1R1P2/2P1NQPP/R1B3K1 b - - 0 1",
    "qnbnr1kr/ppp1b1pp/4p3/3p1p2/8/2NPP3/PPP1BPPP/QNB1R1KR w HEhe - 1 9",
};

fn legal_moves(pos: *position.Position, list: *MoveList) void {
    switch (pos.turn) {
        .White => pos.generate_legal_moves(.White, list),
        .Black => pos.generate_legal_moves(.Black, list),
    }
}

fn play(pos: *position.Position, move: types.Move) void {
    switch (pos.turn) {
        .White => pos.play_move(.White, move),
        .Black => pos.play_move(.Black, move),
    }
}

/// Calls `visit(context, pos, moves)` on every position of seeded random games from `WALK_FENS`.
fn walk_random_games(seed: u128, walks_per_fen: usize, max_ply: usize, context: anytype, comptime visit: anytype) !void {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    var prng = utils.PRNG.new(seed);
    var moves = try MoveList.initCapacity(std.testing.allocator, 256);
    defer moves.deinit();

    for (WALK_FENS) |fen| {
        for (0..walks_per_fen) |_| {
            pos.set_fen(fen);
            for (0..max_ply) |_| {
                moves.clearRetainingCapacity();
                legal_moves(pos, &moves);
                try visit(context, pos, moves.items);
                if (moves.items.len == 0) break;
                play(pos, moves.items[@intCast(prng.rand64() % moves.items.len)]);
            }
        }
    }
}

/// The exchange evaluation as it was before pins were found without slider
/// lookups; `see.see_threshold` must agree with it on every move and threshold.
const reference_see = struct {
    fn pinned_pieces(pos: *position.Position, comptime color: types.Color, occ: types.Bitboard) types.Bitboard {
        const opp = comptime color.invert();
        const king_bb = pos.piece_bitboards[types.Piece.new_comptime(color, .King).index()] & occ;
        if (king_bb == 0) return 0;

        const king_sq: types.Square = @fromBackingInt(@intCast(types.lsb(king_bb)));
        const us = pos.all_pieces(color) & occ;
        const them = pos.all_pieces(opp) & occ;
        var candidates = tables.get_rook_attacks(king_sq, them) & pos.orthogonal_sliders(opp) & occ;
        candidates |= tables.get_bishop_attacks(king_sq, them) & pos.diagonal_sliders(opp) & occ;

        var pinned: types.Bitboard = 0;
        while (candidates != 0) {
            const pinner = types.pop_lsb(&candidates);
            const between = tables.SquaresBetween[king_sq.index()][pinner.index()] & us;
            if (between != 0 and (between & (between - 1)) == 0) pinned |= between;
        }
        return pinned;
    }

    fn legal_attackers(pos: *position.Position, comptime color: types.Color, target: types.Square, occ: types.Bitboard, attackers: types.Bitboard) types.Bitboard {
        var legal = attackers;
        var pinned = pinned_pieces(pos, color, occ) & attackers;
        if (pinned == 0) return legal;

        const king_bb = pos.piece_bitboards[types.Piece.new_comptime(color, .King).index()] & occ;
        const king_sq: types.Square = @fromBackingInt(@intCast(types.lsb(king_bb)));
        while (pinned != 0) {
            const sq = types.pop_lsb(&pinned);
            if (tables.LineOf[king_sq.index()][sq.index()] & types.SquareIndexBB[target.index()] == 0) {
                legal &= ~types.SquareIndexBB[sq.index()];
            }
        }
        return legal;
    }

    fn threshold(pos: *position.Position, move: types.Move, bound: i32) bool {
        if (move.is_castle()) return bound <= 0;

        const from = move.from;
        const to = move.to;
        const target = move.get_to();
        const mover = pos.mailbox[from].color();
        const is_ep = move.get_flags() == types.MoveFlags.EN_PASSANT;
        const victim = pos.mailbox[to];
        const victim_value: i32 = if (is_ep)
            see.SeeWeight[types.PieceType.Pawn.index()]
        else if (victim == types.Piece.NO_PIECE)
            0
        else
            see.SeeWeight[victim.piece_type().index()];

        var swap = victim_value - bound;
        if (swap < 0) return false;
        swap -= see.SeeWeight[pos.mailbox[from].piece_type().index()];
        if (swap >= 0) return true;

        const white_pieces = pos.all_pieces(.White);
        const black_pieces = pos.all_pieces(.Black);

        var occ = (white_pieces | black_pieces) ^ types.SquareIndexBB[from];
        if (is_ep) {
            const captured: usize = if (mover == .White) @as(usize, to) - 8 else @as(usize, to) + 8;
            occ ^= types.SquareIndexBB[captured];
        }
        occ |= types.SquareIndexBB[to];
        var attackers = (pos.attackers_from(.White, target, occ) | pos.attackers_from(.Black, target, occ)) & occ;

        const bishops = pos.diagonal_sliders(.White) | pos.diagonal_sliders(.Black);
        const rooks = pos.orthogonal_sliders(.White) | pos.orthogonal_sliders(.Black);

        var stm = mover.invert();
        while (true) {
            attackers &= occ;
            const pseudo_attackers = attackers & (if (stm == .White) white_pieces else black_pieces);
            const my_attackers = if (stm == .White)
                legal_attackers(pos, .White, target, occ, pseudo_attackers)
            else
                legal_attackers(pos, .Black, target, occ, pseudo_attackers);
            if (my_attackers == 0) break;

            var pt: usize = 0;
            while (pt <= 5) : (pt += 1) {
                if (my_attackers & (pos.piece_bitboards[pt] | pos.piece_bitboards[pt + 8]) != 0) break;
            }

            stm = stm.invert();
            swap = -swap - 1 - see.SeeWeight[pt];
            if (swap >= 0) {
                if (pt == 5 and attackers & (if (stm == .White) white_pieces else black_pieces) != 0) {
                    stm = stm.invert();
                }
                break;
            }

            occ ^= types.SquareIndexBB[@intCast(types.lsb(my_attackers & (pos.piece_bitboards[pt] | pos.piece_bitboards[pt + 8])))];
            if (pt == 0 or pt == 2 or pt == 4) attackers |= tables.get_bishop_attacks(target, occ) & bishops;
            if (pt == 3 or pt == 4) attackers |= tables.get_rook_attacks(target, occ) & rooks;
        }
        return stm != mover;
    }
};

const SEE_THRESHOLDS = [_]i32{ -2000, -995, -994, -700, -522, -521, -347, -346, -309, -308, -215, -94, -93, -1, 0, 1, 93, 94, 215, 308, 346, 428, 521, 648, 994, 1300 };

fn expect_see_matches_reference(prng: *utils.PRNG, pos: *position.Position, moves: []const types.Move) !void {
    for (moves) |move| {
        for (SEE_THRESHOLDS) |bound| {
            try expectEqual(reference_see.threshold(pos, move, bound), see.see_threshold(pos, move, bound));
        }
        const random_bound = @as(i32, @intCast(prng.rand64() % 2401)) - 1200;
        try expectEqual(reference_see.threshold(pos, move, random_bound), see.see_threshold(pos, move, random_bound));
    }
}

test "see: threshold matches the reference exchange on every move of random games" {
    var prng = utils.PRNG.new(0x5EE_7E57_0B0A_2D00_C0FF_EE11);
    try walk_random_games(0xB0A2D_5EE_D1FF_E2E7_1A1, 12, 80, &prng, expect_see_matches_reference);
}

fn king_captures(pos: *const position.Position, moves: []const types.Move, out: *MoveList) !void {
    out.clearRetainingCapacity();
    for (moves) |move| {
        if (move.is_capture() and pos.mailbox[move.from].piece_type() == .King) try out.append(move);
    }
}

const KingCaptureLists = struct {
    captures: MoveList,
    from_legal: MoveList,
    from_captures: MoveList,
};

fn expect_same_king_captures(lists: *KingCaptureLists, pos: *position.Position, legal: []const types.Move) !void {
    lists.captures.clearRetainingCapacity();
    switch (pos.turn) {
        .White => pos.generate_q_moves(.White, &lists.captures),
        .Black => pos.generate_q_moves(.Black, &lists.captures),
    }
    try king_captures(pos, legal, &lists.from_legal);
    try king_captures(pos, lists.captures.items, &lists.from_captures);
    try expectEqualSlices(types.Move, lists.from_legal.items, lists.from_captures.items);
}

test "movegen: the capture generator finds the legal generator's king captures in the same order" {
    var lists = KingCaptureLists{
        .captures = try MoveList.initCapacity(std.testing.allocator, 256),
        .from_legal = try MoveList.initCapacity(std.testing.allocator, 8),
        .from_captures = try MoveList.initCapacity(std.testing.allocator, 8),
    };
    defer lists.captures.deinit();
    defer lists.from_legal.deinit();
    defer lists.from_captures.deinit();
    try walk_random_games(0xC0DE_CAFE_F00D_0BAD_5EED, 40, 160, &lists, expect_same_king_captures);
}

fn reference_material_draw(pos: *const position.Position) bool {
    const all = pos.all_pieces(.White) | pos.all_pieces(.Black);
    const kings = pos.piece_bitboards[types.Piece.WHITE_KING.index()] | pos.piece_bitboards[types.Piece.BLACK_KING.index()];
    if (kings == all) return true;

    inline for ([_]types.Piece{ .WHITE_BISHOP, .BLACK_BISHOP, .WHITE_KNIGHT, .BLACK_KNIGHT }) |minor| {
        const bb = pos.piece_bitboards[minor.index()];
        if (@popCount(bb) == 1 and bb | kings == all) return true;
    }
    return false;
}

test "draw: material draws match the reference on random sparse positions" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    const extras = "NBnbNBnbPRQprq";
    var prng = utils.PRNG.new(0x0DD_BA11_5EED_FACE);
    for (0..4000) |_| {
        var board: [64]u8 = @splat('.');
        board[@intCast(prng.rand64() % 64)] = 'K';
        var placed: usize = 0;
        const wanted = 1 + prng.rand64() % 4;
        while (placed < wanted) {
            const sq: usize = @intCast(prng.rand64() % 64);
            if (board[sq] != '.') continue;
            board[sq] = if (placed == 0) 'k' else extras[@intCast(prng.rand64() % extras.len)];
            placed += 1;
        }

        var fen_buf: [96]u8 = undefined;
        var fen = std.Io.Writer.fixed(&fen_buf);
        for (0..8) |rank| {
            if (rank != 0) try fen.writeByte('/');
            for (board[rank * 8 ..][0..8]) |piece| try fen.writeByte(if (piece == '.') '1' else piece);
        }
        try fen.writeAll(" w - - 0 1");
        pos.set_fen(fen.buffered());
        try expectEqual(reference_material_draw(pos), hce.is_material_draw(pos));
    }
}

fn reference_has_earlier_occurrences(keys: []const u64, key: u64, fifty: u16, needed: u8) bool {
    if (keys.len > 1) {
        var index: i16 = @as(i16, @intCast(keys.len)) - 3;
        const limit: i16 = index - @as(i16, @intCast(fifty)) - 1;
        var count: u8 = 0;
        while (index >= limit and index >= 0) : (index -= 2) {
            if (keys[@intCast(index)] == key) {
                count += 1;
                if (count >= needed) return true;
            }
        }
    }
    return false;
}

test "draw: the repetition scan matches the reference on random key histories" {
    var prng = utils.PRNG.new(0x2E9E_A7ED_C0DE_5EED);
    var keys: [48]u64 = undefined;
    for (0..200_000) |_| {
        const len: usize = @intCast(prng.rand64() % (keys.len + 1));
        for (keys[0..len]) |*key| key.* = prng.rand64() % 3;
        const fifty: u16 = @intCast(prng.rand64() % 100);
        const key = prng.rand64() % 3;
        inline for (.{ 1, 2 }) |needed| {
            try expectEqual(
                reference_has_earlier_occurrences(keys[0..len], key, fifty, needed),
                search.Searcher.has_earlier_occurrences(keys[0..len], key, fifty, needed),
            );
        }
    }
}

const Snapshot = struct {
    piece_bitboards: [types.N_PIECES]types.Bitboard,
    occupancy: [types.N_COLORS]types.Bitboard,
    mailbox: [types.N_SQUARES]types.Piece,
    turn: types.Color,
    game_ply: u32,
    keys: position.Keys,
    undo: position.UndoInfo,

    fn of(pos: *const position.Position) Snapshot {
        return .{
            .piece_bitboards = pos.piece_bitboards,
            .occupancy = pos.occupancy,
            .mailbox = pos.mailbox,
            .turn = pos.turn,
            .game_ply = pos.game_ply,
            .keys = pos.keys(),
            .undo = pos.history[pos.game_ply],
        };
    }
};

fn undo(pos: *position.Position, move: types.Move) void {
    switch (pos.turn) {
        .White => pos.undo_move(.Black, move),
        .Black => pos.undo_move(.White, move),
    }
}

fn occupancy_of_pieces(pos: *const position.Position) [types.N_COLORS]types.Bitboard {
    var occupancy: [types.N_COLORS]types.Bitboard = .{ 0, 0 };
    for (pos.mailbox, 0..) |piece, sq| {
        if (piece != types.Piece.NO_PIECE) occupancy[@backingInt(piece.color())] |= types.SquareIndexBB[sq];
    }
    return occupancy;
}

fn expect_moves_round_trip(fresh: *position.Position, pos: *position.Position, moves: []const types.Move) !void {
    const fen = pos.basic_fen(std.testing.allocator);
    defer std.testing.allocator.free(fen);
    fresh.set_fen(fen);
    try expectEqual(fresh.keys(), pos.keys());
    try expectEqual(occupancy_of_pieces(pos), pos.occupancy);

    const before = Snapshot.of(pos);
    for (moves) |move| {
        play(pos, move);
        undo(pos, move);
        try expectEqual(before, Snapshot.of(pos));
    }
    pos.play_null_move();
    pos.undo_null_move();
    try expectEqual(before, Snapshot.of(pos));
}

test "make/unmake: keys and occupancy match the board, and undoing any move restores the position" {
    const fresh = try support.new_position();
    defer support.destroy_position(fresh);
    try walk_random_games(0x0D0_0BAD_F00D_A11_0E5, 6, 120, fresh, expect_moves_round_trip);
}
