//! See "FEN" in docs/BOARD.md.
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

pub fn validate(fen: []const u8) FenError!void {
    var fields = std.mem.tokenizeScalar(u8, fen, ' ');
    const board = try parse_board(fields.next() orelse return error.MissingField);
    const to_move = try parse_side_to_move(fields.next() orelse return error.MissingField);
    const opponent = to_move.invert();
    try validate_castling(fields.next() orelse return error.MissingField);
    _ = try en_passant_square(fields.next() orelse return error.MissingField, to_move, board.of(opponent, .Pawn), board.occupied());
    if (board.king_attacked(opponent)) return error.OpponentInCheck;
}

pub fn en_passant_square(field: []const u8, to_move: types.Color, opposing_pawns: types.Bitboard, occupied: types.Bitboard) FenError!?types.Square {
    if (std.mem.eql(u8, field, "-")) return null;
    const rank: types.Rank = if (to_move == .White) .RANK6 else .RANK3;
    if (field.len != 2 or field[0] < 'a' or field[0] > 'h' or field[1] != '1' + rank.index()) return error.BadEnPassant;

    const square = types.Square.new(@fromBackingInt(field[0] - 'a'), rank);
    const push: types.Direction = if (to_move == .White) .South else .North;
    const pushed_pawn = types.SquareIndexBB[square.add(push).index()];
    const vacated = types.SquareIndexBB[square.index()] | types.SquareIndexBB[square.sub(push).index()];
    if (pushed_pawn & opposing_pawns == 0 or vacated & occupied != 0) return error.BadEnPassant;
    return square;
}

const PIECE_LETTERS = types.PieceString[0..types.N_PT];

const Board = struct {
    pieces: [types.N_COLORS][types.N_PT]types.Bitboard = @splat(@splat(0)),

    fn of(self: *const Board, color: types.Color, piece_type: types.PieceType) types.Bitboard {
        return self.pieces[@backingInt(color)][piece_type.index()];
    }

    fn put(self: *Board, color: types.Color, piece_type: types.PieceType, square: types.Square) void {
        self.pieces[@backingInt(color)][piece_type.index()] |= types.SquareIndexBB[square.index()];
    }

    fn occupied(self: *const Board) types.Bitboard {
        var all: types.Bitboard = 0;
        for (self.pieces) |of_color| {
            for (of_color) |bits| all |= bits;
        }
        return all;
    }

    fn king_attacked(self: *const Board, king_color: types.Color) bool {
        const attacker = king_color.invert();
        const square: types.Square = @fromBackingInt(@intCast(types.lsb(self.of(king_color, .King))));
        const occupancy = self.occupied();
        const pawn_sources = if (king_color == .White) tables.WhitePawnAttacks[square.index()] else tables.BlackPawnAttacks[square.index()];
        const diagonal = tables.get_bishop_attacks(square, occupancy);
        const straight = tables.get_rook_attacks(square, occupancy);
        return (pawn_sources & self.of(attacker, .Pawn)) |
            (tables.KnightAttacks[square.index()] & self.of(attacker, .Knight)) |
            (tables.KingAttacks[square.index()] & self.of(attacker, .King)) |
            (diagonal & (self.of(attacker, .Bishop) | self.of(attacker, .Queen))) |
            (straight & (self.of(attacker, .Rook) | self.of(attacker, .Queen))) != 0;
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
            const letter = std.mem.findScalar(u8, PIECE_LETTERS, std.ascii.toUpper(ch)) orelse return error.UnknownPiece;
            const piece_type: types.PieceType = @fromBackingInt(@intCast(letter));
            if (piece_type == .Pawn and (rank_count == 0 or rank_count == 7)) return error.PawnOnBackRank;
            if (file >= 8) return error.BadRankLength;
            const color: types.Color = if (std.ascii.isUpper(ch)) .White else .Black;
            board.put(color, piece_type, types.Square.new(@fromBackingInt(@intCast(file)), @fromBackingInt(@intCast(7 - rank_count))));
            file += 1;
        }
        if (file != 8) return error.BadRankLength;
    }
    if (rank_count != 8) return error.BadRankCount;
    if (@popCount(board.of(.White, .King)) != 1 or @popCount(board.of(.Black, .King)) != 1) return error.BadKingCount;
    return board;
}

fn parse_side_to_move(field: []const u8) FenError!types.Color {
    if (std.mem.eql(u8, field, "w")) return .White;
    if (std.mem.eql(u8, field, "b")) return .Black;
    return error.BadSideToMove;
}

fn validate_castling(castling: []const u8) FenError!void {
    if (std.mem.eql(u8, castling, "-")) return;
    for (castling) |ch| {
        const standard = std.mem.findScalar(u8, "KQkq", ch) != null;
        const shredder = (ch >= 'A' and ch <= 'H') or (ch >= 'a' and ch <= 'h');
        if (!standard and !shredder) return error.BadCastling;
    }
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

test "fen: an en-passant square is rejected unless a double push can have left it" {
    tables.init_all();
    try validate("4k3/8/8/3Pp3/8/8/8/4K3 w - e6 0 1");
    try validate("4k3/8/8/8/3pP3/8/8/4K3 b - e3 0 1");
    try testing.expectError(error.BadEnPassant, validate("8/8/8/3Pk3/8/8/8/4K3 w - e6 0 1"));
    try testing.expectError(error.BadEnPassant, validate("4k3/8/8/3P4/8/8/8/4K3 w - e6 0 1"));
    try testing.expectError(error.BadEnPassant, validate("4k3/8/8/3PP3/8/8/8/4K3 w - e6 0 1"));
    try testing.expectError(error.BadEnPassant, validate("4k3/8/4n3/3Pp3/8/8/8/4K3 w - e6 0 1"));
    try testing.expectError(error.BadEnPassant, validate("4k3/4p3/8/3Pp3/8/8/8/4K3 w - e6 0 1"));
    try testing.expectError(error.BadEnPassant, validate("4k3/8/8/8/3pp3/8/8/4K3 b - e3 0 1"));
}
