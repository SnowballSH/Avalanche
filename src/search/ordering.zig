const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const Encode = @import("../move/encode.zig");
const HCE = @import("../evaluation/hce.zig");

pub const OrderInfo = struct {
    pos: *Position.Position,
};

pub fn order(info: OrderInfo, lhs: u24, rhs: u24) bool {
    return score_move(lhs, info.pos) > score_move(rhs, info.pos);
}

// MVV_LVA[attacker][captured]
const MVV_LVA: [6][6]i16 = .{
    .{ 60, 61, 62, 63, 64, 65 },
    .{ 50, 51, 52, 53, 54, 55 },
    .{ 40, 41, 42, 43, 44, 45 },
    .{ 30, 31, 32, 33, 34, 35 },
    .{ 20, 21, 22, 23, 24, 25 },
    .{ 10, 11, 12, 13, 14, 15 },
};

pub fn score_move(move: u24, pos: *Position.Position) i16 {
    var score: i16 = 0;
    var ts = Position.fen_sq_to_sq(Encode.target(move));
    var pt = Encode.pt(move);
    if (Encode.capture(move) != 0) {
        score += 3000;

        var captured = @enumToInt(pos.mailbox[ts].?);
        score += MVV_LVA[pt % 6][captured % 6];
    }

    if (Encode.castling(move) != 0) {
        score += 500;
    }

    if (Encode.promote(move) != 0) {
        score += 500 + HCE.PieceValues[Encode.promote(move) % 6];
    }

    if (pos.turn == Piece.Color.White) {
        score += HCE.PSQT[pt % 6][ts];
    } else {
        score += HCE.PSQT[pt % 6][ts ^ 56];
    }

    return score;
}
