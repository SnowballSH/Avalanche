//! See docs/STRENGTH.md.

const std = @import("std");
const types = @import("../chess/types.zig");

pub const MAX_LEVEL: u8 = 20;
pub const MIN_ELO: u32 = 1320;
pub const MAX_ELO: u32 = 3000;
pub const DEFAULT_ELO: u32 = MAX_ELO;

const DECISIVE_CLAMP: i32 = 2000;
const MIN_CANDIDATES: usize = 2;
const MAX_CANDIDATES: usize = types.MoveList.capacity;
const LEVELS_PER_EXTRA_CANDIDATE: f32 = 3.0;
const BASE_TEMPERATURE: f32 = 2.0;
const TEMPERATURE_PER_HANDICAP_SQUARED: f32 = 0.6;

pub const Strength = struct {
    level: f32 = MAX_LEVEL,

    pub fn from_skill_level(level: u8) Strength {
        return .{ .level = @floatFromInt(@min(level, MAX_LEVEL)) };
    }

    pub fn from_elo(elo: u32) Strength {
        const clamped = std.math.clamp(elo, MIN_ELO, MAX_ELO);
        const fraction = @as(f32, @floatFromInt(clamped - MIN_ELO)) / @as(f32, @floatFromInt(MAX_ELO - MIN_ELO));
        return .{ .level = fraction * @as(f32, @floatFromInt(MAX_LEVEL)) };
    }

    pub inline fn is_limited(self: Strength) bool {
        return self.level < @as(f32, @floatFromInt(MAX_LEVEL));
    }

    pub fn max_depth(self: Strength) usize {
        return 1 + @as(usize, @intFromFloat(self.level));
    }

    fn handicap(self: Strength) f32 {
        return @as(f32, @floatFromInt(MAX_LEVEL)) - self.level;
    }

    pub fn candidate_count(self: Strength) usize {
        return MIN_CANDIDATES + @as(usize, @intFromFloat(self.handicap() / LEVELS_PER_EXTRA_CANDIDATE));
    }

    pub fn temperature(self: Strength) f32 {
        return BASE_TEMPERATURE + TEMPERATURE_PER_HANDICAP_SQUARED * self.handicap() * self.handicap();
    }

    pub fn pick(self: Strength, scores_best_first: []const i32, random: std.Random) usize {
        const count = scores_best_first.len;
        std.debug.assert(count > 0 and count <= MAX_CANDIDATES);
        const best = clamp_score(scores_best_first[0]);
        const temp = self.temperature();
        var weights: [MAX_CANDIDATES]f32 = undefined;
        var total: f32 = 0;
        for (scores_best_first, weights[0..count]) |score, *weight| {
            const gap: f32 = @floatFromInt(best - clamp_score(score));
            weight.* = @exp(-@max(gap, 0) / temp);
            total += weight.*;
        }

        var target = random.float(f32) * total;
        for (weights[0..count], 0..) |weight, index| {
            if (target < weight) return index;
            target -= weight;
        }
        return count - 1;
    }

    fn clamp_score(score: i32) i32 {
        return std.math.clamp(score, -DECISIVE_CLAMP, DECISIVE_CLAMP);
    }
};

test "strength: full level is unlimited, lower levels are limited" {
    try std.testing.expect(!Strength.from_skill_level(MAX_LEVEL).is_limited());
    try std.testing.expect(!(Strength{}).is_limited());
    try std.testing.expect(Strength.from_skill_level(0).is_limited());
    try std.testing.expect(!Strength.from_elo(MAX_ELO).is_limited());
    try std.testing.expect(Strength.from_elo(MAX_ELO - 1).is_limited());
    try std.testing.expectEqual(@as(usize, 1), Strength.from_skill_level(0).max_depth());
    try std.testing.expectEqual(@as(usize, 20), Strength.from_skill_level(19).max_depth());
}

test "strength: every level considers at least the minimum and at most a full move list of candidates" {
    try std.testing.expectEqual(MIN_CANDIDATES, Strength.from_skill_level(MAX_LEVEL).candidate_count());
    var previous = MIN_CANDIDATES;
    var level: u8 = MAX_LEVEL;
    while (level > 0) {
        level -= 1;
        const count = Strength.from_skill_level(level).candidate_count();
        try std.testing.expect(count >= previous and count <= MAX_CANDIDATES);
        previous = count;
    }
    try std.testing.expect(previous > MIN_CANDIDATES);
}

test "strength: elo maps monotonically onto levels" {
    var previous: f32 = -1;
    var elo = MIN_ELO;
    while (elo <= MAX_ELO) : (elo += 40) {
        const level = Strength.from_elo(elo).level;
        try std.testing.expect(level >= previous);
        previous = level;
    }
    try std.testing.expectEqual(@as(f32, 0), Strength.from_elo(0).level);
}

test "strength: strong levels keep the best move, weak levels spread choices" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const close = [_]i32{ 40, 5, -20 };
    const strong = Strength.from_skill_level(19);
    for (0..200) |_| {
        try std.testing.expectEqual(@as(usize, 0), strong.pick(&close, random));
    }

    const level_ties = [_]i32{ 10, 10, 10, 10 };
    const weak = Strength.from_skill_level(0);
    var hits: [level_ties.len]usize = @splat(0);
    for (0..400) |_| hits[weak.pick(&level_ties, random)] += 1;
    for (hits) |count| try std.testing.expect(count > 50);
}
