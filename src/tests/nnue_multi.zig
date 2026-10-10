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

const QUANTISED_PAIRWISE_TOLERANCE_CP: f64 = 0.75;
const EXACT_PAIRWISE_TOLERANCE_CP: f64 = 16.0;
const L1_ROUNDING_TOLERANCE_CP: f64 = 16.0;

fn expect_mean_well_above(tolerance_cp: f64, magnitude: parity.Difference) !void {
    try expect(magnitude.mean() > 3 * tolerance_cp);
}

const Accumulators = struct { own: arch.Accumulator align(64), opp: arch.Accumulator align(64) };

const Density = enum {
    mixed,
    sparse,
    high,
    extreme,
    isolated,

    fn of_round(round: usize) Density {
        return @fromBackingInt(@intCast(round % @typeInfo(Density).@"enum".field_names.len));
    }
};

fn random_accumulators(random: std.Random, density: Density, round: usize) Accumulators {
    var result: Accumulators = undefined;
    for ([_]*arch.Accumulator{ &result.own, &result.opp }) |acc| {
        for (acc) |*value| {
            value.* = switch (density) {
                .mixed => random.intRangeAtMost(i16, -300, 600),
                .sparse => if (random.uintLessThan(u8, 8) == 0) random.intRangeAtMost(i16, 0, 255) else random.intRangeAtMost(i16, -200, 0),
                .high => random.intRangeAtMost(i16, 200, 300),
                .extreme => random.int(i16),
                .isolated => if (random.uintLessThan(u8, 40) == 0) 255 else 0,
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

    var distinct_outputs = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer distinct_outputs.deinit();
    for (0..@as(usize, head_multi.L1_SHIFT_MAX) + 1) |l1_shift| {
        const shift: head_multi.L1Shift = @intCast(l1_shift);
        for ([_]parity.RandomRange{ .full, .trained_magnitude }) |magnitudes| {
            var range = magnitudes;
            range.l1_shift = shift;
            parity.fill_random_head(head, random, range);
            try head_multi.validate(std.mem.asBytes(head));
            for (0..200) |round| {
                const acc = random_accumulators(random, .of_round(round), round);
                const bucket = round % arch.OUTPUT_SIZE;
                const scalar = head_multi.evaluate_scalar(head, shift, &acc.own, &acc.opp, bucket);
                try expectEqual(scalar, head_multi.evaluate(head, &.init(head, shift), &acc.own, &acc.opp, bucket));
                try distinct_outputs.put(scalar, {});
            }
        }
    }
    try expect(distinct_outputs.count() > 1000);
}

test "multi head: the SIMD comparisons cover the intrinsic paths" {
    if (head_multi.L1_PATH == .portable or head_multi.PAIRWISE_PATH == .portable) return error.SkipZigTest;
}

test "multi head: the prepared L2 weights are the file's, in pairs" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0009);
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    parity.fill_random_head(head, prng.random(), .full);

    const prepared: head_multi.Prepared = .init(head, 5);
    try expectEqual(@as(head_multi.L1Shift, 5), prepared.l1_shift);
    for (0..arch.OUTPUT_SIZE) |bucket| {
        for (0..head_multi.L1_SIZE) |j| {
            for (0..head_multi.L2_SIZE) |o| {
                const pair = prepared.l2_pairs[bucket][j][o];
                try expectEqual(head.l2_weights[bucket][j][o], @as(i32, pair[0]));
                try expectEqual(head.l2_weights[bucket][head_multi.L1_SIZE + j][o], @as(i32, pair[1]));
            }
        }
    }
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
    const extremes = [_]i16{ std.math.minInt(i16), -256, -255, 256, 257, 511, 512, std.math.maxInt(i16) };
    const AROUND_CLAMP_FIRST = -3;
    const AROUND_CLAMP_COUNT: usize = arch.QA + 7;
    var values: [AROUND_CLAMP_COUNT + extremes.len]i16 = undefined;
    for (values[0..AROUND_CLAMP_COUNT], 0..) |*value, i| value.* = @intCast(AROUND_CLAMP_FIRST + @as(i32, @intCast(i)));
    @memcpy(values[AROUND_CLAMP_COUNT..], &extremes);

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
    for (0..50) |round| try expect_pairwise(&random_accumulators(prng.random(), .of_round(round), round));
}

fn activations_nonzero_in(random: std.Random, blocks: []const usize, value: ?u8) head_multi.Activations {
    var activations: head_multi.Activations = @splat(0);
    for (blocks) |block| {
        const inputs = activations[block * 4 ..][0..4];
        for (inputs) |*input| input.* = value orelse random.uintAtMost(u8, head_multi.ACTIVATION_MAX);
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

    const L1Weights = enum { random, all_lowest, all_highest };
    for (std.enums.values(L1Weights)) |l1_weights| {
        switch (l1_weights) {
            .random => parity.fill_random_head(head, random, .full),
            .all_lowest => @memset(std.mem.asBytes(&head.l1_weights), @bitCast(@as(i8, std.math.minInt(i8)))),
            .all_highest => @memset(std.mem.asBytes(&head.l1_weights), std.math.maxInt(i8)),
        }
        for (0..head_multi.L1_BLOCKS + 1) |count| {
            random.shuffle(usize, &order);
            const blocks = order[0..count];
            std.mem.sort(usize, blocks, {}, std.sort.asc(usize));
            const value: ?u8 = if (l1_weights == .random) null else head_multi.ACTIVATION_MAX;
            const activations: head_multi.Activations align(64) = activations_nonzero_in(random, blocks, value);
            try expect_l1(head, &activations, blocks, count % arch.OUTPUT_SIZE);
        }
    }
}

test "multi head: the non-zero block search finds a block by any single input" {
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    var prng = std.Random.DefaultPrng.init(0x5eed_0008);
    parity.fill_random_head(head, prng.random(), .full);

    for (0..head_multi.L1_INPUTS) |input| {
        var activations: head_multi.Activations align(64) = @splat(0);
        activations[input] = if (input % 2 == 0) 1 else head_multi.ACTIVATION_MAX;
        try expect_l1(head, &activations, &.{input / 4}, input % arch.OUTPUT_SIZE);
    }
}

test "multi head: accumulators of all zeros and of all ones" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0009);
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    parity.fill_random_head(head, prng.random(), .full);

    var acc: Accumulators = undefined;
    for ([_][2]i16{ .{ 0, 0 }, .{ 255, 255 }, .{ 0, 255 }, .{ -1, 1000 }, .{ 1000, 1000 } }) |fill| {
        @memset(&acc.own, fill[0]);
        @memset(&acc.opp, fill[1]);
        try expect_pairwise(&acc);
        for (0..arch.OUTPUT_SIZE) |bucket| {
            const scalar = head_multi.evaluate_scalar(head, 0, &acc.own, &acc.opp, bucket);
            try expectEqual(scalar, head_multi.evaluate(head, &.init(head, 0), &acc.own, &acc.opp, bucket));
        }
    }
}

