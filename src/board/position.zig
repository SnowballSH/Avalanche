const BB = @import("./bitboard.zig");
const Piece = @import("./piece.zig");

pub const Position = struct {
    bitboards: BB.Bitboards,
    turn: Piece.Color,
};
