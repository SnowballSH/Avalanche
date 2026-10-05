const std = @import("std");
const types = @import("../chess/types.zig");
const movepick = @import("../engine/movepick.zig");
const search = @import("../engine/search.zig");

const capacity = types.MoveList.capacity;
const block_lens = [_]usize{ 4, 8, 16 };

const quiet_flags = [_]types.MoveFlags{ .QUIET, .DOUBLE_PUSH, .OO, .OOO };
const promotion_flags = [_]u4{ types.PR_KNIGHT, types.PR_BISHOP, types.PR_ROOK, types.PR_QUEEN };
const capture_flags = [_]types.MoveFlags{ .CAPTURE, .EN_PASSANT };
const promotion_capture_flags = [_]u4{ types.PC_KNIGHT, types.PC_BISHOP, types.PC_ROOK, types.PC_QUEEN };

const Script = struct {
    moves: [capacity]types.Move = undefined,
    scored: [capacity]movepick.ScoredMove = undefined,
    exchange_wins: [capacity]bool = undefined,
    exchange_queries: [capacity]u32 = @splat(0),

    fn move_of(id: usize, flags: u4) types.Move {
        return @bitCast((@as(u16, @intCast(id + 1)) << 4) | flags);
    }

    fn id_of(move: types.Move) usize {
        return (move.to_u16() >> 4) - 1;
    }

    fn eager_score(self: *const Script, id: usize) i32 {
        const scored = self.scored[id];
        const lost = scored.kind == .assumes_winning_exchange and !self.exchange_wins[id];
        return if (lost) scored.score - movepick.SortWinningCapture else scored.score;
    }

    fn list(self: *const Script, len: usize) types.MoveList {
        var moves: types.MoveList = .{};
        for (self.moves[0..len]) |move| moves.append(move);
        return moves;
    }
};

const ScriptedContext = struct {
    script: *Script,

    pub fn score(self: *const ScriptedContext, move: types.Move) movepick.ScoredMove {
        return self.script.scored[Script.id_of(move)];
    }

    pub fn exchange_wins(self: *const ScriptedContext, move: types.Move) bool {
        const id = Script.id_of(move);
        self.script.exchange_queries[id] += 1;
        return self.script.exchange_wins[id];
    }
};

fn ScriptedPicker(comptime block_len: usize) type {
    return movepick.PickerOver(ScriptedContext, block_len);
}

// The move ordering the search was tuned with: every score known up front, then one
// swap-on-improvement scan per pick.
const ReferenceOrder = struct {
    moves: [capacity]types.Move = undefined,
    scores: [capacity]i32 = undefined,
    len: usize,

    fn init(script: *const Script, len: usize) ReferenceOrder {
        var order: ReferenceOrder = .{ .len = len };
        for (0..len) |id| {
            order.moves[id] = script.moves[id];
            order.scores[id] = script.eager_score(id);
        }
        return order;
    }

    fn pick(self: *ReferenceOrder, step: usize) types.Move {
        var cur_move = self.moves[step];
        var cur_score = self.scores[step];
        var j = step + 1;
        while (j < self.len) : (j += 1) {
            if (cur_score < self.scores[j]) {
                std.mem.swap(types.Move, &self.moves[j], &cur_move);
                std.mem.swap(i32, &self.scores[j], &cur_score);
            }
        }
        self.moves[step] = cur_move;
        self.scores[step] = cur_score;
        return cur_move;
    }

    fn is_winning_capture(self: *const ReferenceOrder, step: usize) bool {
        return self.scores[step] >= movepick.SortWinningCaptureFloor;
    }
};

const Searched = struct {
    moves: [capacity]types.Move = undefined,
    indices: [capacity]usize = undefined,
    len: usize = 0,

    fn add(self: *Searched, index: usize, move: types.Move) void {
        self.moves[self.len] = move;
        self.indices[self.len] = index;
        self.len += 1;
    }

    fn expect_equal(expected: *const Searched, actual: *const Searched) !void {
        try std.testing.expectEqualSlices(usize, expected.indices[0..expected.len], actual.indices[0..actual.len]);
        for (expected.moves[0..expected.len], actual.moves[0..actual.len]) |e, a| {
            try std.testing.expectEqual(e.to_u16(), a.to_u16());
        }
    }
};

