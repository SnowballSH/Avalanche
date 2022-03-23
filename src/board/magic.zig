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
    0xFFEDF9FD7CFCFFFF, 0xFC0962854A77F576, 0x5822022042000000, 0x2CA804A100200020,
    0x0204042200000900, 0x2002121024000002, 0xFC0A66C64A7EF576, 0x7FFDFDFCBD79FFFF,
    0xFC0846A64A34FFF6, 0xFC087A874A3CF7F6, 0x1001080204002100, 0x1810080489021800,
    0x0062040420010A00, 0x5028043004300020, 0xFC0864AE59B4FF76, 0x3C0860AF4B35FF76,
    0x73C01AF56CF4CFFB, 0x41A01CFAD64AAFFC, 0x040C0422080A0598, 0x4228020082004050,
    0x0200800400E00100, 0x020B001230021040, 0x7C0C028F5B34FF76, 0xFC0A028E5AB4DF76,
    0x0020208050A42180, 0x001004804B280200, 0x2048020024040010, 0x0102C04004010200,
    0x020408204C002010, 0x02411100020080C1, 0x102A008084042100, 0x0941030000A09846,
    0x0244100800400200, 0x4000901010080696, 0x0000280404180020, 0x0800042008240100,
    0x0220008400088020, 0x04020182000904C9, 0x0023010400020600, 0x0041040020110302,
    0xDCEFD9B54BFCC09F, 0xF95FFA765AFD602B, 0x1401210240484800, 0x0022244208010080,
    0x1105040104000210, 0x2040088800C40081, 0x43FF9A5CF4CA0C01, 0x4BFFCD8E7C587601,
    0xFC0FF2865334F576, 0xFC0BF6CE5924F576, 0x80000B0401040402, 0x0020004821880A00,
    0x8200002022440100, 0x0009431801010068, 0xC3FFB7DC36CA8C89, 0xC3FF8A54F4CA2C89,
    0xFFFFFCFCFD79EDFF, 0xFC0863FCCB147576, 0x040C000022013020, 0x2000104000420600,
    0x0400000260142410, 0x0800633408100500, 0xFC087E8E4BB2F736, 0x43FF9E4EF4CA2C89,
};

inline fn get_rook_mask(index: u6) u64 {
    var edge = ((C.SQ_C.RANK_1 | C.SQ_C.RANK_8) & ~C.SQ_C.RANKS[BB.rank_of(index)]) | ((C.SQ_C.FILE_A | C.SQ_C.FILE_H) & ~C.SQ_C.FILES[BB.file_of(index)]);
    return Patterns.get_rook_attacks(index, 0) & ~edge;
}

inline fn get_bishop_mask(index: u6) u64 {
    var edge = ((C.SQ_C.RANK_1 | C.SQ_C.RANK_8) & ~C.SQ_C.RANKS[BB.rank_of(index)]) | ((C.SQ_C.FILE_A | C.SQ_C.FILE_H) & ~C.SQ_C.FILES[BB.file_of(index)]);
    return Patterns.DiagPatterns[index] & ~edge;
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
    const shift = MAGIC_BISHOP_SHIFTS[field];
    const mask = get_bishop_mask(field);
    const count = @as(i32, 1) << @intCast(u5, shift);

    var permutations: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;
    var attacks: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;

    var index: u64 = 0;
    while (index < count) {
        var permutation = get_permutation(mask, index);

        permutations.append(permutation) catch {};
        attacks.append(Patterns.get_bishop_attacks(field, permutation)) catch {};

        index += 1;
    }

    const result = apply_magic_for_field(
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
    const shift = MAGIC_ROOK_SHIFTS[field];
    const mask = get_rook_mask(field);
    const count = @as(i32, 1) << @intCast(u5, shift);

    var permutations: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;
    var attacks: std.ArrayList(u64) = std.ArrayList(u64).initCapacity(std.heap.page_allocator, @intCast(usize, count)) catch unreachable;

    var index: u64 = 0;
    while (index < count) {
        var permutation = get_permutation(mask, index);

        permutations.append(permutation) catch {};
        attacks.append(Patterns.get_rook_attacks(field, permutation)) catch {};

        index += 1;
    }

    const result = apply_magic_for_field(
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