fn fill_section(head: *head_multi.Weights, comptime field: []const u8, value: i32) void {
    const values: *[@sizeOf(@FieldType(head_multi.Weights, field)) / 4]i32 = @ptrCast(&@field(head, field));
    @memset(values, value);
}

fn centipawns(l3_sum: i64) i32 {
    return @intCast((l3_sum * arch.SCALE + (1 << (head_multi.SUM_BITS - 1))) >> head_multi.SUM_BITS);
}

test "multi head: weights and biases at their limits overflow no sum, whatever the sign of each layer" {
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    const acc: Accumulators = .{ .own = @splat(arch.QA), .opp = @splat(arch.QA) };

    const signs = [_]i32{ 1, -1 };
    for (signs) |l1_sign| {
        for (signs) |l2_sign| {
            for (signs) |l3_sign| {
                const l1_weight: i8 = if (l1_sign > 0) std.math.maxInt(i8) else std.math.minInt(i8);
                @memset(std.mem.asBytes(&head.l1_weights), @bitCast(l1_weight));
                fill_section(head, "l1_bias", l1_sign * head_multi.BIAS_LIMIT);
                fill_section(head, "l2_weights", l2_sign * head_multi.WEIGHT_LIMIT);
                fill_section(head, "l2_bias", l2_sign * head_multi.BIAS_LIMIT);
                fill_section(head, "l3_weights", l3_sign * head_multi.WEIGHT_LIMIT);
                fill_section(head, "l3_bias", l3_sign * head_multi.BIAS_LIMIT);
                try head_multi.validate(std.mem.asBytes(head));

                const saturated_l2_outputs: i64 = if (l2_sign > 0) @as(i64, head_multi.L2_SIZE) * head_multi.ONE * head_multi.WEIGHT_LIMIT else 0;
                const expected = centipawns(l3_sign * (head_multi.BIAS_LIMIT + saturated_l2_outputs));
                for ([_]head_multi.L1Shift{ 0, 1, head_multi.L1_SHIFT_MAX }) |shift| {
                    try expectEqual(expected, head_multi.evaluate_scalar(head, shift, &acc.own, &acc.opp, 0));
                    try expectEqual(expected, head_multi.evaluate(head, &.init(head, shift), &acc.own, &acc.opp, 0));
                }
            }
        }
    }
}

