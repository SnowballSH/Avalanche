const std = @import("std");
const Position = @import("./board/position.zig");
const Perft = @import("./uci/perft.zig");
const Magic = @import("./board/magic.zig");
const Zobrist = @import("./board/zobrist.zig");
const TT = @import("./cache/tt.zig");
const HCE = @import("./evaluation/hce.zig");

pub fn main() !void {
    Zobrist.init_zobrist();
    Magic.init_magic();

    defer TT.TTArena.deinit();

    std.debug.print("Avalanche 0.0 by SnowballSH\n", .{});

    // https://www.chessprogramming.org/Perft_Results
    // const s = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - ";
    const s = "rnbqkb1r/ppp2ppp/4pn2/8/2pP4/6P1/PP2PPBP/RNBQK1NR w KQkq - 0 5";
    // const s = Position.STARTPOS;
    var pos = Position.new_position_by_fen(s);
    defer pos.deinit();
    pos.display();

    // _ = try Perft.perft_root(&pos, 5);
    std.debug.print("{}\n", .{HCE.evaluate(&pos)});
}
