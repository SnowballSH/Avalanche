const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const utils = @import("../chess/utils.zig");
const search = @import("../engine/search.zig");
const support = @import("support.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const WALK_FENS = [_][]const u8{
    types.DEFAULT_FEN,
    types.KIWIPETE_FEN,
    types.ENDGAME_FEN,
    "rnbqkbnr/pp1ppppp/8/2pP4/8/8/PPP1PPPP/RNBQKBNR w KQkq c6 0 3",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "8/PPP4k/8/8/8/8/4Kppp/8 w - - 0 1",
    "4k3/1p1p1p1p/8/P1P1P1P1/1p1p1p1p/8/P1P1P1P1/4K3 w - - 0 1",
    "qnbnr1kr/ppp1b1pp/4p3/3p1p2/8/2NPP3/PPP1BPPP/QNB1R1KR w HEhe - 1 9",
    "1r2k2r/pppppppp/8/8/8/8/PPPPPPPP/R2K3R w HAhb - 0 1",
    "rk5r/pppppppp/8/8/8/8/PPPPPPPP/RK5R w HAha - 0 1",
};

const WALKS_PER_FEN = 24;
const MAX_WALK_PLY = 96;

fn expect_keys_match(pos: *const position.Position) !void {
    try expectEqual(pos.compute_pawn_hash(), pos.pawn_hash);
    try expectEqual(pos.compute_nonpawn_hash(.White), pos.nonpawn_hash[0]);
    try expectEqual(pos.compute_nonpawn_hash(.Black), pos.nonpawn_hash[1]);
}

test "pawn and non-pawn keys: incremental match recomputed over random move sequences" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const fresh = try support.new_position();
    defer support.destroy_position(fresh);

    var prng = utils.PRNG.new(0x5EED_0F_C0_77_EC_71_0B);
    var en_passants: usize = 0;
    var promotions: usize = 0;
    var pawn_captures: usize = 0;
    var piece_captures: usize = 0;
    var castles: usize = 0;

    for (WALK_FENS) |fen| {
        var walk: usize = 0;
        while (walk < WALKS_PER_FEN) : (walk += 1) {
            pos.set_fen(fen);
            const root_pawn_hash = pos.pawn_hash;
            const root_nonpawn_hash = pos.nonpawn_hash;
            try expect_keys_match(pos);

            var played: [MAX_WALK_PLY]types.Move = undefined;
            var ply: usize = 0;
            while (ply < MAX_WALK_PLY) : (ply += 1) {
                const moves = pos.legal_moves();
                if (moves.len == 0) break;

                const move = moves.items()[prng.rand64() % moves.len];
                switch (move.get_flags()) {
                    .EN_PASSANT => en_passants += 1,
                    .OO, .OOO => castles += 1,
                    else => {},
                }
                if (move.is_promotion()) promotions += 1;
                const victim = pos.mailbox[move.to];
                if (victim == types.Piece.WHITE_PAWN or victim == types.Piece.BLACK_PAWN) {
                    pawn_captures += 1;
                } else if (victim != types.Piece.NO_PIECE) {
                    piece_captures += 1;
                }

                support.play(pos, move);
                played[ply] = move;
                try expect_keys_match(pos);

                const board_fen = pos.basic_fen(std.testing.allocator);
                defer std.testing.allocator.free(board_fen);
                fresh.set_fen(board_fen);
                try expectEqual(fresh.pawn_hash, pos.pawn_hash);
                try expectEqual(fresh.nonpawn_hash, pos.nonpawn_hash);
            }

            while (ply > 0) {
                ply -= 1;
                support.undo(pos, played[ply]);
                try expect_keys_match(pos);
            }
            try expectEqual(root_pawn_hash, pos.pawn_hash);
            try expectEqual(root_nonpawn_hash, pos.nonpawn_hash);
        }
    }

    try expect(en_passants > 0);
    try expect(promotions > 0);
    try expect(pawn_captures > 0);
    try expect(piece_captures > 0);
    try expect(castles > 0);
}

test "pawn key: ignores pieces other than pawns" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen(types.DEFAULT_FEN);
    const start = pos.pawn_hash;
    try expect(start != 0);

    const knight = types.Move.new_from_string(pos, "g1f3");
    pos.play_move(.White, knight);
    try expectEqual(start, pos.pawn_hash);

    const pawn = types.Move.new_from_string(pos, "e7e5");
    pos.play_move(.Black, pawn);
    try expect(start != pos.pawn_hash);
}

test "non-pawn key: tracks only its own color's pieces" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen(types.DEFAULT_FEN);
    const white = pos.nonpawn_hash[0];
    const black = pos.nonpawn_hash[1];
    try expect(white != 0 and black != 0 and white != black);

    const pawn = types.Move.new_from_string(pos, "e2e4");
    pos.play_move(.White, pawn);
    try expectEqual(white, pos.nonpawn_hash[0]);
    try expectEqual(black, pos.nonpawn_hash[1]);

    const knight = types.Move.new_from_string(pos, "g8f6");
    pos.play_move(.Black, knight);
    try expectEqual(white, pos.nonpawn_hash[0]);
    try expect(black != pos.nonpawn_hash[1]);
}

test "correction history: gravity keeps entries within the limit" {
    var entry: i16 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        search.update_correction(&entry, 888888, -888888, 255);
        try expect(entry <= search.CORRHIST_LIMIT);
    }
    try expectEqual(@as(i16, search.CORRHIST_LIMIT), entry);

    i = 0;
    while (i < 1000) : (i += 1) {
        search.update_correction(&entry, -888888, 888888, 255);
        try expect(entry >= -search.CORRHIST_LIMIT);
    }
    try expectEqual(@as(i16, -search.CORRHIST_LIMIT), entry);

    var prng = utils.PRNG.new(0xC0_44_EC_71_0B);
    i = 0;
    while (i < 100000) : (i += 1) {
        const r = prng.rand64();
        const diff: i32 = @as(i32, @intCast(r % 4001)) - 2000;
        const depth: usize = @intCast((r >> 32) % 64 + 1);
        search.update_correction(&entry, diff, 0, depth);
        try expect(entry <= search.CORRHIST_LIMIT and entry >= -search.CORRHIST_LIMIT);
    }
}

test "correction history: a consistent error converges instead of saturating" {
    var pawn: i16 = 0;
    var nonpawn_white: i16 = 0;
    var nonpawn_black: i16 = 0;
    const raw_eval: i32 = 40;
    const true_value: i32 = 50;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const corrected = raw_eval + search.weighted_correction(pawn, nonpawn_white, nonpawn_black);
        search.update_correction(&pawn, true_value, corrected, 8);
        search.update_correction(&nonpawn_white, true_value, corrected, 8);
        search.update_correction(&nonpawn_black, true_value, corrected, 8);
    }
    try expectEqual(true_value, raw_eval + search.weighted_correction(pawn, nonpawn_white, nonpawn_black));
}
