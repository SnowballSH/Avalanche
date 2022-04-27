const std = @import("std");
const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const Patterns = @import("../board/patterns.zig");
const Encode = @import("../move/encode.zig");
const BB = @import("../board/bitboard.zig");

const SEE_VAL: [6]i16 = .{
    100, 345, 350, 530, 1000, 10000,
};

pub fn see(pos: *Position.Position, move: u24) i16 {
    var max_depth: usize = 0;
    const SEARCH_DEPTH: usize = 16;
    var gains: [SEARCH_DEPTH]i16 = std.mem.zeroes([SEARCH_DEPTH]i16);
    var turn = pos.turn.invert();
    var defenders: u64 = undefined;
    var pbb: u64 = undefined;
    const all_pieces: u64 = pos.bitboards.WhiteAll | pos.bitboards.BlackAll;
    var blockers = all_pieces & ~BB.ShiftLocations[Encode.source(move)];
    const target = Encode.target(move);

    gains[0] = SEE_VAL[@enumToInt(pos.mailbox[Position.fen_sq_to_sq(target)].?) % 6];
    var last_piece_val = SEE_VAL[Encode.pt(move) % 6];

    var depth: usize = 1;
    outer: while (depth < SEARCH_DEPTH) : (depth += 1) {
        gains[depth] = last_piece_val - gains[depth - 1];
        defenders = if (turn == Piece.Color.White)
            pos.bitboards.WhiteAll
        else
            pos.bitboards.BlackAll;
        defenders &= blockers;

        var pt: usize = 0;
        while (pt < 6) : (pt += 1) {
            last_piece_val = SEE_VAL[pt];
            pbb = if (pt == 0)
                Patterns.PawnCapturePatterns[@enumToInt(turn.invert())][target] & defenders & (pos.bitboards.WhitePawns | pos.bitboards.BlackPawns)
            else if (pt == 1)
                Patterns.KnightPatterns[target] & defenders & (pos.bitboards.WhiteKnights | pos.bitboards.BlackKnights)
            else if (pt == 2)
                Patterns.get_bishop_attacks(target, blockers) & defenders & (pos.bitboards.WhiteBishops | pos.bitboards.BlackBishops)
            else if (pt == 3)
                Patterns.get_rook_attacks(target, blockers) & defenders & (pos.bitboards.WhiteRooks | pos.bitboards.BlackRooks)
            else if (pt == 4)
                Patterns.get_queen_attacks(target, blockers) & defenders & (pos.bitboards.WhiteQueens | pos.bitboards.BlackQueens)
            else
                Patterns.KingPatterns[target] & defenders & (pos.bitboards.WhiteKing | pos.bitboards.BlackKing);
            if (pbb != 0) {
                blockers &= ~(BB.ShiftLocations[@ctz(u64, pbb)]);
                turn = turn.invert();
                continue :outer;
            }
        }
        max_depth = depth;
        break;
    }

    depth = max_depth - 1;
    while (depth >= 1) : (depth -= 1) {
        gains[depth - 1] = -@maximum(-gains[depth - 1], gains[depth]);
    }

    return gains[0];
}
