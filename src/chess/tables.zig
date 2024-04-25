const std = @import("std");
const types = @import("types.zig");

pub const KingAttacks = [64]types.Bitboard{
    0x302,              0x705,              0xe0a,              0x1c14,
    0x3828,             0x7050,             0xe0a0,             0xc040,
    0x30203,            0x70507,            0xe0a0e,            0x1c141c,
    0x382838,           0x705070,           0xe0a0e0,           0xc040c0,
    0x3020300,          0x7050700,          0xe0a0e00,          0x1c141c00,
    0x38283800,         0x70507000,         0xe0a0e000,         0xc040c000,
    0x302030000,        0x705070000,        0xe0a0e0000,        0x1c141c0000,
    0x3828380000,       0x7050700000,       0xe0a0e00000,       0xc040c00000,
    0x30203000000,      0x70507000000,      0xe0a0e000000,      0x1c141c000000,
    0x382838000000,     0x705070000000,     0xe0a0e0000000,     0xc040c0000000,
    0x3020300000000,    0x7050700000000,    0xe0a0e00000000,    0x1c141c00000000,
    0x38283800000000,   0x70507000000000,   0xe0a0e000000000,   0xc040c000000000,
    0x302030000000000,  0x705070000000000,  0xe0a0e0000000000,  0x1c141c0000000000,
    0x3828380000000000, 0x7050700000000000, 0xe0a0e00000000000, 0xc040c00000000000,
    0x203000000000000,  0x507000000000000,  0xa0e000000000000,  0x141c000000000000,
    0x2838000000000000, 0x5070000000000000, 0xa0e0000000000000, 0x40c0000000000000,
};

pub const KnightAttacks = [64]types.Bitboard{
    0x20400,            0x50800,            0xa1100,            0x142200,
    0x284400,           0x508800,           0xa01000,           0x402000,
    0x2040004,          0x5080008,          0xa110011,          0x14220022,
    0x28440044,         0x50880088,         0xa0100010,         0x40200020,
    0x204000402,        0x508000805,        0xa1100110a,        0x1422002214,
    0x2844004428,       0x5088008850,       0xa0100010a0,       0x4020002040,
    0x20400040200,      0x50800080500,      0xa1100110a00,      0x142200221400,
    0x284400442800,     0x508800885000,     0xa0100010a000,     0x402000204000,
    0x2040004020000,    0x5080008050000,    0xa1100110a0000,    0x14220022140000,
    0x28440044280000,   0x50880088500000,   0xa0100010a00000,   0x40200020400000,
    0x204000402000000,  0x508000805000000,  0xa1100110a000000,  0x1422002214000000,
    0x2844004428000000, 0x5088008850000000, 0xa0100010a0000000, 0x4020002040000000,
    0x400040200000000,  0x800080500000000,  0x1100110a00000000, 0x2200221400000000,
    0x4400442800000000, 0x8800885000000000, 0x100010a000000000, 0x2000204000000000,
    0x4020000000000,    0x8050000000000,    0x110a0000000000,   0x22140000000000,
    0x44280000000000,   0x0088500000000000, 0x0010a00000000000, 0x20400000000000,
};

pub const WhitePawnAttacks = [64]types.Bitboard{
    0x200,              0x500,              0xa00,              0x1400,
    0x2800,             0x5000,             0xa000,             0x4000,
    0x20000,            0x50000,            0xa0000,            0x140000,
    0x280000,           0x500000,           0xa00000,           0x400000,
    0x2000000,          0x5000000,          0xa000000,          0x14000000,
    0x28000000,         0x50000000,         0xa0000000,         0x40000000,
    0x200000000,        0x500000000,        0xa00000000,        0x1400000000,
    0x2800000000,       0x5000000000,       0xa000000000,       0x4000000000,
    0x20000000000,      0x50000000000,      0xa0000000000,      0x140000000000,
    0x280000000000,     0x500000000000,     0xa00000000000,     0x400000000000,
    0x2000000000000,    0x5000000000000,    0xa000000000000,    0x14000000000000,
    0x28000000000000,   0x50000000000000,   0xa0000000000000,   0x40000000000000,
    0x200000000000000,  0x500000000000000,  0xa00000000000000,  0x1400000000000000,
    0x2800000000000000, 0x5000000000000000, 0xa000000000000000, 0x4000000000000000,
    0x0,                0x0,                0x0,                0x0,
    0x0,                0x0,                0x0,                0x0,
};

