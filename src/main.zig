const std = @import("std");
const types = @import("chess/types.zig");
const tables = @import("chess/tables.zig");
const zobrist = @import("chess/zobrist.zig");
const position = @import("chess/position.zig");
const perft = @import("chess/perft.zig");
const search = @import("engine/search.zig");
const tt = @import("engine/tt.zig");
const hce = @import("engine/hce.zig");
const interface = @import("engine/interface.zig");
const weights = @import("engine/weights.zig");

const arch = @import("build_options");

pub fn main() anyerror!void {
    // std.debug.print("Using NNUE of architecture {}x{}x{}\n", .{ arch.INPUT_SIZE, arch.HIDDEN_SIZE, arch.OUTPUT_SIZE });

    tables.init_all();
    zobrist.init_zobrist();
    tt.GlobalTT.reset(16);
    weights.do_nnue();
    search.init_lmr();

    var inter = interface.UciInterface.new();
    return inter.main_loop();
}
