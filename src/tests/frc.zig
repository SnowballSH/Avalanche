const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const castling = @import("../chess/castling.zig");
const frc = @import("../chess/frc.zig");
const perft = @import("../chess/perft.zig");
const search = @import("../engine/search.zig");
const tt = @import("../engine/tt.zig");
const support = @import("support.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const PerftCase = struct {
    fen: []const u8,
    nodes: []const usize,
};

// Reference counts produced independently with python-chess (chess960=True).
const PERFT_SUITE = [_]PerftCase{
    .{ .fen = "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9", .nodes = &.{ 21, 528, 12189, 326672 } },
    .{ .fen = "2nnrbkr/p1qppppp/8/1ppb4/6PP/3PP3/PPP2P2/BQNNRBKR w HEhe - 1 9", .nodes = &.{ 21, 807, 18002, 667366 } },
    .{ .fen = "b1q1rrkb/pppppppp/3nn3/8/P7/1PPP4/4PPPP/BQNNRKRB w GE - 1 9", .nodes = &.{ 20, 479, 10471, 273318 } },
    .{ .fen = "qbbnnrkr/2pp2pp/p7/1p2pp2/8/P3PP2/1PPP1KPP/QBBNNR1R w hf - 0 9", .nodes = &.{ 22, 593, 13440, 382958 } },
    .{ .fen = "1nbbnrkr/p1p1ppp1/3p4/1p3P1p/3Pq2P/8/PPP1P1P1/QNBBNRKR w HFhf - 0 9", .nodes = &.{ 28, 1120, 31058, 1171749 } },
    .{ .fen = "qnbnr1kr/ppp1b1pp/4p3/3p1p2/8/2NPP3/PPP1BPPP/QNB1R1KR w HEhe - 1 9", .nodes = &.{ 29, 899, 26578, 824055 } },
    .{ .fen = "q1bnrkr1/ppppp2p/2n2p2/4b1p1/2NP4/8/PPP1PPPP/QNB1RRKB w ge - 1 9", .nodes = &.{ 30, 860, 24566, 732757 } },
    .{ .fen = "qbn1brkr/ppp1p1p1/2n4p/3p1p2/P7/6PP/QPPPPP2/1BNNBRKR w HFhf - 0 9", .nodes = &.{ 25, 635, 17054, 465806 } },
    .{ .fen = "qnnbbrkr/1p2ppp1/2pp3p/p7/1P5P/2NP4/P1P1PPP1/Q1NBBRKR w HFhf - 0 9", .nodes = &.{ 24, 572, 15243, 384260 } },
    .{ .fen = "qn1rbbkr/ppp2p1p/1n1pp1p1/8/3P4/P6P/1PP1PPPK/QNNRBB1R w hd - 2 9", .nodes = &.{ 28, 811, 23175, 679699 } },
    .{ .fen = "nrbbqknr/pppppppp/8/8/8/8/PPPPPPPP/NRBBQKNR w HBhb - 0 1", .nodes = &.{ 19, 361, 7813, 168483 } },
    .{ .fen = "rkrnnqbb/pppppppp/8/8/8/8/PPPPPPPP/BBQNNRKR w HFca - 0 1", .nodes = &.{ 20, 400, 9014, 202136 } },
};

// Positions isolating Chess960 castling corner cases.
const CASTLING_EDGE_SUITE = [_]PerftCase{
    // King already on its destination file; rook on the adjacent file.
    .{ .fen = "1k6/8/8/8/8/8/8/RK5R w A - 0 1", .nodes = &.{ 24, 70, 1872, 9476 } },
    // Different rook files per side, including Shredder "b" for an inner rook.
    .{ .fen = "1r2k2r/8/8/8/8/8/8/R2K3R w HAhb - 0 1", .nodes = &.{ 26, 585, 13736, 323269 } },
    .{ .fen = "rk5r/8/8/8/8/8/8/RK5R w HAha - 0 1", .nodes = &.{ 24, 479, 11099, 242723 } },
    // The castling rook shields the king destination from a rank attack.
    .{ .fen = "4k3/8/8/8/8/8/8/q3KR2 w F - 0 1", .nodes = &.{ 3, 68, 833, 18715 } },
    .{ .fen = "r3k1r1/8/8/8/8/8/8/1R1K3R w HBga - 0 1", .nodes = &.{ 25, 584, 14141, 341171 } },
    // An enemy rook sits outside the castling rook.
    .{ .fen = "4k3/8/8/8/8/8/8/rR3K1R w HB - 0 1", .nodes = &.{ 18, 204, 4872, 70481 } },
    // King and rook swap squares.
    .{ .fen = "4k3/8/8/8/8/8/8/5KR1 w G - 0 1", .nodes = &.{ 13, 58, 1033, 5689, 105989 } },
    .{ .fen = "4k3/8/8/8/8/8/8/1q3RK1 w F - 0 1", .nodes = &.{ 8, 142, 1687, 36496, 476384 } },
};

const init_tables = support.init_tables;
const new_position = support.new_position;
const destroy_position = support.destroy_position;

