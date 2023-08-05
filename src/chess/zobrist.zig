const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

pub var ZobristTable: [types.N_PIECES][types.N_SQUARES]u64 = std.mem.zeroes([types.N_PIECES][types.N_SQUARES]u64);
pub var TurnHash: u64 = 0;
pub var EnPassantHash: [8]u64 = std.mem.zeroes([8]u64);
pub var DepthHash: [64]u64 = std.mem.zeroes([64]u64);

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

    var k: usize = 0;
    while (k < 64) : (k += 1) {
        DepthHash[k] = prng.rand64();
    }
}
