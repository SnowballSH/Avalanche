const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

pub var ZobristTable: [types.N_PIECES][types.N_SQUARES]u64 = std.mem.zeroes([types.N_PIECES][types.N_SQUARES]u64);
pub var TurnHash: u64 = 0;
pub var EnPassantHash: [8]u64 = std.mem.zeroes([8]u64);
pub var CastlingHash: [16]u64 = std.mem.zeroes([16]u64);

pub fn init_zobrist() void {
    var prng = utils.PRNG.new(0x246C_CB2D_3B40_2853_9918_0A6D_BC3A_F444);
    for (ZobristTable[0 .. types.N_PIECES - 1]) |*piece_keys| {
        for (piece_keys) |*key| key.* = prng.rand64();
    }
    TurnHash = prng.rand64();
    for (&EnPassantHash) |*key| key.* = prng.rand64();
    for (&CastlingHash) |*key| key.* = prng.rand64();
}
