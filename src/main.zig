const std = @import("std");
const BB = @import("./board/bitboard.zig");
const Patterns = @import("./board/patterns.zig");
const C = @import("./c.zig");

pub fn main() void {
    BB.display(0x2444008c0001);
    BB.display(Patterns.index_to_bb(C.SQ_C.F3));
    BB.display(Patterns.KnightPatterns[C.SQ_C.F3]);
    BB.display(Patterns.slider_attacks(C.SQ_C.F3, 0x2444008c0001, Patterns.RookDelta));
}