fn perft_from(pos: *position.Position, depth: u32) usize {
    return switch (pos.turn) {
        .White => perft.perft(.White, pos, depth),
        .Black => perft.perft(.Black, pos, depth),
    };
}

const legal_moves = support.legal_moves;
const play = support.play;
const undo = support.undo;

fn expect_perft_suite(suite: []const PerftCase) !void {
    init_tables();
    const pos = try new_position();
    defer destroy_position(pos);
    for (suite) |case| {
        for (case.nodes, 1..) |expected, depth| {
            pos.set_fen(case.fen);
            try expectEqual(expected, perft_from(pos, @intCast(depth)));
        }
    }
}

fn expect_nnue_matches_fresh(pos: *position.Position) !void {
    const reference = try new_position();
    defer destroy_position(reference);
    reference.copy_game_state(pos);
    reference.rebuild_evaluation();

    const actual = pos.evaluator.nnue_evaluator.accumulator(pos);
    const expected = reference.evaluator.nnue_evaluator.accumulator(reference);
    try std.testing.expectEqualSlices(i16, expected.white[0..], actual.white[0..]);
    try std.testing.expectEqualSlices(i16, expected.black[0..], actual.black[0..]);
}

fn format_move(move: types.Move, chess960: bool, buf: *[8]u8) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    move.uci_print(&writer, chess960);
    return writer.buffered();
}

test "frc: Scharnagl numbering yields 960 distinct legal back ranks" {
    try std.testing.expectEqualSlices(
        types.PieceType,
        &.{ .Rook, .Knight, .Bishop, .Queen, .King, .Bishop, .Knight, .Rook },
        &frc.back_rank(frc.STANDARD_INDEX),
    );

    var seen = std.AutoHashMap([8]types.PieceType, void).init(std.testing.allocator);
    defer seen.deinit();
    for (0..frc.N_POSITIONS) |index| {
        const rank = frc.back_rank(@intCast(index));
        var bishop_colors: u2 = 0;
        var rooks_left_of_king: usize = 0;
        var king_seen = false;
        for (rank, 0..) |piece, file| {
            switch (piece) {
                .Bishop => bishop_colors |= @as(u2, 1) << @intCast(file % 2),
                .Rook => if (!king_seen) {
                    rooks_left_of_king += 1;
                },
                .King => king_seen = true,
                else => {},
            }
        }
        try expectEqual(@as(u2, 0b11), bishop_colors);
        try expectEqual(@as(usize, 1), rooks_left_of_king);
        try seen.put(rank, {});
    }
    try expectEqual(@as(u32, frc.N_POSITIONS), seen.count());
}

test "frc: standard index reproduces the standard start position" {
    init_tables();
    const pos = try new_position();
    defer destroy_position(pos);

    var buf: [frc.FEN_CAPACITY]u8 = undefined;
    pos.set_fen(frc.frc_fen(frc.STANDARD_INDEX, &buf));
    const frc_hash = pos.hash;
    try expect(!pos.castling.is_chess960);

    pos.set_fen(types.DEFAULT_FEN);
    try expectEqual(pos.hash, frc_hash);
}

test "frc: perft suite matches reference counts" {
    try expect_perft_suite(&PERFT_SUITE);
}

test "frc: castling edge cases match reference counts" {
    try expect_perft_suite(&CASTLING_EDGE_SUITE);
}

test "frc: back ranks match the reference Scharnagl table" {
    const samples = [_]struct { index: u16, rank: []const u8 }{
        .{ .index = 0, .rank = "BBQNNRKR" },
        .{ .index = 1, .rank = "BQNBNRKR" },
        .{ .index = 2, .rank = "BQNNRBKR" },
        .{ .index = 100, .rank = "QBBNRNKR" },
        .{ .index = 359, .rank = "NRBKRQNB" },
        .{ .index = 518, .rank = "RNBQKBNR" },
        .{ .index = 700, .rank = "RBQKNNBR" },
        .{ .index = 959, .rank = "RKRNNQBB" },
    };
    for (samples) |sample| {
        var rank: [8]u8 = undefined;
        for (frc.back_rank(sample.index), &rank) |piece, *ch| {
            ch.* = types.PieceString[types.Piece.new(.White, piece).index()];
        }
        try expectEqualStrings(sample.rank, &rank);
    }
}

test "frc: double fischer random starts match reference perft" {
    init_tables();
    const pos = try new_position();
    defer destroy_position(pos);

    const cases = [_]struct { white: u16, black: u16, nodes: [4]usize }{
        .{ .white = 123, .black = 876, .nodes = .{ 20, 400, 8930, 196471 } },
        .{ .white = 0, .black = 959, .nodes = .{ 20, 400, 9014, 202136 } },
        .{ .white = 518, .black = 0, .nodes = .{ 20, 400, 8902, 199818 } },
        .{ .white = 305, .black = 650, .nodes = .{ 20, 380, 8419, 180597 } },
        // Both sides can castle on the first move (king and rook adjacent).
        .{ .white = 3, .black = 7, .nodes = .{ 21, 441, 10236, 233661 } },
    };
    var buf: [frc.FEN_CAPACITY]u8 = undefined;
    for (cases) |case| {
        for (case.nodes, 1..) |expected, depth| {
            pos.set_fen(frc.dfrc_fen(case.white, case.black, &buf));
            try expectEqual(@as(castling.Rights, 0b1111), pos.castling_rights());
            try expectEqual(expected, perft_from(pos, @intCast(depth)));
        }
    }
}

