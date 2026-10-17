//! The mapping from a position to its index in a table, and the per-table parameters of that
//! mapping that a file's header describes. Only the piece and file encodings exist here: the rank
//! encoding belongs to the DTM tables, which Avalanche does not probe.

const std = @import("std");
const pairs = @import("pairs.zig");

pub const MAX_PIECES = 7;

pub const Encoding = enum { piece, file };

/// What a table's name says about its material.
pub const Material = struct {
    num: u8,
    /// Piece tables: exactly two unique pieces, the kings, so both are encoded together.
    kk_enc: bool,
    /// Pawn tables: the pawns of the leading colour first.
    pawns: [2]u8,
};

pub const EncInfo = struct {
    pairs: pairs.PairsData,
    factor: [MAX_PIECES]u64,
    pieces: [MAX_PIECES]u8,
    norm: [MAX_PIECES]u8,
};

const OFF_DIAG = [64]i8{
    0, -1, -1, -1, -1, -1, -1, -1,
    1, 0,  -1, -1, -1, -1, -1, -1,
    1, 1,  0,  -1, -1, -1, -1, -1,
    1, 1,  1,  0,  -1, -1, -1, -1,
    1, 1,  1,  1,  0,  -1, -1, -1,
    1, 1,  1,  1,  1,  0,  -1, -1,
    1, 1,  1,  1,  1,  1,  0,  -1,
    1, 1,  1,  1,  1,  1,  1,  0,
};

const TRIANGLE = [64]u8{
    6, 0, 1, 2, 2, 1, 0, 6,
    0, 7, 3, 4, 4, 3, 7, 0,
    1, 3, 8, 5, 5, 8, 3, 1,
    2, 4, 5, 9, 9, 5, 4, 2,
    2, 4, 5, 9, 9, 5, 4, 2,
    1, 3, 8, 5, 5, 8, 3, 1,
    0, 7, 3, 4, 4, 3, 7, 0,
    6, 0, 1, 2, 2, 1, 0, 6,
};

const FLIP_DIAG = blk: {
    var squares: [64]u8 = undefined;
    for (&squares, 0..) |*sq, i| sq.* = (i % 8) * 8 + i / 8;
    break :blk squares;
};

const LOWER = [64]u8{
    28, 0,  1,  2,  3,  4,  5,  6,
    0,  29, 7,  8,  9,  10, 11, 12,
    1,  7,  30, 13, 14, 15, 16, 17,
    2,  8,  13, 31, 18, 19, 20, 21,
    3,  9,  14, 18, 32, 22, 23, 24,
    4,  10, 15, 19, 22, 33, 25, 26,
    5,  11, 16, 20, 23, 25, 34, 27,
    6,  12, 17, 21, 24, 26, 27, 35,
};

const DIAG = [64]u8{
    0,  0,  0,  0,  0,  0,  0, 8,
    0,  1,  0,  0,  0,  0,  9, 0,
    0,  0,  2,  0,  0,  10, 0, 0,
    0,  0,  0,  3,  11, 0,  0, 0,
    0,  0,  0,  12, 4,  0,  0, 0,
    0,  0,  13, 0,  0,  5,  0, 0,
    0,  14, 0,  0,  0,  0,  6, 0,
    15, 0,  0,  0,  0,  0,  0, 7,
};

const FLAP = [64]u8{
    0, 0,  0,  0,  0,  0,  0,  0,
    0, 6,  12, 18, 18, 12, 6,  0,
    1, 7,  13, 19, 19, 13, 7,  1,
    2, 8,  14, 20, 20, 14, 8,  2,
    3, 9,  15, 21, 21, 15, 9,  3,
    4, 10, 16, 22, 22, 16, 10, 4,
    5, 11, 17, 23, 23, 17, 11, 5,
    0, 0,  0,  0,  0,  0,  0,  0,
};

const PAWN_TWIST = [64]u8{
    0,  0,  0,  0,  0,  0,  0,  0,
    47, 35, 23, 11, 10, 22, 34, 46,
    45, 33, 21, 9,  8,  20, 32, 44,
    43, 31, 19, 7,  6,  18, 30, 42,
    41, 29, 17, 5,  4,  16, 28, 40,
    39, 27, 15, 3,  2,  14, 26, 38,
    37, 25, 13, 1,  0,  12, 24, 36,
    0,  0,  0,  0,  0,  0,  0,  0,
};

