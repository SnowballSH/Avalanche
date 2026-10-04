const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const datagen = @import("../engine/datagen.zig");
const viriformat = @import("../engine/datagen/viriformat.zig");
const support = @import("support.zig");
const testing = std.testing;

fn expect_header_round_trip(fen_text: []const u8) !void {
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(fen_text);
    const packed_board = viriformat.pack_board(pos, 17);

    var buf: [viriformat.FEN_CAPACITY]u8 = undefined;
    const rebuilt = viriformat.header_to_fen(packed_board, &buf);
    pos.set_fen(rebuilt);
    try testing.expectEqual(packed_board, viriformat.pack_board(pos, 17));
}

test "viriformat: headers round-trip through FEN" {
    support.init_search();
    try expect_header_round_trip("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    try expect_header_round_trip("r3k2r/8/8/8/8/8/8/R3K2R b Kq - 12 40");
    try expect_header_round_trip("nrkbbqrn/pppppppp/8/8/8/8/PPPPPPPP/NRKBBQRN w GBgb - 0 1");
    try expect_header_round_trip("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3");
    try expect_header_round_trip("8/8/8/4k3/8/8/4P3/4K3 b - - 3 57");
}

test "viriformat: every generated game replays move by move" {
    platform.io = std.testing.io;
    support.init_search();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const book =
        \\bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9
        \\nrkbbqrn/pppppppp/8/8/8/8/PPPPPPPP/NRKBBQRN w GBgb - 0 1
        \\rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.epd", .data = book });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const book_path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "b.epd", &path_buf)];
    var diag: datagen.BookDiagnostic = .{};
    const lines = try datagen.loadEpdFile(book_path, &diag);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "{s}.viribin", .{book_path});
    var gen = datagen.Datagen.new(.{ .soft_nodes = 300, .hard_node_multiplier = 4, .positions_target = 3000 }, 9);
    defer gen.deinit();
    gen.openings = lines;
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
        viriformat.set_position(pos, game.header.*);
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

test "viriformat: a truncated game is an error" {
    var bytes: [34]u8 = @splat(0);
    var reader = viriformat.Reader.init(&bytes);
    try testing.expectError(error.Truncated, reader.next());
}
