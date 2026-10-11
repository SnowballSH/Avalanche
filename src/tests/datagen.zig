const std = @import("std");
const platform = @import("../platform.zig");
const datagen = @import("../engine/datagen.zig");
const book = @import("../engine/datagen/book.zig");
const genfens = @import("../engine/genfens.zig");
const types = @import("../chess/types.zig");
const utils = @import("../chess/utils.zig");
const hce = @import("../engine/hce.zig");
const support = @import("support.zig");
const testing = std.testing;

const GameCount = struct { games: u64, positions: u64 };

const HEADER_BYTES = 32;
const PAIR_BYTES = 4;

fn count_viri(bytes: []const u8) !GameCount {
    var at: usize = 0;
    var count: GameCount = .{ .games = 0, .positions = 0 };
    while (at < bytes.len) {
        if (bytes.len - at < HEADER_BYTES) return error.Truncated;
        at += HEADER_BYTES;
        while (true) {
            if (bytes.len - at < PAIR_BYTES) return error.Truncated;
            const pair = bytes[at..][0..PAIR_BYTES];
            at += PAIR_BYTES;
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
        self.path = try std.mem.print(&self.path_buf, "{s}/{s}", .{ dir, name });
    }

    fn read(self: *Run) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, self.name, testing.allocator, .unlimited);
    }
};

fn quick_config(target: u64) datagen.DatagenConfig {
    return .{ .soft_nodes = 200, .hard_node_multiplier = 64, .positions_target = target };
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
    try testing.expectError(error.OutputNotCreated, gen.generate(1, run.path));
    try testing.expectEqual(@as(?anyerror, error.PathAlreadyExists), gen.output_failure);
    const bytes = try run.read();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("keep", bytes);
}

test "datagen: default output path is portable and seed-derived" {
    var buf: [datagen.DEFAULT_OUTPUT_PATH_CAPACITY]u8 = undefined;
    try testing.expectEqualStrings("data_000000000000002a.viribin", datagen.default_output_path(&buf, 42, .viri));
    try testing.expectEqualStrings("data_000000000000002a.bin", datagen.default_output_path(&buf, 42, .bullet));
    try testing.expectEqualStrings("data_ffffffffffffffff.viribin", datagen.default_output_path(&buf, std.math.maxInt(u64), .viri));
}

const MATE_IN_ONE_OPENING = "6k1/5ppp/8/8/8/8/8/R6K w - - 0 1";
const STALEMATE_OPENING = "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1";

fn searching_book_lines_as_they_are(config: datagen.DatagenConfig) datagen.DatagenConfig {
    var without_random_plies = config;
    without_random_plies.book_random_plies_min = 0;
    without_random_plies.book_random_plies_range = 1;
    return without_random_plies;
}

test "datagen: a book whose every opening is rejected fails the run instead of running forever" {
    platform.io = std.testing.io;
    support.init_search();

    inline for (.{ MATE_IN_ONE_OPENING, MATE_IN_ONE_OPENING, STALEMATE_OPENING }, .{ .viri, .bullet, .bullet }) |opening, format| {
        var run: Run = undefined;
        try run.init("rejected.out");
        defer run.tmp.cleanup();

        var config = searching_book_lines_as_they_are(quick_config(100));
        config.format = format;
        config.max_consecutive_discards = 20;
        var gen = datagen.Datagen.new(config, 1);
        defer gen.deinit();
        gen.openings = &.{opening};

        try testing.expectError(error.WorkerFailed, gen.generate(1, run.path));
        try testing.expectEqual(@as(?anyerror, error.NoUsableOpening), gen.workers.items[0].failure);
        try testing.expectEqual(@as(u64, 20), gen.summary().discarded_games);
        try testing.expectEqual(@as(u64, 0), gen.summary().games);
        const bytes = try run.read();
        defer testing.allocator.free(bytes);
        try testing.expectEqual(@as(usize, 0), bytes.len);
    }
}

fn seed_whose_first_game_starts_from(opening: usize, opening_count: usize) u64 {
    var seed: u64 = 0;
    while (true) : (seed += 1) {
        var first_worker = utils.PRNG.new(datagen.thread_seed(seed, 0));
        if (first_worker.rand64() % opening_count == opening) return seed;
    }
}