test "multi head: a weight or a bias beyond its limit is refused" {
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);
    @memset(std.mem.asBytes(head), 0);
    try head_multi.validate(std.mem.asBytes(head));

    head.l3_weights[3][5] = head_multi.WEIGHT_LIMIT + 1;
    try expectError(head_multi.ValidateError.WeightOutOfRange, head_multi.validate(std.mem.asBytes(head)));
    head.l3_weights[3][5] = 0;
    head.l1_bias[7][15] = -head_multi.BIAS_LIMIT - 1;
    try expectError(head_multi.ValidateError.BiasOutOfRange, head_multi.validate(std.mem.asBytes(head)));
}

const DENSITIES_WITH_ROUNDING = [_]Density{ .mixed, .sparse, .high };

fn trained_magnitude_at(shift: head_multi.L1Shift) parity.RandomRange {
    var range: parity.RandomRange = .trained_magnitude;
    range.l1_weight = (range.l1_weight >> range.l1_shift) << shift;
    range.l1_shift = shift;
    return range;
}

test "multi head: the integer formula follows the float forward pass" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0002);
    const random = prng.random();
    const head = try std.testing.allocator.create(head_multi.Weights);
    defer std.testing.allocator.destroy(head);

    var exact_pairwise: parity.Difference = .{};
    var quantised_pairwise: parity.Difference = .{};
    var magnitude: parity.Difference = .{};
    const shifts = @as(usize, parity.RandomRange.trained_magnitude.l1_shift) + 1;
    for (0..2 * shifts) |net| {
        const shift: head_multi.L1Shift = @intCast(net % shifts);
        parity.fill_random_head(head, random, trained_magnitude_at(shift));
        for (0..250) |round| {
            const acc = random_accumulators(random, DENSITIES_WITH_ROUNDING[round % DENSITIES_WITH_ROUNDING.len], round);
            const bucket = round % arch.OUTPUT_SIZE;
            const integer: f64 = @floatFromInt(head_multi.evaluate(head, &.init(head, shift), &acc.own, &acc.opp, bucket));
            exact_pairwise.add(integer, parity.evaluate_float(head, shift, &acc.own, &acc.opp, bucket, .exact_pairwise));
            quantised_pairwise.add(integer, parity.evaluate_float(head, shift, &acc.own, &acc.opp, bucket, .quantised_pairwise));
            magnitude.add(integer, 0);
        }
    }

    try expect_mean_well_above(EXACT_PAIRWISE_TOLERANCE_CP, magnitude);
    try expect(quantised_pairwise.max <= QUANTISED_PAIRWISE_TOLERANCE_CP);
    try expect(exact_pairwise.max <= EXACT_PAIRWISE_TOLERANCE_CP);
}

fn l1_shift_for(max_weight: f64) head_multi.L1Shift {
    var shift: head_multi.L1Shift = 0;
    while (shift < head_multi.L1_SHIFT_MAX and @round(max_weight * head_multi.L1_WEIGHT_SCALE * @as(f64, @floatFromInt(@as(u32, 2) << shift))) <= std.math.maxInt(i8)) shift += 1;
    return shift;
}