const KK_IDX = [10][64]i16{
    .{
        -1, -1, -1, 0,  1,  2,  3,  4,
        -1, -1, -1, 5,  6,  7,  8,  9,
        10, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25,
        26, 27, 28, 29, 30, 31, 32, 33,
        34, 35, 36, 37, 38, 39, 40, 41,
        42, 43, 44, 45, 46, 47, 48, 49,
        50, 51, 52, 53, 54, 55, 56, 57,
    },
    .{
        58,  -1,  -1,  -1,  59,  60,  61,  62,
        63,  -1,  -1,  -1,  64,  65,  66,  67,
        68,  69,  70,  71,  72,  73,  74,  75,
        76,  77,  78,  79,  80,  81,  82,  83,
        84,  85,  86,  87,  88,  89,  90,  91,
        92,  93,  94,  95,  96,  97,  98,  99,
        100, 101, 102, 103, 104, 105, 106, 107,
        108, 109, 110, 111, 112, 113, 114, 115,
    },
    .{
        116, 117, -1,  -1,  -1,  118, 119, 120,
        121, 122, -1,  -1,  -1,  123, 124, 125,
        126, 127, 128, 129, 130, 131, 132, 133,
        134, 135, 136, 137, 138, 139, 140, 141,
        142, 143, 144, 145, 146, 147, 148, 149,
        150, 151, 152, 153, 154, 155, 156, 157,
        158, 159, 160, 161, 162, 163, 164, 165,
        166, 167, 168, 169, 170, 171, 172, 173,
    },
    .{
        174, -1,  -1,  -1,  175, 176, 177, 178,
        179, -1,  -1,  -1,  180, 181, 182, 183,
        184, -1,  -1,  -1,  185, 186, 187, 188,
        189, 190, 191, 192, 193, 194, 195, 196,
        197, 198, 199, 200, 201, 202, 203, 204,
        205, 206, 207, 208, 209, 210, 211, 212,
        213, 214, 215, 216, 217, 218, 219, 220,
        221, 222, 223, 224, 225, 226, 227, 228,
    },
    .{
        229, 230, -1,  -1,  -1,  231, 232, 233,
        234, 235, -1,  -1,  -1,  236, 237, 238,
        239, 240, -1,  -1,  -1,  241, 242, 243,
        244, 245, 246, 247, 248, 249, 250, 251,
        252, 253, 254, 255, 256, 257, 258, 259,
        260, 261, 262, 263, 264, 265, 266, 267,
        268, 269, 270, 271, 272, 273, 274, 275,
        276, 277, 278, 279, 280, 281, 282, 283,
    },
    .{
        284, 285, 286, 287, 288, 289, 290, 291,
        292, 293, -1,  -1,  -1,  294, 295, 296,
        297, 298, -1,  -1,  -1,  299, 300, 301,
        302, 303, -1,  -1,  -1,  304, 305, 306,
        307, 308, 309, 310, 311, 312, 313, 314,
        315, 316, 317, 318, 319, 320, 321, 322,
        323, 324, 325, 326, 327, 328, 329, 330,
        331, 332, 333, 334, 335, 336, 337, 338,
    },
    .{
        -1, -1, 339, 340, 341, 342, 343, 344,
        -1, -1, 345, 346, 347, 348, 349, 350,
        -1, -1, 441, 351, 352, 353, 354, 355,
        -1, -1, -1,  442, 356, 357, 358, 359,
        -1, -1, -1,  -1,  443, 360, 361, 362,
        -1, -1, -1,  -1,  -1,  444, 363, 364,
        -1, -1, -1,  -1,  -1,  -1,  445, 365,
        -1, -1, -1,  -1,  -1,  -1,  -1,  446,
    },
    .{
        -1, -1, -1, 366, 367, 368, 369, 370,
        -1, -1, -1, 371, 372, 373, 374, 375,
        -1, -1, -1, 376, 377, 378, 379, 380,
        -1, -1, -1, 447, 381, 382, 383, 384,
        -1, -1, -1, -1,  448, 385, 386, 387,
        -1, -1, -1, -1,  -1,  449, 388, 389,
        -1, -1, -1, -1,  -1,  -1,  450, 390,
        -1, -1, -1, -1,  -1,  -1,  -1,  451,
    },
    .{
        452, 391, 392, 393, 394, 395, 396, 397,
        -1,  -1,  -1,  -1,  398, 399, 400, 401,
        -1,  -1,  -1,  -1,  402, 403, 404, 405,
        -1,  -1,  -1,  -1,  406, 407, 408, 409,
        -1,  -1,  -1,  -1,  453, 410, 411, 412,
        -1,  -1,  -1,  -1,  -1,  454, 413, 414,
        -1,  -1,  -1,  -1,  -1,  -1,  455, 415,
        -1,  -1,  -1,  -1,  -1,  -1,  -1,  456,
    },
    .{
        457, 416, 417, 418, 419, 420, 421, 422,
        -1,  458, 423, 424, 425, 426, 427, 428,
        -1,  -1,  -1,  -1,  -1,  429, 430, 431,
        -1,  -1,  -1,  -1,  -1,  432, 433, 434,
        -1,  -1,  -1,  -1,  -1,  435, 436, 437,
        -1,  -1,  -1,  -1,  -1,  459, 438, 439,
        -1,  -1,  -1,  -1,  -1,  -1,  460, 440,
        -1,  -1,  -1,  -1,  -1,  -1,  -1,  461,
    },
};

