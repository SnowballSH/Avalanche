const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const hce = @import("../engine/hce.zig");
const search = @import("../engine/search.zig");
const weights = @import("../engine/weights.zig");
const options = @import("../engine/uci/options.zig");
const support = @import("support.zig");
const build_options = @import("build_options");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Fixture = struct {
    settings: options.Settings = .{},
    pos: *position.Position,
    buf: [512]u8 = undefined,
    out: std.Io.Writer = undefined,

    fn init(self: *Fixture) !void {
        support.init_tables();
        self.* = .{ .pos = try support.new_position() };
        self.out = std.Io.Writer.fixed(&self.buf);
        self.pos.set_fen(types.DEFAULT_FEN);
    }

    fn deinit(self: *Fixture) void {
        support.destroy_position(self.pos);
    }

    fn set(self: *Fixture, args: []const u8) !void {
        self.out = std.Io.Writer.fixed(&self.buf);
        try options.set_option(args, .{ .settings = &self.settings, .position = self.pos, .out = &self.out });
    }

    fn output(self: *Fixture) []const u8 {
        return self.out.buffered();
    }
};

test "options: names with spaces, case-insensitive matching and clamping" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    try f.set("name Skill Level value 7");
    try expectEqual(@as(u8, 7), f.settings.skill_level);

    try f.set("name multipv value 999");
    try expectEqual(@as(usize, search.MAX_MULTI_PV), f.settings.multi_pv);

    try f.set("name UCI_LimitStrength value true");
    try f.set("name UCI_Elo value 1500");
    try expect(f.settings.playing_strength().is_limited());

    try std.testing.expectError(options.SetOptionError.InvalidValue, f.set("name Ponder value maybe"));
    try std.testing.expectError(options.SetOptionError.UnknownOption, f.set("name NoSuchOption value 1"));
}

test "options: Move Overhead accepts its legacy name" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const saved = search.MOVE_OVERHEAD;
    defer search.MOVE_OVERHEAD = saved;

    try f.set("name Move Overhead value 120");
    try expectEqual(@as(u64, 120), search.MOVE_OVERHEAD);
    try f.set("name MoveOverhead value 40");
    try expectEqual(@as(u64, 40), search.MOVE_OVERHEAD);

    var listing: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&listing);
    try options.print_all(&w);
    try expect(std.mem.indexOf(u8, w.buffered(), "option name Move Overhead type spin") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "option name MoveOverhead") == null);
}

test "options: combo values are validated" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expectError(options.SetOptionError.InvalidValue, f.set("name NumaPolicy value sometimes"));
    try f.set("name NumaPolicy value NONE");
    try f.set("name NumaPolicy value auto");
}

test "options: UCI_Chess960 toggles castling notation on the position" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.set("name UCI_Chess960 value true");
    try expect(f.pos.uci_chess960);
    f.pos.set_fen(types.DEFAULT_FEN);
    try expect(f.pos.chess960_notation());
    try f.set("name UCI_Chess960 value false");
    try expect(!f.pos.chess960_notation());
}

test "options: EvalFile keeps the network on bad files and loads valid ones" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    platform.io = std.testing.io;
    const embedded_eval = hce.evaluate_nnue(f.pos);

    try f.set("name EvalFile value /nonexistent/avalanche.nnue");
    try expect(std.mem.indexOf(u8, f.output(), "failed to load") != null);
    try expectEqual(embedded_eval, hce.evaluate_nnue(f.pos));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "short.nnue", .data = "not a network" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const short_path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "short.nnue", &path_buf)];
    var args_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    try f.set(try std.fmt.bufPrint(&args_buf, "name EvalFile value {s}", .{short_path}));
    try expect(std.mem.indexOf(u8, f.output(), if (weights.HEAD == .single) "WrongSize" else "NotANetwork") != null);
    try expectEqual(embedded_eval, hce.evaluate_nnue(f.pos));

    // A valid network with shifted output biases must change the evaluation.
    const altered = try std.testing.allocator.dupe(u8, std.mem.asBytes(weights.MODEL));
    defer std.testing.allocator.free(altered);
    const head_offset = @offsetOf(weights.NNUEWeights, "head");
    switch (weights.HEAD) {
        .single => for (0..weights.OUTPUT_SIZE) |bucket| {
            const bytes = altered[head_offset + @offsetOf(weights.head_single.Weights, "layer_2_bias") + 2 * bucket ..][0..2];
            std.mem.writeInt(i16, bytes, std.mem.readInt(i16, bytes, .little) +% 500, .little);
        },
        .multi => for (0..weights.OUTPUT_SIZE) |bucket| {
            const bytes = altered[head_offset + @offsetOf(weights.head_multi.Weights, "l3_bias") + 4 * bucket ..][0..4];
            std.mem.writeInt(i32, bytes, std.mem.readInt(i32, bytes, .little) + (1 << 20), .little);
        },
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "altered.nnue", .data = altered });
    const altered_path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "altered.nnue", &path_buf)];
    try f.set(try std.fmt.bufPrint(&args_buf, "name EvalFile value {s}", .{altered_path}));
    try expect(std.mem.indexOf(u8, f.output(), "using altered.nnue") != null);
    try std.testing.expectEqualStrings("altered.nnue", weights.active_network());
    try expect(hce.evaluate_nnue(f.pos) != embedded_eval);

    try f.set("name EvalFile value " ++ weights.EMBEDDED_NAME);
    try expectEqual(embedded_eval, hce.evaluate_nnue(f.pos));
    try std.testing.expectEqualStrings(build_options.net_name, weights.active_network());
}

