const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const hce = @import("../engine/hce.zig");
const weights = @import("../engine/weights.zig");
const bench = @import("../engine/bench.zig");
const options = @import("../engine/uci/options.zig");
const arch = @import("../engine/nnue/arch.zig");
const head_multi = @import("../engine/nnue/head_multi.zig");
const parity = @import("../engine/nnue/parity.zig");
const support = @import("support.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const Accumulators = struct { own: arch.Accumulator align(64), opp: arch.Accumulator align(64) };

/// Accumulators that reach every branch of the pairwise step: values below 0
/// and above 255, runs of zero products (whole blocks the sparse L1 skips),
/// and the extremes.
fn random_accumulators(random: std.Random, round: usize) Accumulators {
    var result: Accumulators = undefined;
    const density = round % 5;
    for ([_]*arch.Accumulator{ &result.own, &result.opp }) |acc| {
        for (acc) |*value| {
            value.* = switch (density) {
                0 => random.intRangeAtMost(i16, -300, 600),
                1 => if (random.uintLessThan(u8, 8) == 0) random.intRangeAtMost(i16, 0, 255) else random.intRangeAtMost(i16, -200, 0),
                2 => random.intRangeAtMost(i16, 200, 300),
                3 => random.int(i16),
                else => if (random.uintLessThan(u8, 40) == 0) 255 else 0,
            };
        }
    }
    if (round % 11 == 0) @memset(&result.own, 0);
    if (round % 13 == 0) @memset(&result.opp, 255);
    return result;
}

test "multi head: the SIMD path equals the scalar path on random weights" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0001);
    const random = prng.random();
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);

    var distinct = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer distinct.deinit();
    for (0..16) |net| {
        // Every L1 shift, with the whole validated range (including its
        // extremes) and with weights of trained magnitude.
        const shift: head_multi.L1Shift = @intCast(net / 2);
        var range: head_multi.RandomRange = if (net % 2 == 0) .{} else parity.REALISTIC_RANGE;
        range.l1_shift = shift;
        head_multi.fill_random(head, random, range);
        try head_multi.validate(std.mem.asBytes(head));
        for (0..200) |round| {
            const acc = random_accumulators(random, round);
            const bucket = round % arch.OUTPUT_SIZE;
            const scalar = head_multi.evaluate_scalar(head, shift, &acc.own, &acc.opp, bucket);
            try expectEqual(scalar, head_multi.evaluate_simd(head, shift, &acc.own, &acc.opp, bucket));
            try expectEqual(scalar, head_multi.evaluate(head, shift, &acc.own, &acc.opp, bucket));
            try distinct.put(scalar, {});
        }
    }
    // The comparison would be empty if the head saturated to a few values.
    try expect(distinct.count() > 1000);
}

test "multi head: the SIMD comparisons cover the intrinsic paths" {
    // Skipped, so that the summary shows it, when this build has a portable
    // pairwise product or L1: Debug builds, wasm, and x86 without SSSE3. The
    // comparisons then say nothing about the instructions a release binary
    // runs; run them again with -Doptimize=ReleaseSafe.
    if (head_multi.L1_PATH == .portable or head_multi.PAIRWISE_PATH == .portable) return error.SkipZigTest;
}

fn expect_pairwise(acc: *const Accumulators) !void {
    var activations: head_multi.Activations align(64) = undefined;
    head_multi.activate(&acc.own, &acc.opp, &activations);
    for ([_]*const arch.Accumulator{ &acc.own, &acc.opp }, 0..) |side_acc, side| {
        for (0..head_multi.PAIRS) |i| {
            try expectEqual(head_multi.pairwise(side_acc[i], side_acc[i + head_multi.PAIRS]), activations[side * head_multi.PAIRS + i]);
        }
    }
}