pub const BlackPawnAttacks = [64]types.Bitboard{
    0x0,              0x0,              0x0,              0x0,
    0x0,              0x0,              0x0,              0x0,
    0x2,              0x5,              0xa,              0x14,
    0x28,             0x50,             0xa0,             0x40,
    0x200,            0x500,            0xa00,            0x1400,
    0x2800,           0x5000,           0xa000,           0x4000,
    0x20000,          0x50000,          0xa0000,          0x140000,
    0x280000,         0x500000,         0xa00000,         0x400000,
    0x2000000,        0x5000000,        0xa000000,        0x14000000,
    0x28000000,       0x50000000,       0xa0000000,       0x40000000,
    0x200000000,      0x500000000,      0xa00000000,      0x1400000000,
    0x2800000000,     0x5000000000,     0xa000000000,     0x4000000000,
    0x20000000000,    0x50000000000,    0xa0000000000,    0x140000000000,
    0x280000000000,   0x500000000000,   0xa00000000000,   0x400000000000,
    0x2000000000000,  0x5000000000000,  0xa000000000000,  0x14000000000000,
    0x28000000000000, 0x50000000000000, 0xa0000000000000, 0x40000000000000,
};

pub inline fn reverse_bitboard(b_: types.Bitboard) types.Bitboard {
    var b = b_;
    b = (b & 0x5555555555555555) << 1 | ((b >> 1) & 0x5555555555555555);
    b = (b & 0x3333333333333333) << 2 | ((b >> 2) & 0x3333333333333333);
    b = (b & 0x0f0f0f0f0f0f0f0f) << 4 | ((b >> 4) & 0x0f0f0f0f0f0f0f0f);
    b = (b & 0x00ff00ff00ff00ff) << 8 | ((b >> 8) & 0x00ff00ff00ff00ff);

    return (b << 48) | ((b & 0xffff0000) << 16) |
        ((b >> 16) & 0xffff0000) | (b >> 48);
}

// Hyperbola Quintessence Algorithm
pub inline fn sliding_attack(square_: types.Square, occ: types.Bitboard, mask: types.Bitboard) types.Bitboard {
    const square = square_.index();
    return (((mask & occ) -% types.SquareIndexBB[square] *% 2) ^
        reverse_bitboard(reverse_bitboard(mask & occ) -% reverse_bitboard(types.SquareIndexBB[square]) *% 2)) & mask;
}

// ROOK MAGIC BITBOARDS

inline fn get_rook_attacks_for_init(square: types.Square, occ: types.Bitboard) types.Bitboard {
    return sliding_attack(square, occ, types.MaskFile[@intFromEnum(square.file())]) | sliding_attack(square, occ, types.MaskRank[@intFromEnum(square.rank())]);
}

var RookAttackMasks: [64]types.Bitboard = std.mem.zeroes([64]types.Bitboard);
var RookAttackShifts: [64]i32 = std.mem.zeroes([64]i32);
var RookAttacks: [64][4096]types.Bitboard = std.mem.zeroes([64][4096]types.Bitboard);

const RookMagics = [64]types.Bitboard{
    0x0080001020400080, 0x0040001000200040, 0x0080081000200080, 0x0080040800100080,
    0x0080020400080080, 0x0080010200040080, 0x0080008001000200, 0x0080002040800100,
    0x0000800020400080, 0x0000400020005000, 0x0000801000200080, 0x0000800800100080,
    0x0000800400080080, 0x0000800200040080, 0x0000800100020080, 0x0000800040800100,
    0x0000208000400080, 0x0000404000201000, 0x0000808010002000, 0x0000808008001000,
    0x0000808004000800, 0x0000808002000400, 0x0000010100020004, 0x0000020000408104,
    0x0000208080004000, 0x0000200040005000, 0x0000100080200080, 0x0000080080100080,
    0x0000040080080080, 0x0000020080040080, 0x0000010080800200, 0x0000800080004100,
    0x0000204000800080, 0x0000200040401000, 0x0000100080802000, 0x0000080080801000,
    0x0000040080800800, 0x0000020080800400, 0x0000020001010004, 0x0000800040800100,
    0x0000204000808000, 0x0000200040008080, 0x0000100020008080, 0x0000080010008080,
    0x0000040008008080, 0x0000020004008080, 0x0000010002008080, 0x0000004081020004,
    0x0000204000800080, 0x0000200040008080, 0x0000100020008080, 0x0000080010008080,
    0x0000040008008080, 0x0000020004008080, 0x0000800100020080, 0x0000800041000080,
    0x00FFFCDDFCED714A, 0x007FFCDDFCED714A, 0x003FFFCDFFD88096, 0x0000040810002101,
    0x0001000204080011, 0x0001000204000801, 0x0001000082000401, 0x0001FFFAABFAD1A2,
};