fn expect_same_moves(expected: []const types.Move, actual: []const types.Move) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectEqual(e.to_u16(), a.to_u16());
}

fn percent(random: std.Random) u8 {
    const levels = [_]u8{ 0, 5, 30, 70, 95, 100 };
    return levels[random.uintLessThan(usize, levels.len)];
}

fn chance(random: std.Random, of_hundred: u8) bool {
    return random.uintLessThan(u8, 100) < of_hundred;
}

fn random_flags(random: std.Random, capture: bool, promotion: bool) u4 {
    const kind = random.uintLessThan(usize, 4);
    if (capture and promotion) return promotion_capture_flags[kind];
    if (promotion) return promotion_flags[kind];
    if (capture) return @backingInt(capture_flags[kind % capture_flags.len]);
    return @backingInt(quiet_flags[kind]);
}

fn random_palette(random: std.Random, palette: []i32) void {
    const anchors = [_]i32{
        0,
        movepick.SortKiller1,
        movepick.SortKiller2,
        movepick.SortCounterMove,
        movepick.SortWinningCaptureFloor,
        movepick.SortWinningCapture,
        movepick.SortWinningCapture + movepick.SortWinningCaptureFloor,
        2 * movepick.SortWinningCapture,
    };
    for (palette) |*value| {
        const anchor = anchors[random.uintLessThan(usize, anchors.len)];
        const spread: i32 = switch (random.uintLessThan(u8, 4)) {
            0 => 0,
            1 => random.intRangeAtMost(i32, -1, 1),
            2 => random.intRangeAtMost(i32, -700, 700),
            else => random.intRangeAtMost(i32, -40_000, 40_000),
        };
        value.* = anchor + spread;
    }
}

fn random_script(random: std.Random, script: *Script, len: usize) void {
    var palette_storage: [12]i32 = undefined;
    const palette = palette_storage[0..random.intRangeAtMost(usize, 1, palette_storage.len)];
    random_palette(random, palette);
    const pending_percent = percent(random);
    const winning_percent = percent(random);
    const capture_percent = percent(random);
    const promotion_percent = percent(random) / 4;

    for (0..len) |id| {
        script.moves[id] = Script.move_of(id, random_flags(random, chance(random, capture_percent), chance(random, promotion_percent)));
        script.scored[id] = .{
            .score = palette[random.uintLessThan(usize, palette.len)],
            .kind = if (chance(random, pending_percent)) .assumes_winning_exchange else .exact,
        };
        script.exchange_wins[id] = chance(random, winning_percent);
        script.exchange_queries[id] = 0;
    }
    if (len > 0 and random.boolean()) {
        const promotion_bonus = [_]i32{ 0, 650_000, 1_000_000 };
        script.scored[random.uintLessThan(usize, len)] = .{
            .score = movepick.SortHash + promotion_bonus[random.uintLessThan(usize, promotion_bonus.len)],
            .kind = .hash_move,
        };
    }
}

fn random_len(random: std.Random, trial: usize) usize {
    return switch (trial % 16) {
        0 => random.intRangeAtMost(usize, 200, capacity),
        1 => random.uintAtMost(usize, 3),
        else => random.uintAtMost(usize, 70),
    };
}

fn random_killers(random: std.Random, script: *const Script, len: usize) [2]types.Move {
    var killers: [2]types.Move = @splat(types.Move.empty());
    for (&killers) |*killer| {
        if (len > 0 and random.boolean()) killer.* = script.moves[random.uintLessThan(usize, len)];
    }
    return killers;
}

