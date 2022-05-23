const std = @import("std");
const types = @import("./types.zig");
const utils = @import("./utils.zig");

pub var ZobristTable: [types.N_PIECES][types.N_SQUARES]u64 = std.mem.zeroes([types.N_PIECES][types.N_SQUARES]u64);

pub fn init_zobrist() void {
    var prng = utils.PRNG.new(70026072);
    var i: usize = 0;
    while (i < types.N_PIECES) : (i += 1) {
        var j: usize = 0;
        while (j < types.N_SQUARES) : (j += 1) {
            ZobristTable[i][j] = prng.rand64();
        }
    }
}
