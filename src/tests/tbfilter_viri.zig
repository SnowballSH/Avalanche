const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const syzygy = @import("../engine/syzygy.zig");
const viriformat = @import("../engine/datagen/viriformat.zig");
const viri_clean = @import("../engine/tbfilter/viri.zig");
const tbfilter = @import("../engine/tbfilter.zig");
const arguments = @import("../engine/datagen/arguments.zig");
const support = @import("support.zig");
const testing = std.testing;

const START = "8/8/8/4k3/8/8/8/R3K3 w - - 0 1";
const MOVES = [_][]const u8{ "a1a7", "e5d5", "e1e2" };

fn build_game(allocator: std.mem.Allocator, fen: []const u8, moves: []const []const u8, white_result: u8) ![]u8 {
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(fen);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var header = viriformat.PackedBoard.pack(pos, 0);
    header.wdl = white_result;
    try bytes.appendSlice(allocator, std.mem.asBytes(&header));
    for (moves, 0..) |text, index| {
        const move = types.Move.new_from_string(pos, text);
        const pair = viriformat.MoveScorePair{ .move = viriformat.encode_move(move), .score = @intCast(100 + index) };
        try bytes.appendSlice(allocator, std.mem.asBytes(&pair));
        if (pos.turn == types.Color.White) pos.play_move(types.Color.White, move) else pos.play_move(types.Color.Black, move);
    }
    try bytes.appendSlice(allocator, std.mem.asBytes(&viriformat.TERMINATOR));
    return bytes.toOwnedSlice(allocator);
}

fn always(comptime result: ?syzygy.WdlResult) viri_clean.Prober {
    return struct {
        fn probe(_: *const position.Position) ?syzygy.WdlResult {
            return result;
        }
    }.probe;
}

fn scores(bytes: []u8) ![3]i16 {
    var reader = viriformat.Reader.init(bytes);
    const game = (try reader.next()).?;
    return .{ game.pairs[0].score, game.pairs[1].score, game.pairs[2].score };
}

fn clean(bytes: []u8, prober: viri_clean.Prober, max_men: u32, mode: viri_clean.Rule50Mode) !viri_clean.Stats {
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    var cleaner = viri_clean.Cleaner{ .probe = prober, .max_men = max_men, .mode = mode };
    try cleaner.clean_buffer(pos, bytes);
    return cleaner.stats;
}

test "tbfilter viri: a contradicted position's eval is masked and nothing else changes" {
    support.init_search();
    const bytes = try build_game(testing.allocator, START, &MOVES, 2);
    defer testing.allocator.free(bytes);
    const original = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(original);

    const stats = try clean(bytes, always(.win), 6, .keep);

    try testing.expectEqual([3]i16{ 100, viri_clean.MASKED_EVAL, 102 }, try scores(bytes));
    try testing.expectEqual(@as(u64, 1), stats.masked);
    try testing.expectEqual(@as(u64, 2), stats.agree);
    var differing: usize = 0;
    for (bytes, original) |a, b| differing += @intFromBool(a != b);
    try testing.expect(differing <= 2);
}

test "tbfilter viri: cursed wins are kept under rule50=keep and draws follow the tables" {
    support.init_search();
    const bytes = try build_game(testing.allocator, START, &MOVES, 1);
    defer testing.allocator.free(bytes);
    const stats = try clean(bytes, always(.cursed_win), 6, .keep);
    try testing.expectEqual([3]i16{ 100, 101, 102 }, try scores(bytes));
    try testing.expectEqual(@as(u64, 3), stats.ambiguous);
}

test "tbfilter viri: positions with too many men, castling rights or failed probes are kept" {
    support.init_search();
    const many = try build_game(testing.allocator, START, &MOVES, 0);
    defer testing.allocator.free(many);
    try testing.expectEqual(@as(u64, 3), (try clean(many, always(.win), 2, .keep)).over_men);

    const castling = try build_game(testing.allocator, "8/8/8/4k3/8/8/8/R3K3 w Q - 0 1", &MOVES, 0);
    defer testing.allocator.free(castling);
    const castling_stats = try clean(castling, always(.win), 6, .keep);
    try testing.expectEqual(@as(u64, 1), castling_stats.castling);

    const failed = try build_game(testing.allocator, START, &MOVES, 0);
    defer testing.allocator.free(failed);
    try testing.expectEqual(@as(u64, 3), (try clean(failed, always(null), 6, .keep)).failed);
    try testing.expectEqual([3]i16{ 100, 101, 102 }, try scores(failed));
}

test "tbfilter viri: a game whose header cannot be a position is reported, not replayed" {
    support.init_search();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    var cleaner = viri_clean.Cleaner{ .probe = always(.win), .max_men = 6, .mode = .keep };

    const impossible_result = try build_game(testing.allocator, START, &MOVES, 3);
    defer testing.allocator.free(impossible_result);
    try testing.expectError(error.InvalidHeader, cleaner.clean_buffer(pos, impossible_result));

    const crowded = try build_game(testing.allocator, START, &MOVES, 2);
    defer testing.allocator.free(crowded);
    @memset(crowded[0..@sizeOf(u64)], 0xFF);
    try testing.expectError(error.InvalidHeader, cleaner.clean_buffer(pos, crowded));

    try testing.expectEqual(@as(u64, 0), cleaner.stats.positions);
}

