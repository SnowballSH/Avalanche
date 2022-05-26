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
    pos.set_fen(types.DEFAULT_FEN[0..]);
    perft.perft_test(&pos, 5);
}
