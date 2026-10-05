const std = @import("std");
const tables = @import("../chess/tables.zig");
const zobrist = @import("../chess/zobrist.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const weights = @import("../engine/weights.zig");
const cuckoo = @import("../chess/cuckoo.zig");
const search = @import("../engine/search.zig");

pub fn init_tables() void {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
}

pub fn init_search() void {
    init_tables();
    cuckoo.init();
    search.init_lmr();
}

pub fn new_position() !*position.Position {
    const pos = try std.testing.allocator.create(position.Position);
    pos.init();
    return pos;
}

pub fn destroy_position(pos: *position.Position) void {
    pos.deinit();
    std.testing.allocator.destroy(pos);
}

pub fn play(pos: *position.Position, move: types.Move) void {
    switch (pos.turn) {
        .White => pos.play_move(.White, move),
        .Black => pos.play_move(.Black, move),
    }
}

/// Takes back `move`, the last one played.
pub fn undo(pos: *position.Position, move: types.Move) void {
    switch (pos.turn) {
        .White => pos.undo_move(.Black, move),
        .Black => pos.undo_move(.White, move),
    }
}

/// Plays the legal move written as `text` in UCI notation.
pub fn play_uci(pos: *position.Position, text: []const u8) !types.Move {
    const move = types.Move.new_from_string(pos, text);
    try std.testing.expect(move.to_u16() != 0);
    play(pos, move);
    return move;
}

/// Checks the accumulators of `pos` against those `reference` builds for the same pieces.
pub fn expect_nnue_matches_rebuild(pos: *position.Position, reference: *position.Position) !void {
    reference.copy_game_state(pos);
    reference.rebuild_evaluation();

    const actual = pos.evaluator.nnue_evaluator.accumulator(pos);
    const expected = reference.evaluator.nnue_evaluator.accumulator(reference);
    try std.testing.expectEqualSlices(i16, &expected.white, &actual.white);
    try std.testing.expectEqualSlices(i16, &expected.black, &actual.black);
}

/// The reference is a new position: rebuilding `pos` itself would go through the Finny table under test.
pub fn expect_nnue_matches_fresh(pos: *position.Position) !void {
    const reference = try new_position();
    defer destroy_position(reference);
    try expect_nnue_matches_rebuild(pos, reference);
}

/// The network's output for the side to move, computed by the head and not taken from the evaluation cache.
pub fn network_output(pos: *position.Position) i32 {
    return switch (pos.turn) {
        inline else => |turn| pos.evaluator.nnue_evaluator.evaluate_uncached(turn, pos),
    };
}
