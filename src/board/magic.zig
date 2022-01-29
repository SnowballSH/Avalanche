const std = @import("std");
const BB = @import("./bitboard.zig");
const Patterns = @import("./patterns.zig");

const C = @import("../c.zig");

// zig fmt: off
pub const MAGIC_ROOK_SHIFTS: [64]u8 = . {
    12, 11, 11, 11, 11, 11, 11, 12,
    11, 10, 10, 10, 10, 10, 10, 11,
    11, 10, 10, 10, 10, 10, 10, 11,
    11, 10, 10, 10, 10, 10, 10, 11,
    11, 10, 10, 10, 10, 10, 10, 11,
    11, 10, 10, 10, 10, 10, 10, 11,
    11, 10, 10, 10, 10, 10, 10, 11,
    12, 11, 11, 11, 11, 11, 11, 12,
};

pub const MAGIC_BISHOP_SHIFTS: [64]u8 = . {
    6, 5, 5, 5, 5, 5, 5, 6,
    5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 7, 7, 7, 7, 5, 5,
    5, 5, 7, 9, 9, 7, 5, 5,
    5, 5, 7, 9, 9, 7, 5, 5,
    5, 5, 7, 7, 7, 7, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5,
    6, 5, 5, 5, 5, 5, 5, 6,
};

// zig fmt: on

pub const MagicField = struct {
    mask: u64,
    shift: u8,
    magic: u64,
    attacks: std.ArrayList(u64),
};

pub fn new_magic_field() MagicField {
    return MagicField{
        .mask = 0,
        .shift = 0,
        .magic = 0,
        .attacks = undefined,
    };
}

pub var MAGIC_ROOK_FIELDS: [64]MagicField = init: {
    var patterns: [64]MagicField = undefined;
    for (patterns) |*pt| {
        pt.* = new_magic_field();
    }
    break :init patterns;
};

pub var MAGIC_BISHOP_FIELDS: [64]MagicField = init: {
    var patterns: [64]MagicField = undefined;
    for (patterns) |*pt| {
        pt.* = new_magic_field();
    }
    break :init patterns;
};

pub const MAGIC_ROOK_NUMBERS: [64]u64 = .{
    0xA180022080400230, 0x0040100040022000, 0x0080088020001002, 0x0080080280841000,
    0x4200042010460008, 0x04800A0003040080, 0x0400110082041008, 0x008000A041000880,
    0x10138001A080C010, 0x0000804008200480, 0x00010011012000C0, 0x0022004128102200,
    0x000200081201200C, 0x202A001048460004, 0x0081000100420004, 0x4000800380004500,
    0x0000208002904001, 0x0090004040026008, 0x0208808010002001, 0x2002020020704940,
    0x8048010008110005, 0x6820808004002200, 0x0A80040008023011, 0x00B1460000811044,
    0x4204400080008EA0, 0xB002400180200184, 0x2020200080100380, 0x0010080080100080,
    0x2204080080800400, 0x0000A40080360080, 0x02040604002810B1, 0x008C218600004104,
    0x8180004000402000, 0x488C402000401001, 0x4018A00080801004, 0x1230002105001008,
    0x8904800800800400, 0x0042000C42003810, 0x008408110400B012, 0x0018086182000401,
    0x2240088020C28000, 0x001001201040C004, 0x0A02008010420020, 0x0010003009010060,
    0x0004008008008014, 0x0080020004008080, 0x0282020001008080, 0x50000181204A0004,
    0x48FFFE99FECFAA00, 0x48FFFE99FECFAA00, 0x497FFFADFF9C2E00, 0x613FFFDDFFCE9200,
    0xFFFFFFE9FFE7CE00, 0xFFFFFFF5FFF3E600, 0x0010301802830400, 0x510FFFF5F63C96A0,
    0xEBFFFFB9FF9FC526, 0x61FFFEDDFEEDAEAE, 0x53BFFFEDFFDEB1A2, 0x127FFFB9FFDFB5F6,
    0x411FFFDDFFDBF4D6, 0x0801000804000603, 0x0003FFEF27EEBE74, 0x7645FFFECBFEA79E,
};

pub const MAGIC_BISHOP_NUMBERS: [64]u64 = .{
    18018831217729569,
    7566619154406457857,
    5769265629886676992,
    11836590258269718532,
    1130711343955976,
    5188711992789051600,
    2595223508957332480,
    4613977417873621504,
    52914355962521,
    720584771016851496,
    81672282392551681,
    1443689575104709154,
    2315497890614674434,
    4504720752246850,
    4683757923315231234,
    36030472065647684,
    869195003027850256,
    2533343613162048,
    9077585216569856,
    4613938370177974404,
    1819740157378038914,
    3026981903850120192,
    150100551208960,
    9250534398112121088,
    13983151348368280608,
    2453353491453707520,
    1189838711584489508,
    5188437052588310784,
    73192707253608448,
    1171008470900605200,
    2304869587485219,
    72216611327312384,
    1416312765554720,
    4902326593860936194,
    7494553009214460168,
    4535619944704,
    289464028735078528,
    9572356859152384,
    24771999121551488,
    4611968773312806976,
    594765529323978768,
    290309994972256,
    73747544500340740,
    4504287224791296,
    18109643855331840,
    9242583324889711104,
    302884692999082816,
    2315421958013010688,
    2306969493907701858,
    1153521859699409280,
    2254007511875588,
    12687767152414427136,
    9008713537683586,
    164399116042125312,
    1315103887499739200,
    24772082878251017,
    1188989888384471040,
    144124276262832640,
    9801521853783640080,
    1153489127519306752,
    5783255261986030084,
    9259968324145381506,
    9513590469632983681,
    9377059641948700736,
};

