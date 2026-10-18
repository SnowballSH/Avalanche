const std = @import("std");
const platform = @import("../platform.zig");
const syzygy = @import("../engine/syzygy.zig");
const tablebases = @import("../syzygy/tablebases.zig");
const enumeration = @import("syzygy_enumeration.zig");
const support = @import("support.zig");
const testing = std.testing;

/// Where these come from is in syzygy/README.md.
const FIXTURES = [_][]const u8{
    "KQvK.rtbw", "KQvK.rtbz", "KRvK.rtbw", "KRvK.rtbz", "KBvK.rtbw",  "KBvK.rtbz",
    "KNvK.rtbw", "KNvK.rtbz", "KPvK.rtbw", "KPvK.rtbz", "KRvKR.rtbw", "KRvKR.rtbz",
};

const Fixture = struct {
    tmp: testing.TmpDir,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = &.{},

    fn init(self: *Fixture, comptime names: []const []const u8) !void {
        if (!syzygy.supported) return error.SkipZigTest;
        platform.io = testing.io;
        support.init_tables();
        self.tmp = testing.tmpDir(.{});
        inline for (names) |name| {
            try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = @embedFile("syzygy/" ++ name) });
        }
        self.path = self.path_buf[0..try self.tmp.dir.realPath(testing.io, &self.path_buf)];
    }

    fn deinit(self: *Fixture) void {
        syzygy.deinit();
        self.tmp.cleanup();
    }
};

fn expect_wdl(fen: []const u8, expected: ?syzygy.WdlResult) !void {
    const pos = try support.position_at(fen);
    defer support.destroy_position(pos);
    try testing.expectEqual(expected, syzygy.probe_wdl_position(pos));
}

test "syzygy: WDL probes of the fixture tables" {
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init(&FIXTURES);
    defer fixture.deinit();
    try testing.expect(syzygy.init(fixture.path));
    try testing.expectEqual(@as(i32, 4), syzygy.max_pieces());

    try expect_wdl("8/8/8/4k3/8/8/8/R3K3 w - - 0 1", .win);
    try expect_wdl("8/8/8/4k3/8/8/8/R3K3 b - - 0 1", .loss);
    // Black takes the rook: the capture is resolved before the table is read.
    try expect_wdl("8/8/8/8/8/8/1k6/R3K3 b - - 0 1", .draw);
    try expect_wdl("8/8/8/4k3/8/8/8/3QK3 w - - 0 1", .win);
    try expect_wdl("k7/2Q5/1K6/8/8/8/8/8 b - - 0 1", .draw);
    try expect_wdl("4k3/8/4K3/4P3/8/8/8/8 w - - 0 1", .win);
    try expect_wdl("4k3/8/4K3/4P3/8/8/8/8 b - - 0 1", .loss);
    try expect_wdl("8/8/8/8/8/4k3/4P3/4K3 w - - 0 1", .draw);
    try expect_wdl("8/8/8/8/8/4k3/4P3/4K3 b - - 0 1", .draw);
    // The same positions with the colours exchanged.
    try expect_wdl("4k3/4p3/4K3/8/8/8/8/8 b - - 0 1", .draw);
    try expect_wdl("8/8/8/8/4p3/4k3/8/4K3 b - - 0 1", .win);
    try expect_wdl("8/8/8/8/4p3/4k3/8/4K3 w - - 0 1", .loss);
    try expect_wdl("8/8/8/4k3/8/8/8/2B1K3 w - - 0 1", .draw);
    try expect_wdl("7r/8/8/4k3/8/8/8/R3K3 w - - 0 1", .draw);
    // No KQvKR table among the fixtures.
    try expect_wdl("7r/8/8/4k3/8/8/8/Q3K3 w - - 0 1", null);
}

test "syzygy: root probes keep only the moves of the best rank" {
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init(&FIXTURES);
    defer fixture.deinit();
    try testing.expect(syzygy.init(fixture.path));

    {
        // With 98 plies on the counter only the mate, Rh8, wins in time.
        const pos = try support.position_at("k7/8/1K6/8/8/8/8/7R w - - 98 120");
        defer support.destroy_position(pos);
        const result = syzygy.probe_root(pos, false) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(syzygy.Wdl.win, result.wdl);
        try testing.expectEqual(@as(usize, 1), result.count);
        try testing.expectEqual(syzygy.RootMove{ .from = 7, .to = 63, .promo = .none }, result.moves[0]);
    }
    {
        // Every safe win ranks equally; promoting to a knight or a bishop draws.
        const pos = try support.position_at("8/4P3/8/8/8/8/k7/4K3 w - - 0 1");
        defer support.destroy_position(pos);
        const result = syzygy.probe_root(pos, false) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(syzygy.Wdl.win, result.wdl);
        var queen = false;
        for (result.moves[0..result.count]) |move| {
            try testing.expect(move.promo != .knight and move.promo != .bishop);
            queen = queen or (move.from == 52 and move.to == 60 and move.promo == .queen);
        }
        try testing.expect(queen);
    }
    {
        const pos = try support.position_at("8/8/8/8/8/4k3/4P3/4K3 w - - 0 1");
        defer support.destroy_position(pos);
        const result = syzygy.probe_root(pos, false) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(syzygy.Wdl.draw, result.wdl);
        try testing.expect(result.count > 0);
    }
}

/// The C Pyrrhic's results on the same positions.
const GOLDEN = [_]struct { enumeration.Material, enumeration.Summary }{
    .{ .{ .white = .pawn }, .{ .wdl = .{ 5945, 0, 7058, 0, 7638, 0 }, .roots = 1280, .hash = 12404180976039970340 } },
    .{ .{ .white = .knight }, .{ .wdl = .{ 0, 0, 26765, 0, 0, 0 }, .roots = 1528, .hash = 7690022762095160583 } },
    .{ .{ .white = .bishop }, .{ .wdl = .{ 0, 0, 26021, 0, 0, 0 }, .roots = 1710, .hash = 17002901234408038029 } },
    .{ .{ .white = .rook }, .{ .wdl = .{ 12575, 0, 1375, 0, 10916, 0 }, .roots = 1328, .hash = 14025748810210947336 } },
    .{ .{ .white = .queen }, .{ .wdl = .{ 12529, 0, 1421, 0, 9037, 0 }, .roots = 1328, .hash = 8539840885785805269 } },
    .{
        .{ .white = .rook, .black = .rook, .black_squares = &.{ 18, 45, 60 } },
        .{ .wdl = .{ 564, 0, 47897, 0, 21215, 0 }, .roots = 3882, .hash = 9813512874025999383 },
    },
};

test "syzygy: the fixture tables probe as the C Pyrrhic does" {
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init(&FIXTURES);
    defer fixture.deinit();
    var tbs = try tablebases.Tablebases.open(testing.allocator, testing.io, fixture.path);
    defer tbs.deinit();

    for (GOLDEN) |golden| {
        const material, const expected = golden;
        try testing.expectEqualDeep(expected, enumeration.summarize(enumeration.ZigProber{ .tablebases = &tbs }, material));
    }
}

test "syzygy: no tables, or only incomplete ones, fail to load" {
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init(&.{});
    defer fixture.deinit();
    try testing.expect(!syzygy.init(fixture.path));
    try testing.expect(!syzygy.active());

    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "KRvK.rtbw", .data = @embedFile("syzygy/KRvK.rtbw")[0..100] });
    try testing.expect(!syzygy.init(fixture.path));
}
