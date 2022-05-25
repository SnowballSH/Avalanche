const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");
const zobrist = @import("./chess/zobrist.zig");
const position = @import("./chess/position.zig");
const perft = @import("./chess/perft.zig");

pub fn main() anyerror!void {
    tables.init_all();
    zobrist.init_zobrist();

    var pos = position.Position.new();
    pos.set_fen("r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w -"[0..]);
    perft.perft_test(&pos, 5);
}
