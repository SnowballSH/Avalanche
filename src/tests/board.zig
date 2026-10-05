const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");
const utils = @import("../chess/utils.zig");
const hce = @import("../engine/hce.zig");
const search = @import("../engine/search.zig");
const see = @import("../engine/see.zig");
const support = @import("support.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const MoveList = types.MoveList;

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

/// Calls `visit(context, pos, moves)` on every position of seeded random games from `WALK_FENS`.
fn walk_random_games(seed: u128, walks_per_fen: usize, max_ply: usize, context: anytype, comptime visit: anytype) !void {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    var prng = utils.PRNG.new(seed);

    for (WALK_FENS) |fen| {
        for (0..walks_per_fen) |_| {
            pos.set_fen(fen);
            for (0..max_ply) |_| {
                const moves = pos.legal_moves();
                try visit(context, pos, moves.items());
                if (moves.len == 0) break;
                support.play(pos, moves.items()[@intCast(prng.rand64() % moves.len)]);
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

fn king_captures(pos: *const position.Position, moves: []const types.Move) MoveList {
    var out: MoveList = .{};
    for (moves) |move| {
        if (move.is_capture() and pos.mailbox[move.from].piece_type() == .King) out.append(move);
    }
    return out;
}

fn expect_same_king_captures(_: void, pos: *position.Position, legal: []const types.Move) !void {
    var captures: MoveList = .{};
    switch (pos.turn) {
        .White => pos.generate_q_moves(.White, &captures),
        .Black => pos.generate_q_moves(.Black, &captures),
    }
    try expectEqualSlices(types.Move, king_captures(pos, legal).items(), king_captures(pos, captures.items()).items());
}

test "movegen: the capture generator finds the legal generator's king captures in the same order" {
    try walk_random_games(0xC0DE_CAFE_F00D_0BAD_5EED, 40, 160, {}, expect_same_king_captures);
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

fn occupancy_of_pieces(pos: *const position.Position) [types.N_COLORS]types.Bitboard {
    var occupancy: [types.N_COLORS]types.Bitboard = .{ 0, 0 };
    for (pos.mailbox, 0..) |piece, sq| {
        if (piece != types.Piece.NO_PIECE) occupancy[@backingInt(piece.color())] |= types.SquareIndexBB[sq];
    }
    return occupancy;
}

fn attackers_of_king_to_move(pos: *const position.Position) types.Bitboard {
    return switch (pos.turn) {
        .White => pos.king_attackers(.White),
        .Black => pos.king_attackers(.Black),
    };
}

fn expect_moves_round_trip(fresh: *position.Position, pos: *position.Position, moves: []const types.Move) !void {
    const fen = pos.basic_fen(std.testing.allocator);
    defer std.testing.allocator.free(fen);
    fresh.set_fen(fen);
    try expectEqual(fresh.keys(), pos.keys());
    try expectEqual(occupancy_of_pieces(pos), pos.occupancy);
    try expectEqual(attackers_of_king_to_move(pos), pos.history[pos.game_ply].king_attackers);

    const before = Snapshot.of(pos);
    for (moves) |move| {
        support.play(pos, move);
        support.undo(pos, move);
        try expectEqual(before, Snapshot.of(pos));
    }
    if (before.undo.king_attackers == 0) {
        pos.play_null_move();
        try expectEqual(attackers_of_king_to_move(pos), pos.history[pos.game_ply].king_attackers);
        pos.undo_null_move();
        try expectEqual(before, Snapshot.of(pos));
    }
}

test "make/unmake: keys, occupancy and king attackers match the board, and undoing any move restores the position" {
    const fresh = try support.new_position();
    defer support.destroy_position(fresh);
    try walk_random_games(0x0D0_0BAD_F00D_A11_0E5, 6, 120, fresh, expect_moves_round_trip);
}

fn set_up(pos: *position.Position, fen: []const u8) MoveList {
    pos.set_fen(fen);
    return pos.legal_moves();
}

const SeeCase = struct {
    fen: []const u8,
    move: []const u8,
    /// What the exchange is worth: it passes this bound and fails the next.
    value: i32,
};

const SEE_CASES = [_]SeeCase{
    // The bishop is pinned by the queen and takes on the line of the pin; the rook behind it
    // then makes the queen's recapture a loss.
    .{ .fen = "3r3k/6b1/8/8/8/5N2/8/Q6K w - - 0 1", .move = "f3d4", .value = -308 },
    // The pawn's recapture leaves the rook alone between its king and the bishop, so the
    // rook is pinned for the rest of the exchange.
    .{ .fen = "7k/6r1/5p2/6n1/8/5N2/8/BK4R1 w - - 0 1", .move = "f3g5", .value = 93 },
    // En passant: the bishop behind the capturing pawn joins the exchange.
    .{ .fen = "4k3/3p4/8/2pP4/8/8/6B1/4K3 w - c6 0 2", .move = "d5c6", .value = 93 },
    // The king is the last attacker of an undefended rook, ...
    .{ .fen = "4k3/8/8/8/8/3r4/3PK3/8 b - - 0 1", .move = "d3d2", .value = 93 - 521 },
    // ... of a rook defended through the square it came from, ...
    .{ .fen = "3rk3/8/8/8/8/3r4/3PK3/8 b - - 0 1", .move = "d3d2", .value = 93 },
    // ... and of a rook that the other king defends.
    .{ .fen = "8/8/8/8/8/2k5/3pK3/3R4 w - - 0 1", .move = "d1d2", .value = 93 },
};

test "see: pins on the capture line, pins that appear during the exchange, en passant and king recaptures" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    var prng = utils.PRNG.new(0x5EE_CA5E_5EED);

    for (SEE_CASES) |case| {
        const moves = set_up(pos, case.fen);
        try expect_see_matches_reference(&prng, pos, moves.items());

        const move = types.Move.new_from_string(pos, case.move);
        try expect(move.to_u16() != 0);
        try expect(see.see_threshold(pos, move, case.value));
        try expect(!see.see_threshold(pos, move, case.value + 1));
    }
}

fn squares(comptime list: []const types.Square) types.Bitboard {
    var bb: types.Bitboard = 0;
    for (list) |sq| bb |= types.SquareIndexBB[sq.index()];
    return bb;
}

test "fen: set_fen finds the pieces attacking the king of the side to move" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    const cases = [_]struct { fen: []const u8, attackers: types.Bitboard }{
        .{ .fen = types.DEFAULT_FEN, .attackers = 0 },
        .{ .fen = "rnb1kbnr/pppp1ppp/8/4p3/4PP1q/8/PPPP2PP/RNBQKBNR w KQkq - 1 3", .attackers = squares(&.{.h4}) },
        .{ .fen = "4k3/8/8/8/8/5n2/8/r3K3 w - - 0 1", .attackers = squares(&.{ .a1, .f3 }) },
        .{ .fen = "4k3/4R3/8/8/8/8/8/4K3 b - - 0 1", .attackers = squares(&.{.e7}) },
    };
    for (cases) |case| {
        pos.set_fen(case.fen);
        try expectEqual(case.attackers, pos.history[pos.game_ply].king_attackers);
        const attacked = switch (pos.turn) {
            .White => pos.in_check(.White),
            .Black => pos.in_check(.Black),
        };
        try expectEqual(case.attackers != 0, attacked);
    }
}

test "make/unmake: castling in which king and rook swap squares" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const fresh = try support.new_position();
    defer support.destroy_position(fresh);

    const cases = [_]struct { fen: []const u8, king_to: types.Square, rook_to: types.Square }{
        .{ .fen = "4k3/8/8/8/8/8/8/5KR1 w G - 0 1", .king_to = .g1, .rook_to = .f1 },
        .{ .fen = "4k3/8/8/8/8/8/8/2RK4 w C - 0 1", .king_to = .c1, .rook_to = .d1 },
        .{ .fen = "5kr1/8/8/8/8/8/8/4K3 b g - 0 1", .king_to = .g8, .rook_to = .f8 },
    };
    for (cases) |case| {
        const moves = set_up(pos, case.fen);
        try expect_moves_round_trip(fresh, pos, moves.items());

        const castle = for (moves.items()) |move| {
            if (move.is_castle()) break move;
        } else return error.TestExpectedCastlingMove;
        const mover = pos.turn;
        support.play(pos, castle);
        try expectEqual(types.Piece.new(mover, .King), pos.mailbox[case.king_to.index()]);
        try expectEqual(types.Piece.new(mover, .Rook), pos.mailbox[case.rook_to.index()]);
        try expectEqual(@as(usize, 3), @popCount(pos.occupancy[0] | pos.occupancy[1]));

        try expect_moves_round_trip(fresh, pos, pos.legal_moves().items());
    }
}