test "multi head: the SIMD pairwise products equal the scalar ones" {
    // Every pair of values around the clamp, where the rounding and the
    // saturation of each path differ, and the extremes of an i16.
    const edges = [_]i16{ std.math.minInt(i16), -256, -255, 256, 257, 511, 512, std.math.maxInt(i16) };
    const FIRST = -3;
    const SPAN = 262;
    var values: [SPAN + edges.len]i16 = undefined;
    for (values[0..SPAN], 0..) |*value, i| value.* = @intCast(FIRST + @as(i32, @intCast(i)));
    @memcpy(values[SPAN..], &edges);

    // Each accumulator holds PAIRS pairs: lane i gets (values[x], values[y])
    // for the next pair (x, y) of the product set, in both perspectives.
    var acc: Accumulators = undefined;
    var pair: usize = 0;
    while (pair < values.len * values.len) : (pair += head_multi.PAIRS) {
        for (0..head_multi.PAIRS) |i| {
            const current = (pair + i) % (values.len * values.len);
            acc.own[i] = values[current / values.len];
            acc.own[i + head_multi.PAIRS] = values[current % values.len];
            acc.opp[i] = values[current % values.len];
            acc.opp[i + head_multi.PAIRS] = values[current / values.len];
        }
        try expect_pairwise(&acc);
    }

    var prng = std.Random.DefaultPrng.init(0x5eed_0006);
    for (0..50) |round| try expect_pairwise(&random_accumulators(prng.random(), round));
}

/// Activations with exactly the blocks of `blocks` non-zero.
fn activations_with_blocks(random: std.Random, blocks: []const usize, value: ?u8) head_multi.Activations {
    var activations: head_multi.Activations = @splat(0);
    for (blocks) |block| {
        const inputs = activations[block * 4 ..][0..4];
        for (inputs) |*input| input.* = value orelse random.uintAtMost(u8, 127);
        // At least one input of the block is not zero, at any of the four places.
        if (value == null) inputs[random.uintLessThan(usize, 4)] |= 1;
    }
    return activations;
}

fn expect_l1(head: *const head_multi.Weights, activations: *align(64) const head_multi.Activations, blocks: []const usize, bucket: usize) !void {
    var indices: head_multi.BlockIndices = undefined;
    try expectEqual(blocks.len, head_multi.nonzero_blocks(activations, &indices));
    for (blocks, indices[0..blocks.len]) |block, index| try expectEqual(block, @as(usize, index));

    var sums = head.l1_bias[bucket];
    for (activations, 0..) |input, i| {
        for (&sums, &head.l1_weights[bucket][i / 4]) |*sum, *block_weights| sum.* += @as(i32, input) * block_weights[i % 4];
    }
    try expectEqual(sums, @as([head_multi.L1_SIZE]i32, head_multi.l1_sums(head, activations, bucket)));
}

test "multi head: the sparse L1 equals the plain sum for every number of non-zero blocks" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0007);
    const random = prng.random();
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);

    var order: [head_multi.L1_BLOCKS]usize = undefined;
    for (&order, 0..) |*block, i| block.* = i;

    for (0..3) |net| {
        switch (net) {
            // The whole i8 range, then the two weights that bring a
            // saturating instruction closest to its limit.
            0 => head_multi.fill_random(head, random, .{}),
            1 => @memset(std.mem.asBytes(&head.l1_weights), @bitCast(@as(i8, -128))),
            else => @memset(std.mem.asBytes(&head.l1_weights), 127),
        }
        // Every count from none to all, so every remainder of the vector
        // width and of the unrolled loop; the blocks are a random subset.
        for (0..head_multi.L1_BLOCKS + 1) |count| {
            random.shuffle(usize, &order);
            const blocks = order[0..count];
            std.mem.sort(usize, blocks, {}, std.sort.asc(usize));
            const value: ?u8 = if (net == 0) null else 127;
            const activations: head_multi.Activations align(64) = activations_with_blocks(random, blocks, value);
            try expect_l1(head, &activations, blocks, count % arch.OUTPUT_SIZE);
        }
    }
}

test "multi head: the non-zero block search finds a block by any single input" {
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    var prng = std.Random.DefaultPrng.init(0x5eed_0008);
    head_multi.fill_random(head, prng.random(), .{});

    for (0..head_multi.L1_INPUTS) |input| {
        var activations: head_multi.Activations align(64) = @splat(0);
        activations[input] = if (input % 2 == 0) 1 else 127;
        try expect_l1(head, &activations, &.{input / 4}, input % arch.OUTPUT_SIZE);
    }
}

