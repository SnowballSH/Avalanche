const std = @import("std");
const platform = @import("../platform.zig");
const position = @import("../chess/position.zig");
const hce = @import("../engine/hce.zig");
const weights = @import("../engine/weights.zig");
const netscale = @import("../engine/netscale.zig");
const support = @import("support.zig");
const testing = std.testing;

const CHECK_FEN = "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1";
// No pawns and phase 2: scored by the classical endgame evaluation, not the network.
const CLASSICAL_FEN = "8/8/4k3/8/8/4K3/8/R7 w - - 0 1";

const FENS = [_][]const u8{
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
    "rnbqkb1r/pp2pppp/3p1n2/8/3NP3/8/PPP2PPP/RNBQKB1R w KQkq - 1 5",
    CHECK_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    CLASSICAL_FEN,
    "r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 3 9",
    "2r3k1/5ppp/p3p3/1p1n4/3P4/P4N2/1P3PPP/2R3K1 b - - 0 24",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1",
    "8/5k2/8/8/q7/8/5K2/8 b - - 0 1",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "8/8/4k3/8/2P5/4K3/8/8 w - - 0 1",
};
const SKIPPED = 2;

fn embedded_copy() ![]u8 {
    support.init_tables();
    try weights.load(weights.EMBEDDED_NAME);
    return testing.allocator.dupe(u8, std.mem.asBytes(weights.MODEL));
}

/// Multiplies the output layer of the network file `net` by `factor`, as a stand-in for a network trained to a
/// different eval scale.
fn scale_output_layer(net: []u8, factor: f64) void {
    const start = @offsetOf(weights.NNUEWeights, "layer_2");
    const end = @offsetOf(weights.NNUEWeights, "layer_2_bias") + @sizeOf(@FieldType(weights.NNUEWeights, "layer_2_bias"));
    var offset: usize = start;
    while (offset < end) : (offset += 2) {
        const cell = net[offset..][0..2];
        const scaled = @round(@as(f64, @floatFromInt(std.mem.readInt(i16, cell, .little))) * factor);
        std.mem.writeInt(i16, cell, @intFromFloat(scaled), .little);
    }
}

test "netscale: positions in check or scored classically are skipped and the limit counts the rest" {
    support.init_tables();
    try weights.load(weights.EMBEDDED_NAME);

    const all = try netscale.mean_abs_eval(&FENS, 0);
    try testing.expectEqual(FENS.len - SKIPPED, all.positions);
    try testing.expect(all.abs_eval > 0);

    const limited = try netscale.mean_abs_eval(&FENS, 5);
    try testing.expectEqual(@as(usize, 5), limited.positions);
    try testing.expectEqual((try netscale.mean_abs_eval(FENS[0..3] ++ FENS[4..5] ++ FENS[6..7], 0)).abs_eval, limited.abs_eval);

    try testing.expectError(error.NoPositions, netscale.mean_abs_eval(&.{ CHECK_FEN, CLASSICAL_FEN }, 0));
}

test "netscale: the statistic is the raw network output, whatever EvalScale is" {
    support.init_tables();
    try weights.load(weights.EMBEDDED_NAME);
    defer hce.eval_scale = hce.DEFAULT_EVAL_SCALE;

    const unscaled = try netscale.mean_abs_eval(&FENS, 0);
    hce.eval_scale = 800;
    try testing.expectEqual(unscaled.abs_eval, (try netscale.mean_abs_eval(&FENS, 0)).abs_eval);
}

test "netscale: a network measured against itself needs no scaling" {
    const net = try embedded_copy();
    defer testing.allocator.free(net);

    const result = try netscale.measure(net, net, &FENS, 0);
    try testing.expectEqual(FENS.len - SKIPPED, result.positions);
    try testing.expectEqual(@as(f64, 1.0), result.factor);
    try testing.expectEqual(@as(i64, hce.DEFAULT_EVAL_SCALE), result.eval_scale);
    try testing.expect(result.eval_scale_in_range());
}