fn expect_same_order(comptime Picker: type, random: std.Random, script: *Script, len: usize) !void {
    var list = script.list(len);
    var picker: Picker = undefined;
    picker.init(.{ .script = script }, &list);
    var reference = ReferenceOrder.init(script, len);

    const picks = if (random.boolean()) len else random.uintAtMost(usize, len);
    const ask_percent = percent(random);
    if (chance(random, ask_percent)) try expect_same_moves(reference.moves[0..len], picker.unpicked());
    for (0..picks) |step| {
        const expected = reference.pick(step);
        const move = picker.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(expected.to_u16(), move.to_u16());
        try std.testing.expectEqual(step, picker.index());
        if (chance(random, ask_percent)) try expect_same_moves(reference.moves[step + 1 .. len], picker.unpicked());
        if (chance(random, ask_percent)) {
            try std.testing.expectEqual(reference.is_winning_capture(step), picker.current_is_winning_capture());
            try std.testing.expectEqual(reference.is_winning_capture(step), picker.current_is_winning_capture());
        }
    }
    if (picks == len) try std.testing.expectEqual(@as(?types.Move, null), picker.next());

    for (0..len) |id| {
        const queries = script.exchange_queries[id];
        try std.testing.expect(queries <= 1);
        if (script.scored[id].kind != .assumes_winning_exchange) try std.testing.expectEqual(@as(u32, 0), queries);
    }
}

// `negamax` once `skip_quiet` is set from pick `prune_after` on, with and without leaving the loop early.
fn expect_quiet_pruning_exit_is_exact(comptime Picker: type, random: std.Random, script: *Script, len: usize) !bool {
    const killers = random_killers(random, script, len);
    const prune_after = random.uintAtMost(usize, len);

    var reference = ReferenceOrder.init(script, len);
    var expected: Searched = .{};
    for (0..len) |step| {
        const move = reference.pick(step);
        if (step > prune_after and search.is_prunable_quiet(move, killers)) continue;
        expected.add(step, move);
    }

    var list = script.list(len);
    var picker: Picker = undefined;
    picker.init(.{ .script = script }, &list);
    var actual: Searched = .{};
    var left_early = false;
    while (picker.next()) |move| {
        const index = picker.index();
        if (index > prune_after and search.is_prunable_quiet(move, killers)) {
            if (search.only_prunable_quiets(picker.unpicked(), killers)) {
                left_early = picker.unpicked().len > 0;
                break;
            }
            continue;
        }
        actual.add(index, move);
    }
    try expected.expect_equal(&actual);
    return left_early;
}

// `quiescence_search` outside check, with and without leaving the loop at the first losing capture.
fn expect_losing_capture_exit_is_exact(comptime Picker: type, script: *Script, len: usize) !bool {
    var reference = ReferenceOrder.init(script, len);
    var expected: Searched = .{};
    for (0..len) |step| {
        const move = reference.pick(step);
        if (move.is_capture() and step > 0 and !reference.is_winning_capture(step)) continue;
        expected.add(step, move);
    }

    var list = script.list(len);
    var picker: Picker = undefined;
    picker.init(.{ .script = script }, &list);
    var actual: Searched = .{};
    var left_early = false;
    while (picker.next()) |move| {
        if (move.is_capture() and picker.index() > 0) {
            if (!picker.current_is_winning_capture()) {
                if (search.only_captures(picker.unpicked())) {
                    left_early = picker.unpicked().len > 0;
                    break;
                }
                continue;
            }
        }
        actual.add(picker.index(), move);
    }
    try expected.expect_equal(&actual);
    return left_early;
}

test "move picker: lazy exchanges and the deferred hash move keep the eager pick order" {
    var prng = std.Random.DefaultPrng.init(0x6d6f7665_7069636b);
    const random = prng.random();
    var script: Script = .{};

    inline for (block_lens) |block_len| {
        for (0..15_000) |trial| {
            const len = random_len(random, trial);
            random_script(random, &script, len);
            try expect_same_order(ScriptedPicker(block_len), random, &script, len);
        }
    }
}

