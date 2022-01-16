const BB = @import("./bitboard.zig");
const C = @import("../c.zig");

pub inline fn is_valid(rank: i8, file: i8) bool {
    return 0 <= rank and rank < C.SQ_C.N_RANKS and 0 <= file and file < C.SQ_C.N_RANKS;
}

pub inline fn rank_file_to_bb(rank: i8, file: i8) u64 {
    if (is_valid(rank, file)) {
        return index_to_bb(@intCast(u6, (rank << 3) + file));
    } else {
        return 0;
    }
}

pub inline fn index_to_bb(index: u6) u64 {
    return @intCast(u64, 1) << index;
}

pub const KingDelta: [8][2]i8 = [8][2]i8{
    [2]i8{ -1, -1 },
    [2]i8{ -1, 0 },
    [2]i8{ -1, 1 },
    [2]i8{ 0, -1 },
    [2]i8{ 0, 1 },
    [2]i8{ 1, -1 },
    [2]i8{ 1, 0 },
    [2]i8{ 1, 1 },
};

pub const KnightDelta: [8][2]i8 = [8][2]i8{
    [2]i8{ -1, -2 },
    [2]i8{ -2, -1 },
    [2]i8{ -1, 2 },
    [2]i8{ -2, 1 },
    [2]i8{ 1, -2 },
    [2]i8{ 2, -1 },
    [2]i8{ 1, 2 },
    [2]i8{ 2, 1 },
};

pub const KingPatterns: [64]u64 align(64) = init: {
    @setEvalBranchQuota(64 * 8 * 3);
    var patterns: [64]u64 align(64) = undefined;
    for (patterns) |*pt, idx| {
        const r: i8 = idx >> 3;
        const f: i8 = idx & 7;
        var bb: u64 = 0;
        for (KingDelta) |delta| {
            bb |= rank_file_to_bb(r + delta[0], f + delta[1]);
        }
        pt.* = bb;
    }
    break :init patterns;
};

pub const KnightPatterns: [64]u64 align(64) = init: {
    @setEvalBranchQuota(64 * 8 * 3);
    var patterns: [64]u64 align(64) = undefined;
    for (patterns) |*pt, idx| {
        const r: i8 = idx >> 3;
        const f: i8 = idx & 7;
        var bb: u64 = 0;
        for (KnightDelta) |delta| {
            bb |= rank_file_to_bb(r + delta[0], f + delta[1]);
        }
        pt.* = bb;
    }
    break :init patterns;
};
