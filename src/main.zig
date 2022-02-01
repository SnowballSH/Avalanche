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
const Zobrist = @import("./board/zobrist.zig");
const C = @import("./c.zig");
const TT = @import("./cache/tt.zig");

pub fn main() !void {
    Zobrist.init_zobrist();
    Magic.init_magic();

    defer TT.TTArena.deinit();

    std.debug.print("Avalanche 0.0 by SnowballSH\n", .{});

    // https://www.chessprogramming.org/Perft_Results
    // const s = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - ";
    const s = Position.STARTPOS;
    // const s = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    var pos = Position.new_position_by_fen(s);
    defer pos.deinit();
    pos.display();

    _ = try Perft.perft_root(&pos, 5);
}
