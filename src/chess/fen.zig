const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");

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
    OpponentInCheck,
};

const PIECES = "PNBRQKpnbrqk";

/// Checks the first four FEN/EPD fields (board, side to move, castling, en passant) without building a position,
/// and that the side not to move is not in check. Later fields (move counters or EPD opcodes) are not inspected.
/// Requires `tables.init_all()`.
pub fn validate(fen: []const u8) FenError!void {
    var fields = std.mem.tokenizeScalar(u8, fen, ' ');
    const board = try parse_board(fields.next() orelse return error.MissingField);
    const side = fields.next() orelse return error.MissingField;
    if (!std.mem.eql(u8, side, "w") and !std.mem.eql(u8, side, "b")) return error.BadSideToMove;
    try validate_castling(fields.next() orelse return error.MissingField);
    try validate_en_passant(fields.next() orelse return error.MissingField, side[0]);
    const mover: usize = if (side[0] == 'w') WHITE else BLACK;
    if (board.king_attacked(1 - mover, mover)) return error.OpponentInCheck;
}

const WHITE = 0;
const BLACK = 1;
const PAWN = 0;
const KNIGHT = 1;
const BISHOP = 2;
const ROOK = 3;
const QUEEN = 4;
const KING = 5;

const Board = struct {
    pieces: [2][6]u64 = @splat(@splat(0)),

    fn occupied(self: Board) u64 {
        var all: u64 = 0;
        for (self.pieces) |colour| {
            for (colour) |bits| all |= bits;
        }
        return all;
    }

    fn king_attacked(self: Board, king_colour: usize, attacker: usize) bool {
        const square: types.Square = @fromBackingInt(@intCast(@ctz(self.pieces[king_colour][KING])));
        const theirs = self.pieces[attacker];
        const occupancy = self.occupied();
        const pawn_sources = if (king_colour == WHITE) tables.WhitePawnAttacks[square.index()] else tables.BlackPawnAttacks[square.index()];
        const diagonal = tables.get_bishop_attacks(square, occupancy);
        const straight = tables.get_rook_attacks(square, occupancy);
        return (pawn_sources & theirs[PAWN]) |
            (tables.KnightAttacks[square.index()] & theirs[KNIGHT]) |
            (tables.KingAttacks[square.index()] & theirs[KING]) |
            (diagonal & (theirs[BISHOP] | theirs[QUEEN])) |
            (straight & (theirs[ROOK] | theirs[QUEEN])) != 0;
    }
};

fn parse_board(text: []const u8) FenError!Board {
    var board: Board = .{};
    var ranks = std.mem.splitScalar(u8, text, '/');
    var rank_count: usize = 0;
    while (ranks.next()) |rank| : (rank_count += 1) {
        if (rank_count == 8) return error.BadRankCount;
        var file: usize = 0;
        for (rank) |ch| {
            if (std.ascii.isDigit(ch)) {
                if (ch == '0' or ch == '9') return error.BadRankLength;
                file += ch - '0';
                continue;
            }
            const kind = std.mem.indexOfScalar(u8, PIECES[0..6], std.ascii.toUpper(ch)) orelse return error.UnknownPiece;
            if (kind == PAWN and (rank_count == 0 or rank_count == 7)) return error.PawnOnBackRank;
            if (file >= 8) return error.BadRankLength;
            const colour: usize = if (std.ascii.isUpper(ch)) WHITE else BLACK;
            board.pieces[colour][kind] |= @as(u64, 1) << @intCast((7 - rank_count) * 8 + file);
            file += 1;
        }
        if (file != 8) return error.BadRankLength;
    }
    if (rank_count != 8) return error.BadRankCount;
    if (@popCount(board.pieces[WHITE][KING]) != 1 or @popCount(board.pieces[BLACK][KING]) != 1) return error.BadKingCount;
    return board;
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

test "fen: the side not to move may not be in check" {
    tables.init_all();
    try testing.expectError(error.OpponentInCheck, validate("4k3/4R3/8/8/8/8/8/4K3 w - - 0 1"));
    try testing.expectError(error.OpponentInCheck, validate("4k3/8/8/8/8/8/3p4/4K3 b - - 0 1"));
    try testing.expectError(error.OpponentInCheck, validate("4k3/8/8/8/1b6/8/8/4K3 b - - 0 1"));
    try testing.expectError(error.OpponentInCheck, validate("4k3/8/8/8/8/8/2n5/4K3 b - - 0 1"));
    try validate("4k3/4R3/8/8/8/8/8/4K3 b - - 0 1");
    try validate("4k3/8/8/8/8/8/4p3/4K3 b - - 0 1");
}
