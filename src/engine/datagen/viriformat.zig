const std = @import("std");
const types = @import("../../chess/types.zig");
const position = @import("../../chess/position.zig");

// Viriformat PackedBoard — 32 bytes, little-endian
// Piece encoding: bits 0-2 = type (0=P,1=N,2=B,3=R,4=Q,5=K,6=unmoved_rook), bit3 = color (0=white,1=black)
pub const PackedBoard = extern struct {
    occ: u64,
    pcs: [16]u8,
    stm_ep: u8,
    halfmove: u8,
    fullmove: u16,
    eval: i16,
    wdl: u8,
    extra: u8,
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

pub fn encode_move(move: types.Move) u16 {
    const from: u16 = @as(u16, move.from);
    const raw_flags: u4 = move.flags;

    const to: u16 = @as(u16, move.to);
    var promo: u16 = 0;
    var mtype: u16 = 0;

    if (move.is_castle()) {
        mtype = 2;
    } else if (raw_flags == 0b1010) {
        // EN_PASSANT
        mtype = 1;
    } else if (raw_flags & 0b0100 != 0) {
        // Any promotion (bit 2 set in flags = promotion)
        mtype = 3;
        promo = @as(u16, raw_flags & 0b0011);
    }

    return from | (to << 6) | (promo << 12) | (mtype << 14);
}

pub fn pack_board(pos: *position.Position, white_relative_score: i32) PackedBoard {
    const all_occ = pos.all_all_pieces();

    const castling_rooks = pos.castling_rook_squares();

    // Pack pieces in occupancy order (LSB first)
    var pcs: [16]u8 = @splat(0);
    var idx: usize = 0;
    var occ_iter = all_occ;
    while (occ_iter != 0) {
        const sq_idx = @ctz(occ_iter);
        const sq_bit: u64 = @as(u64, 1) << @as(u6, @intCast(sq_idx));
        occ_iter &= occ_iter - 1;

        const piece = pos.mailbox[sq_idx];
        if (piece == types.Piece.NO_PIECE) continue;

        const pt = piece.piece_type();
        const color = piece.color();
        var piece_nibble: u8 = @as(u8, pt.index());

        // Mark unmoved rooks as type 6 (castling rights indicator in viriformat)
        if (pt == types.PieceType.Rook and castling_rooks & sq_bit != 0) {
            piece_nibble = 6;
        }

        // Color bit: 0=white, 1=black (bit 3)
        if (color == types.Color.Black) piece_nibble |= 8;

        pcs[idx / 2] |= piece_nibble << @as(u3, @intCast(4 * (idx & 1)));
        idx += 1;
    }

    // Side-to-move + en-passant byte
    const ep_sq = pos.history[pos.game_ply].ep_sq;
    const ep_val: u8 = if (ep_sq == types.Square.NO_SQUARE) 64 else @as(u8, @intCast(ep_sq.index()));
    const stm_bit: u8 = if (pos.turn == types.Color.Black) 0x80 else 0;
    const stm_ep: u8 = stm_bit | (ep_val & 0x7F);

    // Halfmove clock
    const halfmove: u8 = @as(u8, @intCast(@min(pos.history[pos.game_ply].fifty, 255)));

    // Fullmove counter
    const fullmove: u16 = @as(u16, @intCast(pos.absolute_ply() / 2 + 1));

    // Eval: white-relative, clamped
    const clamped = std.math.clamp(white_relative_score, -32000, 32000);

    return PackedBoard{
        .occ = all_occ,
        .pcs = pcs,
        .stm_ep = stm_ep,
        .halfmove = halfmove,
        .fullmove = fullmove,
        .eval = @as(i16, @intCast(clamped)),
        .wdl = 1, // filled at game end
        .extra = 0,
    };
}

pub const FEN_CAPACITY = 128;
const NO_EP_SQUARE: u8 = 64;
const UNMOVED_ROOK: u4 = 6;
const PIECE_CHARS = "pnbrqk";

/// Rebuilds a FEN from a packed header; unmoved rooks become Shredder-FEN castling files, which `set_fen` reads for
/// standard chess and Chess960 alike.
pub fn header_to_fen(board: PackedBoard, buf: *[FEN_CAPACITY]u8) []const u8 {
    var squares: [64]u8 = @splat(0);
    var white_rights: [8]bool = @splat(false);
    var black_rights: [8]bool = @splat(false);
    var occupancy = board.occ;
    var index: usize = 0;
    while (occupancy != 0) : (index += 1) {
        const square: u6 = @intCast(@ctz(occupancy));
        occupancy &= occupancy - 1;
        const nibble: u4 = @truncate(board.pcs[index / 2] >> @as(u3, @intCast(4 * (index & 1))));
        const black = nibble & 8 != 0;
        const kind = nibble & 7;
        if (kind == UNMOVED_ROOK) {
            if (black) black_rights[square % 8] = true else white_rights[square % 8] = true;
        }
        const char = PIECE_CHARS[if (kind == UNMOVED_ROOK) 3 else kind];
        squares[square] = if (black) char else std.ascii.toUpper(char);
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
    writer.writeAll(if (board.stm_ep & 0x80 != 0) " b " else " w ") catch unreachable;

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

    const ep = board.stm_ep & 0x7F;
    if (ep == NO_EP_SQUARE) {
        writer.writeAll(" -") catch unreachable;
    } else {
        writer.print(" {c}{c}", .{ 'a' + ep % 8, '1' + ep / 8 }) catch unreachable;
    }
    writer.print(" {} {}", .{ board.halfmove, board.fullmove }) catch unreachable;
    return writer.buffered();
}

pub fn set_position(pos: *position.Position, board: PackedBoard) void {
    var buf: [FEN_CAPACITY]u8 = undefined;
    pos.set_fen(header_to_fen(board, &buf));
}

/// Finds the legal move whose viriformat encoding is `raw`, so decoding can never disagree with `encode_move`.
pub fn decode_move(pos: *position.Position, raw: u16) error{IllegalMove}!types.Move {
    var buffer: [256]types.Move = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&buffer));
    var moves = std.array_list.Managed(types.Move).initCapacity(fba.allocator(), buffer.len) catch unreachable;
    if (pos.turn == types.Color.White) pos.generate_legal_moves(types.Color.White, &moves) else pos.generate_legal_moves(types.Color.Black, &moves);
    for (moves.items) |move| {
        if (encode_move(move) == raw) return move;
    }
    return error.IllegalMove;
}

pub const Game = struct {
    header: *align(1) PackedBoard,
    pairs: []align(1) MoveScorePair,
};

/// Iterates the games of an in-memory viriformat file; the returned slices alias the buffer, so evals can be edited
/// in place.
pub const Reader = struct {
    bytes: []u8,
    at: usize = 0,

    pub fn init(bytes: []u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Reader) error{Truncated}!?Game {
        if (self.at == self.bytes.len) return null;
        if (self.bytes.len - self.at < @sizeOf(PackedBoard)) return error.Truncated;
        const header: *align(1) PackedBoard = @ptrCast(self.bytes[self.at..].ptr);
        self.at += @sizeOf(PackedBoard);
        const first = self.at;
        while (true) {
            if (self.bytes.len - self.at < @sizeOf(MoveScorePair)) return error.Truncated;
            const pair: *align(1) const MoveScorePair = @ptrCast(self.bytes[self.at..].ptr);
            self.at += @sizeOf(MoveScorePair);
            if (pair.move == 0 and pair.score == 0) break;
        }
        const pairs_bytes = self.bytes[first .. self.at - @sizeOf(MoveScorePair)];
        return .{ .header = header, .pairs = std.mem.bytesAsSlice(MoveScorePair, pairs_bytes) };
    }
};