pub fn init_rook_attacks() void {
    var sq: usize = @intFromEnum(types.Square.a1);

    while (sq <= @intFromEnum(types.Square.h8)) : (sq += 1) {
        const edges = ((types.MaskRank[types.File.AFILE.index()] | types.MaskRank[types.File.HFILE.index()]) & ~types.MaskRank[types.rank_plain(sq)]) |
            ((types.MaskFile[types.File.AFILE.index()] | types.MaskFile[types.File.HFILE.index()]) & ~types.MaskFile[types.file_plain(sq)]);

        RookAttackMasks[sq] = (types.MaskRank[types.rank_plain(sq)] ^ types.MaskFile[types.file_plain(sq)]) & ~edges;
        RookAttackShifts[sq] = 64 - types.popcount(RookAttackMasks[sq]);

        var subset: types.Bitboard = 0;
        var index: types.Bitboard = 0;

        index = index *% RookMagics[sq];
        index = index >> @as(u6, @intCast(RookAttackShifts[sq]));
        RookAttacks[sq][index] = get_rook_attacks_for_init(@as(types.Square, @enumFromInt(sq)), subset);
        subset = (subset -% RookAttackMasks[sq]) & RookAttackMasks[sq];

        while (subset != 0) {
            index = subset;
            index = index *% RookMagics[sq];
            index = index >> @as(u6, @intCast(RookAttackShifts[sq]));
            RookAttacks[sq][index] = get_rook_attacks_for_init(@as(types.Square, @enumFromInt(sq)), subset);
            subset = (subset -% RookAttackMasks[sq]) & RookAttackMasks[sq];
        }
    }
}

// Returns the bitboard for rook attacks
pub inline fn get_rook_attacks(square: types.Square, occ: types.Bitboard) types.Bitboard {
    return RookAttacks[square.index()][((occ & RookAttackMasks[square.index()]) *% RookMagics[square.index()]) >> @as(u6, @intCast(RookAttackShifts[square.index()]))];
}

// Returns x-ray attacks, which is the attack when the first-layer blockers are removed.
pub inline fn get_xray_rook_attacks(square: types.Square, occ: types.Bitboard, blockers: types.Bitboard) types.Bitboard {
    const attacks = get_rook_attacks(square, occ);
    return attacks ^ get_rook_attacks(square, occ ^ (blockers & attacks));
}

// BISHOP MAGIC BITBOARDS

inline fn get_bishop_attacks_for_init(square: types.Square, occ: types.Bitboard) types.Bitboard {
    return sliding_attack(square, occ, types.MaskDiagonal[@as(usize, @intCast(square.diagonal()))]) | sliding_attack(square, occ, types.MaskAntiDiagonal[@as(usize, @intCast(square.anti_diagonal()))]);
}

var BishopAttackMasks: [64]types.Bitboard = std.mem.zeroes([64]types.Bitboard);
var BishopAttackShifts: [64]i32 = std.mem.zeroes([64]i32);
var BishopAttacks: [64][512]types.Bitboard = std.mem.zeroes([64][512]types.Bitboard);

const BishopMagics = [64]types.Bitboard{
    0x0002020202020200, 0x0002020202020000, 0x0004010202000000, 0x0004040080000000,
    0x0001104000000000, 0x0000821040000000, 0x0000410410400000, 0x0000104104104000,
    0x0000040404040400, 0x0000020202020200, 0x0000040102020000, 0x0000040400800000,
    0x0000011040000000, 0x0000008210400000, 0x0000004104104000, 0x0000002082082000,
    0x0004000808080800, 0x0002000404040400, 0x0001000202020200, 0x0000800802004000,
    0x0000800400A00000, 0x0000200100884000, 0x0000400082082000, 0x0000200041041000,
    0x0002080010101000, 0x0001040008080800, 0x0000208004010400, 0x0000404004010200,
    0x0000840000802000, 0x0000404002011000, 0x0000808001041000, 0x0000404000820800,
    0x0001041000202000, 0x0000820800101000, 0x0000104400080800, 0x0000020080080080,
    0x0000404040040100, 0x0000808100020100, 0x0001010100020800, 0x0000808080010400,
    0x0000820820004000, 0x0000410410002000, 0x0000082088001000, 0x0000002011000800,
    0x0000080100400400, 0x0001010101000200, 0x0002020202000400, 0x0001010101000200,
    0x0000410410400000, 0x0000208208200000, 0x0000002084100000, 0x0000000020880000,
    0x0000001002020000, 0x0000040408020000, 0x0004040404040000, 0x0002020202020000,
    0x0000104104104000, 0x0000002082082000, 0x0000000020841000, 0x0000000000208800,
    0x0000000010020200, 0x0000000404080200, 0x0000040404040400, 0x0002020202020200,
};

