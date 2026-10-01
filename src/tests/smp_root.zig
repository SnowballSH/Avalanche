const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const search = @import("../engine/search.zig");
const tt = @import("../engine/tt.zig");
const support = @import("support.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn play(pos: *position.Position, text: []const u8) !void {
    const move = types.Move.new_from_string(pos, text);
    try expect(move.to_u16() != 0);
    switch (pos.turn) {
        .White => pos.play_move(.White, move),
        .Black => pos.play_move(.Black, move),
    }
}

fn expect_same_evaluation(a: *const position.Position, b: *const position.Position) !void {
    const acc_a = a.evaluator.nnue_evaluator.current();
    const acc_b = b.evaluator.nnue_evaluator.current();
    try expect(std.mem.eql(i16, &acc_a.white, &acc_b.white));
    try expect(std.mem.eql(i16, &acc_a.black, &acc_b.black));
    try expectEqual(a.evaluator.nnue_evaluator.evaluate(a.turn, a), b.evaluator.nnue_evaluator.evaluate(b.turn, b));
}

fn expect_matches_fresh(pos: *position.Position) !void {
    const fen = pos.basic_fen(std.testing.allocator);
    defer std.testing.allocator.free(fen);
    const fresh = try support.new_position();
    defer support.destroy_position(fresh);
    fresh.set_fen(fen);
    try expectEqual(fresh.hash, pos.hash);
    try expectEqual(fresh.pawn_hash, pos.pawn_hash);
    try expectEqual(fresh.nonpawn_hash, pos.nonpawn_hash);
    try expectEqual(fresh.castling_rights(), pos.castling_rights());
    try expect_same_evaluation(fresh, pos);
}

fn legal_moves(pos: *position.Position, storage: *[256]types.Move) []types.Move {
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(storage));
    var list = std.array_list.Managed(types.Move).initCapacity(fba.allocator(), storage.len) catch unreachable;
    switch (pos.turn) {
        .White => pos.generate_legal_moves(.White, &list),
        .Black => pos.generate_legal_moves(.Black, &list),
    }
    return list.items;
}

const RootCase = struct { fen: []const u8, moves: []const []const u8 };

// One helper adopts every root in turn, so each rebuild runs against a Finny
// table warmed by unrelated positions. The king walks cross input buckets and
// the mirroring boundary.
const root_cases = [_]RootCase{
    .{ .fen = types.DEFAULT_FEN, .moves = &.{} },
    .{ .fen = types.DEFAULT_FEN, .moves = &.{ "e2e4", "e7e5", "e1e2", "e8e7", "e2d3", "e7d6" } },
    .{ .fen = "r3k2r/pppq1ppp/2npbn2/2b1p3/2B1P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 4 8", .moves = &.{ "e1c1", "e8g8", "c1b1", "g8h8" } },
    .{ .fen = "8/5k2/3p4/1p1Pp2p/pP2Pp1P/P4P1K/8/8 b - - 99 50", .moves = &.{ "f7e8", "h3g2", "e8d8", "g2f1", "d8c7" } },
    .{ .fen = "4k3/8/8/8/8/8/4P3/R3K2R w KQ - 0 1", .moves = &.{ "e1g1", "e8d7", "g1h1", "d7c6", "h1g1", "c6b5" } },
    .{ .fen = types.DEFAULT_FEN, .moves = &.{"g1f3"} },
};

test "smp root: adopted root evaluates like a fresh set_fen" {
    support.init_tables();

    const main = try support.new_position();
    defer support.destroy_position(main);
    const helper = try support.new_position();
    defer support.destroy_position(helper);

    for (root_cases) |case| {
        main.set_fen(case.fen);
        for (case.moves) |move| try play(main, move);

        helper.copy_game_state(main);
        helper.rebuild_evaluation();

        try expectEqual(main.hash, helper.hash);
        try expectEqual(main.pawn_hash, helper.pawn_hash);
        try expectEqual(main.nonpawn_hash, helper.nonpawn_hash);
        try expectEqual(main.turn, helper.turn);
        try expectEqual(main.history[main.game_ply], helper.history[helper.game_ply]);
        try expect_same_evaluation(main, helper);
        try expect_matches_fresh(helper);

        // Moves from the adopted root update incrementally and unwind back to it.
        var storage: [256]types.Move = undefined;
        for (legal_moves(helper, &storage)) |move| {
            switch (helper.turn) {
                .White => helper.play_move(.White, move),
                .Black => helper.play_move(.Black, move),
            }
            try expect_matches_fresh(helper);
            switch (helper.turn) {
                .White => helper.undo_move(.Black, move),
                .Black => helper.undo_move(.White, move),
            }
        }
        try expectEqual(main.hash, helper.hash);
        try expect_same_evaluation(main, helper);
    }
}

test "smp root: helper sees a repetition from before the root" {
    support.init_search();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN);

    var main = search.Searcher.new();
    defer main.deinit();
    var helper = search.Searcher.new();
    defer helper.deinit();
    // Leftover history from an earlier, longer game must not survive.
    try helper.hash_history.appendNTimes(pos.hash, 40);

    try main.hash_history.append(pos.hash);
    for ([_][]const u8{ "g1f3", "g8f6", "f3g1" }) |move| {
        try play(pos, move);
        try main.hash_history.append(pos.hash);
    }

    helper.adopt_root(&main, pos);
    helper.root_board.rebuild_evaluation();
    try expect(!helper.is_draw(helper.root_board, false));

    try play(pos, "f6g8");
    try main.hash_history.append(pos.hash);

    helper.adopt_root(&main, pos);
    helper.root_board.rebuild_evaluation();
    try expectEqual(main.hash_history.items.len, helper.hash_history.items.len);
    try expect(helper.is_draw(helper.root_board, false));
    try expect(!helper.is_draw(helper.root_board, true));
}

test "smp root: multi-threaded search returns legal moves and helpers end on the root" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    platform.io = std.testing.io;
    support.init_search();
    tt.GlobalTT.reset(16);

    search.set_helper_count(3);
    defer search.set_helper_count(0);
    try expectEqual(@as(usize, 3), search.helper_count());

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    var s = search.Searcher.new();
    defer s.deinit();
    s.force_thinking = true;
    s.silent_output = true;

    var helper_nodes: u64 = 0;
    // Consecutive searches from different roots, as in a game.
    for (root_cases) |case| {
        tt.GlobalTT.clear();
        pos.set_fen(case.fen);
        s.hash_history.clearRetainingCapacity();
        try s.hash_history.append(pos.hash);
        for (case.moves) |move| {
            try play(pos, move);
            try s.hash_history.append(pos.hash);
        }
        const root_hash = pos.hash;

        s.stop = false;
        switch (pos.turn) {
            .White => _ = s.iterative_deepening(pos, .White, 9),
            .Black => _ = s.iterative_deepening(pos, .Black, 9),
        }

        try expectEqual(root_hash, pos.hash);
        var storage: [256]types.Move = undefined;
        var legal = false;
        for (legal_moves(pos, &storage)) |move| {
            if (move.to_u16() == s.best_move.to_u16()) legal = true;
        }
        try expect(legal);

        for (0..search.helper_count()) |i| {
            const h = search.helper_pool.worker(i).searcher;
            helper_nodes += h.nodes;
            try expectEqual(root_hash, h.root_board.hash);
            try expectEqual(s.hash_history.items.len, h.hash_history.items.len);
            try expectEqual(@as(u16, 0), h.root_board.evaluator.nnue_evaluator.depth);
            try expect_matches_fresh(h.root_board);
        }
    }
    try expect(helper_nodes > 0);
}
