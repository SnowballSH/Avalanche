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
    for (0..6) |net| {
        // Even rounds use the whole validated range, including its extremes.
        head_multi.fill_random(head, random, if (net % 2 == 0) .{} else parity.REALISTIC_RANGE);
        try head_multi.validate(std.mem.asBytes(head));
        for (0..400) |round| {
            const acc = random_accumulators(random, round);
            const bucket = round % arch.OUTPUT_SIZE;
            const scalar = head_multi.evaluate_scalar(head, &acc.own, &acc.opp, bucket);
            try expectEqual(scalar, head_multi.evaluate_simd(head, &acc.own, &acc.opp, bucket));
            try expectEqual(scalar, head_multi.evaluate(head, &acc.own, &acc.opp, bucket));
            try distinct.put(scalar, {});
        }
    }
    // The comparison would be empty if the head saturated to a few values.
    try expect(distinct.count() > 1000);
}

test "multi head: the SIMD comparison covers an L1 intrinsic path" {
    // Skipped, so that the summary shows it, when this build only has the
    // portable L1: Debug builds, wasm, and x86 without SSSE3. The comparison
    // above then says nothing about pmaddubsw or sdot; run it again with
    // -Doptimize=ReleaseSafe.
    if (head_multi.L1_PATH == .portable) return error.SkipZigTest;
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
        const scalar = head_multi.evaluate_scalar(head, &acc.own, &acc.opp, 0);
        try expectEqual(scalar, head_multi.evaluate_simd(head, &acc.own, &acc.opp, 0));
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
    for (0..8) |_| {
        head_multi.fill_random(head, random, parity.REALISTIC_RANGE);
        for (0..250) |round| {
            // Dense rounds only: `random.int(i16)` rounds are all 0 or 255.
            const acc = random_accumulators(random, round % 3);
            const bucket = round % arch.OUTPUT_SIZE;
            const engine: f64 = @floatFromInt(head_multi.evaluate(head, &acc.own, &acc.opp, bucket));
            trainer.add(engine, head_multi.evaluate_float(head, &acc.own, &acc.opp, bucket, .trainer));
            quantised.add(engine, head_multi.evaluate_float(head, &acc.own, &acc.opp, bucket, .quantised_pairwise));
            magnitude.add(engine, 0);
        }
    }

    // Tolerances, in centipawns; docs/NNUE.md derives them. A wrong layout or
    // formula is off by the spread of the evaluations, hundreds of centipawns.
    try expect(magnitude.mean() > 50);
    try expect(quantised.max <= head_multi.QUANTISED_TOLERANCE_CP);
    try expect(trainer.max <= head_multi.TRAINER_TOLERANCE_CP);
}

fn random_network(seed: u64, range: head_multi.RandomRange) !*parity.Net {
    const net = try std.testing.allocator.create(parity.Net);
    var prng = std.Random.DefaultPrng.init(seed);
    parity.fill_random(net, prng.random(), range);
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
        std.mem.sliceAsBytes(&[_]u32{ 1, 1, 16, 1024, 8, 16, 32, 255, 9, 13, 10, 400, 0, 0 }),
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
