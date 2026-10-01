const std = @import("std");
const weights = @import("../engine/weights.zig");
const netscale = @import("../engine/netscale.zig");
const support = @import("support.zig");
const testing = std.testing;

const CHECK_FEN = "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1";

const FENS = [_][]const u8{
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
    "rnbqkb1r/pp2pppp/3p1n2/8/3NP3/8/PPP2PPP/RNBQKB1R w KQkq - 1 5",
    CHECK_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 3 9",
    "2r3k1/5ppp/p3p3/1p1n4/3P4/P4N2/1P3PPP/2R3K1 b - - 0 24",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1",
    "8/5k2/8/8/q7/8/5K2/8 b - - 0 1",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "8/8/4k3/8/2P5/4K3/8/8 w - - 0 1",
};

/// A copy of the embedded network file; the embedded network is active again once the caller frees it.
fn embedded_copy() ![]u8 {
    support.init_tables();
    try weights.load(weights.EMBEDDED_NAME);
    return testing.allocator.dupe(u8, std.mem.asBytes(weights.MODEL));
}

fn release(net: []u8) void {
    testing.allocator.free(net);
    weights.load(weights.EMBEDDED_NAME) catch unreachable;
}

fn value_at(net: []const u8, offset: usize) i16 {
    return std.mem.readInt(i16, net[offset..][0..2], .little);
}

test "netscale: a known factor changes only the output layer, each value rounded to nearest" {
    const original = try embedded_copy();
    defer release(original);
    const scaled = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(scaled);

    const factor = 0.75;
    try netscale.scale_output_layer(scaled, factor);

    const start = weights.OUTPUT_WEIGHT_BYTES.start;
    const end = weights.OUTPUT_BIAS_BYTES.start + weights.OUTPUT_BIAS_BYTES.len;
    try testing.expectEqual(weights.OUTPUT_WEIGHT_BYTES.start + weights.OUTPUT_WEIGHT_BYTES.len, weights.OUTPUT_BIAS_BYTES.start);
    try testing.expectEqualSlices(u8, original[0..start], scaled[0..start]);
    try testing.expectEqualSlices(u8, original[end..], scaled[end..]);

    var changed: usize = 0;
    var offset = start;
    while (offset < end) : (offset += 2) {
        const before = value_at(original, offset);
        const expected: i16 = @intFromFloat(@round(@as(f64, @floatFromInt(before)) * factor));
        try testing.expectEqual(expected, value_at(scaled, offset));
        changed += @intFromBool(expected != before);
    }
    try testing.expect(changed > 0);
    try weights.validate(scaled);
}

test "netscale: a factor of 1.0 is the identity" {
    const original = try embedded_copy();
    defer release(original);
    const scaled = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(scaled);

    try netscale.scale_output_layer(scaled, 1.0);
    try testing.expectEqualSlices(u8, original, scaled);
}

test "netscale: the scaled network's mean |eval| is the factor times the original's" {
    const net = try embedded_copy();
    defer release(net);

    const before = try netscale.mean_abs_eval(net, &FENS, 0);
    try testing.expectEqual(FENS.len - 1, before.positions);
    try testing.expect(before.abs_eval > 0);

    const factor = 0.8;
    try netscale.scale_output_layer(net, factor);
    const after = try netscale.mean_abs_eval(net, &FENS, 0);
    try testing.expectApproxEqRel(before.abs_eval * factor, after.abs_eval, 0.03);
}

test "netscale: positions in check are skipped and the limit counts the rest" {
    const net = try embedded_copy();
    defer release(net);

    try testing.expectEqual(@as(usize, 4), (try netscale.mean_abs_eval(net, &FENS, 4)).positions);
    try testing.expectEqual(
        (try netscale.mean_abs_eval(net, FENS[0..3] ++ FENS[4..5], 0)).abs_eval,
        (try netscale.mean_abs_eval(net, &FENS, 4)).abs_eval,
    );
    try testing.expectError(error.NoPositions, netscale.mean_abs_eval(net, &.{CHECK_FEN}, 0));
}

test "netscale: a network rescaled against itself is unchanged with factor 1" {
    const net = try embedded_copy();
    defer release(net);
    const reference = try testing.allocator.dupe(u8, net);
    defer testing.allocator.free(reference);

    const result = try netscale.rescale(net, reference, &FENS, 0);
    try testing.expectEqual(@as(f64, 1.0), result.factor);
    try testing.expectEqual(result.ref_mean_abs, result.scaled_mean_abs);
    try testing.expectEqualSlices(u8, reference, net);
}

test "netscale: a rescaled network matches the reference's mean |eval|" {
    const reference = try embedded_copy();
    defer release(reference);
    const candidate = try testing.allocator.dupe(u8, reference);
    defer testing.allocator.free(candidate);
    try netscale.scale_output_layer(candidate, 0.8);

    const result = try netscale.rescale(candidate, reference, &FENS, 0);
    try testing.expectApproxEqRel(@as(f64, 1.25), result.factor, 0.03);
    try testing.expectApproxEqRel(result.ref_mean_abs, result.scaled_mean_abs, 0.03);
}

test "netscale: a weight leaving the inference range or a bias overflowing i16 is refused" {
    const original = try embedded_copy();
    defer release(original);
    const net = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(net);

    try testing.expectError(error.OutputWeightOutOfRange, netscale.scale_output_layer(net, 1000.0));
    try testing.expectEqualSlices(u8, original, net);

    const output_weights = weights.OUTPUT_WEIGHT_BYTES.of(net[0..@sizeOf(weights.NNUEWeights)]);
    @memset(output_weights, 0);
    std.mem.writeInt(i16, output_weights[0..2], 100, .little);
    try testing.expectError(error.OutputWeightOutOfRange, netscale.scale_output_layer(net, 1.28));
    try netscale.scale_output_layer(net, 1.27);
    try testing.expectEqual(@as(i16, 127), value_at(net, weights.OUTPUT_WEIGHT_BYTES.start));

    std.mem.writeInt(i16, output_weights[0..2], -100, .little);
    try netscale.scale_output_layer(net, 1.28);
    try testing.expectEqual(@as(i16, -128), value_at(net, weights.OUTPUT_WEIGHT_BYTES.start));

    @memset(output_weights, 0);
    std.mem.writeInt(i16, weights.OUTPUT_BIAS_BYTES.of(net[0..@sizeOf(weights.NNUEWeights)])[0..2], 20000, .little);
    try testing.expectError(error.OutputBiasOverflow, netscale.scale_output_layer(net, 2.0));
    try testing.expectEqual(@as(i16, 20000), value_at(net, weights.OUTPUT_BIAS_BYTES.start));

    try testing.expectError(error.InvalidFactor, netscale.scale_output_layer(net, 0));
    try testing.expectError(error.InvalidFactor, netscale.scale_output_layer(net, std.math.nan(f64)));
}