test "multi head: the L1 shift is the largest at which the largest weight fits an i8" {
    try expectEqual(@as(head_multi.L1Shift, 0), l1_shift_for(1.9689));
    try expectEqual(@as(head_multi.L1Shift, 0), l1_shift_for(1.0));
    try expectEqual(@as(head_multi.L1Shift, 1), l1_shift_for(0.98));
    try expectEqual(@as(head_multi.L1Shift, 3), l1_shift_for(0.2166));
    try expectEqual(head_multi.L1_SHIFT_MAX, l1_shift_for(0.001));
    try expectEqual(head_multi.L1_SHIFT_MAX, l1_shift_for(0));
}

fn quantise_l1(head: *head_multi.Weights, bucket: usize, shift: head_multi.L1Shift, l1_weights: *const [head_multi.L1_INPUTS][head_multi.L1_SIZE]f64, bias: *const [head_multi.L1_SIZE]f64) void {
    const shifted: f64 = @floatFromInt(@as(u32, 1) << shift);
    for (l1_weights, 0..) |*outputs, input| {
        for (outputs, 0..) |weight, j| {
            head.l1_weights[bucket][input / 4][j][input % 4] = @intFromFloat(@round(weight * head_multi.L1_WEIGHT_SCALE * shifted));
        }
    }
    for (bias, &head.l1_bias[bucket]) |value, *stored| {
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

    const max_weight = 0.2166;
    const shift = l1_shift_for(max_weight);
    try expect(shift > 0);
    const bucket = 0;
    const half_of_the_i8_range = (std.math.maxInt(i8) + 1) / 2;

    var shifted: parity.Difference = .{};
    var unshifted: parity.Difference = .{};
    var magnitude: parity.Difference = .{};
    for (0..4) |_| {
        parity.fill_random_head(head, random, .trained_magnitude);
        var bias: [head_multi.L1_SIZE]f64 = undefined;
        for (&bias) |*value| value.* = random.float(f64) - 0.5;
        for (l1_weights) |*outputs| {
            for (outputs) |*weight| weight.* = max_weight * std.math.pow(f64, random.float(f64), 3) * (if (random.boolean()) @as(f64, 1) else -1);
        }
        l1_weights[0][0] = max_weight;

        for (0..100) |round| {
            const acc = random_accumulators(random, DENSITIES_WITH_ROUNDING[round % DENSITIES_WITH_ROUNDING.len], round);
            var z1 = bias;
            for ([_]arch.AccumulatorPtr{ &acc.own, &acc.opp }, 0..) |side_acc, side| {
                for (0..head_multi.PAIRS) |i| {
                    const activation = @as(f64, @floatFromInt(head_multi.pairwise(side_acc[i], side_acc[i + head_multi.PAIRS]))) / head_multi.PAIRWISE_ONE;
                    for (&z1, l1_weights[side * head_multi.PAIRS + i]) |*sum, weight| sum.* += activation * weight;
                }
            }
            const float = parity.evaluate_float_from_l1(head, bucket, z1);

            quantise_l1(head, bucket, shift, l1_weights, &bias);
            try expect(@abs(@as(i32, head.l1_weights[bucket][0][0][0])) >= half_of_the_i8_range);
            const with_shift: f64 = @floatFromInt(head_multi.evaluate(head, &.init(head, shift), &acc.own, &acc.opp, bucket));
            quantise_l1(head, bucket, 0, l1_weights, &bias);
            const without: f64 = @floatFromInt(head_multi.evaluate(head, &.init(head, 0), &acc.own, &acc.opp, bucket));
            shifted.add(with_shift, float);
            unshifted.add(without, float);
            magnitude.add(float, 0);
        }
    }

    try expect_mean_well_above(L1_ROUNDING_TOLERANCE_CP, magnitude);
    try expect(shifted.max <= L1_ROUNDING_TOLERANCE_CP);
    try expect(shifted.mean() <= L1_ROUNDING_TOLERANCE_CP / 4);
    try expect(unshifted.mean() > 4 * shifted.mean());
}

fn random_network(seed: u64, range: parity.RandomRange) !*parity.Net {
    const net = try std.testing.allocator.create(parity.Net);
    var prng = std.Random.DefaultPrng.init(seed);
    parity.fill_random(net, prng.random(), range, .dense);
    return net;
}

test "multi net: a file in the documented layout round-trips" {
    if (weights.NUM_INPUT_BUCKETS != 16) return error.SkipZigTest;
    support.init_tables();
    const range: parity.RandomRange = .trained_magnitude;
    const net = try random_network(0x5eed_0003, range);
    defer std.testing.allocator.destroy(net);

    const ft_bytes = weights.INPUT_SIZE * arch.HIDDEN_SIZE * 2;
    const file = try std.testing.allocator.alloc(u8, 25334400);
    defer std.testing.allocator.free(file);
    @memset(file, 0xAA);
    var offset: usize = 0;
    const sections = [_][]const u8{
        "AVALNNUE",
        std.mem.sliceAsBytes(&[_]u32{ 2, 1, 16, 1024, 8, 16, 32, 255, 9, 13, 10, 400, range.l1_shift, 0 }),
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
    var exact_pairwise: parity.Difference = .{};
    var distinct_outputs = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer distinct_outputs.deinit();
    for (bench.FENS) |fen| {
        pos.set_fen(fen);
        const original = parity.evaluate(net, pos);
        const reloaded = parity.evaluate(loaded, pos);
        try expectEqual(original.integer, reloaded.integer);
        exact_pairwise.add(@floatFromInt(reloaded.integer), reloaded.float);
        try distinct_outputs.put(reloaded.integer, {});
    }
    try expect(distinct_outputs.count() > bench.FENS.len / 2);
    try expect(exact_pairwise.max <= EXACT_PAIRWISE_TOLERANCE_CP);

    if (weights.HEAD == .multi) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "multi.nnue", &path_buf)];
        try weights.load(path);
        defer weights.load(weights.EMBEDDED_NAME) catch unreachable;
        for (bench.FENS) |fen| {
            pos.set_fen(fen);
            try expectEqual(parity.evaluate(loaded, pos).integer, hce.evaluate_nnue(pos));
        }
    }
}

