const std = @import("std");
const types = @import("../../chess/types.zig");

/// White-relative game result; the numeric value is the WDL byte stored in viriformat and bulletformat.
pub const Outcome = enum(u8) {
    black_win = 0,
    draw = 1,
    white_win = 2,

    pub fn for_winner(winner: types.Color) Outcome {
        return if (winner == types.Color.White) .white_win else .black_win;
    }
};

pub const Thresholds = struct {
    win_score: i32 = 2500,
    win_plies: usize = 4,
    draw_score: i32 = 5,
    draw_plies: usize = 12,
    draw_min_ply: usize = 50,
};

pub const Adjudicator = struct {
    thresholds: Thresholds,
    white_streak: usize = 0,
    black_streak: usize = 0,
    draw_streak: usize = 0,

    pub fn init(thresholds: Thresholds) Adjudicator {
        return .{ .thresholds = thresholds };
    }

    pub fn observe(self: *Adjudicator, white_score: i32, ply: usize) ?Outcome {
        const t = self.thresholds;
        self.white_streak = if (white_score > t.win_score) self.white_streak + 1 else 0;
        self.black_streak = if (white_score < -t.win_score) self.black_streak + 1 else 0;
        const quiet = ply >= t.draw_min_ply and @abs(white_score) < t.draw_score;
        self.draw_streak = if (quiet) self.draw_streak + 1 else 0;

        if (self.white_streak >= t.win_plies) return .white_win;
        if (self.black_streak >= t.win_plies) return .black_win;
        if (self.draw_streak >= t.draw_plies) return .draw;
        return null;
    }
};

const testing = std.testing;

test "adjudicator: win needs a full streak and resets on a quiet score" {
    var a = Adjudicator.init(.{});
    try testing.expectEqual(@as(?Outcome, null), a.observe(3000, 10));
    try testing.expectEqual(@as(?Outcome, null), a.observe(3000, 11));
    try testing.expectEqual(@as(?Outcome, null), a.observe(100, 12));
    for (0..3) |i| try testing.expectEqual(@as(?Outcome, null), a.observe(3000, 13 + i));
    try testing.expectEqual(@as(?Outcome, .white_win), a.observe(3000, 16));
}

test "adjudicator: black win and draw" {
    var a = Adjudicator.init(.{});
    for (0..3) |i| _ = a.observe(-2600, i);
    try testing.expectEqual(@as(?Outcome, .black_win), a.observe(-2600, 3));

    var d = Adjudicator.init(.{});
    for (0..11) |i| try testing.expectEqual(@as(?Outcome, null), d.observe(0, 60 + i));
    try testing.expectEqual(@as(?Outcome, .draw), d.observe(0, 71));
}

test "adjudicator: draws are not adjudicated before the minimum ply" {
    var d = Adjudicator.init(.{});
    for (0..40) |i| try testing.expectEqual(@as(?Outcome, null), d.observe(0, i));
}

test "adjudicator: winner maps to a white-relative outcome" {
    try testing.expectEqual(Outcome.white_win, Outcome.for_winner(types.Color.White));
    try testing.expectEqual(Outcome.black_win, Outcome.for_winner(types.Color.Black));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Outcome.white_win));
}
