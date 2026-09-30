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

fn legal_moves(pos: *position.Position, list: *std.array_list.Managed(types.Move)) void {
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

fn undo(pos: *position.Position, move: types.Move) void {
    switch (pos.turn) {
        .White => pos.undo_move(.Black, move),
        .Black => pos.undo_move(.White, move),
    }
}

test "pawn key: incremental matches recomputed over random move sequences" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const fresh = try support.new_position();
    defer support.destroy_position(fresh);

    var prng = utils.PRNG.new(0x5EED_0F_C0_77_EC_71_0B);
    var en_passants: usize = 0;
    var promotions: usize = 0;
    var pawn_captures: usize = 0;
    var castles: usize = 0;

    for (WALK_FENS) |fen| {
        var walk: usize = 0;
        while (walk < WALKS_PER_FEN) : (walk += 1) {
            pos.set_fen(fen);
            const root_pawn_hash = pos.pawn_hash;
            try expectEqual(pos.compute_pawn_hash(), root_pawn_hash);

            var played: [MAX_WALK_PLY]types.Move = undefined;
            var ply: usize = 0;
            while (ply < MAX_WALK_PLY) : (ply += 1) {
                var storage: [256]types.Move = undefined;
                var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&storage));
                var moves = try std.array_list.Managed(types.Move).initCapacity(fba.allocator(), storage.len);
                legal_moves(pos, &moves);
                if (moves.items.len == 0) break;

                const move = moves.items[prng.rand64() % moves.items.len];
                switch (move.get_flags()) {
                    .EN_PASSANT => en_passants += 1,
                    .OO, .OOO => castles += 1,
                    else => {},
                }
                if (move.is_promotion()) promotions += 1;
                const victim = pos.mailbox[move.to];
                if (victim == types.Piece.WHITE_PAWN or victim == types.Piece.BLACK_PAWN) pawn_captures += 1;

                play(pos, move);
                played[ply] = move;
                try expectEqual(pos.compute_pawn_hash(), pos.pawn_hash);

                const board_fen = pos.basic_fen(std.testing.allocator);
                defer std.testing.allocator.free(board_fen);
                fresh.set_fen(board_fen);
                try expectEqual(fresh.pawn_hash, pos.pawn_hash);
            }

            while (ply > 0) {
                ply -= 1;
                undo(pos, played[ply]);
                try expectEqual(pos.compute_pawn_hash(), pos.pawn_hash);
            }
            try expectEqual(root_pawn_hash, pos.pawn_hash);
        }
    }

    try expect(en_passants > 0);
    try expect(promotions > 0);
    try expect(pawn_captures > 0);
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
    var entry: i16 = 0;
    const raw_eval: i32 = 40;
    const true_value: i32 = 50;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const corrected = raw_eval + @divTrunc(@as(i32, entry), search.CORRHIST_GRAIN);
        search.update_correction(&entry, true_value, corrected, 8);
    }
    try expectEqual(true_value, raw_eval + @divTrunc(@as(i32, entry), search.CORRHIST_GRAIN));
}
