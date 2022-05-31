const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");
const zobrist = @import("./chess/zobrist.zig");
const position = @import("./chess/position.zig");
const perft = @import("./chess/perft.zig");
const search = @import("./engine/search.zig");
const tt = @import("./engine/tt.zig");
const hce = @import("./engine/hce.zig");
const interface = @import("./engine/interface.zig");

pub fn main() anyerror!void {
    tables.init_all();
    zobrist.init_zobrist();
    tt.GlobalTT.reset(16);

    var inter = interface.UciInterface.new();
    return inter.main_loop();
}
