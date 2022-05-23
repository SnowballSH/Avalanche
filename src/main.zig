const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");
const zobrist = @import("./chess/zobrist.zig");
const position = @import("./chess/position.zig");

pub fn main() anyerror!void {
    tables.init_all();
    zobrist.init_zobrist();

    var pos = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);
    pos.debug_print();
    pos.play_move(types.Color.White, types.Move.new_from_string("e2e4"[0..]));
    pos.debug_print();
    pos.undo_move(types.Color.White, types.Move.new_from_string("e2e4"[0..]));
    pos.debug_print();
}
