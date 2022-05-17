const std = @import("std");
const types = @import("./chess/types.zig");

pub fn main() anyerror!void {
    types.debug_print_bitboard(types.MaskAntiDiagonal[5]);
}
