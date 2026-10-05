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

pub fn legal_moves(pos: *position.Position, list: *std.array_list.Managed(types.Move)) void {
    switch (pos.turn) {
        .White => pos.generate_legal_moves(.White, list),
        .Black => pos.generate_legal_moves(.Black, list),
    }
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

/// The network's output for the side to move, computed by the head and not taken from the evaluation cache.
pub fn network_output(pos: *position.Position) i32 {
    return switch (pos.turn) {
        inline else => |turn| pos.evaluator.nnue_evaluator.evaluate_uncached(turn, pos),
    };
}
