const Piece = @import("./piece.zig");

fn rand_u64(seed: *u64) u64 {
    seed.* ^= seed.* >> 12;
    seed.* ^= seed.* << 25;
    seed.* ^= seed.* >> 27;

    return seed.* *% 2685821657736338717;
}

pub var ZobristKeys: [12][64]u64 = undefined;
pub var ZobristCastleKeys: [16]u64 = undefined;
pub var ZobristEpKeys: [8]u64 = undefined;
pub var ZobristTurn: u64 = 0;

pub fn init_zobrist() void {
    var seed: u64 = 1070372;

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