fn rebuild_accumulator(pos: *const position.Position, perspective: types.Color, out: *arch.Accumulator) void {
    parity.accumulate(&weights.MODEL.layer_1, &weights.MODEL.layer_1_bias, pos, perspective, out);
}

test "multi net: the feature transformer of parity matches the engine's accumulators" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    for (bench.FENS) |fen| {
        pos.set_fen(fen);
        const engine = pos.evaluator.nnue_evaluator.accumulator(pos);
        var acc: arch.Accumulator = undefined;
        rebuild_accumulator(pos, types.Color.White, &acc);
        try expect(std.mem.eql(i16, &acc, &engine.white));
        rebuild_accumulator(pos, types.Color.Black, &acc);
        try expect(std.mem.eql(i16, &acc, &engine.black));
    }
}

fn expect_accumulators_rebuilt(pos: *position.Position) !void {
    const engine = pos.evaluator.nnue_evaluator.accumulator(pos);
    var rebuilt: Accumulators = undefined;
    rebuild_accumulator(pos, types.Color.White, &rebuilt.own);
    rebuild_accumulator(pos, types.Color.Black, &rebuilt.opp);
    try std.testing.expectEqualSlices(i16, &rebuilt.own, &engine.white);
    try std.testing.expectEqualSlices(i16, &rebuilt.opp, &engine.black);

    const bucket = parity.output_bucket(pos);
    const expected = if (pos.turn == types.Color.White)
        weights.evaluate(&rebuilt.own, &rebuilt.opp, bucket)
    else
        weights.evaluate(&rebuilt.opp, &rebuilt.own, bucket);
    try expectEqual(expected, hce.evaluate_nnue(pos));
}

test "multi net: a rebuild from the cache of an unrelated position equals a scalar one" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    const source = try support.new_position();
    defer support.destroy_position(source);

    const fens_with_the_kings_on_e1_and_e8 = [_][]const u8{
        types.DEFAULT_FEN,
        "4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1",
        types.DEFAULT_FEN,
        types.KIWIPETE_FEN,
        "4k3/pppppppp/8/8/8/8/8/4K3 b - - 0 1",
        "4k3/pppppppp/8/8/8/8/8/4K3 b - - 0 1",
    };
    for (fens_with_the_kings_on_e1_and_e8) |fen| {
        source.set_fen(fen);
        pos.copy_game_state(source);
        pos.rebuild_evaluation();
        try expect_accumulators_rebuilt(pos);
    }
}

