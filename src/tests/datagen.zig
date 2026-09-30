const std = @import("std");
const platform = @import("../platform.zig");
const datagen = @import("../engine/datagen.zig");
const types = @import("../chess/types.zig");
const support = @import("support.zig");
const testing = std.testing;

const GameCount = struct { games: u64, positions: u64 };

// Walks a viriformat file: 32-byte header, 4-byte (move, score) pairs, 4 zero bytes per game.
fn count_viri(bytes: []const u8) !GameCount {
    var at: usize = 0;
    var count: GameCount = .{ .games = 0, .positions = 0 };
    while (at < bytes.len) {
        if (bytes.len - at < 32) return error.Truncated;
        at += 32;
        while (true) {
            if (bytes.len - at < 4) return error.Truncated;
            const pair = bytes[at..][0..4];
            at += 4;
            if (std.mem.allEqual(u8, pair, 0)) break;
            count.positions += 1;
        }
        count.games += 1;
    }
    return count;
}

const Run = struct {
    tmp: std.testing.TmpDir,
    name: []const u8,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",

    fn init(self: *Run, name: []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.name = name;
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = dir_buf[0..try self.tmp.dir.realPath(std.testing.io, &dir_buf)];
        self.path = try std.fmt.bufPrint(&self.path_buf, "{s}/{s}", .{ dir, name });
    }

    fn read(self: *Run) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, self.name, testing.allocator, .unlimited);
    }
};

fn quick_config(target: u64) datagen.DatagenConfig {
    return .{ .soft_nodes = 200, .hard_node_multiplier = 4, .positions_target = target };
}

test "datagen: positions target ends on a game boundary and the summary matches the file" {
    platform.io = std.testing.io;
    support.init_search();
    var run: Run = undefined;
    try run.init("chunk.viribin");
    defer run.tmp.cleanup();

    var gen = datagen.Datagen.new(quick_config(400), 7);
    defer gen.deinit();
    try gen.start(2, run.path);

    const summary = gen.summary();
    try testing.expect(summary.positions >= 400);
    try testing.expectEqual(summary.games, summary.white_wins + summary.draws + summary.black_wins);
    const bytes = try run.read();
    defer testing.allocator.free(bytes);
    const counted = try count_viri(bytes);
    try testing.expectEqual(summary.positions, counted.positions);
    try testing.expectEqual(summary.games, counted.games);
}

test "datagen: a target smaller than one game writes exactly one game" {
    platform.io = std.testing.io;
    support.init_search();
    var run: Run = undefined;
    try run.init("one.viribin");
    defer run.tmp.cleanup();

    var gen = datagen.Datagen.new(quick_config(1), 3);
    defer gen.deinit();
    try gen.start(1, run.path);
    try testing.expectEqual(@as(u64, 1), gen.summary().games);
}

test "datagen: one thread with the same seed is byte-identical" {
    platform.io = std.testing.io;
    support.init_search();
    var a: Run = undefined;
    try a.init("a.viribin");
    defer a.tmp.cleanup();
    var b: Run = undefined;
    try b.init("b.viribin");
    defer b.tmp.cleanup();

    for ([_]*Run{ &a, &b }) |run| {
        var gen = datagen.Datagen.new(quick_config(300), 11);
        defer gen.deinit();
        try gen.start(1, run.path);
    }
    const x = try a.read();
    defer testing.allocator.free(x);
    const y = try b.read();
    defer testing.allocator.free(y);
    try testing.expectEqualSlices(u8, x, y);
}

test "datagen: never overwrites an existing output file" {
    platform.io = std.testing.io;
    support.init_search();
    var run: Run = undefined;
    try run.init("exists.viribin");
    defer run.tmp.cleanup();
    try run.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exists.viribin", .data = "keep" });

    var gen = datagen.Datagen.new(quick_config(10), 1);
    defer gen.deinit();
    try testing.expectError(error.PathAlreadyExists, gen.start(1, run.path));
    const bytes = try run.read();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("keep", bytes);
}