test "datagen: discarded games are counted in the summary and leave no trace in the file" {
    platform.io = std.testing.io;
    support.init_search();
    var run: Run = undefined;
    try run.init("mixed.viribin");
    defer run.tmp.cleanup();

    const openings = [_][]const u8{ STALEMATE_OPENING, MATE_IN_ONE_OPENING, types.DEFAULT_FEN };
    var gen = datagen.Datagen.new(quick_config(300), seed_whose_first_game_starts_from(0, openings.len));
    defer gen.deinit();
    gen.openings = &openings;
    try gen.start(1, run.path);

    const summary = gen.summary();
    try testing.expect(summary.discarded_games > 0);
    const bytes = try run.read();
    defer testing.allocator.free(bytes);
    const counted = try count_viri(bytes);
    try testing.expectEqual(summary.games, counted.games);
    try testing.expectEqual(summary.positions, counted.positions);
}

test "datagen: a node budget that cannot finish depth 1 fails the run instead of recording a mate score" {
    platform.io = std.testing.io;
    support.init_search();
    var run: Run = undefined;
    try run.init("starved.viribin");
    defer run.tmp.cleanup();

    var gen = datagen.Datagen.new(.{ .soft_nodes = 1, .hard_node_multiplier = 1, .positions_target = 10 }, 1);
    defer gen.deinit();
    try testing.expectError(error.WorkerFailed, gen.generate(1, run.path));
    try testing.expectEqual(@as(?anyerror, error.NodeBudgetBelowDepthOne), gen.workers.items[0].failure);
    try testing.expect(datagen.explain(error.NodeBudgetBelowDepthOne).len > 0);
    const bytes = try run.read();
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

const LoadedBook = struct {
    tmp: std.testing.TmpDir,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",

    fn write(self: *LoadedBook, text: []const u8) !void {
        platform.io = std.testing.io;
        support.init_search();
        self.tmp = std.testing.tmpDir(.{});
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "book.epd", .data = text });
        self.path = self.path_buf[0..try self.tmp.dir.realPathFile(std.testing.io, "book.epd", &self.path_buf)];
    }

    fn load(self: *LoadedBook, diag: *book.Diagnostic) !book.Book {
        return book.Book.load(testing.allocator, self.path, diag);
    }
};

fn expect_rejected_line(text: []const u8, line: usize, reason: []const u8) !void {
    var file: LoadedBook = undefined;
    try file.write(text);
    defer file.tmp.cleanup();
    var diag: book.Diagnostic = .{};
    try testing.expectError(error.InvalidBookLine, file.load(&diag));
    try testing.expectEqual(line, diag.line);
    try testing.expectEqualStrings(reason, diag.reason);
}

test "datagen: EPD lines with opcodes, 4-field FENs and Shredder castling all load and play" {
    var file: LoadedBook = undefined;
    try file.write(
        \\rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - bm e5; id "x";
        \\rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -
        \\bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9
        \\
    );
    defer file.tmp.cleanup();

    var diag: book.Diagnostic = .{};
    var openings = try file.load(&diag);
    defer openings.deinit();
    try testing.expectEqual(@as(usize, 3), openings.lines.len);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.mem.print(&out_buf, "{s}.viribin", .{file.path});
    var gen = datagen.Datagen.new(quick_config(600), 5);
    defer gen.deinit();
    gen.openings = openings.lines;
    try gen.start(1, out);
    try testing.expect(gen.summary().games > 0);
}

test "datagen: a missing book is an error, not a panic" {
    platform.io = std.testing.io;
    var diag: book.Diagnostic = .{};
    try testing.expectError(error.FileNotFound, book.Book.load(testing.allocator, "/nonexistent/book.epd", &diag));
}

test "datagen: a malformed book line is rejected with its line number and reason" {
    try expect_rejected_line(
        \\rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
        \\
        \\rnbq1bnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1
        \\
    , 3, "BadKingCount");
    try expect_rejected_line("# openings\n" ++ types.DEFAULT_FEN ++ "\n", 1, "UnknownPiece");
}

test "datagen: a book line whose side not to move is in check is rejected" {
    try expect_rejected_line("4k3/8/8/8/8/8/8/4K2r w - - 0 1\n4k3/4R3/8/8/8/8/8/4K3 w - - 0 1\n", 2, "OpponentInCheck");
}

test "datagen: a book line with more pieces or a later move number than a game record holds is rejected" {
    try expect_rejected_line("rnbqkbnr/pppppppp/pppppppp/8/8/PPPPPPPP/PPPPPPPP/RNBQKBNR w - - 0 1\n", 1, "TooManyPieces");
    try expect_rejected_line(types.DEFAULT_FEN ++ "\n4k3/8/8/8/8/8/4P3/4K3 w - - 0 65536\n", 2, "MoveNumberTooLarge");
    inline for (.{ "4294967295", "3_000_000_000", "6_5536", "99999999999999999999999999" }) |move_number| {
        try expect_rejected_line("4k3/8/8/8/8/8/4P3/4K3 w - - 0 " ++ move_number ++ "\n", 1, "MoveNumberTooLarge");
    }

    try book.validate_line("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 99 65535");
    try book.validate_line("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 99 6_5535");
    try book.validate_line("4k3/8/8/8/8/8/4P3/4K3 w - - bm e4; id \"12345678\";");
    try book.validate_line("4k3/8/8/8/8/8/4P3/4K3 w - - acn 12345678901;");
}