fn is_rare_update(move: types.Move) bool {
    return move.is_castle() or move.is_promotion() or move.get_flags() == types.MoveFlags.EN_PASSANT;
}

test "multi net: incremental accumulators equal a rebuild after every move of random games" {
    support.init_tables();
    const pos = try support.new_position();
    defer support.destroy_position(pos);
    var prng = std.Random.DefaultPrng.init(0x5eed_0005);
    const random = prng.random();

    const promotions_with_and_without_capture = "1n2k1n1/P1P2P1P/8/8/8/8/p1p2p1p/1N2K1N1 w - - 0 1";
    const en_passant_at_once_and_double_pushes_to_come = "4k3/pp1p1ppp/8/2pP4/4pP2/8/PPP1P1PP/4K3 w - c6 0 1";
    const chess960_castling_onto_each_others_squares = "1r2k1r1/pppppppp/8/8/8/8/PPPPPPPP/1R2K1R1 w GBgb - 0 1";
    const king_walks_across_buckets = "8/2k2p2/3p4/8/8/3P4/2K2P2/8 w - - 0 1";
    const starts = [_][]const u8{
        types.DEFAULT_FEN,
        types.KIWIPETE_FEN,
        promotions_with_and_without_capture,
        en_passant_at_once_and_double_pushes_to_come,
        chess960_castling_onto_each_others_squares,
        king_walks_across_buckets,
    };
    const plies = 160;
    for (starts) |fen| {
        for (0..3) |_| {
            pos.set_fen(fen);
            try expect_accumulators_rebuilt(pos);
            var played: [plies]types.Move = undefined;
            var count: usize = 0;
            while (count < plies) {
                const moves = pos.legal_moves();
                if (moves.len == 0) break;

                var rare: [256]types.Move = undefined;
                var rare_count: usize = 0;
                for (moves.items()) |move| {
                    if (is_rare_update(move)) {
                        rare[rare_count] = move;
                        rare_count += 1;
                    }
                }
                const move = if (rare_count != 0 and random.boolean())
                    rare[random.uintLessThan(usize, rare_count)]
                else
                    moves.items()[random.uintLessThan(usize, moves.len)];
                support.play(pos, move);
                played[count] = move;
                count += 1;
                try expect_accumulators_rebuilt(pos);

                if (random.uintLessThan(u8, 8) == 0) {
                    for (0..random.uintAtMost(usize, @min(count, 6))) |_| {
                        count -= 1;
                        support.undo(pos, played[count]);
                        try expect_accumulators_rebuilt(pos);
                    }
                }
            }
        }
    }
}

fn zeroed_single_network() ![]u8 {
    const single = try std.testing.allocator.alloc(u8, @sizeOf(weights.Network(.single)));
    @memset(single, 0);
    return single;
}

const HEADER_FORMAT_VERSION_OFFSET = weights.MAGIC.len;
const HEADER_L1_OUTPUTS_OFFSET = weights.MAGIC.len + 5 * @sizeOf(u32);

