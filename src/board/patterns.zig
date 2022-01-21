const BB = @import("./bitboard.zig");
const C = @import("../c.zig");
const std = @import("std");

pub inline fn is_valid(rank: i8, file: i8) bool {
    return 0 <= rank and rank < 8 and 0 <= file and file < 8;
}

pub inline fn rank_file_to_bb(rank: i8, file: i8) u64 {
    if (is_valid(rank, file)) {
        return index_to_bb(@intCast(u6, rank * 8 + file));
    } else {
        return 0;
    }
}

pub inline fn index_to_bb(index: u6) u64 {
    return @intCast(u64, 1) << index;
}

pub const KingDelta: [8][2]i8 = .{
    .{ -1, -1 },
    .{ -1, 0 },
    .{ -1, 1 },
    .{ 0, -1 },
    .{ 0, 1 },
    .{ 1, -1 },
    .{ 1, 0 },
    .{ 1, 1 },
};

pub const KnightDelta: [8][2]i8 = .{
    .{ -1, -2 },
    .{ -2, -1 },
    .{ -1, 2 },
    .{ -2, 1 },
    .{ 1, -2 },
    .{ 2, -1 },
    .{ 1, 2 },
    .{ 2, 1 },
};

pub const BishopDelta: [4][2]i8 = .{
    .{ -1, -1 },
    .{ -1, 1 },
    .{ 1, -1 },
    .{ 1, 1 },
};

pub const RookDelta: [4][2]i8 = .{
    .{ -1, 0 },
    .{ 0, -1 },
    .{ 1, 0 },
    .{ 0, 1 },
};

pub const PawnDelta: [2][2][2]i8 = .{ .{
    .{ 1, 1 },
    .{ 1, -1 },
}, .{
    .{ -1, -1 },
    .{ -1, 1 },
} };

pub const KingPatterns: [C.SQ_C.N_SQUARES]u64 align(64) = init: {
    @setEvalBranchQuota(C.SQ_C.N_SQUARES * 8 * 3);
    var patterns: [C.SQ_C.N_SQUARES]u64 align(64) = undefined;
    for (patterns) |*pt, idx| {
        const r: i8 = BB.rank_of(idx);
        const f: i8 = BB.file_of(idx);
        var bb: u64 = 0;
        for (KingDelta) |delta| {
            bb |= rank_file_to_bb(r + delta[0], f + delta[1]);
        }
        pt.* = bb;
    }
    break :init patterns;
};

pub const KnightPatterns: [C.SQ_C.N_SQUARES]u64 align(64) = init: {
    @setEvalBranchQuota(C.SQ_C.N_SQUARES * 8 * 3);
    var patterns: [C.SQ_C.N_SQUARES]u64 align(64) = undefined;
    for (patterns) |*pt, idx| {
        const r: i8 = BB.rank_of(idx);
        const f: i8 = BB.file_of(idx);
        var bb: u64 = 0;
        for (KnightDelta) |delta| {
            bb |= rank_file_to_bb(r + delta[0], f + delta[1]);
        }
        pt.* = bb;
    }
    break :init patterns;
};

pub const PawnCapturePatterns: [2][C.SQ_C.N_SQUARES]u64 align(64) = init: {
    @setEvalBranchQuota(C.SQ_C.N_SQUARES * 8 * 3);
    var patterns: [2][C.SQ_C.N_SQUARES]u64 align(64) = undefined;
    for (patterns) |*ptc, c| {
        for (ptc.*) |*pt, idx| {
            const r: i8 = BB.rank_of(idx);
            const f: i8 = BB.file_of(idx);
            var bb: u64 = 0;
            for (PawnDelta[c]) |delta| {
                bb |= rank_file_to_bb(r + delta[0], f + delta[1]);
            }
            pt.* = bb;
        }
    }
    break :init patterns;
};

// get slider attacks using computation
pub fn slider_attacks(sq: u6, occupied: u64, comptime delta: [4][2]i8) u64 {
    var result: u64 = 0;

    inline for (delta) |d| {
        const dr = d[0];
        const df = d[1];

        var rank = @intCast(i8, BB.rank_of(sq));
        var file = @intCast(i8, BB.file_of(sq));
        while (is_valid(rank, file)) {
            const k = rank_file_to_bb(rank, file);
            result |= k;
            if (occupied & k != 0) {
                break;
            }
            rank += dr;
            file += df;
        }
    }

    return result;
}

pub inline fn get_bishop_attacks(sq: u6, occupied: u64) u64 {
    return slider_attacks(sq, occupied, BishopDelta);
}

pub inline fn get_rook_attacks(sq: u6, occupied: u64) u64 {
    return slider_attacks(sq, occupied, RookDelta);
}

pub inline fn get_queen_attacks(sq: u6, occupied: u64) u64 {
    return get_bishop_attacks(sq, occupied) | get_rook_attacks(sq, occupied);
}
