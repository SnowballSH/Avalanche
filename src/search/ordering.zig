const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const Encode = @import("../move/encode.zig");
const HCE = @import("../evaluation/hce.zig");

pub fn order(pos: *Position.Position, lhs: u24, rhs: u24) bool {
    return score_move(lhs, pos) < score_move(rhs, pos);
}

pub fn score_move(move: u24, pos: *Position.Position) i16 {
    var score: i16 = 0;
    var ts = Position.fen_sq_to_sq(Encode.target(move));
    if (Encode.capture(move) != 0) {
        score += 3000;

        var captured = @enumToInt(pos.mailbox[ts].?);
        score += HCE.PieceValues[captured % 6];
        if (pos.turn == Piece.Color.White) {
            score += HCE.PSQT[captured % 6][ts];
        } else {
            score += HCE.PSQT[captured % 6][ts ^ 56];
        }
    }

    if (Encode.castling(move) != 0) {
        score += 1500;
    }

    if (Encode.promote(move) != 0) {
        score += 300 + HCE.PieceValues[Encode.promote(move) % 6];
    }

    var pt = Encode.pt(move);
    var sq = Position.fen_sq_to_sq(Encode.source(move));

    if (pos.turn == Piece.Color.White) {
        score += HCE.PSQT[pt % 6][sq];
        score -= HCE.PSQT[pt % 6][ts];
    } else {
        score += HCE.PSQT[pt % 6][sq ^ 56];
        score -= HCE.PSQT[pt % 6][ts ^ 56];
    }

    return score;
}
