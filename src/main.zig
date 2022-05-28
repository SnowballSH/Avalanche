const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");
const zobrist = @import("./chess/zobrist.zig");
const position = @import("./chess/position.zig");
const perft = @import("./chess/perft.zig");
const search = @import("./engine/search.zig");
const tt = @import("./engine/tt.zig");
const hce = @import("./engine/hce.zig");

pub fn main() anyerror!void {
    tables.init_all();
    zobrist.init_zobrist();
    tt.GlobalTT.reset(16);

    var pos = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);
    // perft.perft_test(&pos, 6);
    // std.debug.print("{}\n", .{hce.evaluate(&pos)});
    var searcher = search.Searcher.new();
    searcher.max_millis = 3000;
    _ = searcher.iterative_deepening(&pos, types.Color.White);
}