test "netscale: the reported EvalScale brings a quieter network back to the reference's mean |eval|" {
    const reference = try embedded_copy();
    defer testing.allocator.free(reference);
    const candidate = try testing.allocator.dupe(u8, reference);
    defer testing.allocator.free(candidate);
    scale_output_layer(candidate, 0.8);

    const result = try netscale.measure(candidate, reference, &FENS, 0);
    try testing.expectApproxEqRel(@as(f64, 1.25), result.factor, 0.03);
    try testing.expectEqual(@as(i64, @intFromFloat(@round(result.factor * 1000))), result.eval_scale);
    try testing.expectEqualSlices(u8, reference, std.mem.asBytes(weights.MODEL));

    // The candidate's evals under that EvalScale average to the reference's.
    try weights.install(candidate);
    defer weights.load(weights.EMBEDDED_NAME) catch unreachable;
    hce.eval_scale = @intCast(result.eval_scale);
    defer hce.eval_scale = hce.DEFAULT_EVAL_SCALE;
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    var total: f64 = 0;
    for (FENS) |fen| {
        if (std.mem.eql(u8, fen, CHECK_FEN) or std.mem.eql(u8, fen, CLASSICAL_FEN)) continue;
        pos.set_fen(fen);
        total += @floatFromInt(@abs(hce.scale_network_output(hce.evaluate_nnue(pos))));
    }
    try testing.expectApproxEqRel(result.ref_mean_abs, total / @as(f64, @floatFromInt(result.positions)), 0.005);
}

test "netscale: measuring restores the active network, on errors too" {
    const embedded = try embedded_copy();
    defer testing.allocator.free(embedded);
    const quiet = try testing.allocator.dupe(u8, embedded);
    defer testing.allocator.free(quiet);
    scale_output_layer(quiet, 0.5);

    try weights.install(quiet);
    defer weights.load(weights.EMBEDDED_NAME) catch unreachable;
    _ = try netscale.measure(embedded, embedded, &FENS, 0);
    try testing.expectEqualSlices(u8, quiet, std.mem.asBytes(weights.MODEL));
    try testing.expectError(error.NoPositions, netscale.measure(embedded, embedded, &.{CHECK_FEN}, 0));
    try testing.expectEqualSlices(u8, quiet, std.mem.asBytes(weights.MODEL));
    try testing.expectError(error.WrongSize, netscale.measure(embedded[1..], embedded, &FENS, 0));
    try testing.expectEqualSlices(u8, quiet, std.mem.asBytes(weights.MODEL));
}

const RunFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,
    dir_buf: [std.fs.max_path_bytes]u8 = undefined,
    arg_bufs: [4][std.fs.max_path_bytes + 16]u8 = undefined,
    out_buf: [512]u8 = undefined,
    err_buf: [2048]u8 = undefined,

    fn init(self: *RunFixture) !void {
        platform.io = std.testing.io;
        self.tmp = std.testing.tmpDir(.{});
        self.dir = self.dir_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.dir_buf)];
    }

    fn write(self: *RunFixture, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    }

    /// Runs `netscale` with each `key=file` argument's file resolved inside the temporary directory.
    fn run(self: *RunFixture, comptime args: []const [2][]const u8, extra: []const []const u8) !struct { code: u8, output: []const u8, errors: []const u8 } {
        var argv: [8][]const u8 = undefined;
        inline for (args, 0..) |arg, i| {
            argv[i] = try std.fmt.bufPrint(&self.arg_bufs[i], "{s}={s}/{s}", .{ arg[0], self.dir, arg[1] });
        }
        @memcpy(argv[args.len..][0..extra.len], extra);
        var out = std.Io.Writer.fixed(&self.out_buf);
        var err = std.Io.Writer.fixed(&self.err_buf);
        const code = try netscale.run(argv[0 .. args.len + extra.len], &out, &err);
        return .{ .code = code, .output = out.buffered(), .errors = err.buffered() };
    }
};

