const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const zobrist = @import("../chess/zobrist.zig");
const hce = @import("../engine/hce.zig");
const nnue = @import("../engine/nnue.zig");
const support = @import("support.zig");

const expectEqual = std.testing.expectEqual;

const FENS = [_][]const u8{
    types.DEFAULT_FEN,
    "r3k2r/pppq1ppp/2npbn2/2b1p3/2B1P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 0 1",
    "4k3/1P4P1/8/3pP3/8/8/1p4p1/4K3 w - d6 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2",
    "bnrqkrnb/pppppppp/8/8/8/8/PPPPPPPP/BNRQKRNB w FCfc - 0 1",
};

fn expect_matches_rebuild(pos: *position.Position, reference: *position.Position) !void {
    try support.expect_nnue_matches_rebuild(pos, reference);

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

    var played: [96]types.Move = undefined;

    var prng = std.Random.DefaultPrng.init(0x1a2b_3c4d);
    const random = prng.random();

    for (FENS) |fen| {
        pos.set_fen(fen);
        var depth: usize = 0;
        for (0..1500) |_| {
            const moves = pos.legal_moves();
            const go_back = depth == played.len or moves.len == 0 or (depth > 0 and random.uintLessThan(u8, 5) < 2);
            if (go_back) {
                if (depth == 0) break;
                depth -= 1;
                support.undo(pos, played[depth]);
            } else {
                played[depth] = moves.items()[random.uintLessThan(usize, moves.len)];
                support.play(pos, played[depth]);
                depth += 1;
            }
            if (random.uintLessThan(u8, 4) == 0) try expect_matches_rebuild(pos, reference);
        }
        try expect_matches_rebuild(pos, reference);
    }
}

const Line = struct {
    fen: []const u8,
    moves: []const []const u8,
};

const LINES = [_]Line{
    .{ .fen = types.DEFAULT_FEN, .moves = &.{ "e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "e1g1", "f6e4" } },
    // Both kings leave their buckets in the middle of the line.
    .{ .fen = "4k3/8/8/8/8/8/3p3P/4K3 w - - 0 1", .moves = &.{ "e1d2", "e8d7", "h2h4", "d7c6", "d2c3", "c6b5", "h4h5" } },
    .{ .fen = "4k3/1P4P1/8/3pP3/8/8/1p4p1/4K3 w - d6 0 1", .moves = &.{ "e5d6", "b2b1q", "e1e2", "g2g1n", "e2d2", "e8d7", "g7g8q" } },
};

/// Plays `moves` with every position evaluated, so that the cache knows them, and takes them back.
fn rehearse(pos: *position.Position, moves: []const []const u8) !void {
    var played: [16]types.Move = undefined;
    for (moves, 0..) |text, ply| {
        played[ply] = try support.play_uci(pos, text);
        _ = hce.evaluate_nnue(pos);
    }
    var ply = moves.len;
    while (ply > 0) : (ply -= 1) support.undo(pos, played[ply - 1]);
}

test "lazy accumulators: a replayed line stays a record until it is needed, then matches a rebuild at every depth" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const reference = try support.new_position();
    defer support.destroy_position(reference);

    for (LINES) |line| {
        for (1..line.moves.len + 1) |walk_length| {
            pos.set_fen(line.fen);
            try rehearse(pos, line.moves);

            var played: [16]types.Move = undefined;
            for (line.moves[0..walk_length], 0..) |text, ply| {
                played[ply] = try support.play_uci(pos, text);
                try std.testing.expect(!pos.evaluator.nnue_evaluator.frame_is_computed());
            }
            try expect_matches_rebuild(pos, reference);
            try std.testing.expect(pos.evaluator.nnue_evaluator.frame_is_computed());

            var ply = walk_length;
            while (ply > 0) : (ply -= 1) {
                support.undo(pos, played[ply - 1]);
                try expect_matches_rebuild(pos, reference);
            }
        }
    }
}

test "lazy accumulators: a null move on a frame that is still a record is evaluated from that frame" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const reference = try support.new_position();
    defer support.destroy_position(reference);

    const line = LINES[0];
    pos.set_fen(line.fen);
    try rehearse(pos, line.moves);
    for (line.moves[0..5]) |text| _ = try support.play_uci(pos, text);
    try std.testing.expect(!pos.evaluator.nnue_evaluator.frame_is_computed());

    pos.play_null_move();
    try expect_matches_rebuild(pos, reference);
    pos.undo_null_move();
    try expect_matches_rebuild(pos, reference);
}

test "lazy accumulators: frames that are still records survive the stack running out" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const reference = try support.new_position();
    defer support.destroy_position(reference);

    const shuffle = [_][]const u8{ "g1f3", "g8f6", "f3g1", "f6g8" };
    pos.set_fen(types.DEFAULT_FEN);
    try rehearse(pos, &shuffle);

    var records: usize = 0;
    for (0..2 * nnue.STACK_CAP + 3) |ply| {
        _ = try support.play_uci(pos, shuffle[ply % shuffle.len]);
        records += @intFromBool(!pos.evaluator.nnue_evaluator.frame_is_computed());
    }
    try std.testing.expect(records > 2 * nnue.STACK_CAP);
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