test "datagen: default output path is portable and seed-derived" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("data_000000000000002a.viribin", datagen.default_output_path(&buf, 42, .viri));
    try testing.expectEqualStrings("data_000000000000002a.bin", datagen.default_output_path(&buf, 42, .bullet));
}

test "datagen: EPD lines with opcodes, 4-field FENs and Shredder castling all load and play" {
    platform.io = std.testing.io;
    support.init_search();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const book =
        \\rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - bm e5; id "x";
        \\rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -
        \\bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.epd", .data = book });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp.dir.realPathFile(std.testing.io, "b.epd", &buf)];

    var diag: datagen.BookDiagnostic = .{};
    const lines = try datagen.loadEpdFile(path, &diag);
    try testing.expectEqual(@as(usize, 3), lines.len);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "{s}.viribin", .{path});
    var gen = datagen.Datagen.new(.{ .soft_nodes = 200, .hard_node_multiplier = 4, .positions_target = 600 }, 5);
    defer gen.deinit();
    gen.openings = lines;
    try gen.start(1, out);
    try testing.expect(gen.summary().games > 0);
}

test "datagen: a missing book is an error, not a panic" {
    platform.io = std.testing.io;
    var diag: datagen.BookDiagnostic = .{};
    try testing.expectError(error.FileNotFound, datagen.loadEpdFile("/nonexistent/book.epd", &diag));
}

fn load_book_text(text: []const u8, diag: *datagen.BookDiagnostic) ![]const []const u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "book.epd", .data = text });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp.dir.realPathFile(std.testing.io, "book.epd", &buf)];
    return datagen.loadEpdFile(path, diag);
}

test "datagen: a malformed book line is rejected with its line number and reason" {
    platform.io = std.testing.io;
    support.init_search();
    var diag: datagen.BookDiagnostic = .{};
    const book =
        \\rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
        \\
        \\rnbq1bnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1
        \\
    ;
    try testing.expectError(error.InvalidBookLine, load_book_text(book, &diag));
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqualStrings("BadKingCount", diag.reason);
}

test "datagen: a book line whose side not to move is in check is rejected" {
    platform.io = std.testing.io;
    support.init_search();
    var diag: datagen.BookDiagnostic = .{};
    try testing.expectError(error.InvalidBookLine, load_book_text("4k3/8/8/8/8/8/8/4K2r w - - 0 1\n4k3/4R3/8/8/8/8/8/4K3 w - - 0 1\n", &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expectEqualStrings("OpponentInCheck", diag.reason);
}

test "datagen: an empty book is an error" {
    platform.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.epd", .data = "\n  \n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp.dir.realPathFile(std.testing.io, "empty.epd", &buf)];
    var diag: datagen.BookDiagnostic = .{};
    try testing.expectError(error.EmptyBook, datagen.loadEpdFile(path, &diag));
}

test "viriformat: FRC castling encodes king-to-rook-square with the castle type" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("4k3/8/8/8/8/8/8/1R3K2 w B - 0 1");

    var moves = std.array_list.Managed(types.Move).init(testing.allocator);
    defer moves.deinit();
    pos.generate_legal_moves(types.Color.White, &moves);
    var castle: ?types.Move = null;
    for (moves.items) |m| {
        if (m.is_castle()) castle = m;
    }
    const encoded = datagen.encode_viri_move(castle.?);
    try testing.expectEqual(@as(u16, 2), encoded >> 14);
    try testing.expectEqual(@as(u16, @intFromEnum(types.Square.b1)), (encoded >> 6) & 63);
    try testing.expectEqual(@as(u16, @intFromEnum(types.Square.f1)), encoded & 63);
}

test "viriformat: FRC unmoved castling rooks are marked as type 6" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("nrkbbqrn/pppppppp/8/8/8/8/PPPPPPPP/NRKBBQRN w GBgb - 0 1");
    const board = datagen.pos_to_viri_packed_board(pos, 0);
    var unmoved: usize = 0;
    for (board.pcs) |byte| {
        if (byte & 0x7 == 6) unmoved += 1;
        if ((byte >> 4) & 0x7 == 6) unmoved += 1;
    }
    try testing.expectEqual(@as(usize, 4), unmoved);
}
