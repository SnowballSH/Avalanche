const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

pub var ZobristTable: [types.N_PIECES][types.N_SQUARES]u64 = std.mem.zeroes([types.N_PIECES][types.N_SQUARES]u64);
pub var TurnHash: u64 = 0;
pub var EnPassantHash: [8]u64 = std.mem.zeroes([8]u64);
pub var CastlingHash: [16]u64 = std.mem.zeroes([16]u64);
pub var DepthHash: [64]u64 = std.mem.zeroes([64]u64);

/// Canonical 4-bit castling-rights index from the cumulative `entry` bitboard.
/// A right is available when its mask bits are clear in `entry`.
pub inline fn castling_rights_index(entry: types.Bitboard) u4 {
    var idx: u4 = 0;
    if (entry & types.WhiteOOMask == 0) idx |= 1;
    if (entry & types.WhiteOOOMask == 0) idx |= 2;
    if (entry & types.BlackOOMask == 0) idx |= 4;
    if (entry & types.BlackOOOMask == 0) idx |= 8;
    return idx;
}

pub fn init_zobrist() void {
    var prng = utils.PRNG.new(0x246C_CB2D_3B40_2853_9918_0A6D_BC3A_F444);
    var i: usize = 0;
    while (i < types.N_PIECES - 1) : (i += 1) {
        var j: usize = 0;
        while (j < types.N_SQUARES) : (j += 1) {
            ZobristTable[i][j] = prng.rand64();
        }
    }
    TurnHash = prng.rand64();

    var l: usize = 0;
    while (l < 8) : (l += 1) {
        EnPassantHash[l] = prng.rand64();
    }

    var c: usize = 0;
    while (c < 16) : (c += 1) {
        CastlingHash[c] = prng.rand64();
    }

    var k: usize = 0;
    while (k < 64) : (k += 1) {
        DepthHash[k] = prng.rand64();
    }
}