test "datagen: an empty book is an error" {
    var file: LoadedBook = undefined;
    try file.write("\n  \n");
    defer file.tmp.cleanup();
    var diag: book.Diagnostic = .{};
    try testing.expectError(error.EmptyBook, file.load(&diag));
}

fn genfens_lines(options: genfens.Options, book_lines: []const []const u8, buffer: []u8) ![]const u8 {
    support.init_search();
    var out = std.Io.Writer.fixed(buffer);
    try genfens.generate(options, book_lines, &out);
    return out.buffered();
}

test "genfens: prints the requested number of openings, the same ones for the same seed" {
    var first_buf: [4096]u8 = undefined;
    var second_buf: [4096]u8 = undefined;
    var other_buf: [4096]u8 = undefined;
    inline for (.{ genfens.Variant.standard, genfens.Variant.frc, genfens.Variant.dfrc }) |variant| {
        const first = try genfens_lines(.{ .count = 5, .seed = 3, .variant = variant }, &.{}, &first_buf);
        try testing.expectEqual(@as(usize, 5), std.mem.count(u8, first, "info string genfens "));
        try testing.expectEqual(@as(usize, 5), std.mem.count(u8, first, "\n"));
        try testing.expectEqualStrings(first, try genfens_lines(.{ .count = 5, .seed = 3, .variant = variant }, &.{}, &second_buf));
        try testing.expect(!std.mem.eql(u8, first, try genfens_lines(.{ .count = 5, .seed = 4, .variant = variant }, &.{}, &other_buf)));
    }
}

test "genfens: every opening is a position a datagen book accepts" {
    var buf: [8192]u8 = undefined;
    const output = try genfens_lines(.{ .count = 20, .seed = 9 }, &.{ types.DEFAULT_FEN, "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9" }, &buf);
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        try book.validate_line(line["info string genfens ".len..]);
    }
    try testing.expectEqual(@as(usize, 20), count);
}

test "genfens: a book without a usable opening is an error instead of an endless loop" {
    var buf: [256]u8 = undefined;
    try testing.expectError(error.NoUsableOpening, genfens_lines(.{ .count = 1 }, &.{STALEMATE_OPENING}, &buf));
}

test "genfens: arguments are a count, then seed, book and variant in any order" {
    var offending: []const u8 = "";
    const defaults = try genfens.parse(&.{}, &offending);
    try testing.expectEqual(@as(u64, 1), defaults.count);
    try testing.expectEqual(@as(?[]const u8, null), defaults.book_path);

    const all = try genfens.parse(&.{ "64", "seed", "7", "book", "books/x.epd", "dfrc" }, &offending);
    try testing.expectEqual(@as(u64, 64), all.count);
    try testing.expectEqual(@as(u64, 7), all.seed);
    try testing.expectEqualStrings("books/x.epd", all.book_path.?);
    try testing.expectEqual(genfens.Variant.dfrc, all.variant);

    const no_book = try genfens.parse(&.{ "8", "frc", "book", "None", "seed", "1" }, &offending);
    try testing.expectEqual(@as(?[]const u8, null), no_book.book_path);
    try testing.expectEqual(genfens.Variant.frc, no_book.variant);
}

test "genfens: malformed, unknown and incomplete arguments are errors naming the argument" {
    var offending: []const u8 = "";
    try testing.expectError(error.InvalidValue, genfens.parse(&.{"many"}, &offending));
    try testing.expectEqualStrings("many", offending);
    try testing.expectError(error.InvalidValue, genfens.parse(&.{ "8", "seed", "-1" }, &offending));
    try testing.expectError(error.UnknownArgument, genfens.parse(&.{ "8", "DFRC" }, &offending));
    try testing.expectEqualStrings("DFRC", offending);
    try testing.expectError(error.MissingValue, genfens.parse(&.{ "8", "seed", "1", "book" }, &offending));
    try testing.expectEqualStrings("book", offending);
}