test "multi head: accumulators of all zeros and of all ones" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0009);
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    head_multi.fill_random(head, prng.random(), .{});

    var acc: Accumulators = undefined;
    for ([_][2]i16{ .{ 0, 0 }, .{ 255, 255 }, .{ 0, 255 }, .{ -1, 1000 }, .{ 1000, 1000 } }) |fill| {
        @memset(&acc.own, fill[0]);
        @memset(&acc.opp, fill[1]);
        try expect_pairwise(&acc);
        for (0..arch.OUTPUT_SIZE) |bucket| {
            const scalar = head_multi.evaluate_scalar(head, 0, &acc.own, &acc.opp, bucket);
            try expectEqual(scalar, head_multi.evaluate_simd(head, 0, &acc.own, &acc.opp, bucket));
        }
    }
}

test "multi head: saturated weights cannot overflow" {
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    var acc: Accumulators = undefined;
    @memset(&acc.own, 255);
    @memset(&acc.opp, 255);

    // Every sum at its largest magnitude; a debug build traps on i32 overflow.
    for ([_]i32{ 1, -1 }) |sign| {
        @memset(std.mem.asBytes(&head.l1_weights), @bitCast(@as(i8, if (sign > 0) 127 else -128)));
        inline for (.{ "l1_bias", "l2_bias", "l3_bias" }) |field| {
            const values: *[@sizeOf(@FieldType(head_multi.Weights, field)) / 4]i32 = @ptrCast(&@field(head, field));
            @memset(values, sign * head_multi.BIAS_LIMIT);
        }
        inline for (.{ "l2_weights", "l3_weights" }) |field| {
            const values: *[@sizeOf(@FieldType(head_multi.Weights, field)) / 4]i32 = @ptrCast(&@field(head, field));
            @memset(values, sign * head_multi.WEIGHT_LIMIT);
        }
        try head_multi.validate(std.mem.asBytes(head));
        for ([_]head_multi.L1Shift{ 0, 1, head_multi.L1_SHIFT_MAX }) |shift| {
            const scalar = head_multi.evaluate_scalar(head, shift, &acc.own, &acc.opp, 0);
            try expectEqual(scalar, head_multi.evaluate_simd(head, shift, &acc.own, &acc.opp, 0));
        }
    }

    head.l3_weights[3][5] = head_multi.WEIGHT_LIMIT + 1;
    try expectError(head_multi.ValidateError.WeightOutOfRange, head_multi.validate(std.mem.asBytes(head)));
    head.l3_weights[3][5] = 0;
    head.l1_bias[7][15] = -head_multi.BIAS_LIMIT - 1;
    try expectError(head_multi.ValidateError.BiasOutOfRange, head_multi.validate(std.mem.asBytes(head)));
}

test "multi head: the integer formula follows the float forward pass" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0002);
    const random = prng.random();
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);

    var trainer: parity.Difference = .{};
    var quantised: parity.Difference = .{};
    var magnitude: parity.Difference = .{};
    for (0..8) |net| {
        // The same float magnitudes at every shift: 12 << shift is stored.
        const shift: head_multi.L1Shift = @intCast(net % 4);
        var range = parity.REALISTIC_RANGE;
        range.l1_shift = shift;
        range.l1_weight = @as(i8, 12) << shift;
        head_multi.fill_random(head, random, range);
        for (0..250) |round| {
            // Dense rounds only: `random.int(i16)` rounds are all 0 or 255.
            const acc = random_accumulators(random, round % 3);
            const bucket = round % arch.OUTPUT_SIZE;
            const engine: f64 = @floatFromInt(head_multi.evaluate(head, shift, &acc.own, &acc.opp, bucket));
            trainer.add(engine, head_multi.evaluate_float(head, shift, &acc.own, &acc.opp, bucket, .trainer));
            quantised.add(engine, head_multi.evaluate_float(head, shift, &acc.own, &acc.opp, bucket, .quantised_pairwise));
            magnitude.add(engine, 0);
        }
    }

    // Tolerances, in centipawns; docs/NNUE.md derives them. A wrong layout or
    // formula is off by the spread of the evaluations, hundreds of centipawns.
    try expect(magnitude.mean() > 50);
    try expect(quantised.max <= head_multi.QUANTISED_TOLERANCE_CP);
    try expect(trainer.max <= head_multi.TRAINER_TOLERANCE_CP);
}

