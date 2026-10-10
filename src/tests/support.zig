const std = @import("std");
const platform = @import("../platform.zig");
const tables = @import("../chess/tables.zig");
const zobrist = @import("../chess/zobrist.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const weights = @import("../engine/weights.zig");
const cuckoo = @import("../chess/cuckoo.zig");
const search = @import("../engine/search.zig");
const tt = @import("../engine/tt.zig");

pub fn init_tables() void {
    tables.init_all();
    zobrist.init_zobrist();
    weights.use_embedded();
}

pub fn init_search() void {
    init_tables();
    cuckoo.init();
    search.init_lmr();
}

pub fn init_engine() void {
    platform.io = std.testing.io;
    init_search();
    tt.GlobalTT.reset(tt.DEFAULT_HASH_MB);
    search.set_helper_count(0);
}

pub fn new_position() !*position.Position {
    const pos = try std.testing.allocator.create(position.Position);
    pos.init();
    return pos;
}

pub fn position_at(fen: []const u8) !*position.Position {
    init_tables();
    const pos = try new_position();
    pos.set_fen(fen);
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

pub fn undo(pos: *position.Position, last_move: types.Move) void {
    switch (pos.turn) {
        .White => pos.undo_move(.Black, last_move),
        .Black => pos.undo_move(.White, last_move),
    }
}

pub fn play_uci(pos: *position.Position, text: []const u8) !types.Move {
    const move = types.Move.new_from_string(pos, text);
    try std.testing.expect(move.to_u16() != 0);
    play(pos, move);
    return move;
}

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

pub fn network_output(pos: *position.Position) i32 {
    return switch (pos.turn) {
        inline else => |turn| pos.evaluator.nnue_evaluator.evaluate_uncached(turn, pos),
    };
}

pub const SearchFixture = struct {
    pos: *position.Position,
    searcher: *search.Searcher,

    pub fn init(fen: []const u8) !SearchFixture {
        init_engine();

        const pos = try new_position();
        errdefer destroy_position(pos);
        pos.set_fen(fen);
        const searcher = try std.testing.allocator.create(search.Searcher);
        var fixture: SearchFixture = .{ .pos = pos, .searcher = searcher };
        fixture.start_searcher();
        return fixture;
    }

    pub fn deinit(self: *SearchFixture) void {
        self.searcher.deinit();
        std.testing.allocator.destroy(self.searcher);
        destroy_position(self.pos);
    }

    pub fn renew_searcher(self: *SearchFixture) void {
        self.searcher.deinit();
        self.start_searcher();
    }

    fn start_searcher(self: *SearchFixture) void {
        self.searcher.init();
        self.searcher.force_thinking = true;
        self.searcher.silent_output = true;
        self.restart_at_root();
    }

    fn restart_at_root(self: *SearchFixture) void {
        tt.GlobalTT.clear();
        self.searcher.shared.stop = false;
        self.searcher.hash_history.clear();
        self.searcher.hash_history.append(self.pos.hash) catch unreachable;
    }

    pub fn run(self: *SearchFixture, max_depth: ?u8) i32 {
        self.restart_at_root();
        return switch (self.pos.turn) {
            inline else => |turn| self.searcher.iterative_deepening(self.pos, turn, max_depth),
        };
    }

    pub fn quiescence(self: *SearchFixture, alpha: i32, beta: i32) i32 {
        return switch (self.pos.turn) {
            inline else => |turn| self.searcher.quiescence_search(self.pos, turn, .scaled, alpha, beta),
        };
    }

    pub fn move(self: *SearchFixture, text: []const u8) types.Move {
        return types.Move.new_from_string(self.pos, text);
    }
};
