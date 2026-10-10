//! The viriformat game record; see "Output" in docs/DATAGEN.md.

const std = @import("std");
const types = @import("../../chess/types.zig");
const position = @import("../../chess/position.zig");
const fen = @import("../../chess/fen.zig");
const adjudicator = @import("adjudicator.zig");

pub const MAX_PIECES = 32;
pub const MAX_EVAL = 32000;
pub const FEN_CAPACITY = 128;
pub const MoveNumber = u16;

const NO_EP_SQUARE: u8 = 64;
const EP_SQUARE_MASK: u8 = 0x7F;
const BLACK_TO_MOVE: u8 = 0x80;
const PIECE_CHARS = "pnbrqk";

const PieceCode = packed struct(u4) {
    kind: u3,
    black: bool,

    const UNMOVED_ROOK: u3 = 6;
};

const PackedPiece = struct {
    square: u6,
    code: PieceCode,
};

fn nibble_shift(piece_index: usize) u3 {
    return @intCast(4 * (piece_index & 1));
}

pub fn clamp_eval(score: i32) i16 {
    return @intCast(std.math.clamp(score, -MAX_EVAL, MAX_EVAL));
}

pub const PackedBoard = extern struct {
    occ: u64,
    pcs: [MAX_PIECES / 2]u8,
    stm_ep: u8,
    halfmove: u8,
    fullmove: MoveNumber,
    eval: i16,
    wdl: u8,
    extra: u8,

    const PieceIterator = struct {
        pcs: [MAX_PIECES / 2]u8,
        remaining: u64,
        index: usize = 0,

        fn next(self: *PieceIterator) ?PackedPiece {
            if (self.remaining == 0) return null;
            const square: u6 = @intCast(@ctz(self.remaining));
            self.remaining &= self.remaining - 1;
            const nibble: u4 = @truncate(self.pcs[self.index / 2] >> nibble_shift(self.index));
            self.index += 1;
            return .{ .square = square, .code = @bitCast(nibble) };
        }
    };

    fn pieces(self: PackedBoard) PieceIterator {
        std.debug.assert(@popCount(self.occ) <= MAX_PIECES);
        return .{ .pcs = self.pcs, .remaining = self.occ };
    }

    pub fn pack(pos: *position.Position, white_relative_score: i32) PackedBoard {
        const occupancy = pos.all_all_pieces();
        std.debug.assert(@popCount(occupancy) <= MAX_PIECES);
        const castling_rooks = pos.castling_rook_squares();

        var pcs: [MAX_PIECES / 2]u8 = @splat(0);
        var remaining = occupancy;
        var index: usize = 0;
        while (remaining != 0) : (index += 1) {
            const square: u6 = @intCast(@ctz(remaining));
            remaining &= remaining - 1;

            const piece = pos.mailbox[square];
            std.debug.assert(piece != types.Piece.NO_PIECE);
            const unmoved_rook = piece.piece_type() == types.PieceType.Rook and castling_rooks & (@as(u64, 1) << square) != 0;
            const code: PieceCode = .{
                .kind = if (unmoved_rook) PieceCode.UNMOVED_ROOK else @intCast(piece.piece_type().index()),
                .black = piece.color() == types.Color.Black,
            };
            pcs[index / 2] |= @as(u8, @as(u4, @bitCast(code))) << nibble_shift(index);
        }

        const ep_square = pos.history[pos.game_ply].ep_sq;
        const ep_code: u8 = if (ep_square == types.Square.NO_SQUARE) NO_EP_SQUARE else ep_square.index();
        const side_to_move: u8 = if (pos.turn == types.Color.Black) BLACK_TO_MOVE else 0;

        return .{
            .occ = occupancy,
            .pcs = pcs,
            .stm_ep = side_to_move | ep_code,
            .halfmove = @intCast(@min(pos.history[pos.game_ply].fifty, std.math.maxInt(u8))),
            .fullmove = @intCast(@min(pos.absolute_ply() / 2 + 1, std.math.maxInt(MoveNumber))),
            .eval = clamp_eval(white_relative_score),
            .wdl = @backingInt(adjudicator.Outcome.draw),
            .extra = 0,
        };
    }

    pub fn validate(self: PackedBoard) error{InvalidHeader}!void {
        if (@popCount(self.occ) > MAX_PIECES) return error.InvalidHeader;
        var packed_pieces = self.pieces();
        while (packed_pieces.next()) |piece| {
            if (piece.code.kind > PieceCode.UNMOVED_ROOK) return error.InvalidHeader;
        }
        if (self.stm_ep & EP_SQUARE_MASK > NO_EP_SQUARE) return error.InvalidHeader;
        if (std.enums.fromInt(adjudicator.Outcome, self.wdl) == null) return error.InvalidHeader;

        var buf: [FEN_CAPACITY]u8 = undefined;
        fen.validate(self.to_fen(&buf)) catch return error.InvalidHeader;
    }

    pub fn outcome(self: PackedBoard) adjudicator.Outcome {
        return @fromBackingInt(self.wdl);
    }

    pub fn to_fen(self: PackedBoard, buf: *[FEN_CAPACITY]u8) []const u8 {
        var squares: [64]u8 = @splat(0);
        var white_rights: [8]bool = @splat(false);
        var black_rights: [8]bool = @splat(false);
        var packed_pieces = self.pieces();
        while (packed_pieces.next()) |piece| {
            const unmoved_rook = piece.code.kind == PieceCode.UNMOVED_ROOK;
            if (unmoved_rook) {
                if (piece.code.black) black_rights[piece.square % 8] = true else white_rights[piece.square % 8] = true;
            }
            const char = PIECE_CHARS[if (unmoved_rook) types.PieceType.Rook.index() else piece.code.kind];
            squares[piece.square] = if (piece.code.black) char else std.ascii.toUpper(char);
        }

        var writer = std.Io.Writer.fixed(buf);
        var rank: usize = 8;
        while (rank > 0) {
            rank -= 1;
            var empty: u8 = 0;
            for (0..8) |file| {
                const piece = squares[rank * 8 + file];
                if (piece == 0) {
                    empty += 1;
                    continue;
                }
                if (empty > 0) writer.writeByte('0' + empty) catch unreachable;
                empty = 0;
                writer.writeByte(piece) catch unreachable;
            }
            if (empty > 0) writer.writeByte('0' + empty) catch unreachable;
            if (rank > 0) writer.writeByte('/') catch unreachable;
        }
        writer.writeAll(if (self.stm_ep & BLACK_TO_MOVE != 0) " b " else " w ") catch unreachable;

        var any_right = false;
        for (0..8) |file| {
            if (white_rights[7 - file]) {
                writer.writeByte('A' + @as(u8, @intCast(7 - file))) catch unreachable;
                any_right = true;
            }
        }
        for (0..8) |file| {
            if (black_rights[7 - file]) {
                writer.writeByte('a' + @as(u8, @intCast(7 - file))) catch unreachable;
                any_right = true;
            }
        }
        if (!any_right) writer.writeByte('-') catch unreachable;

        const ep = self.stm_ep & EP_SQUARE_MASK;
        if (ep == NO_EP_SQUARE) {
            writer.writeAll(" -") catch unreachable;
        } else {
            writer.print(" {c}{c}", .{ 'a' + ep % 8, '1' + ep / 8 }) catch unreachable;
        }
        writer.print(" {} {}", .{ self.halfmove, self.fullmove }) catch unreachable;
        return writer.buffered();
    }

    pub fn set_position(self: PackedBoard, pos: *position.Position) void {
        var buf: [FEN_CAPACITY]u8 = undefined;
        pos.set_fen(self.to_fen(&buf));
    }
};

