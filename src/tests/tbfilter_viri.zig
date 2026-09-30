const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const syzygy = @import("../engine/syzygy.zig");
const viriformat = @import("../engine/datagen/viriformat.zig");
const viri_clean = @import("../engine/tbfilter/viri.zig");
const support = @import("support.zig");
const testing = std.testing;

const START = "8/8/8/4k3/8/8/8/R3K3 w - - 0 1";
const MOVES = [_][]const u8{ "a1a7", "e5d5", "e1e2" };

fn build_game(allocator: std.mem.Allocator, fen: []const u8, moves: []const []const u8, white_result: u8) ![]u8 {
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(fen);
    var bytes = std.array_list.Managed(u8).init(allocator);
    var header = viriformat.pack_board(pos, 0);
    header.wdl = white_result;
    try bytes.appendSlice(std.mem.asBytes(&header));
    for (moves, 0..) |text, index| {
        const move = types.Move.new_from_string(pos, text);
        const pair = viriformat.MoveScorePair{ .move = viriformat.encode_move(move), .score = @intCast(100 + index) };
        try bytes.appendSlice(std.mem.asBytes(&pair));
        if (pos.turn == types.Color.White) pos.play_move(types.Color.White, move) else pos.play_move(types.Color.Black, move);
    }
    try bytes.appendSlice(std.mem.asBytes(&viriformat.TERMINATOR));
    return bytes.toOwnedSlice();
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

test "tbclean: a contradicted position's eval is masked and nothing else changes" {
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

test "tbclean: cursed wins are kept under rule50=keep and draws follow the tables" {
    support.init_search();
    const bytes = try build_game(testing.allocator, START, &MOVES, 1);
    defer testing.allocator.free(bytes);
    const stats = try clean(bytes, always(.cursed_win), 6, .keep);
    try testing.expectEqual([3]i16{ 100, 101, 102 }, try scores(bytes));
    try testing.expectEqual(@as(u64, 3), stats.ambiguous);
}

test "tbclean: positions with too many men, castling rights or failed probes are kept" {
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