fn get_rook_mask(index: u6) u64 {
    return Patterns.get_rook_attacks(index, 0) & ~C.SQ_C.EDGE;
}

fn get_bishop_mask(index: u6) u64 {
    return Patterns.DiagPatterns[index] & ~C.SQ_C.EDGE;
}

fn apply_magic_for_field(
    shift: u8,
    count: i32,
    mask: u64,
    permutations: *std.ArrayList(u64),
    attacks: *std.ArrayList(u64),
    magic_number: u64,
    magic_field: *MagicField,
) void {
    magic_field.*.shift = shift;
    magic_field.*.mask = mask;
    magic_field.*.magic = magic_number;

    magic_field.*.attacks = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;
    var k: i32 = 0;
    while (k < count) {
        magic_field.*.attacks.append(0) catch {};
        k += 1;
    }

    var index: usize = 0;
    while (index < count) {
        var permutation = permutations.*.items[index];
        var attack = attacks.*.items[index];

        var hash = (permutation *% magic_number) >> @intCast(u6, 64 - shift);
        magic_field.*.attacks.items[hash] = attack;
        index += 1;
    }
}

pub fn init_magic() void {
    var index: u7 = 0;
    while (index < 64) {
        apply_bishop_magic_for_field(@intCast(u6, index));
        apply_rook_magic_for_field(@intCast(u6, index));
        index += 1;
    }
}

pub fn get_bishop_moves(sq: u6, occupancy: u64) u64 {
    var hash = occupancy & MAGIC_BISHOP_FIELDS[sq].mask;
    hash *%= MAGIC_BISHOP_FIELDS[sq].magic;
    hash >>= @intCast(u6, 64 - MAGIC_BISHOP_FIELDS[sq].shift);

    return MAGIC_BISHOP_FIELDS[sq].attacks.items[hash];
}

pub fn get_rook_moves(sq: u6, occupancy: u64) u64 {
    var hash = occupancy & MAGIC_ROOK_FIELDS[sq].mask;
    hash *%= MAGIC_ROOK_FIELDS[sq].magic;
    hash >>= @intCast(u6, 64 - MAGIC_ROOK_FIELDS[sq].shift);

    return MAGIC_ROOK_FIELDS[sq].attacks.items[hash];
}

fn apply_bishop_magic_for_field(field: u6) void {
    var shift = MAGIC_BISHOP_SHIFTS[field];
    var mask = get_bishop_mask(field);
    var count = @as(i32, 1) << @intCast(u5, shift);

    var permutations: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;
    var attacks: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;

    var index: u64 = 0;
    while (index < count) {
        var permutation = get_permutation(mask, index);

        permutations.append(permutation) catch {};
        attacks.append(Patterns.get_bishop_attacks(field, permutation)) catch {};

        index += 1;
    }

    var result = apply_magic_for_field(
        shift,
        count,
        mask,
        &permutations,
        &attacks,
        MAGIC_BISHOP_NUMBERS[field],
        &MAGIC_BISHOP_FIELDS[field],
    );
    attacks.deinit();
    permutations.deinit();
    return result;
}

fn apply_rook_magic_for_field(field: u6) void {
    var shift = MAGIC_ROOK_SHIFTS[field];
    var mask = get_rook_mask(field);
    var count = @as(i32, 1) << @intCast(u5, shift);

    var permutations: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;
    var attacks: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;

    var index: u64 = 0;
    while (index < count) {
        var permutation = get_permutation(mask, index);

        permutations.append(permutation) catch {};
        attacks.append(Patterns.get_rook_attacks(field, permutation)) catch {};

        index += 1;
    }

    var result = apply_magic_for_field(
        shift,
        count,
        mask,
        &permutations,
        &attacks,
        MAGIC_ROOK_NUMBERS[field],
        &MAGIC_ROOK_FIELDS[field],
    );
    attacks.deinit();
    permutations.deinit();
    return result;
}

fn get_permutation(mask_: u64, index_: u64) u64 {
    var mask = mask_;
    var index = index_;
    var result: u64 = 0;

    while (mask != 0) {
        var lsb_index = @intCast(u6, @ctz(u64, mask));
        mask &= mask - 1;

        result |= (index & 1) << lsb_index;
        index >>= 1;
    }

    return result;
}