test "multi net: the loaders reject the other architecture and damaged files" {
    if (weights.NUM_INPUT_BUCKETS != 16) return error.SkipZigTest;
    support.init_tables();
    const net = try random_network(0x5eed_0004, .full);
    defer std.testing.allocator.destroy(net);
    const multi = std.mem.asBytes(net);
    const single = try zeroed_single_network();
    defer std.testing.allocator.free(single);

    try weights.validate_as(.multi, multi);
    try weights.validate_as(.single, single);
    try expectError(weights.NetworkError.WrongArchitecture, weights.validate_as(.single, multi));
    try expectError(weights.NetworkError.WrongArchitecture, weights.validate_as(.multi, single));
    try expectError(weights.NetworkError.NotANetwork, weights.validate_as(.multi, ""));
    try expectError(weights.NetworkError.NotANetwork, weights.validate_as(.multi, "not a network"));
    try expectError(weights.NetworkError.NotANetwork, weights.validate_as(.multi, single[0 .. single.len - 64]));
    try expectError(weights.NetworkError.WrongSize, weights.validate_as(.single, "not a network"));
    try expect(std.mem.find(u8, weights.explain(weights.NetworkError.NotANetwork), "-Dhead") == null);
    try expectError(weights.NetworkError.UnsupportedHeader, weights.validate_as(.multi, weights.MAGIC));
    try expectError(weights.NetworkError.WrongSize, weights.validate_as(.multi, multi[0 .. multi.len - 64]));

    for ([_]usize{ HEADER_FORMAT_VERSION_OFFSET, HEADER_L1_OUTPUTS_OFFSET }) |field| {
        net.header[field] += 1;
        try expectError(weights.NetworkError.UnsupportedHeader, weights.validate_as(.multi, multi));
        net.header[field] -= 1;
    }
    const shift_field = net.header[weights.L1_SHIFT_OFFSET..][0..4];
    for (0..@as(usize, head_multi.L1_SHIFT_MAX) + 1) |shift| {
        std.mem.writeInt(u32, shift_field, @intCast(shift), .little);
        try weights.validate_as(.multi, multi);
        try expectEqual(shift, @as(usize, weights.l1_shift(&net.header)));
    }
    for ([_]u32{ @as(u32, head_multi.L1_SHIFT_MAX) + 1, 256, 1 << 31 }) |shift| {
        std.mem.writeInt(u32, shift_field, shift, .little);
        try expectError(weights.NetworkError.UnsupportedHeader, weights.validate_as(.multi, multi));
    }
    std.mem.writeInt(u32, shift_field, 0, .little);

    net.head.l2_weights[0][0][0] = head_multi.WEIGHT_LIMIT + 1;
    try expectError(weights.NetworkError.WeightOutOfRange, weights.validate_as(.multi, multi));
    net.head.l2_weights[0][0][0] = 0;
    try weights.validate_as(.multi, multi);
}

test "multi net: EvalFile reports a network of the other architecture and keeps the current one" {
    if (weights.NUM_INPUT_BUCKETS != 16) return error.SkipZigTest;
    support.init_tables();
    const net = try random_network(0x5eed_0004, .full);
    defer std.testing.allocator.destroy(net);
    const single = try zeroed_single_network();
    defer std.testing.allocator.free(single);

    platform.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const other: []const u8 = if (weights.HEAD == .single) std.mem.asBytes(net) else single;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.nnue", .data = other });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPathFile(std.testing.io, "other.nnue", &path_buf)];

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.KIWIPETE_FEN);
    const before = support.network_output(pos);
    var settings: options.Settings = .{};
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var args_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    try options.set_option(try std.mem.print(&args_buf, "name EvalFile value {s}", .{path}), .{ .settings = &settings, .position = pos, .out = &out });
    try expect(std.mem.find(u8, out.buffered(), "WrongArchitecture") != null);
    try expect(std.mem.find(u8, out.buffered(), "-Dhead=") != null);
    try expectEqual(before, support.network_output(pos));
    try std.testing.expectEqualStrings(@import("build_options").net_name, weights.active_network());
}

test "nnue tools: a command that is none of the three prints the usage and fails" {
    for ([_][]const u8{ "nnue-partiy", "nnue-", "nnue-speed-x", "nnue-help" }) |name| {
        var buffer: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try expect(parity.execute(name, &.{}, &out) != 0);
        try expect(std.mem.find(u8, out.buffered(), name) != null);
        try expect(std.mem.find(u8, out.buffered(), "usage: nnue-parity") != null);
    }
}

test "nnue tools: the speed checksum is the sum of the evaluations, and digits when that is negative" {
    var checksum: u64 = 0;
    for ([_]i32{ 300, -100, 50 }) |evaluation| checksum = parity.add_to_checksum(checksum, evaluation);
    try expectEqual(@as(u64, 250), checksum);

    checksum = parity.add_to_checksum(checksum, -251);
    var buffer: [32]u8 = undefined;
    const printed = try std.mem.print(&buffer, "{d}", .{checksum});
    for (printed) |character| try expect(std.ascii.isDigit(character));
}