test "options: EvalScale parses, clamps to its bounds and is advertised" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer hce.eval_scale = hce.DEFAULT_EVAL_SCALE;

    try expectEqual(@as(i32, 1000), hce.eval_scale);
    try f.set("name EvalScale value 1234");
    try expectEqual(@as(i32, 1234), hce.eval_scale);
    try f.set("name evalscale value 100");
    try expectEqual(@as(i32, 500), hce.eval_scale);
    try f.set("name EvalScale value 99999");
    try expectEqual(@as(i32, 2000), hce.eval_scale);
    try std.testing.expectError(options.SetOptionError.InvalidValue, f.set("name EvalScale value loud"));
    try expectEqual(@as(i32, 2000), hce.eval_scale);

    var listing: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&listing);
    try options.print_all(&w);
    try expect(std.mem.indexOf(u8, w.buffered(), "option name EvalScale type spin default 1000 min 500 max 2000") != null);
}

const EVAL_SCALE_FENS = [_][]const u8{
    types.DEFAULT_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "2r3k1/5ppp/p3p3/1p1n4/3P4/P4N2/1P3PPP/2R3K1 b - - 0 24",
    "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1",
    "6k1/5ppp/8/8/8/8/5PPP/R5K1 b - - 0 1",
    "8/5k2/8/8/q7/8/5K2/8 b - - 0 1",
};

fn static_eval(pos: *position.Position) i32 {
    return if (pos.turn == types.Color.White) hce.evaluate_comptime(pos, types.Color.White) else hce.evaluate_comptime(pos, types.Color.Black);
}

test "options: EvalScale 1000 leaves every evaluation unchanged" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer hce.eval_scale = hce.DEFAULT_EVAL_SCALE;

    for (EVAL_SCALE_FENS) |fen| {
        f.pos.set_fen(fen);
        const raw = hce.evaluate_nnue(f.pos);
        const before = static_eval(f.pos);
        try f.set("name EvalScale value 700");
        try f.set("name EvalScale value 1000");
        try expectEqual(raw, hce.scale_network_output(raw));
        try expectEqual(raw, hce.evaluate_nnue(f.pos));
        try expectEqual(before, static_eval(f.pos));
    }
}

test "options: EvalScale 800 scales the network output to exactly raw * 800 / 1000" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer hce.eval_scale = hce.DEFAULT_EVAL_SCALE;

    var negative: usize = 0;
    for (EVAL_SCALE_FENS) |fen| {
        f.pos.set_fen(fen);
        const raw = hce.evaluate_nnue(f.pos);
        const unscaled = static_eval(f.pos);
        negative += @intFromBool(raw < 0);

        try f.set("name EvalScale value 800");
        try expectEqual(@divTrunc(raw * 800, 1000), hce.scale_network_output(raw));
        try expectEqual(raw, hce.evaluate_nnue(f.pos));
        // The rest of the static evaluation is applied to the scaled output.
        const scaled = static_eval(f.pos);
        try expect(@abs(scaled) <= @abs(unscaled));
        if (@abs(unscaled) >= 100) {
            try std.testing.expectApproxEqRel(@as(f64, @floatFromInt(unscaled)) * 0.8, @as(f64, @floatFromInt(scaled)), 0.02);
        }
        try f.set("name EvalScale value 1000");
    }
    try expect(negative > 0);

    try f.set("name EvalScale value 800");
    try expectEqual(@as(i32, -80), hce.scale_network_output(-101));
    try expectEqual(@as(i32, 80), hce.scale_network_output(101));
    try expectEqual(@as(i32, 0), hce.scale_network_output(-1));
}
