const std = @import("std");

pub const FenError = error{
    MissingField,
    BadRankCount,
    BadRankLength,
    UnknownPiece,
    BadKingCount,
    PawnOnBackRank,
    BadSideToMove,
    BadCastling,
    BadEnPassant,
};

const PIECES = "PNBRQKpnbrqk";

/// Checks the first four FEN/EPD fields (board, side to move, castling, en passant) without building a position.
/// Later fields (move counters or EPD opcodes) are not inspected.
pub fn validate(fen: []const u8) FenError!void {
    var fields = std.mem.tokenizeScalar(u8, fen, ' ');
    try validate_board(fields.next() orelse return error.MissingField);
    const side = fields.next() orelse return error.MissingField;
    if (!std.mem.eql(u8, side, "w") and !std.mem.eql(u8, side, "b")) return error.BadSideToMove;
    try validate_castling(fields.next() orelse return error.MissingField);
    try validate_en_passant(fields.next() orelse return error.MissingField, side[0]);
}

fn validate_board(board: []const u8) FenError!void {
    var ranks = std.mem.splitScalar(u8, board, '/');
    var rank_count: usize = 0;
    var white_kings: usize = 0;
    var black_kings: usize = 0;
    while (ranks.next()) |rank| : (rank_count += 1) {
        if (rank_count == 8) return error.BadRankCount;
        var files: usize = 0;
        for (rank) |ch| {
            if (std.ascii.isDigit(ch)) {
                if (ch == '0' or ch == '9') return error.BadRankLength;
                files += ch - '0';
                continue;
            }
            if (std.mem.indexOfScalar(u8, PIECES, ch) == null) return error.UnknownPiece;
            if ((ch == 'P' or ch == 'p') and (rank_count == 0 or rank_count == 7)) return error.PawnOnBackRank;
            if (ch == 'K') white_kings += 1;
            if (ch == 'k') black_kings += 1;
            files += 1;
        }
        if (files != 8) return error.BadRankLength;
    }
    if (rank_count != 8) return error.BadRankCount;
    if (white_kings != 1 or black_kings != 1) return error.BadKingCount;
}

fn validate_castling(castling: []const u8) FenError!void {
    if (std.mem.eql(u8, castling, "-")) return;
    for (castling) |ch| {
        const standard = std.mem.indexOfScalar(u8, "KQkq", ch) != null;
        const shredder = (ch >= 'A' and ch <= 'H') or (ch >= 'a' and ch <= 'h');
        if (!standard and !shredder) return error.BadCastling;
    }
}

fn validate_en_passant(square: []const u8, side: u8) FenError!void {
    if (std.mem.eql(u8, square, "-")) return;
    const expected_rank: u8 = if (side == 'w') '6' else '3';
    if (square.len != 2 or square[0] < 'a' or square[0] > 'h' or square[1] != expected_rank) return error.BadEnPassant;
}

const testing = std.testing;

test "fen: standard, Chess960 and EPD lines are valid" {
    try validate("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    try validate("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 bm e5; id \"x\";");
    try validate("bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9");
    try validate("8/8/8/4k3/8/8/4P3/4K2R w - -");
}

test "fen: malformed boards are rejected with a reason" {
    try testing.expectError(error.UnknownPiece, validate("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNX w - - 0 1"));
    try testing.expectError(error.BadRankLength, validate("rnbqkbnr/ppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1"));
    try testing.expectError(error.BadRankLength, validate("rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1"));
    try testing.expectError(error.BadRankCount, validate("rnbqkbnr/pppppppp/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1"));
    try testing.expectError(error.BadKingCount, validate("rnbq1bnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1"));
    try testing.expectError(error.PawnOnBackRank, validate("rnbqkbnP/pppppppp/8/8/8/8/PPPPPPP1/RNBQKBNR w - - 0 1"));
    try testing.expectError(error.BadSideToMove, validate("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x - - 0 1"));
    try testing.expectError(error.MissingField, validate("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w"));
    try testing.expectError(error.BadCastling, validate("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQxq - 0 1"));
    try testing.expectError(error.BadEnPassant, validate("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e4 0 1"));
    try testing.expectError(error.UnknownPiece, validate("# a comment"));
    try testing.expectError(error.UnknownPiece, validate("1. e4 e5 2. Nf3 Nc6"));
}
