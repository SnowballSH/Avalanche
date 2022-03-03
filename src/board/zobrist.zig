const Piece = @import("./piece.zig");

fn rand_u32(seed: *u32) u32 {
    seed.* ^= seed.* << 13;
    seed.* ^= seed.* >> 17;
    seed.* ^= seed.* << 5;

    return seed.*;
}

fn rand_u64(seed: *u32) u64 {
    var n1 = @as(u64, rand_u32(seed) & 0xFFFF);
    var n2 = @as(u64, rand_u32(seed) & 0xFFFF);
    var n3 = @as(u64, rand_u32(seed) & 0xFFFF);
    var n4 = @as(u64, rand_u32(seed) & 0xFFFF);

    return n1 | (n2 << 16) | (n3 << 32) | (n4 << 48);
}

pub var ZobristKeys: [12][64]u64 = undefined;
pub var ZobristCastleKeys: [16]u64 = undefined;
pub var ZobristEpKeys: [8]u64 = undefined;
pub var ZobristTurn: u64 = 0;

pub fn init_zobrist() void {
    var seed: u32 = 1804289383;

    var piece = @enumToInt(Piece.Piece.WhitePawn);
    while (piece <= @enumToInt(Piece.Piece.BlackKing)) {
        var sq: u8 = 0;
        while (sq < 64) {
            ZobristKeys[piece][sq] = rand_u64(&seed);
            sq += 1;
        }
        piece += 1;
    }

    var key: u8 = 0;
    while (key < 16) {
        ZobristCastleKeys[key] = rand_u64(&seed);
        key += 1;
    }

    var ep: u8 = 0;
    while (ep < 8) {
        ZobristEpKeys[ep] = rand_u64(&seed);
        ep += 1;
    }

    ZobristTurn = rand_u64(&seed);
}