/// Stores float L1 weights and biases of bucket 0 as the trainer does at `shift`.
fn quantise_l1(head: *head_multi.Weights, shift: head_multi.L1Shift, l1_weights: *const [head_multi.L1_INPUTS][head_multi.L1_SIZE]f64, bias: *const [head_multi.L1_SIZE]f64) void {
    const shifted: f64 = @floatFromInt(@as(u32, 1) << shift);
    for (l1_weights, 0..) |*outputs, input| {
        for (outputs, 0..) |weight, j| {
            head.l1_weights[0][input / 4][j][input % 4] = @intFromFloat(@round(weight * head_multi.L1_WEIGHT_SCALE * shifted));
        }
    }
    for (bias, &head.l1_bias[0]) |value, *stored| {
        stored.* = @intFromFloat(@round(value * @as(f64, @floatFromInt(head_multi.ONE)) * shifted));
    }
}

test "multi head: small L1 weights are stored with a shift and stay close to the float model" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0005);
    const random = prng.random();
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    const l1_weights = try std.testing.allocator.create([head_multi.L1_INPUTS][head_multi.L1_SIZE]f64);
    defer std.testing.allocator.destroy(l1_weights);

    try expectEqual(@as(head_multi.L1Shift, 0), head_multi.l1_shift_for(1.9689));
    try expectEqual(@as(head_multi.L1Shift, 0), head_multi.l1_shift_for(1.0));
    try expectEqual(@as(head_multi.L1Shift, 1), head_multi.l1_shift_for(0.98));
    try expectEqual(@as(head_multi.L1Shift, 3), head_multi.l1_shift_for(0.2166));
    try expectEqual(head_multi.L1_SHIFT_MAX, head_multi.l1_shift_for(0.001));
    try expectEqual(head_multi.L1_SHIFT_MAX, head_multi.l1_shift_for(0));

    // The largest L1 weight of the first net trained on a GPU: 14 of 127
    // levels at shift 0.
    const max_weight = 0.2166;
    const shift = head_multi.l1_shift_for(max_weight);
    try expect(shift > 0);

    var shifted: parity.Difference = .{};
    var unshifted: parity.Difference = .{};
    var magnitude: parity.Difference = .{};
    for (0..4) |_| {
        head_multi.fill_random(head, random, parity.REALISTIC_RANGE);
        var bias: [head_multi.L1_SIZE]f64 = undefined;
        for (&bias) |*value| value.* = random.float(f64) - 0.5;
        // Most weights small, as in a trained net; the largest sets the shift.
        for (l1_weights) |*outputs| {
            for (outputs) |*weight| weight.* = max_weight * std.math.pow(f64, random.float(f64), 3) * (if (random.boolean()) @as(f64, 1) else -1);
        }
        l1_weights[0][0] = max_weight;

        for (0..100) |round| {
            const acc = random_accumulators(random, round % 3);
            // The float model: exact L1 weights on the engine's pairwise
            // products, so that only the weight rounding is measured.
            var z1 = bias;
            for ([_]arch.AccumulatorPtr{ &acc.own, &acc.opp }, 0..) |side_acc, side| {
                for (0..head_multi.PAIRS) |i| {
                    const activation = @as(f64, @floatFromInt(head_multi.pairwise(side_acc[i], side_acc[i + head_multi.PAIRS]))) / head_multi.PAIRWISE_ONE;
                    for (&z1, l1_weights[side * head_multi.PAIRS + i]) |*sum, weight| sum.* += activation * weight;
                }
            }
            const float = head_multi.evaluate_float_from_l1(head, 0, z1);

            quantise_l1(head, shift, l1_weights, &bias);
            // docs/NNUE.md: the chosen shift puts the largest weight at 64..127 levels.
            try expect(@abs(@as(i32, head.l1_weights[0][0][0][0])) >= 64);
            const with_shift: f64 = @floatFromInt(head_multi.evaluate(head, shift, &acc.own, &acc.opp, 0));
            quantise_l1(head, 0, l1_weights, &bias);
            const without: f64 = @floatFromInt(head_multi.evaluate(head, 0, &acc.own, &acc.opp, 0));
            shifted.add(with_shift, float);
            unshifted.add(without, float);
            magnitude.add(float, 0);
        }
    }

    try expect(magnitude.mean() > 50);
    // Measured: 8.1 max and 1.2 mean with the shift, 81 and 17 without, which
    // is what the first GPU net showed against the trainer (84 and 23).
    try expect(shifted.max <= head_multi.L1_ROUNDING_TOLERANCE_CP);
    try expect(shifted.mean() <= head_multi.L1_ROUNDING_TOLERANCE_CP / 4);
    try expect(unshifted.mean() > 4 * shifted.mean());
}