fn parse(args: []const []const u8) tbfilter.ParseError!tbfilter.Config {
    var diag: arguments.Diagnostic = .{};
    return tbfilter.parse_config(args, &diag);
}

test "tbfilter options: the input's extension names the format unless format= does" {
    try testing.expectEqual(tbfilter.Format.viri, (try parse(&.{ "in.viribin", "out.viribin", "tb=tables" })).format);
    try testing.expectEqual(tbfilter.Format.bullet, (try parse(&.{ "in.bin", "out.bin", "tb=tables" })).format);
    try testing.expectEqual(tbfilter.Format.bullet, (try parse(&.{ "in.viribin", "out", "tb=tables", "format=bullet" })).format);
    try testing.expectEqual(tbfilter.Format.viri, (try parse(&.{ "in.bin", "out", "format=viri", "tb=tables" })).format);
    try testing.expectEqual(tbfilter.Format.viri, (try parse(&.{ "in", "out", "tb=tables", "format=viri" })).format);

    var diag: arguments.Diagnostic = .{};
    try testing.expectError(error.UndecidedFormat, tbfilter.parse_config(&.{ "chunk.data", "out.bin", "tb=tables" }, &diag));
    try testing.expectEqualStrings("chunk.data", diag.value);
    try testing.expectError(error.UndecidedFormat, tbfilter.parse_config(&.{ "in", "out.viribin", "tb=tables" }, &diag));
}

test "tbfilter options: an output whose extension names the other format is refused" {
    var diag: arguments.Diagnostic = .{};
    try testing.expectError(error.OutputExtensionOfOtherFormat, tbfilter.parse_config(&.{ "in.viribin", "out.bin", "tb=tables" }, &diag));
    try testing.expectEqualStrings("out.bin", diag.value);
    try testing.expectError(error.OutputExtensionOfOtherFormat, tbfilter.parse_config(&.{ "in.bin", "out.viribin", "tb=tables" }, &diag));
    try testing.expectError(error.OutputExtensionOfOtherFormat, tbfilter.parse_config(&.{ "in.viribin", "out.viribin", "tb=tables", "format=bullet" }, &diag));
    try testing.expectError(error.OutputExtensionOfOtherFormat, tbfilter.parse_config(&.{ "in", "out.bin", "tb=tables", "format=viri" }, &diag));

    _ = try parse(&.{ "in.viribin", "out.cleaned", "tb=tables" });
    _ = try parse(&.{ "in.viribin", "out.bin", "tb=tables", "format=bullet" });
}

test "tbfilter options: in= and out= name the paths, so a path may contain an equals sign" {
    const keyed = try parse(&.{ "tb=tables", "out=runs/seed=42/clean.viribin", "in=runs/seed=42/chunk.viribin" });
    try testing.expectEqualStrings("runs/seed=42/chunk.viribin", keyed.input);
    try testing.expectEqualStrings("runs/seed=42/clean.viribin", keyed.output);
    try testing.expectEqual(tbfilter.Format.viri, keyed.format);

    const mixed = try parse(&.{ "out=a=b.bin", "chunk.bin", "tb=tables" });
    try testing.expectEqualStrings("chunk.bin", mixed.input);
    try testing.expectEqualStrings("a=b.bin", mixed.output);
    const bare_output = try parse(&.{ "in=a=b.bin", "clean.bin", "tb=tables" });
    try testing.expectEqualStrings("a=b.bin", bare_output.input);
    try testing.expectEqualStrings("clean.bin", bare_output.output);

    var diag: arguments.Diagnostic = .{};
    try testing.expectError(error.DuplicateKey, tbfilter.parse_config(&.{ "chunk.bin", "in=other.bin", "out.bin", "tb=tables" }, &diag));
    try testing.expectEqualStrings("in", diag.key);
    try testing.expectError(error.UnexpectedArgument, tbfilter.parse_config(&.{ "in=chunk.bin", "out=clean.bin", "tb=tables", "extra.bin" }, &diag));
    try testing.expectEqualStrings("extra.bin", diag.value);
    try testing.expectError(error.InvalidValue, tbfilter.parse_config(&.{ "in=", "clean.bin", "tb=tables" }, &diag));
    try testing.expectEqualStrings("in", diag.key);
    try testing.expectError(error.UnknownKey, tbfilter.parse_config(&.{ "runs/seed=42/chunk.bin", "clean.bin", "tb=tables" }, &diag));
    try testing.expectEqualStrings("runs/seed", diag.key);
    try testing.expectError(error.MissingArgument, parse(&.{ "in=chunk.bin", "tb=tables" }));
}

