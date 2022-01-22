const std = @import("std");
const BB = @import("./board/bitboard.zig");
const Patterns = @import("./board/patterns.zig");
const Piece = @import("./board/piece.zig");
const Position = @import("./board/position.zig");
const Encode = @import("./move/encode.zig");
const Uci = @import("./uci/uci.zig");
const MoveGen = @import("./move/movegen.zig");
const C = @import("./c.zig");

pub fn main() void {
    // https://www.chessprogramming.org/Perft_Results
    const s = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - ";
    var pos = Position.new_position_by_fen(s);
    pos.display();

    var moves = MoveGen.generate_all_pseudo_legal_moves(&pos);
    defer moves.deinit();

    for (moves.items) |x| {
        std.debug.print("{s}\n", .{Uci.move_to_detailed(x)});
    }
    std.debug.print("{d}", .{moves.items.len});
}
