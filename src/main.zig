const std = @import("std");
const Position = @import("./board/position.zig");
const Perft = @import("./uci/perft.zig");
const Magic = @import("./board/magic.zig");
const Zobrist = @import("./board/zobrist.zig");
const TT = @import("./cache/tt.zig");
const Uci = @import("./uci/uci.zig");
const HCE = @import("./evaluation/hce.zig");
const Search = @import("./search/search.zig");
const Interface = @import("./uci/interface.zig");
const SEE = @import("./search/see.zig");

pub fn main() !void {
    Zobrist.init_zobrist();
    Magic.init_magic();
    Search.init_tt();
    SEE.init_see();

    defer TT.TTArena.deinit();

    var interface = Interface.UciInterface.new();

    try interface.main_loop();
}