test "netscale: run reports the result as JSON and failures through its exit code" {
    const embedded = try embedded_copy();
    defer testing.allocator.free(embedded);
    const quiet = try testing.allocator.dupe(u8, embedded);
    defer testing.allocator.free(quiet);
    scale_output_layer(quiet, 0.25);

    var f: RunFixture = undefined;
    try f.init();
    defer f.tmp.cleanup();
    try f.write("net.nnue", embedded);
    try f.write("quiet.nnue", quiet);
    try f.write("short.nnue", "not a network");
    try f.write("book.epd", FENS[0] ++ "\n" ++ FENS[1] ++ "\n" ++ CHECK_FEN ++ "\n" ++ FENS[2] ++ "\n");
    try f.write("bad.epd", FENS[0] ++ "\nnot a position\n");
    try f.write("check.epd", CHECK_FEN ++ "\n");

    const same = try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "book.epd" } }, &.{});
    try testing.expectEqual(@as(u8, 0), same.code);
    try testing.expectEqualStrings("", same.errors);
    try testing.expect(std.mem.startsWith(u8, same.output, "{\"positions\":3,\"ref_mean_abs\":"));
    try testing.expect(std.mem.endsWith(u8, same.output, ",\"factor\":1,\"eval_scale\":1000}\n"));

    const limited = try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "book.epd" } }, &.{"limit=2"});
    try testing.expectEqual(@as(u8, 0), limited.code);
    try testing.expect(std.mem.startsWith(u8, limited.output, "{\"positions\":2,"));

    // A scale the EvalScale option cannot express is still reported, as a failure.
    const loud = try f.run(&.{ .{ "net", "quiet.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "book.epd" } }, &.{});
    try testing.expectEqual(@as(u8, 1), loud.code);
    try testing.expect(std.mem.indexOf(u8, loud.output, "\"eval_scale\":") != null);
    try testing.expect(std.mem.indexOf(u8, loud.errors, "outside the EvalScale range 500-2000") != null);

    const unknown = try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "book.epd" } }, &.{"out=x.nnue"});
    try testing.expectEqual(@as(u8, 2), unknown.code);
    try testing.expectEqualStrings("", unknown.output);
    try testing.expect(std.mem.startsWith(u8, unknown.errors, "netscale: unknown option 'out'\nUsage: "));
    const missing = try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" } }, &.{});
    try testing.expectEqual(@as(u8, 2), missing.code);
    try testing.expect(std.mem.startsWith(u8, missing.errors, "netscale: missing required option positions\nUsage: "));
    const duplicate = try f.run(&.{ .{ "net", "net.nnue" }, .{ "net", "net.nnue" } }, &.{});
    try testing.expectEqual(@as(u8, 2), duplicate.code);
    try testing.expect(std.mem.startsWith(u8, duplicate.errors, "netscale: option net is given more than once\n"));
    const invalid = try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "book.epd" } }, &.{"limit=many"});
    try testing.expectEqual(@as(u8, 2), invalid.code);
    try testing.expect(std.mem.startsWith(u8, invalid.errors, "netscale: invalid value 'many' for option limit\n"));

    try testing.expectEqual(@as(u8, 1), (try f.run(&.{ .{ "net", "missing.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "book.epd" } }, &.{})).code);
    try testing.expectEqual(@as(u8, 1), (try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "short.nnue" }, .{ "positions", "book.epd" } }, &.{})).code);
    try testing.expectEqual(@as(u8, 1), (try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "bad.epd" } }, &.{})).code);
    try testing.expectEqual(@as(u8, 1), (try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "missing.epd" } }, &.{})).code);
    try testing.expectEqual(@as(u8, 1), (try f.run(&.{ .{ "net", "net.nnue" }, .{ "ref", "net.nnue" }, .{ "positions", "check.epd" } }, &.{})).code);

    try testing.expectEqualSlices(u8, embedded, std.mem.asBytes(weights.MODEL));
}
