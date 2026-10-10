const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const datagen = @import("../engine/datagen.zig");
const book = @import("../engine/datagen/book.zig");
const viriformat = @import("../engine/datagen/viriformat.zig");
const support = @import("support.zig");
const testing = std.testing;

const PackedBoard = viriformat.PackedBoard;

fn expect_header_round_trip(fen_text: []const u8) !void {
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(fen_text);
    const packed_board = PackedBoard.pack(pos, 17);
    try packed_board.validate();

    var buf: [viriformat.FEN_CAPACITY]u8 = undefined;
    const rebuilt = packed_board.to_fen(&buf);
    pos.set_fen(rebuilt);
    try testing.expectEqual(packed_board, PackedBoard.pack(pos, 17));
}

test "viriformat: headers round-trip through FEN" {
    support.init_search();
    try expect_header_round_trip("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    try expect_header_round_trip("r3k2r/8/8/8/8/8/8/R3K2R b Kq - 12 40");
    try expect_header_round_trip("nrkbbqrn/pppppppp/8/8/8/8/PPPPPPPP/NRKBBQRN w GBgb - 0 1");
    try expect_header_round_trip("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3");
    try expect_header_round_trip("8/8/8/4k3/8/8/4P3/4K3 b - - 3 57");
}

test "viriformat: FRC castling encodes king-to-rook-square with the castle type" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("4k3/8/8/8/8/8/8/1R3K2 w B - 0 1");

    var moves: types.MoveList = .{};
    pos.generate_legal_moves(types.Color.White, &moves);
    var castle: ?types.Move = null;
    for (moves.items()) |m| {
        if (m.is_castle()) castle = m;
    }
    const encoded = viriformat.encode_move(castle.?);
    try testing.expectEqual(@as(u16, 2), encoded >> 14);
    try testing.expectEqual(@as(u16, @backingInt(types.Square.b1)), (encoded >> 6) & 63);
    try testing.expectEqual(@as(u16, @backingInt(types.Square.f1)), encoded & 63);
}

test "viriformat: en passant and promotions carry their type, and a promotion its piece" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2");
    const en_passant = types.Move.new_from_string(pos, "e5d6");
    try testing.expectEqual(types.MoveFlags.EN_PASSANT, en_passant.get_flags());
    try testing.expectEqual(@as(u16, 1), viriformat.encode_move(en_passant) >> 14);

    pos.set_fen("1n2k3/P7/8/8/8/8/8/4K3 w - - 0 1");
    inline for (.{ "a7a8n", "a7a8b", "a7a8r", "a7a8q", "a7b8n", "a7b8q" }, .{ 0, 1, 2, 3, 0, 3 }) |text, piece| {
        const encoded = viriformat.encode_move(types.Move.new_from_string(pos, text));
        try testing.expectEqual(@as(u16, 3), encoded >> 14);
        try testing.expectEqual(@as(u16, piece), (encoded >> 12) & 3);
    }

    pos.set_fen(types.DEFAULT_FEN);
    try testing.expectEqual(@as(u16, 0), viriformat.encode_move(types.Move.new_from_string(pos, "e2e4")) >> 12);
}

test "viriformat: FRC unmoved castling rooks are marked as type 6" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("nrkbbqrn/pppppppp/8/8/8/8/PPPPPPPP/NRKBBQRN w GBgb - 0 1");
    const board = PackedBoard.pack(pos, 0);
    var unmoved: usize = 0;
    for (board.pcs) |byte| {
        if (byte & 0x7 == 6) unmoved += 1;
        if ((byte >> 4) & 0x7 == 6) unmoved += 1;
    }
    try testing.expectEqual(@as(usize, 4), unmoved);
}

test "viriformat: a move number beyond the header's 16 bits is stored as the largest one" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("4k3/8/8/8/8/8/4P3/4K3 w - - 0 70000");
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), PackedBoard.pack(pos, 0).fullmove);
}

test "viriformat: every generated game replays move by move" {
    platform.io = std.testing.io;
    support.init_search();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const book_text =
        \\bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9
        \\nrkbbqrn/pppppppp/8/8/8/8/PPPPPPPP/NRKBBQRN w GBgb - 0 1
        \\rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.epd", .data = book_text });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const book_path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "b.epd", &path_buf)];
    var diag: book.Diagnostic = .{};
    var openings = try book.Book.load(testing.allocator, book_path, &diag);
    defer openings.deinit();

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.mem.print(&out_buf, "{s}.viribin", .{book_path});
    var gen = datagen.Datagen.new(.{ .soft_nodes = 300, .hard_node_multiplier = 64, .positions_target = 3000 }, 9);
    defer gen.deinit();
    gen.openings = openings.lines;
    try gen.start(2, out);

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "b.epd.viribin", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    var reader = viriformat.Reader.init(bytes);
    var games: u64 = 0;
    var positions: u64 = 0;
    var castles: u64 = 0;
    while (try reader.next()) |game| {
        game.header.set_position(pos);
        for (game.pairs) |pair| {
            const move = try viriformat.decode_move(pos, pair.move);
            if (move.is_castle()) castles += 1;
            if (pos.turn == types.Color.White) pos.play_move(types.Color.White, move) else pos.play_move(types.Color.Black, move);
        }
        games += 1;
        positions += game.pairs.len;
    }
    try testing.expectEqual(gen.summary().games, games);
    try testing.expectEqual(gen.summary().positions, positions);
    try testing.expect(castles > 0);
}

test "viriformat: a move that is not legal in the position is an error" {
    support.init_search();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN);
    const e2e5: u16 = @backingInt(types.Square.e2) | (@as(u16, @backingInt(types.Square.e5)) << 6);
    try testing.expectError(error.IllegalMove, viriformat.decode_move(pos, e2e5));
}