fn random_network(seed: u64, range: head_multi.RandomRange) !*parity.Net {
    const net = try std.testing.allocator.create(parity.Net);
    var prng = std.Random.DefaultPrng.init(seed);
    parity.fill_random(net, prng.random(), range, .dense);
    return net;
}

test "multi net: a file in the documented layout round-trips" {
    if (weights.NUM_INPUT_BUCKETS != 16) return error.SkipZigTest;
    support.init_tables();
    const net = try random_network(0x5eed_0003, parity.REALISTIC_RANGE);
    defer std.testing.allocator.destroy(net);

    // Written field by field at the offsets of docs/NNUE.md, not as the struct.
    const ft_bytes = weights.INPUT_SIZE * arch.HIDDEN_SIZE * 2;
    const file = try std.testing.allocator.alloc(u8, 25334400);
    defer std.testing.allocator.free(file);
    @memset(file, 0xAA);
    var offset: usize = 0;
    const sections = [_][]const u8{
        "AVALNNUE",
        std.mem.sliceAsBytes(&[_]u32{ 2, 1, 16, 1024, 8, 16, 32, 255, 9, 13, 10, 400, 3, 0 }),
        std.mem.asBytes(&net.layer_1),
        std.mem.asBytes(&net.layer_1_bias),
        std.mem.asBytes(&net.head.l1_weights),
        std.mem.asBytes(&net.head.l1_bias),
        std.mem.asBytes(&net.head.l2_weights),
        std.mem.asBytes(&net.head.l2_bias),
        std.mem.asBytes(&net.head.l3_weights),
        std.mem.asBytes(&net.head.l3_bias),
    };
    for (sections) |section| {
        @memcpy(file[offset..][0..section.len], section);
        offset += section.len;
    }
    try expectEqual(@as(usize, 64 + ft_bytes + 2048 + 131072 + 512 + 32768 + 1024 + 1024 + 32), offset);
    try expectEqual(file.len, std.mem.alignForward(usize, offset, 64));

    platform.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "multi.nnue", .data = file });
    const loaded_bytes = try tmp.dir.readFileAlloc(std.testing.io, "multi.nnue", std.testing.allocator, .limited(file.len + 1));
    defer std.testing.allocator.free(loaded_bytes);
    try weights.validate_as(.multi, loaded_bytes);
    const loaded = try std.testing.allocator.create(parity.Net);
    defer std.testing.allocator.destroy(loaded);
    @memcpy(std.mem.asBytes(loaded), loaded_bytes);

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    var trainer: parity.Difference = .{};
    var distinct = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer distinct.deinit();
    for (bench.FENS) |fen| {
        pos.set_fen(fen);
        const original = parity.evaluate(net, pos);
        const reloaded = parity.evaluate(loaded, pos);
        try expectEqual(original.engine, reloaded.engine);
        trainer.add(@floatFromInt(reloaded.engine), reloaded.trainer);
        try distinct.put(reloaded.engine, {});
    }
    try expect(distinct.count() > bench.FENS.len / 2);
    try expect(trainer.max <= head_multi.TRAINER_TOLERANCE_CP);

    if (weights.HEAD == .multi) {
        // The engine's own loader and incremental accumulators agree with the
        // from-scratch ones.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "multi.nnue", &path_buf)];
        try weights.load(path);
        defer weights.load(weights.EMBEDDED_NAME) catch unreachable;
        for (bench.FENS) |fen| {
            pos.set_fen(fen);
            try expectEqual(parity.evaluate(loaded, pos).engine, hce.evaluate_nnue(pos));
        }
    }
}

