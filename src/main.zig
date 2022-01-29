const std = @import("std");
const BB = @import("./board/bitboard.zig");
const Patterns = @import("./board/patterns.zig");
const Piece = @import("./board/piece.zig");
const Position = @import("./board/position.zig");
const Encode = @import("./move/encode.zig");
const Uci = @import("./uci/uci.zig");
const MoveGen = @import("./move/movegen.zig");
const Perft = @import("./uci/perft.zig");
const Magic = @import("./board/magic.zig");
const C = @import("./c.zig");

pub fn main() !void {
    Magic.init_magic();

    std.debug.print("Loaded\n", .{});

    // https://www.chessprogramming.org/Perft_Results
    // const s = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - ";
    // const s = Position.STARTPOS;
    const s = "R1R1R1R1/7R/R7/3R3R/R4K2/2kp1R1R/R7/7R w - - 0 1";
    var pos = Position.new_position_by_fen(s);
    defer pos.deinit();
    pos.display();

    // v1: 22.67s
    // Cosette: 8s
    // FSF: 6.27s
    // SF: 0.84s

    _ = try Perft.perft_root(&pos, 1);
}
