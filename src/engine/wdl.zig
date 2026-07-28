const std = @import("std");

pub var show_wdl: bool = false;

// m = min(240, ply) / 64
const AS: [4]f64 = .{ -7.40343244, 45.35831446, -35.16076861, 192.49866823 };
const BS: [4]f64 = .{ -5.80808972, 47.88443986, -126.65793303, 176.74595484 };

const SCORE_CLAMP: f64 = 2000.0;
const MAX_PLY: usize = 240;

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
