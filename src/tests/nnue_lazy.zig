const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const zobrist = @import("../chess/zobrist.zig");
const nnue = @import("../engine/nnue.zig");
const support = @import("support.zig");

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const MoveList = std.array_list.Managed(types.Move);

const FENS = [_][]const u8{
    types.DEFAULT_FEN,
    "r3k2r/pppq1ppp/2npbn2/2b1p3/2B1P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 0 1",
    "4k3/1P4P1/8/3pP3/8/8/1p4p1/4K3 w - d6 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2",
    "bnrqkrnb/pppppppp/8/8/8/8/PPPPPPPP/BNRQKRNB w FCfc - 0 1",
};

fn expect_matches_rebuild(pos: *position.Position, reference: *position.Position) !void {
    reference.copy_game_state(pos);
    reference.rebuild_evaluation();

    const actual = pos.evaluator.nnue_evaluator.accumulator(pos);
    const expected = reference.evaluator.nnue_evaluator.accumulator(reference);
    try expectEqualSlices(i16, &expected.white, &actual.white);
    try expectEqualSlices(i16, &expected.black, &actual.black);

    inline for (.{ types.Color.White, types.Color.Black }) |turn| {
        const uncached = reference.evaluator.nnue_evaluator.evaluate_uncached(turn, reference);
        try expectEqual(uncached, pos.evaluator.nnue_evaluator.evaluate_uncached(turn, pos));
        try expectEqual(uncached, pos.evaluator.nnue_evaluator.evaluate_comptime(turn, pos));
        try expectEqual(uncached, pos.evaluator.nnue_evaluator.evaluate_comptime(turn, pos));
    }
}

test "lazy accumulators: a random walk of moves and take-backs matches a rebuild wherever it is evaluated" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const reference = try support.new_position();
    defer support.destroy_position(reference);

    var storage: [256]types.Move = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&storage));
    var moves = try MoveList.initCapacity(fba.allocator(), storage.len);
    var played: [96]types.Move = undefined;

    var prng = std.Random.DefaultPrng.init(0x1a2b_3c4d);
    const random = prng.random();

    for (FENS) |fen| {
        pos.set_fen(fen);
        var depth: usize = 0;
        for (0..1500) |_| {
            moves.clearRetainingCapacity();
            support.legal_moves(pos, &moves);
            const go_back = depth == played.len or moves.items.len == 0 or (depth > 0 and random.uintLessThan(u8, 5) < 2);
            if (go_back) {
                if (depth == 0) break;
                depth -= 1;
                support.undo(pos, played[depth]);
            } else {
                played[depth] = moves.items[random.uintLessThan(usize, moves.items.len)];
                support.play(pos, played[depth]);
                depth += 1;
            }
            if (random.uintLessThan(u8, 4) == 0) try expect_matches_rebuild(pos, reference);
        }
        try expect_matches_rebuild(pos, reference);
    }
}

test "lazy accumulators: frames that were never evaluated survive the stack running out" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const reference = try support.new_position();
    defer support.destroy_position(reference);

    pos.set_fen(types.DEFAULT_FEN);
    const shuffle = [_][]const u8{ "g1f3", "g8f6", "f3g1", "f6g8" };
    for (0..2 * nnue.STACK_CAP + 3) |ply| {
        support.play(pos, types.Move.new_from_string(pos, shuffle[ply % shuffle.len]));
    }
    try expect_matches_rebuild(pos, reference);
}

test "lazy accumulators: a piece edited outside a move invalidates the frame" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const reference = try support.new_position();
    defer support.destroy_position(reference);

    pos.set_fen("4k3/8/8/8/8/8/8/4K3 w - - 0 1");
    try expect_matches_rebuild(pos, reference);
    pos.add_piece(types.Piece.WHITE_QUEEN, types.Square.d4);
    try expect_matches_rebuild(pos, reference);
    pos.remove_piece(types.Square.d4);
    try expect_matches_rebuild(pos, reference);
}

test "evaluation cache: the two sides' outputs of one position do not collide" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("r1bq1rk1/ppp2ppp/2np1n2/2b1p3/4P3/2NP1N2/PPP1BPPP/R1BQ1RK1 w - - 0 8");
    const evaluator = &pos.evaluator.nnue_evaluator;
    const white = evaluator.evaluate_uncached(.White, pos);
    const black = evaluator.evaluate_uncached(.Black, pos);
    try std.testing.expect(white != black);
    for (0..2) |_| {
        try expectEqual(white, evaluator.evaluate_comptime(.White, pos));
        try expectEqual(black, evaluator.evaluate_comptime(.Black, pos));
    }

    pos.turn = .Black;
    pos.hash ^= zobrist.TurnHash;
    try expectEqual(white, evaluator.evaluate_comptime(.White, pos));
    try expectEqual(black, evaluator.evaluate_comptime(.Black, pos));
}
