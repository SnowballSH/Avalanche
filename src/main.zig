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

pub fn main() !void {
    Zobrist.init_zobrist();
    Magic.init_magic();
    Search.init_tt();

    defer TT.TTArena.deinit();

    // const s = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - ";
    // const s = "4nrk1/1pq2p1p/r3p1p1/7Q/3B1P2/3R4/1PP3PP/2K4R w - - 0 1";
    const s = Position.STARTPOS;
    var pos = Position.new_position_by_fen(s);
    defer pos.deinit();

    var interface = Interface.UciInterface.new();

    try interface.main_loop();

    // _ = try Perft.perft_root(&pos, 5);
}