test "move picker: a hash move that is the only pick costs no exchange evaluation" {
    var script: Script = .{};
    const len = 9;
    for (0..len) |id| {
        script.moves[id] = Script.move_of(id, @backingInt(types.MoveFlags.CAPTURE));
        script.scored[id] = .{ .score = movepick.SortWinningCapture + @as(i32, @intCast(id)), .kind = .assumes_winning_exchange };
        script.exchange_wins[id] = id % 2 == 0;
    }
    script.scored[5] = .{ .score = movepick.SortHash, .kind = .hash_move };

    var list = script.list(len);
    var picker: ScriptedPicker(4) = undefined;
    picker.init(.{ .script = &script }, &list);

    try std.testing.expectEqual(script.moves[5].to_u16(), picker.next().?.to_u16());
    try std.testing.expect(picker.current_is_winning_capture());
    for (script.exchange_queries[0..len]) |queries| try std.testing.expectEqual(@as(u32, 0), queries);
}

test "move loops: leaving early searches the moves the full loops search" {
    var prng = std.Random.DefaultPrng.init(0x6561726c_79657869);
    const random = prng.random();
    var script: Script = .{};
    var quiet_exits: usize = 0;
    var capture_exits: usize = 0;

    inline for (block_lens) |block_len| {
        for (0..10_000) |trial| {
            const len = random_len(random, trial);
            random_script(random, &script, len);
            quiet_exits += @intFromBool(try expect_quiet_pruning_exit_is_exact(ScriptedPicker(block_len), random, &script, len));
            capture_exits += @intFromBool(try expect_losing_capture_exit_is_exact(ScriptedPicker(block_len), &script, len));
        }
    }
    try std.testing.expect(quiet_exits > 3000);
    try std.testing.expect(capture_exits > 5000);
}

test "move loops: only plain quiet moves that are not killers are prunable" {
    const killer = Script.move_of(7, @backingInt(types.MoveFlags.QUIET));
    const killers = [_][2]types.Move{
        .{ types.Move.empty(), types.Move.empty() },
        .{ killer, types.Move.empty() },
        .{ types.Move.empty(), killer },
    };
    for (killers) |pair| {
        for (quiet_flags) |flags| {
            const move = Script.move_of(3, @backingInt(flags));
            try std.testing.expect(search.is_prunable_quiet(move, pair));
            try std.testing.expect(search.only_prunable_quiets(&.{ move, move }, pair));
            try std.testing.expect(!search.only_captures(&.{move}));
        }
        const is_killer = pair[0].to_u16() == killer.to_u16() or pair[1].to_u16() == killer.to_u16();
        try std.testing.expectEqual(!is_killer, search.is_prunable_quiet(killer, pair));

        const plain = Script.move_of(3, @backingInt(types.MoveFlags.QUIET));
        for (promotion_flags) |flags| {
            const move = Script.move_of(3, flags);
            try std.testing.expect(!search.is_prunable_quiet(move, pair));
            try std.testing.expect(!search.only_prunable_quiets(&.{ plain, move }, pair));
            try std.testing.expect(!search.only_captures(&.{move}));
        }
        for (capture_flags) |flags| {
            const move = Script.move_of(3, @backingInt(flags));
            try std.testing.expect(!search.is_prunable_quiet(move, pair));
            try std.testing.expect(!search.only_prunable_quiets(&.{ plain, move }, pair));
            try std.testing.expect(search.only_captures(&.{ move, move }));
            try std.testing.expect(!search.only_captures(&.{ move, plain }));
        }
        for (promotion_capture_flags) |flags| {
            const move = Script.move_of(3, flags);
            try std.testing.expect(!search.is_prunable_quiet(move, pair));
            try std.testing.expect(search.only_captures(&.{move}));
        }
    }
    try std.testing.expect(search.only_prunable_quiets(&.{}, killers[0]));
    try std.testing.expect(search.only_captures(&.{}));
}

test "move list: appending past the capacity drops the surplus" {
    var list: types.MoveList = .{};
    for (0..capacity + 13) |id| list.append(Script.move_of(id, 0));

    try std.testing.expectEqual(@as(usize, capacity), list.len);
    for (list.items(), 0..) |move, id| try std.testing.expectEqual(Script.move_of(id, 0).to_u16(), move.to_u16());
}