test "tbfilter options: viriformat rejects the bulletformat-only max= and threads= options" {
    var diag: arguments.Diagnostic = .{};
    _ = try tbfilter.parse_config(&.{ "in", "out", "tb=tables", "format=viri", "rule50=on" }, &diag);
    try testing.expectError(error.BulletOnlyOption, tbfilter.parse_config(&.{ "in", "out", "tb=tables", "max=10", "format=viri" }, &diag));
    try testing.expectEqualStrings("max", diag.key);
    try testing.expectError(error.BulletOnlyOption, tbfilter.parse_config(&.{ "in", "out", "tb=tables", "format=viri", "threads=4" }, &diag));
    try testing.expectEqualStrings("threads", diag.key);
    try testing.expectError(error.BulletOnlyOption, tbfilter.parse_config(&.{ "in.viribin", "out.viribin", "tb=tables", "threads=4" }, &diag));

    const bullet = try tbfilter.parse_config(&.{ "in.bin", "out.bin", "tb=tables", "max=10", "threads=4" }, &diag);
    try testing.expectEqual(@as(?u64, 10), bullet.max_positions);
    try testing.expectEqual(@as(?usize, 4), bullet.threads);
}

test "tbfilter options: every key parses and the defaults probe five men under rule50=keep" {
    const defaults = try parse(&.{ "in.bin", "out.bin", "tb=tables" });
    try testing.expectEqualStrings("in.bin", defaults.input);
    try testing.expectEqualStrings("out.bin", defaults.output);
    try testing.expectEqualStrings("tables", defaults.tb_path);
    try testing.expectEqual(@as(u32, 5), defaults.max_men);
    try testing.expectEqual(tbfilter.Rule50Mode.keep, defaults.rule50);
    try testing.expectEqual(@as(?usize, null), defaults.threads);
    try testing.expectEqual(@as(?u64, null), defaults.max_positions);

    const all = try parse(&.{ "rule50=off", "in.bin", "men=7", "tb=a:b", "out.bin" });
    try testing.expectEqualStrings("a:b", all.tb_path);
    try testing.expectEqual(@as(u32, 7), all.max_men);
    try testing.expectEqual(tbfilter.Rule50Mode.off, all.rule50);
}

test "tbfilter options: malformed values are errors naming the option, not silent defaults" {
    var diag: arguments.Diagnostic = .{};
    inline for (.{ "men=6,", "men=six", "men=1", "men=8", "rule50=On", "rule50=", "threads=0", "threads=257", "threads=many", "max=0", "max=-1", "format=binpack" }) |arg| {
        try testing.expectError(error.InvalidValue, tbfilter.parse_config(&.{ "in.bin", "out.bin", "tb=tables", arg }, &diag));
        try testing.expectEqualStrings(arg[0..comptime std.mem.findScalar(u8, arg, '=').?], diag.key);
    }
    try testing.expectError(error.InvalidValue, tbfilter.parse_config(&.{ "in.bin", "out.bin", "tb=" }, &diag));
    try testing.expectEqualStrings("tb", diag.key);
}

test "tbfilter options: unknown, repeated, surplus and missing arguments are errors" {
    var diag: arguments.Diagnostic = .{};
    try testing.expectError(error.UnknownKey, tbfilter.parse_config(&.{ "in.bin", "out.bin", "tb=tables", "fromat=viri" }, &diag));
    try testing.expectEqualStrings("fromat", diag.key);
    try testing.expectError(error.DuplicateKey, tbfilter.parse_config(&.{ "in.bin", "out.bin", "tb=tables", "men=5", "men=6" }, &diag));
    try testing.expectEqualStrings("men", diag.key);
    try testing.expectError(error.UnexpectedArgument, tbfilter.parse_config(&.{ "in.bin", "out.bin", "tb=tables", "extra.bin" }, &diag));
    try testing.expectEqualStrings("extra.bin", diag.value);
    try testing.expectError(error.MissingArgument, parse(&.{ "in.bin", "tb=tables" }));
    try testing.expectError(error.MissingArgument, parse(&.{ "in.bin", "out.bin" }));
    try testing.expectError(error.MissingArgument, parse(&.{}));
}

test "tbfilter: a bulletformat input must be whole 32-byte records" {
    try testing.expectEqual(@as(u64, 0), try tbfilter.whole_records(0));
    try testing.expectEqual(@as(u64, 3), try tbfilter.whole_records(96));
    try testing.expectError(error.PartialRecord, tbfilter.whole_records(97));
    try testing.expectError(error.PartialRecord, tbfilter.whole_records(36));
}

test "tbfilter viri: the output file is created exclusively and never clobbers an existing one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try viri_clean.write_new_file(testing.io, tmp.dir, "out.vf", "cleaned");
    try testing.expectError(error.PathAlreadyExists, viri_clean.write_new_file(testing.io, tmp.dir, "out.vf", "again"));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("cleaned", try tmp.dir.readFile(testing.io, "out.vf", &buf));
}
