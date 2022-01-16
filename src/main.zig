const std = @import("std");
const BB = @import("./board/bitboard.zig");
const Patterns = @import("./board/patterns.zig");
const C = @import("./c.zig");

pub fn main() void {
    var idx: u6 = C.SQ_C.F3;
    BB.display(Patterns.KnightPatterns[idx] | Patterns.index_to_bb(idx));
}