pub fn init_bishop_attacks() void {
    var sq: usize = @intFromEnum(types.Square.a1);

    while (sq <= @intFromEnum(types.Square.h8)) : (sq += 1) {
        const edges = ((types.MaskRank[types.File.AFILE.index()] | types.MaskRank[types.File.HFILE.index()]) & ~types.MaskRank[types.rank_plain(sq)]) |
            ((types.MaskFile[types.File.AFILE.index()] | types.MaskFile[types.File.HFILE.index()]) & ~types.MaskFile[types.file_plain(sq)]);

        BishopAttackMasks[sq] = (types.MaskDiagonal[types.diagonal_plain(sq)] ^ types.MaskAntiDiagonal[types.anti_diagonal_plain(sq)]) & ~edges;
        BishopAttackShifts[sq] = 64 - types.popcount(BishopAttackMasks[sq]);

        var subset: types.Bitboard = 0;
        var index: types.Bitboard = 0;

        index = index *% BishopMagics[sq];
        index = index >> @as(u6, @intCast(BishopAttackShifts[sq]));
        BishopAttacks[sq][index] = get_bishop_attacks_for_init(@as(types.Square, @enumFromInt(sq)), subset);
        subset = (subset -% BishopAttackMasks[sq]) & BishopAttackMasks[sq];

        while (subset != 0) {
            index = subset;
            index = index *% BishopMagics[sq];
            index = index >> @as(u6, @intCast(BishopAttackShifts[sq]));
            BishopAttacks[sq][index] = get_bishop_attacks_for_init(@as(types.Square, @enumFromInt(sq)), subset);
            subset = (subset -% BishopAttackMasks[sq]) & BishopAttackMasks[sq];
        }
    }
}

// Returns the bitboard for bishop attacks
pub inline fn get_bishop_attacks(square: types.Square, occ: types.Bitboard) types.Bitboard {
    return BishopAttacks[square.index()][((occ & BishopAttackMasks[square.index()]) *% BishopMagics[square.index()]) >> @as(u6, @intCast(BishopAttackShifts[square.index()]))];
}

// Returns x-ray attacks, which is the attack when the first-layer blockers are removed.
pub inline fn get_xray_bishop_attacks(square: types.Square, occ: types.Bitboard, blockers: types.Bitboard) types.Bitboard {
    const attacks = get_bishop_attacks(square, occ);
    return attacks ^ get_bishop_attacks(square, occ ^ (blockers & attacks));
}

// Squares between squares

// Bitboard for the squares between two squares, 0 if they are not aligned
pub var SquaresBetween: [64][64]types.Bitboard = std.mem.zeroes([64][64]types.Bitboard);

pub fn init_squares_between() void {
    var sq1: usize = @intFromEnum(types.Square.a1);

    while (sq1 <= @intFromEnum(types.Square.h8)) : (sq1 += 1) {
        var sq2: usize = @intFromEnum(types.Square.a1);

        while (sq2 <= @intFromEnum(types.Square.h8)) : (sq2 += 1) {
            const sqs = types.SquareIndexBB[sq1] | types.SquareIndexBB[sq2];
            if (types.file_plain(sq1) == types.file_plain(sq2) or types.rank_plain(sq1) == types.rank_plain(sq2)) {
                SquaresBetween[sq1][sq2] = get_rook_attacks_for_init(@as(types.Square, @enumFromInt(sq1)), sqs) & get_rook_attacks_for_init(@as(types.Square, @enumFromInt(sq2)), sqs);
            } else if (types.diagonal_plain(sq1) == types.diagonal_plain(sq2) or types.anti_diagonal_plain(sq1) == types.anti_diagonal_plain(sq2)) {
                SquaresBetween[sq1][sq2] = get_bishop_attacks_for_init(@as(types.Square, @enumFromInt(sq1)), sqs) & get_bishop_attacks_for_init(@as(types.Square, @enumFromInt(sq2)), sqs);
            } else {
                SquaresBetween[sq1][sq2] = 0;
            }
        }
    }
}

// Line between squares

// Bitboard for line of two squares, 0 if they are not aligned
pub var LineOf: [64][64]types.Bitboard = std.mem.zeroes([64][64]types.Bitboard);