comptime {
    if (@sizeOf(PackedBoard) != 32) @compileError("PackedBoard must be 32 bytes");
}

pub const MoveScorePair = extern struct {
    move: u16,
    score: i16,
};

comptime {
    if (@sizeOf(MoveScorePair) != 4) @compileError("MoveScorePair must be 4 bytes");
}

pub const TERMINATOR: MoveScorePair = .{ .move = 0, .score = 0 };

const MoveKind = enum(u2) { normal, en_passant, castle, promotion };

const PackedMove = packed struct(u16) {
    from: u6,
    to: u6,
    promoted: u2,
    kind: MoveKind,
};

pub fn encode_move(move: types.Move) u16 {
    const kind: MoveKind = if (move.is_castle())
        .castle
    else if (move.get_flags() == types.MoveFlags.EN_PASSANT)
        .en_passant
    else if (move.is_promotion())
        .promotion
    else
        .normal;
    return @bitCast(PackedMove{
        .from = move.from,
        .to = move.to,
        .promoted = if (kind == .promotion) @truncate(move.flags) else 0,
        .kind = kind,
    });
}

pub fn decode_move(pos: *position.Position, raw: u16) error{IllegalMove}!types.Move {
    const moves = pos.legal_moves();
    for (moves.items()) |move| {
        if (encode_move(move) == raw) return move;
    }
    return error.IllegalMove;
}

pub const Game = struct {
    header: *align(1) PackedBoard,
    pairs: []align(1) MoveScorePair,
};

pub const Reader = struct {
    bytes: []u8,
    at: usize = 0,

    pub fn init(bytes: []u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Reader) error{ Truncated, InvalidHeader, TooManyMoves }!?Game {
        if (self.at == self.bytes.len) return null;
        if (self.bytes.len - self.at < @sizeOf(PackedBoard)) return error.Truncated;
        const header: *align(1) PackedBoard = @ptrCast(self.bytes[self.at..].ptr);
        try header.validate();
        self.at += @sizeOf(PackedBoard);
        const first = self.at;
        while (true) {
            if (self.bytes.len - self.at < @sizeOf(MoveScorePair)) return error.Truncated;
            const pair: *align(1) const MoveScorePair = @ptrCast(self.bytes[self.at..].ptr);
            self.at += @sizeOf(MoveScorePair);
            if (pair.move == 0 and pair.score == 0) break;
        }
        const pairs_bytes = self.bytes[first .. self.at - @sizeOf(MoveScorePair)];
        const pairs = std.mem.bytesAsSlice(MoveScorePair, pairs_bytes);
        if (pairs.len > position.MAX_HISTORY_PLY) return error.TooManyMoves;
        return .{ .header = header, .pairs = pairs };
    }
};