test "frc: incremental hash, fen and nnue agree with a fresh position after every move" {
    init_tables();
    const pos = try new_position();
    defer destroy_position(pos);
    const fresh = try new_position();
    defer destroy_position(fresh);

    for (PERFT_SUITE ++ CASTLING_EDGE_SUITE) |case| {
        pos.set_fen(case.fen);
        var storage: [256]types.Move = undefined;
        var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&storage));
        var moves = try std.array_list.Managed(types.Move).initCapacity(fba.allocator(), storage.len);
        legal_moves(pos, &moves);

        const root_hash = pos.hash;
        const root_board = pos.mailbox;
        for (moves.items) |move| {
            play(pos, move);
            const fen = pos.basic_fen(std.testing.allocator);
            defer std.testing.allocator.free(fen);
            fresh.set_fen(fen);
            try expectEqual(fresh.hash, pos.hash);
            try expectEqual(fresh.castling_rights(), pos.castling_rights());
            try expect_nnue_matches_fresh(pos);

            undo(pos, move);
            try expectEqual(root_hash, pos.hash);
            try std.testing.expectEqualSlices(types.Piece, &root_board, &pos.mailbox);
        }
    }
}

test "frc: fen castling field accepts Shredder and X-FEN and writes X-FEN" {
    init_tables();
    const pos = try new_position();
    defer destroy_position(pos);

    const cases = [_][2][]const u8{
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w HAha - 0 1", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" },
        .{ "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9", "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w KQkq - 2 9" },
        .{ "1r2k2r/8/8/8/8/8/8/R2K3R w HAhb - 0 1", "1r2k2r/8/8/8/8/8/8/R2K3R w KQkq - 0 1" },
        .{ "rr2k2r/8/8/8/8/8/8/R2K3R w KQb - 0 1", "rr2k2r/8/8/8/8/8/8/R2K3R w KQb - 0 1" },
        .{ "4k3/8/8/8/8/8/8/R3K2R w XYZ - 0 1", "4k3/8/8/8/8/8/8/R3K2R w - - 0 1" },
    };
    for (cases) |case| {
        pos.set_fen(case[0]);
        const fen = pos.basic_fen(std.testing.allocator);
        defer std.testing.allocator.free(fen);
        try expectEqualStrings(case[1], fen);
    }
}

test "frc: castling notation follows UCI_Chess960 and parses both forms" {
    init_tables();
    const pos = try new_position();
    defer destroy_position(pos);

    pos.set_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    var buf: [8]u8 = undefined;

    pos.uci_chess960 = false;
    const standard = types.Move.new_from_string(pos, "e1g1");
    try expect(standard.is_castle());
    try expectEqualStrings("e1g1", format_move(standard, pos.chess960_notation(), &buf));
    try expectEqual(standard.to_u16(), types.Move.new_from_string(pos, "e1h1").to_u16());

    pos.uci_chess960 = true;
    const king_takes_rook = types.Move.new_from_string(pos, "e1a1");
    try expect(king_takes_rook.is_castle());
    try expectEqualStrings("e1a1", format_move(king_takes_rook, pos.chess960_notation(), &buf));
    try expectEqual(@as(u16, 0), types.Move.new_from_string(pos, "e1c1").to_u16());

    pos.uci_chess960 = false;
    pos.set_fen("4k3/8/8/8/8/8/8/1R3K2 w B - 0 1");
    try expect(pos.chess960_notation());
    const b_file_castle = types.Move.new_from_string(pos, "f1b1");
    try expect(b_file_castle.is_castle());
    try expectEqualStrings("f1b1", format_move(b_file_castle, pos.chess960_notation(), &buf));
    try expect(!types.Move.new_from_string(pos, "f1c1").is_castle());
}

test "frc: search returns a legal move from a double fischer random position" {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    platform.io = io_threaded.io();

    init_tables();
    search.init_lmr();
    tt.GlobalTT.reset(16);
    search.NUM_THREADS = 0;

    const pos = try new_position();
    defer destroy_position(pos);
    var buf: [frc.FEN_CAPACITY]u8 = undefined;
    pos.set_fen(frc.dfrc_fen(123, 876, &buf));

    var searcher = search.Searcher.new();
    defer searcher.deinit();
    searcher.force_thinking = true;
    searcher.silent_output = true;
    _ = searcher.iterative_deepening(pos, .White, 6);

    var storage: [256]types.Move = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&storage));
    var moves = try std.array_list.Managed(types.Move).initCapacity(fba.allocator(), storage.len);
    legal_moves(pos, &moves);
    for (moves.items) |move| {
        if (move.to_u16() == searcher.best_move.to_u16()) return;
    }
    return error.TestUnexpectedResult;
}