test "multi net: the feature transformer of parity matches the engine's accumulators" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    for (bench.FENS) |fen| {
        pos.set_fen(fen);
        const engine = pos.evaluator.nnue_evaluator.current();
        var acc: arch.Accumulator = undefined;
        parity.accumulate(weights.MODEL, pos, types.Color.White, &acc);
        try expect(std.mem.eql(i16, &acc, &engine.white));
        parity.accumulate(weights.MODEL, pos, types.Color.Black, &acc);
        try expect(std.mem.eql(i16, &acc, &engine.black));
    }
}

test "multi net: the loaders reject the other architecture and damaged files" {
    if (weights.NUM_INPUT_BUCKETS != 16) return error.SkipZigTest;
    support.init_tables();
    const net = try random_network(0x5eed_0004, .{});
    defer std.testing.allocator.destroy(net);
    const multi = std.mem.asBytes(net);
    const single = try std.testing.allocator.alloc(u8, @sizeOf(weights.Network(.single)));
    defer std.testing.allocator.free(single);
    @memset(single, 0);

    try weights.validate_as(.multi, multi);
    try weights.validate_as(.single, single);
    try expectError(weights.NetworkError.WrongArchitecture, weights.validate_as(.single, multi));
    try expectError(weights.NetworkError.WrongArchitecture, weights.validate_as(.multi, single));
    // Neither kind: empty, garbage, and a truncated single-layer file.
    try expectError(weights.NetworkError.NotANetwork, weights.validate_as(.multi, ""));
    try expectError(weights.NetworkError.NotANetwork, weights.validate_as(.multi, "not a network"));
    try expectError(weights.NetworkError.NotANetwork, weights.validate_as(.multi, single[0 .. single.len - 64]));
    try expectError(weights.NetworkError.WrongSize, weights.validate_as(.single, "not a network"));
    try expect(std.mem.indexOf(u8, weights.explain(weights.NetworkError.NotANetwork), "-Dhead") == null);
    try expectError(weights.NetworkError.UnsupportedHeader, weights.validate_as(.multi, weights.MAGIC));
    try expectError(weights.NetworkError.WrongSize, weights.validate_as(.multi, multi[0 .. multi.len - 64]));

    // A header field that differs: format version, then the L1 width.
    for ([_]usize{ 8, 28 }) |field| {
        net.header[field] += 1;
        try expectError(weights.NetworkError.UnsupportedHeader, weights.validate_as(.multi, multi));
        net.header[field] -= 1;
    }
    // The L1 shift is the one field that varies, within 0..7.
    const shift_field = net.header[weights.L1_SHIFT_OFFSET..][0..4];
    for (0..8) |shift| {
        std.mem.writeInt(u32, shift_field, @intCast(shift), .little);
        try weights.validate_as(.multi, multi);
        try expectEqual(shift, @as(usize, weights.l1_shift(&net.header)));
    }
    for ([_]u32{ 8, 256, 1 << 31 }) |shift| {
        std.mem.writeInt(u32, shift_field, shift, .little);
        try expectError(weights.NetworkError.UnsupportedHeader, weights.validate_as(.multi, multi));
    }
    std.mem.writeInt(u32, shift_field, 0, .little);

    net.head.l2_weights[0][0][0] = head_multi.WEIGHT_LIMIT + 1;
    try expectError(weights.NetworkError.WeightOutOfRange, weights.validate_as(.multi, multi));
    net.head.l2_weights[0][0][0] = 0;
    try weights.validate_as(.multi, multi);

    // Through EvalFile: the wrong architecture is reported and the network kept.
    platform.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const other: []const u8 = if (weights.HEAD == .single) multi else single;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.nnue", .data = other });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "other.nnue", &path_buf)];

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.KIWIPETE_FEN);
    const before = hce.evaluate_nnue(pos);
    var settings: options.Settings = .{};
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var args_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    try options.set_option(try std.fmt.bufPrint(&args_buf, "name EvalFile value {s}", .{path}), .{ .settings = &settings, .position = pos, .out = &out });
    try expect(std.mem.indexOf(u8, out.buffered(), "WrongArchitecture") != null);
    try expect(std.mem.indexOf(u8, out.buffered(), "-Dhead=") != null);
    try expectEqual(before, hce.evaluate_nnue(pos));
    try std.testing.expectEqualStrings(@import("build_options").net_name, weights.active_network());
}