const FILE_TO_FILE = [8]u8{ 0, 1, 2, 3, 3, 2, 1, 0 };

/// `BINOMIAL[k][n]` is n choose k.
const BINOMIAL = blk: {
    @setEvalBranchQuota(10_000);
    var table: [MAX_PIECES][64]u64 = undefined;
    for (&table, 0..) |*row, k| {
        for (row, 0..) |*entry, n| {
            var numerator: u64 = 1;
            var denominator: u64 = 1;
            for (0..k) |i| {
                numerator *%= @as(u64, n) -% i;
                denominator *= i + 1;
            }
            entry.* = numerator / denominator;
        }
    }
    break :blk table;
};

const PawnTables = struct {
    index: [6][24]u64,
    factor: [6][4]u64,
};

const PAWN = blk: {
    @setEvalBranchQuota(10_000);
    var result: PawnTables = undefined;
    for (0..6) |k| {
        var sum: u64 = 0;
        for (0..24) |j| {
            result.index[k][j] = sum;
            sum += BINOMIAL[k][PAWN_TWIST[(1 + j % 6) * 8 + j / 6]];
            if ((j + 1) % 6 == 0) {
                result.factor[k][j / 6] = sum;
                sum = 0;
            }
        }
    }
    break :blk result;
};

/// Brings the leading pawn to `squares[0]` and returns its file in the a to d half.
pub fn leading_pawn(squares: *[MAX_PIECES]u8, material: Material) u2 {
    for (1..material.pawns[0]) |i| {
        if (FLAP[squares[0]] > FLAP[squares[i]]) std.mem.swap(u8, &squares[0], &squares[i]);
    }
    return @intCast(FILE_TO_FILE[squares[0] & 7]);
}

fn sort_ascending(squares: []u8) void {
    std.sort.insertion(u8, squares, {}, std.sort.asc(u8));
}

pub fn encode(squares: *[MAX_PIECES]u8, ei: *const EncInfo, material: Material, comptime encoding: Encoding) u64 {
    const n = material.num;
    const p = squares[0..n];

    if (p[0] & 0x04 != 0) {
        for (p) |*sq| sq.* ^= 0x07;
    }

    var idx: u64 = undefined;
    var k: usize = undefined;
    switch (encoding) {
        .piece => {
            if (p[0] & 0x20 != 0) {
                for (p) |*sq| sq.* ^= 0x38;
            }

            const leading: usize = if (material.kk_enc) 2 else 3;
            for (p, 0..) |sq, i| {
                if (OFF_DIAG[sq] == 0) continue;
                if (OFF_DIAG[sq] > 0 and i < leading) {
                    for (p) |*s| s.* = FLIP_DIAG[s.*];
                }
                break;
            }

            if (material.kk_enc) {
                idx = @intCast(KK_IDX[TRIANGLE[p[0]]][p[1]]);
                k = 2;
            } else {
                const s1: u64 = @intFromBool(p[1] > p[0]);
                const s2: u64 = @as(u64, @intFromBool(p[2] > p[0])) + @intFromBool(p[2] > p[1]);
                const p1: u64 = p[1];
                const p2: u64 = p[2];
                const diag0: u64 = DIAG[p[0]];
                const diag1: u64 = DIAG[p[1]];
                idx = if (OFF_DIAG[p[0]] != 0)
                    @as(u64, TRIANGLE[p[0]]) * 63 * 62 + (p1 - s1) * 62 + (p2 - s2)
                else if (OFF_DIAG[p[1]] != 0)
                    6 * 63 * 62 + diag0 * 28 * 62 + @as(u64, LOWER[p[1]]) * 62 + p2 - s2
                else if (OFF_DIAG[p[2]] != 0)
                    6 * 63 * 62 + 4 * 28 * 62 + diag0 * 7 * 28 + (diag1 - s1) * 28 + LOWER[p[2]]
                else
                    6 * 63 * 62 + 4 * 28 * 62 + 4 * 7 * 28 + diag0 * 7 * 6 + (diag1 - s1) * 6 + (DIAG[p[2]] - s2);
                k = 3;
            }
            idx *= ei.factor[0];
        },
        .file => {
            k = material.pawns[0];
            const leaders = p[1..k];
            std.sort.insertion(u8, leaders, {}, struct {
                fn before(_: void, a: u8, b: u8) bool {
                    return PAWN_TWIST[a] > PAWN_TWIST[b];
                }
            }.before);

            idx = PAWN.index[k - 1][FLAP[p[0]]];
            for (leaders, 1..) |sq, i| idx += BINOMIAL[k - i][PAWN_TWIST[sq]];
            idx *= ei.factor[0];

            if (material.pawns[1] != 0) {
                const t = k + material.pawns[1];
                idx += place(p, k, t, 8) * ei.factor[k];
                k = t;
            }
        },
    }

    while (k < n) {
        const t = k + ei.norm[k];
        idx += place(p, k, t, 0) * ei.factor[k];
        k = t;
    }
    return idx;
}