test "genfens: a bad argument or book is reported and prints no opening" {
    var file: LoadedBook = undefined;
    try file.write("# openings\n" ++ types.DEFAULT_FEN ++ "\n");
    defer file.tmp.cleanup();

    const Case = struct { args: []const []const u8, failure: anyerror, report: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{ "3", "seed", "1", "book", file.path }, .failure = error.InvalidBookLine, .report = "line 1: UnknownPiece\n" },
        .{ .args = &.{ "3", "seed", "1", "book", "/nonexistent/book.epd" }, .failure = error.FileNotFound, .report = "cannot load book '/nonexistent/book.epd': FileNotFound\n" },
        .{ .args = &.{ "3", "seed", "x" }, .failure = error.InvalidValue, .report = "genfens: InvalidValue at 'x'\n" },
    };
    for (cases) |case| {
        var out_buf: [256]u8 = undefined;
        var err_buf: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        var err = std.Io.Writer.fixed(&err_buf);
        try testing.expectError(case.failure, genfens.write_openings(case.args, &out, &err));
        try testing.expectEqualStrings("", out.buffered());
        try testing.expect(std.mem.endsWith(u8, err.buffered(), case.report));
    }
}

test "datagen: thread seeds are non-zero, distinct per thread, and stable" {
    for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |run_seed| {
        const first = datagen.thread_seed(run_seed, 0);
        try testing.expect(first != 0);
        try testing.expect(first != datagen.thread_seed(run_seed, 1));
        try testing.expectEqual(first, datagen.thread_seed(run_seed, 0));
    }
    try testing.expect(datagen.thread_seed(0, 0) != datagen.thread_seed(1, 0));
}

test "datagen: raw eval is the network output and differs from the scaled eval" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);

    const network_positions = [_][]const u8{
        "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 9",
        "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 90 60",
        "2r3k1/5ppp/8/8/8/8/5PPP/2RQ2K1 b - - 70 80",
        "8/5pk1/6p1/8/8/6P1/4PPK1/8 w - - 0 40",
        "8/8/3k4/8/3PK3/8/8/8 b - - 12 60",
        "8/8/3k4/3b4/8/2NBK3/8/8 w - - 0 70",
        "8/8/3k4/3b4/8/2NBK3/8/8 b - - 40 90",
    };
    var differing: usize = 0;
    for (network_positions) |line| {
        pos.set_fen(line);
        inline for (.{ types.Color.White, types.Color.Black }) |color| {
            const network = hce.evaluate_nnue_comptime(pos, color);
            try testing.expectEqual(network, hce.evaluate_mode(pos, color, .raw));
            if (network != hce.evaluate_mode(pos, color, .scaled)) differing += 1;
        }
    }
    try testing.expect(differing >= network_positions.len);

    const hand_crafted_positions = [_][]const u8{ "8/8/3k4/8/8/4K3/8/R7 w - - 0 1", "8/8/3k4/8/8/4K3/8/1NN5 b - - 30 1" };
    for (hand_crafted_positions) |line| {
        pos.set_fen(line);
        try testing.expect(!hce.network_evaluates(pos));
        inline for (.{ types.Color.White, types.Color.Black }) |color| {
            try testing.expectEqual(hce.evaluate_mode(pos, color, .scaled), hce.evaluate_mode(pos, color, .raw));
        }
    }
}

fn run_bytes(config: datagen.DatagenConfig, seed: u64) ![]u8 {
    var run: Run = undefined;
    try run.init("chunk.viribin");
    defer run.tmp.cleanup();

    var gen = datagen.Datagen.new(config, seed);
    defer gen.deinit();
    try gen.start(1, run.path);
    try testing.expectEqual(config.raw_eval, gen.summary().raw_eval);
    return run.read();
}

test "datagen: raweval changes the recorded data and is reported in the summary" {
    platform.io = std.testing.io;
    support.init_search();

    var raw_config = quick_config(300);
    raw_config.raw_eval = true;
    const raw = try run_bytes(raw_config, 11);
    defer testing.allocator.free(raw);
    const raw_again = try run_bytes(raw_config, 11);
    defer testing.allocator.free(raw_again);
    const scaled = try run_bytes(quick_config(300), 11);
    defer testing.allocator.free(scaled);

    try testing.expect((try count_viri(raw)).positions >= 300);
    try testing.expectEqualSlices(u8, raw, raw_again);
    try testing.expect(!std.mem.eql(u8, raw, scaled));
}

test "datagen: the summary line carries the discarded games and ends with raw_eval" {
    var buf: [256]u8 = undefined;
    inline for (.{ .{ false, "\"raw_eval\":false}" }, .{ true, "\"raw_eval\":true}" } }) |case| {
        const line = try std.mem.print(&buf, "{f}", .{std.json.fmt(datagen.Summary{ .discarded_games = 3, .raw_eval = case[0] }, .{})});
        try testing.expect(std.mem.endsWith(u8, line, case[1]));
        try testing.expect(std.mem.find(u8, line, "\"discarded_games\":3,") != null);
    }
}
