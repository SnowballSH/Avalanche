const Position = @import("../board/position.zig");
const Piece = @import("../board/piece.zig");
const Encode = @import("../move/encode.zig");
const HCE = @import("../evaluation/hce.zig");
const Search = @import("./search.zig");

const std = @import("std");

pub const OrderInfo = struct {
    pos: *Position.Position,
    searcher: *Search.Searcher,
};

pub fn order(info: OrderInfo, lhs: u24, rhs: u24) bool {
    return score_move(lhs, info) > score_move(rhs, info);
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

pub fn score_move(move: u24, info: OrderInfo) i16 {
    var pos = info.pos;

    var score: i16 = 0;
    var ts = Position.fen_sq_to_sq(Encode.target(move));
    var sq = Position.fen_sq_to_sq(Encode.source(move));
    var pt = Encode.pt(move);

    if (Encode.capture(move) != 0) {
        // Captures first!
        score += 5000;

        var captured = @enumToInt(pos.mailbox[ts].?);
        score += MVV_LVA[pt % 6][captured % 6];
    } else {
        if (info.searcher.killers[0][info.searcher.ply] == move) {
            score += 2500;
        } else if (info.searcher.killers[1][info.searcher.ply] == move) {
            score += 1020;
        } else {
            score += info.searcher.history[pt][Encode.target(move)] * 2;
        }

        if (pos.turn == Piece.Color.White) {
            score += HCE.PSQT[pt % 6][ts] - HCE.PSQT[pt % 6][sq];
        } else {
            score += HCE.PSQT[pt % 6][ts ^ 56] - HCE.PSQT[pt % 6][sq ^ 56];
        }

        if (Encode.castling(move) != 0) {
            score += 500;
        }
    }

    if (Encode.promote(move) != 0) {
        score += 7500 + HCE.PieceValues[Encode.promote(move) % 6];
    }

    return score;
}
