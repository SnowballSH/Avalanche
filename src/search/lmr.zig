const std = @import("std");

pub const QuietLMR: [32][32]i16 = init: {
    @setEvalBranchQuota(32 * 32 * 6);
    var reductions: [32][32]i16 = undefined;
    var depth = 1;
    inline while (depth < 32) {
        var moves = 1;
        inline while (moves < 32) {
            reductions[depth][moves] = @floatToInt(i16, @floor(0.8 + std.math.ln(@intToFloat(f32, depth)) * std.math.ln(1.2 * @intToFloat(f32, moves)) / 2.5));
            moves += 1;
        }
        depth += 1;
    }
    break :init reductions;
};

pub const NoisyLMR: [32][32]i16 = init: {
    @setEvalBranchQuota(32 * 32 * 6);
    var reductions: [32][32]i16 = undefined;
    var depth = 1;
    inline while (depth < 32) {
        var moves = 1;
        inline while (moves < 32) {
            reductions[depth][moves] = @floatToInt(i16, @floor(std.math.ln(@intToFloat(f32, depth)) * std.math.ln(1.2 * @intToFloat(f32, moves)) / 3.5));
            moves += 1;
        }
        depth += 1;
    }
    break :init reductions;
};
