const std = @import("std");
const platform = @import("../platform.zig");
const datagen = @import("../engine/datagen.zig");
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