/// The index of the like pieces `p[k..t]` among the squares that `p[0..k]` leave free, counted
/// from square `first`.
inline fn place(p: []u8, k: usize, t: usize, comptime first: u8) u64 {
    sort_ascending(p[k..t]);
    var s: u64 = 0;
    for (p[k..t], k..) |sq, i| {
        var skips: u8 = 0;
        for (p[0..k]) |placed| skips += @intFromBool(sq > placed);
        s += BINOMIAL[i - k + 1][sq - skips - first];
    }
    return s;
}

/// The number of ways to place `k` like pieces on `n` squares.
fn subfactor(k: usize, n: u64) u64 {
    var numerator = n;
    var denominator: u64 = 1;
    for (1..k) |i| {
        numerator *= n - i;
        denominator *= i + 1;
    }
    return numerator / denominator;
}

/// Reads the piece order of one subtable from `header` (the nibbles at `shift`) and returns the
/// subtable's size.
pub fn init_enc_info(ei: *EncInfo, material: Material, header: []const u8, shift: u3, file: u2, comptime encoding: Encoding) u64 {
    const more_pawns = encoding != .piece and material.pawns[1] > 0;
    const num = material.num;

    for (0..num) |i| {
        ei.pieces[i] = (header[i + 1 + @intFromBool(more_pawns)] >> shift) & 0x0f;
        ei.norm[i] = 0;
    }

    const order = (header[0] >> shift) & 0x0f;
    const order2: u8 = if (more_pawns) (header[1] >> shift) & 0x0f else 0x0f;

    ei.norm[0] = switch (encoding) {
        .file => material.pawns[0],
        .piece => if (material.kk_enc) 2 else 3,
    };
    var k: usize = ei.norm[0];

    if (more_pawns) {
        ei.norm[k] = material.pawns[1];
        k += ei.norm[k];
    }

    var i = k;
    while (i < num) : (i += ei.norm[i]) {
        var j = i;
        while (j < num and ei.pieces[j] == ei.pieces[i]) : (j += 1) ei.norm[i] += 1;
    }

    var free: u64 = 64 - k;
    var f: u64 = 1;
    var step: u8 = 0;
    while (k < num or step == order or step == order2) : (step += 1) {
        if (step == order) {
            ei.factor[0] = f;
            f *= switch (encoding) {
                .file => PAWN.factor[ei.norm[0] - 1][file],
                .piece => if (material.kk_enc) 462 else 31332,
            };
        } else if (step == order2) {
            ei.factor[ei.norm[0]] = f;
            f *= subfactor(ei.norm[ei.norm[0]], 48 - @as(u64, ei.norm[0]));
        } else {
            ei.factor[k] = f;
            f *= subfactor(ei.norm[k], free);
            free -= ei.norm[k];
            k += ei.norm[k];
        }
    }
    return f;
}

test "the binomial table" {
    try std.testing.expectEqual(@as(u64, 1), BINOMIAL[0][0]);
    try std.testing.expectEqual(@as(u64, 0), BINOMIAL[2][1]);
    try std.testing.expectEqual(@as(u64, 1953), BINOMIAL[2][63]);
    try std.testing.expectEqual(@as(u64, 67_945_521), BINOMIAL[6][63]);
}
