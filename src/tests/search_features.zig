const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const zobrist = @import("../chess/zobrist.zig");
const position = @import("../chess/position.zig");
const weights = @import("../engine/weights.zig");
const search = @import("../engine/search.zig");
const strength = @import("../engine/strength.zig");
const tt = @import("../engine/tt.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Fixture = struct {
    io_threaded: std.Io.Threaded,
    pos: *position.Position,
    searcher: *search.Searcher,

    fn init(self: *Fixture, fen: []const u8) !void {
        self.io_threaded = .init(std.heap.page_allocator, .{});
        types.GLOBAL_IO = self.io_threaded.io();
        tables.init_all();
        zobrist.init_zobrist();
        weights.do_nnue();
        search.init_lmr();
        tt.GlobalTT.reset(16);
        search.NUM_THREADS = 0;

        self.pos = try std.testing.allocator.create(position.Position);
        self.pos.init();
        self.pos.set_fen(fen);
        self.searcher = try std.testing.allocator.create(search.Searcher);
        self.searcher.init();
        self.searcher.force_thinking = true;
        self.searcher.silent_output = true;
    }

    fn deinit(self: *Fixture) void {
        self.searcher.deinit();
        std.testing.allocator.destroy(self.searcher);
        self.pos.deinit();
        std.testing.allocator.destroy(self.pos);
        self.io_threaded.deinit();
    }

    fn run(self: *Fixture, max_depth: ?u8) void {
        tt.GlobalTT.clear();
        self.searcher.stop = false;
        self.searcher.hash_history.clearRetainingCapacity();
        self.searcher.hash_history.append(self.pos.hash) catch unreachable;
        switch (self.pos.turn) {
            .White => _ = self.searcher.iterative_deepening(self.pos, .White, max_depth),
            .Black => _ = self.searcher.iterative_deepening(self.pos, .Black, max_depth),
        }
    }

    fn move(self: *Fixture, uci: []const u8) types.Move {
        return types.Move.new_from_string(self.pos, uci);
    }
};

fn expect_consistent_lines(searcher: *const search.Searcher) !void {
    const lines = searcher.lines[0..searcher.line_count];
    try expect(lines.len > 0);
    try expectEqual(lines[0].pv[0].to_u16(), searcher.best_move.to_u16());
    for (lines, 0..) |line, i| {
        try expectEqual(lines[0].depth, line.depth);
        if (i > 0) try expect(lines[i - 1].score >= line.score);
        for (lines[0..i]) |earlier| {
            try expect(earlier.pv[0].to_u16() != line.pv[0].to_u16());
        }
    }
}

test "multipv: completed search reports distinct lines sorted by score" {
    var f: Fixture = undefined;
    try f.init("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3");
    defer f.deinit();

    f.searcher.multi_pv = 4;
    f.run(6);
    try expectEqual(@as(usize, 4), f.searcher.line_count);
    try expect_consistent_lines(f.searcher);
}

test "multipv: interrupted iterations never mix depths or promote stale lines" {
    var f: Fixture = undefined;
    try f.init("2kr3r/ppp1qppp/2n1bn2/3p4/3P4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 10");
    defer f.deinit();

    f.searcher.multi_pv = 3;
    var nodes: u64 = 1500;
    while (nodes < 60_000) : (nodes = nodes * 5 / 4) {
        f.searcher.max_nodes = nodes;
        f.searcher.soft_max_nodes = nodes;
        f.run(null);
        try expect_consistent_lines(f.searcher);
    }
}

test "go mate: stops once a short enough mate is proven" {
    var f: Fixture = undefined;
    try f.init("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4");
    defer f.deinit();

    f.searcher.mate_in = 1;
    f.run(null);
    try expectEqual(f.move("h5f7").to_u16(), f.searcher.best_move.to_u16());
    try expect(f.searcher.lines[0].depth < 10);
}

test "searchmoves: only the listed root moves are searched" {
    var f: Fixture = undefined;
    try f.init(types.DEFAULT_FEN);
    defer f.deinit();

    const allowed = [_]types.Move{ f.move("a2a3"), f.move("h2h4") };
    @memcpy(f.searcher.search_moves[0..allowed.len], &allowed);
    f.searcher.search_move_count = allowed.len;
    f.searcher.multi_pv = 5;
    f.run(5);

    try expectEqual(@as(usize, allowed.len), f.searcher.line_count);
    for (f.searcher.lines[0..f.searcher.line_count]) |line| {
        try expect(line.pv[0].to_u16() == allowed[0].to_u16() or line.pv[0].to_u16() == allowed[1].to_u16());
    }
}

test "strength: a limited engine searches shallowly but plays a legal candidate" {
    var f: Fixture = undefined;
    try f.init(types.DEFAULT_FEN);
    defer f.deinit();

    f.searcher.strength = strength.Strength.from_skill_level(3);
    f.run(30);

    try expectEqual(@as(usize, 4), f.searcher.lines[0].depth);
    try expectEqual(f.searcher.strength.candidate_count(), f.searcher.line_count);
    var found = false;
    for (f.searcher.lines[0..f.searcher.line_count]) |line| {
        found = found or line.pv[0].to_u16() == f.searcher.best_move.to_u16();
    }
    try expect(found);
}
