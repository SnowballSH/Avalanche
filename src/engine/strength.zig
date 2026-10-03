const std = @import("std");

pub const MAX_LEVEL: u8 = 20;
pub const MIN_ELO: u32 = 1320;
pub const MAX_ELO: u32 = 3000;
pub const DEFAULT_ELO: u32 = MAX_ELO;

const DECISIVE_CLAMP: i32 = 2000;

/// Handicapped play for `Skill Level` / `UCI_LimitStrength`. A weakened engine
/// searches only a shallow MultiPV and samples its move from the candidate
/// lines, preferring better scores less strongly the lower the level.
/// See docs/STRENGTH.md for the model and its calibration caveats.
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

    pub fn candidate_count(self: Strength) usize {
        return 2 + @as(usize, @intFromFloat((@as(f32, @floatFromInt(MAX_LEVEL)) - self.level) / 3.0));
    }

    /// Score gap (in centipawns) at which a candidate becomes e times less likely.
    /// Quadratic so near-full levels rarely concede even small gaps.
    pub fn temperature(self: Strength) f32 {
        const handicap = @as(f32, @floatFromInt(MAX_LEVEL)) - self.level;
        return 2.0 + 0.6 * handicap * handicap;
    }

    /// Samples a candidate index; `scores` must be sorted best first.
    pub fn pick(self: Strength, scores: []const i32, random: std.Random) usize {
        std.debug.assert(scores.len > 0);
        const best = clamp_score(scores[0]);
        const temp = self.temperature();
        var weights: [256]f32 = undefined;
        var total: f32 = 0;
        for (scores, weights[0..scores.len]) |score, *weight| {
            const gap: f32 = @floatFromInt(best - clamp_score(score));
            weight.* = @exp(-@max(gap, 0) / temp);
            total += weight.*;
        }

        var target = random.float(f32) * total;
        for (weights[0..scores.len], 0..) |weight, index| {
            if (target < weight) return index;
            target -= weight;
        }
        return scores.len - 1;
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