const GAME_WITHOUT_MOVES_SIZE = @sizeOf(PackedBoard) + @sizeOf(viriformat.MoveScorePair);

fn game_without_moves(fen_text: []const u8) ![GAME_WITHOUT_MOVES_SIZE]u8 {
    support.init_search();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(fen_text);
    var bytes: [GAME_WITHOUT_MOVES_SIZE]u8 = undefined;
    @memcpy(bytes[0..@sizeOf(PackedBoard)], std.mem.asBytes(&PackedBoard.pack(pos, 0)));
    @memcpy(bytes[@sizeOf(PackedBoard)..], std.mem.asBytes(&viriformat.TERMINATOR));
    return bytes;
}

fn header_of(bytes: *[GAME_WITHOUT_MOVES_SIZE]u8) *align(1) PackedBoard {
    return @ptrCast(bytes);
}

fn expect_invalid_header(bytes: *[GAME_WITHOUT_MOVES_SIZE]u8) !void {
    var reader = viriformat.Reader.init(bytes);
    try testing.expectError(error.InvalidHeader, reader.next());
}

const WHITE_KNIGHT_B1 = 1;
const WHITE_QUEEN_D1 = 3;
const WHITE_KING_E1 = 4;

fn set_piece_kind(header: *align(1) PackedBoard, piece_index: usize, kind: u8) void {
    const shift: u3 = @intCast(4 * (piece_index & 1));
    const colour_bit = header.pcs[piece_index / 2] & (@as(u8, 0x8) << shift);
    header.pcs[piece_index / 2] &= ~(@as(u8, 0xF) << shift);
    header.pcs[piece_index / 2] |= colour_bit | (kind << shift);
}

test "viriformat: a truncated game is an error" {
    var bytes = try game_without_moves(types.DEFAULT_FEN);
    var whole = viriformat.Reader.init(&bytes);
    try testing.expectEqual(@as(usize, 0), (try whole.next()).?.pairs.len);
    try testing.expect((try whole.next()) == null);

    var without_terminator = viriformat.Reader.init(bytes[0 .. bytes.len - 2]);
    try testing.expectError(error.Truncated, without_terminator.next());
    var inside_header = viriformat.Reader.init(bytes[0..20]);
    try testing.expectError(error.Truncated, inside_header.next());
}

test "viriformat: a header with more than 32 pieces is invalid" {
    var bytes = try game_without_moves(types.DEFAULT_FEN);
    header_of(&bytes).occ |= @as(u64, 1) << @backingInt(types.Square.e4);
    try expect_invalid_header(&bytes);
    header_of(&bytes).occ = std.math.maxInt(u64);
    try expect_invalid_header(&bytes);
}

test "viriformat: a header with an unknown piece code is invalid" {
    var bytes = try game_without_moves(types.DEFAULT_FEN);
    set_piece_kind(header_of(&bytes), WHITE_KNIGHT_B1, 7);
    try expect_invalid_header(&bytes);
}

test "viriformat: a header without exactly one king per side is invalid" {
    var missing = try game_without_moves(types.DEFAULT_FEN);
    set_piece_kind(header_of(&missing), WHITE_KING_E1, @backingInt(types.PieceType.Queen));
    try expect_invalid_header(&missing);

    var doubled = try game_without_moves(types.DEFAULT_FEN);
    set_piece_kind(header_of(&doubled), WHITE_QUEEN_D1, @backingInt(types.PieceType.King));
    try expect_invalid_header(&doubled);

    var empty: [GAME_WITHOUT_MOVES_SIZE]u8 = @splat(0);
    try expect_invalid_header(&empty);
}

test "viriformat: a header with a pawn on a back rank or the side not to move in check is invalid" {
    var pawn = try game_without_moves(types.DEFAULT_FEN);
    set_piece_kind(header_of(&pawn), WHITE_KNIGHT_B1, @backingInt(types.PieceType.Pawn));
    try expect_invalid_header(&pawn);

    var check = try game_without_moves("4k3/4R3/8/8/8/8/8/4K3 b - - 0 1");
    header_of(&check).stm_ep &= 0x7F;
    try expect_invalid_header(&check);
}

test "viriformat: a header with an impossible result or en-passant square is invalid" {
    var result = try game_without_moves(types.DEFAULT_FEN);
    header_of(&result).wdl = 3;
    try expect_invalid_header(&result);

    var en_passant = try game_without_moves(types.DEFAULT_FEN);
    header_of(&en_passant).stm_ep = 65;
    try expect_invalid_header(&en_passant);
    header_of(&en_passant).stm_ep = @backingInt(types.Square.e4);
    try expect_invalid_header(&en_passant);
}

test "viriformat: a game longer than a position can replay is an error" {
    const start = try game_without_moves(types.DEFAULT_FEN);
    const any_move = viriformat.MoveScorePair{ .move = 1, .score = 0 };

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, start[0..@sizeOf(PackedBoard)]);
    for (0..position.MAX_HISTORY_PLY) |_| try bytes.appendSlice(testing.allocator, std.mem.asBytes(&any_move));
    const longest_len = bytes.items.len;
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&viriformat.TERMINATOR));

    var longest = viriformat.Reader.init(bytes.items);
    try testing.expectEqual(@as(usize, position.MAX_HISTORY_PLY), (try longest.next()).?.pairs.len);

    bytes.shrinkRetainingCapacity(longest_len);
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&any_move));
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&viriformat.TERMINATOR));
    var too_long = viriformat.Reader.init(bytes.items);
    try testing.expectError(error.TooManyMoves, too_long.next());
}
