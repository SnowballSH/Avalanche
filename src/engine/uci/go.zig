const std = @import("std");
const types = @import("../../chess/types.zig");
const position = @import("../../chess/position.zig");
const search = @import("../search.zig");
const parameters = @import("../parameters.zig");

/// Arguments of a UCI `go` command. Every limit is optional and they combine.
pub const GoCommand = struct {
    time: [types.N_COLORS]?u64 = .{ null, null },
    increment: [types.N_COLORS]?u64 = .{ null, null },
    moves_to_go: ?u64 = null,
    depth: ?u8 = null,
    nodes: ?u64 = null,
    move_time: ?u64 = null,
    mate: ?i32 = null,
    infinite: bool = false,
    ponder: bool = false,
    search_moves: [search.MAX_MOVES]types.Move = undefined,
    search_move_count: usize = 0,

    pub fn parse(tokens: *std.mem.TokenIterator(u8, .scalar), pos: *position.Position) GoCommand {
        var cmd = GoCommand{};
        while (tokens.next()) |token| {
            if (eql(token, "infinite")) {
                cmd.infinite = true;
            } else if (eql(token, "ponder")) {
                cmd.ponder = true;
            } else if (eql(token, "wtime")) {
                cmd.time[@intFromEnum(types.Color.White)] = parse_clock(tokens.next());
            } else if (eql(token, "btime")) {
                cmd.time[@intFromEnum(types.Color.Black)] = parse_clock(tokens.next());
            } else if (eql(token, "winc")) {
                cmd.increment[@intFromEnum(types.Color.White)] = parse_number(u64, tokens.next());
            } else if (eql(token, "binc")) {
                cmd.increment[@intFromEnum(types.Color.Black)] = parse_number(u64, tokens.next());
            } else if (eql(token, "movestogo")) {
                cmd.moves_to_go = parse_number(u64, tokens.next());
                if (cmd.moves_to_go == 0) cmd.moves_to_go = null;
            } else if (eql(token, "depth")) {
                cmd.depth = parse_number(u8, tokens.next());
            } else if (eql(token, "nodes")) {
                cmd.nodes = parse_number(u64, tokens.next());
            } else if (eql(token, "movetime")) {
                cmd.move_time = parse_number(u64, tokens.next());
            } else if (eql(token, "mate")) {
                cmd.mate = parse_number(i32, tokens.next());
            } else if (eql(token, "searchmoves")) {
                cmd.parse_search_moves(tokens, pos);
            }
        }
        return cmd;
    }

    // `searchmoves` consumes tokens until one is not a legal move.
    fn parse_search_moves(self: *GoCommand, tokens: *std.mem.TokenIterator(u8, .scalar), pos: *position.Position) void {
        while (tokens.peek()) |token| {
            const move = types.Move.new_from_string(pos, token);
            if (move.to_u16() == 0) return;
            _ = tokens.next();
            if (self.search_move_count < self.search_moves.len) {
                self.search_moves[self.search_move_count] = move;
                self.search_move_count += 1;
            }
        }
    }

    pub fn has_clock(self: *const GoCommand, turn: types.Color) bool {
        return self.time[@intFromEnum(turn)] != null;
    }
};

pub const TimeBudget = struct {
    ideal_ms: u64,
    maximum_ms: u64,
    // False when no clock or movetime applies; the search then ignores time.
    managed: bool,
};

pub fn allocate_time(cmd: *const GoCommand, turn: types.Color, overhead_ms: u64) TimeBudget {
    var budget = TimeBudget{ .ideal_ms = 1 << 60, .maximum_ms = 1 << 60, .managed = false };

    if (cmd.time[@intFromEnum(turn)]) |remaining| {
        const clock = clock_budget(remaining, cmd.increment[@intFromEnum(turn)] orelse 0, cmd.moves_to_go, overhead_ms);
        budget = .{ .ideal_ms = clock.ideal_ms, .maximum_ms = clock.maximum_ms, .managed = true };
    }
    if (cmd.move_time) |move_time| {
        budget.maximum_ms = @min(budget.maximum_ms, move_time);
        budget.managed = true;
    }
    return budget;
}

fn clock_budget(remaining: u64, increment: u64, moves_to_go: ?u64, overhead: u64) TimeBudget {
    if (remaining <= overhead) {
        const panic_budget = @max(@as(u64, 1), remaining / 2);
        return .{ .ideal_ms = panic_budget, .maximum_ms = panic_budget, .managed = true };
    }

    var ideal: u64 = undefined;
    var maximum: u64 = undefined;
    if (moves_to_go) |mtg| {
        ideal = increment + (2 * (remaining - overhead)) / (2 * mtg + 1);
        maximum = @min(2 * ideal, remaining - @min(remaining - overhead, overhead * @min(mtg, 5)));
    } else {
        const usable = remaining - overhead;
        ideal = increment + ((usable * parameters.TmSoftFactor) >> 10);
        maximum = 2 * increment + ((usable * parameters.TmHardFactor) >> 10);
    }
    return .{
        .ideal_ms = @min(ideal, remaining - overhead),
        .maximum_ms = @min(maximum, remaining - overhead),
        .managed = true,
    };
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parse_number(comptime T: type, token: ?[]const u8) ?T {
    return std.fmt.parseInt(T, token orelse return null, 10) catch null;
}

// Clocks can go non-positive under lag; treat that as 1 ms left.
fn parse_clock(token: ?[]const u8) ?u64 {
    const ms = parse_number(i64, token) orelse return null;
    return @intCast(@max(ms, 1));
}

test "go: limits combine and parse independently of order" {
    var tokens = std.mem.tokenizeScalar(u8, "depth 12 wtime 1000 btime -5 winc 10 nodes 5000 movestogo 0 mate 3 ponder", ' ');
    var pos: position.Position = undefined;
    const cmd = GoCommand.parse(&tokens, &pos);
    try std.testing.expectEqual(@as(?u8, 12), cmd.depth);
    try std.testing.expectEqual(@as(?u64, 1000), cmd.time[0]);
    try std.testing.expectEqual(@as(?u64, 1), cmd.time[1]);
    try std.testing.expectEqual(@as(?u64, 10), cmd.increment[0]);
    try std.testing.expectEqual(@as(?u64, 5000), cmd.nodes);
    try std.testing.expectEqual(@as(?u64, null), cmd.moves_to_go);
    try std.testing.expectEqual(@as(?i32, 3), cmd.mate);
    try std.testing.expect(cmd.ponder);
    try std.testing.expect(!cmd.infinite);
}

test "go: time allocation" {
    const no_clock = GoCommand{ .depth = 5 };
    try std.testing.expect(!allocate_time(&no_clock, .White, 25).managed);

    const move_time = GoCommand{ .move_time = 500 };
    const fixed = allocate_time(&move_time, .White, 25);
    try std.testing.expect(fixed.managed);
    try std.testing.expectEqual(@as(u64, 500), fixed.maximum_ms);

    var clock = GoCommand{};
    clock.time = .{ 60_000, 10 };
    clock.increment = .{ 1000, 0 };
    const white = allocate_time(&clock, .White, 25);
    try std.testing.expect(white.ideal_ms > 1000 and white.ideal_ms < white.maximum_ms);
    try std.testing.expect(white.maximum_ms <= 60_000 - 25);
    const black = allocate_time(&clock, .Black, 25);
    try std.testing.expectEqual(@as(u64, 5), black.maximum_ms);

    clock.move_time = 200;
    try std.testing.expectEqual(@as(u64, 200), allocate_time(&clock, .White, 25).maximum_ms);
}
