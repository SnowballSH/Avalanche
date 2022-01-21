const std = @import("std");
const BB = @import("./board/bitboard.zig");
const Patterns = @import("./board/patterns.zig");
const Piece = @import("./board/piece.zig");
const Position = @import("./board/position.zig");
const Encode = @import("./move/encode.zig");
const Uci = @import("./uci/uci.zig");
const C = @import("./c.zig");

pub fn main() void {
    const s = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    var pos = Position.new_position_by_fen(s);
    pos.display();
    BB.display(pos.bitboards.WhiteAll);
    BB.display(pos.bitboards.BlackBishops);
}
