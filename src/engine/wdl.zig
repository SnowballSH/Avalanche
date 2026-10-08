const std = @import("std");

pub var show_wdl: bool = false;

// m = min(240, ply) / 64
const AS: [4]f64 = .{ -1.94427095, 17.60229338, -16.25767549, 139.03011346 };
const BS: [4]f64 = .{ -3.49822308, 24.88336871, -50.05295749, 63.04117979 };

const SCORE_CLAMP: f64 = 2000.0;
const MAX_PLY: usize = 240;

/// a(1), the unit of UCI scores: `cp 100` is a 50% win chance.
pub const PAWN_VALUE: i32 = @intFromFloat(@round(AS[0] + AS[1] + AS[2] + AS[3]));

pub fn normalized(score: i32) i32 {
    const half = @divTrunc(PAWN_VALUE, 2);
    return @divTrunc(score * 100 + (if (score >= 0) half else -half), PAWN_VALUE);
}

pub const Prediction = struct {
    win: i32,
    draw: i32,
    loss: i32,
};

/// Permille WDL from the side to move. Use `decisive` for mate/TB scores.
pub fn predict(score: i32, ply: usize) Prediction {
    const m = @as(f64, @floatFromInt(@min(ply, MAX_PLY))) / 64.0;

    const a = ((AS[0] * m + AS[1]) * m + AS[2]) * m + AS[3];
    const b = @max(1.0, ((BS[0] * m + BS[1]) * m + BS[2]) * m + BS[3]);

    const x = std.math.clamp(@as(f64, @floatFromInt(score)), -SCORE_CLAMP, SCORE_CLAMP);

    const win = 1.0 / (1.0 + @exp((a - x) / b));
    const loss = 1.0 / (1.0 + @exp((a + x) / b));

    var w = permille(win);
    var l = permille(loss);
    if (w + l > 1000) {
        const excess = w + l - 1000;
        if (w >= l) {
            w -= excess;
        } else {
            l -= excess;
        }
    }

    return .{ .win = w, .draw = 1000 - w - l, .loss = l };
}

pub fn decisive(score: i32) Prediction {
    return if (score > 0)
        .{ .win = 1000, .draw = 0, .loss = 0 }
    else
        .{ .win = 0, .draw = 0, .loss = 1000 };
}

fn permille(p: f64) i32 {
    const v = @as(i32, @intFromFloat(@round(1000.0 * p)));
    return std.math.clamp(v, 0, 1000);
}

test "wdl probabilities sum to 1000 and are symmetric" {
    var ply: usize = 0;
    while (ply <= 300) : (ply += 17) {
        var score: i32 = -3000;
        while (score <= 3000) : (score += 37) {
            const p = predict(score, ply);
            try std.testing.expectEqual(@as(i32, 1000), p.win + p.draw + p.loss);
            try std.testing.expect(p.win >= 0 and p.draw >= 0 and p.loss >= 0);

            const q = predict(-score, ply);
            try std.testing.expectEqual(p.win, q.loss);
            try std.testing.expectEqual(p.loss, q.win);
        }
    }
}

test "normalized scores put a 50% win chance at 100 cp and round to nearest" {
    try std.testing.expectEqual(@as(i32, 100), normalized(PAWN_VALUE));
    try std.testing.expectEqual(@as(i32, -100), normalized(-PAWN_VALUE));
    try std.testing.expectEqual(@as(i32, 0), normalized(0));
    try std.testing.expectEqual(@as(i32, 25), normalized(37));
    try std.testing.expectEqual(normalized(37), -normalized(-37));
    const p = predict(PAWN_VALUE, 64);
    try std.testing.expect(p.win >= 490 and p.win <= 510);
}
