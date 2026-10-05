const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const support = @import("support.zig");
const hce = @import("../engine/hce.zig");
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
        platform.io = self.io_threaded.io();
        support.init_tables();
        search.init_lmr();
        tt.GlobalTT.reset(16);
        search.NUM_THREADS = 0;

        self.pos = try support.new_position();
        self.pos.set_fen(fen);
        self.searcher = try std.testing.allocator.create(search.Searcher);
        self.searcher.init();
        self.searcher.force_thinking = true;
        self.searcher.silent_output = true;
    }

    fn deinit(self: *Fixture) void {
        self.searcher.deinit();
        std.testing.allocator.destroy(self.searcher);
        support.destroy_position(self.pos);
        self.io_threaded.deinit();
    }

    fn run(self: *Fixture, max_depth: ?u8) void {
        tt.GlobalTT.clear();
        self.searcher.shared.stop = false;
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

test "move list: a set-up position with more moves than a list holds is cut at the capacity and searched" {
    var fixture: Fixture = undefined;
    try fixture.init("QQQQQQQQ/Q6Q/Q6Q/Q6Q/Q6Q/Q1k4Q/Q6Q/KQQQQQQQ w - - 0 1");
    defer fixture.deinit();
    try expectEqual(@as(usize, types.MoveList.capacity), fixture.pos.legal_moves().len);

    fixture.pos.set_fen("knQQQQQQ/pp5Q/Q6Q/Q6Q/Q6Q/Q6Q/Q6Q/KQQQQQQQ w - - 0 1");
    const moves = fixture.pos.legal_moves();
    try expectEqual(@as(usize, types.MoveList.capacity), moves.len);

    fixture.run(3);
    var best_is_listed = false;
    for (moves.items()) |move| {
        if (move.to_u16() == fixture.searcher.best_move.to_u16()) best_is_listed = true;
    }
    try expect(best_is_listed);
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

const DrawnScores = struct { quiescence: i32, negamax: i32 };

fn scores_of_drawn_position(fen: []const u8) !DrawnScores {
    var fixture: Fixture = undefined;
    try fixture.init(fen);
    defer fixture.deinit();
    tt.GlobalTT.clear();
    try fixture.searcher.hash_history.append(fixture.pos.hash);

    const searcher = fixture.searcher;
    const pos = fixture.pos;
    return switch (pos.turn) {
        inline else => |color| .{
            .quiescence = searcher.quiescence_search(pos, color, .scaled, -hce.MateScore, hce.MateScore),
            .negamax = searcher.negamax(pos, color, .scaled, 1, -hce.MateScore, hce.MateScore, false, .PV, false),
        },
    };
}

test "search: after a hundred plies without progress a side in check is mated if it has no move and drawn if it has one" {
    const old_contempt = search.CONTEMPT;
    defer search.CONTEMPT = old_contempt;
    search.CONTEMPT = 100;

    const mated = try scores_of_drawn_position("7k/6Q1/6K1/8/8/8/8/8 b - - 100 1");
    try expectEqual(-hce.MateScore, mated.quiescence);
    try expectEqual(-hce.MateScore, mated.negamax);

    const drawn_in_check = try scores_of_drawn_position("7k/8/6K1/8/8/8/8/7R b - - 100 1");
    try expectEqual(-search.CONTEMPT, drawn_in_check.quiescence);
    try expectEqual(-search.CONTEMPT, drawn_in_check.negamax);

    const drawn = try scores_of_drawn_position("7k/8/6K1/8/8/8/8/6R1 b - - 100 1");
    try expectEqual(-search.CONTEMPT, drawn.quiescence);
    try expectEqual(-search.CONTEMPT, drawn.negamax);
}