pub fn init_line_between() void {
    var sq1: usize = @intFromEnum(types.Square.a1);

    while (sq1 <= @intFromEnum(types.Square.h8)) : (sq1 += 1) {
        var sq2: usize = @intFromEnum(types.Square.a1);

        while (sq2 <= @intFromEnum(types.Square.h8)) : (sq2 += 1) {
            if (types.file_plain(sq1) == types.file_plain(sq2) or types.rank_plain(sq1) == types.rank_plain(sq2)) {
                LineOf[sq1][sq2] = get_rook_attacks_for_init(@as(types.Square, @enumFromInt(sq1)), 0) & get_rook_attacks_for_init(@as(types.Square, @enumFromInt(sq2)), 0) | types.SquareIndexBB[sq1] | types.SquareIndexBB[sq2];
            } else if (types.diagonal_plain(sq1) == types.diagonal_plain(sq2) or types.anti_diagonal_plain(sq1) == types.anti_diagonal_plain(sq2)) {
                LineOf[sq1][sq2] = get_bishop_attacks_for_init(@as(types.Square, @enumFromInt(sq1)), 0) & get_bishop_attacks_for_init(@as(types.Square, @enumFromInt(sq2)), 0) | types.SquareIndexBB[sq1] | types.SquareIndexBB[sq2];
            } else {
                LineOf[sq1][sq2] = 0;
            }
        }
    }
}

// Pseudo-legal attacks array

pub var PseudoLegalAttacks: [types.N_PT][64]types.Bitboard = std.mem.zeroes([types.N_PT][64]types.Bitboard);
pub var PawnAttacks: [types.N_COLORS][64]types.Bitboard = std.mem.zeroes([types.N_COLORS][64]types.Bitboard);

pub fn init_pseudo_legal() void {
    @memcpy(PawnAttacks[0][0..64], WhitePawnAttacks[0..64]);
    @memcpy(PawnAttacks[1][0..64], BlackPawnAttacks[0..64]);
    @memcpy(PseudoLegalAttacks[@intFromEnum(types.PieceType.Knight)][0..64], KnightAttacks[0..64]);
    @memcpy(PseudoLegalAttacks[@intFromEnum(types.PieceType.King)][0..64], KingAttacks[0..64]);
    var sq: usize = @intFromEnum(types.Square.a1);

    while (sq <= @intFromEnum(types.Square.h8)) : (sq += 1) {
        PseudoLegalAttacks[@intFromEnum(types.PieceType.Bishop)][sq] = get_bishop_attacks_for_init(@as(types.Square, @enumFromInt(sq)), 0);
        PseudoLegalAttacks[@intFromEnum(types.PieceType.Rook)][sq] = get_rook_attacks_for_init(@as(types.Square, @enumFromInt(sq)), 0);
        PseudoLegalAttacks[@intFromEnum(types.PieceType.Queen)][sq] = PseudoLegalAttacks[@intFromEnum(types.PieceType.Bishop)][sq] | PseudoLegalAttacks[@intFromEnum(types.PieceType.Rook)][sq];
    }
}

pub fn init_all() void {
    init_bishop_attacks();
    init_rook_attacks();
    init_squares_between();
    init_line_between();
    init_pseudo_legal();
}

pub inline fn get_attacks(pt: types.PieceType, sq: types.Square, occ: types.Bitboard) types.Bitboard {
    return switch (pt) {
        types.PieceType.Rook => get_rook_attacks(sq, occ),
        types.PieceType.Bishop => get_bishop_attacks(sq, occ),
        types.PieceType.Queen => get_rook_attacks(sq, occ) | get_bishop_attacks(sq, occ),
        else => PseudoLegalAttacks[@intFromEnum(pt)][sq.index()],
    };
}

// Get Pawn attacks of a given color and square
pub inline fn get_pawn_attacks(comptime color: types.Color, sq: types.Square) types.Bitboard {
    return PawnAttacks[@intFromEnum(color)][sq.index()];
}

// Get Pawn attacks of every pawn on bitboard
pub inline fn get_pawn_attacks_bb(comptime color: types.Color, bb: types.Bitboard) types.Bitboard {
    return if (color == types.Color.White)
        types.shift_bitboard(bb, types.Direction.NorthWest) | types.shift_bitboard(bb, types.Direction.NorthEast)
    else
        types.shift_bitboard(bb, types.Direction.SouthWest) | types.shift_bitboard(bb, types.Direction.SouthEast);
}
