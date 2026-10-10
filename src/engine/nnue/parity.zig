//! See "Parity" in docs/NNUE.md.

const std = @import("std");
const platform = @import("../../platform.zig");
const types = @import("../../chess/types.zig");
const position = @import("../../chess/position.zig");
const weights = @import("../weights.zig");
const hce = @import("../hce.zig");
const bench = @import("../bench.zig");
const arch = @import("arch.zig");
const head_multi = @import("head_multi.zig");

pub const Net = weights.Network(.multi);

const FeatureWeights = [weights.INPUT_SIZE * arch.HIDDEN_SIZE]i16;

const BUCKET_LAYOUT_16: [32]usize = .{
    0,  1,  2,  3,
    4,  5,  6,  7,
    8,  8,  9,  9,
    10, 10, 11, 11,
    12, 12, 13, 13,
    12, 12, 13, 13,
    14, 14, 15, 15,
    14, 14, 15, 15,
};

pub fn accumulate(layer_1: *const FeatureWeights, layer_1_bias: *const arch.Accumulator, pos: *const position.Position, perspective: types.Color, out: *arch.Accumulator) void {
    const rank_flip: usize = if (perspective == types.Color.White) 0 else 56;
    var king: usize = 0;
    for (pos.mailbox, 0..) |piece, sq| {
        if (piece == types.Piece.new(perspective, types.PieceType.King)) king = sq ^ rank_flip;
    }
    const bucketed = weights.NUM_INPUT_BUCKETS > 1;
    const mirrored = bucketed and king % 8 > 3;
    const bucket = if (bucketed) BUCKET_LAYOUT_16[(king / 8) * 4 + (if (mirrored) 7 - king % 8 else king % 8)] else 0;

    out.* = layer_1_bias.*;
    for (pos.mailbox, 0..) |piece, sq| {
        if (piece == types.Piece.NO_PIECE) continue;
        const side: usize = if (piece.color() == perspective) 0 else arch.FEATURES_PER_COLOR;
        const oriented = sq ^ rank_flip ^ @as(usize, if (mirrored) 7 else 0);
        const feature = bucket * arch.FEATURES_PER_BUCKET + side + arch.FEATURES_PER_PIECE * @as(usize, piece.piece_type().index()) + oriented;
        for (out, layer_1[feature * arch.HIDDEN_SIZE ..][0..arch.HIDDEN_SIZE]) |*sum, weight| sum.* +%= weight;
    }
}

pub fn output_bucket(pos: *const position.Position) usize {
    return arch.output_bucket(@popCount(pos.all_all_pieces()));
}

pub const FloatMode = enum { exact_pairwise, quantised_pairwise };

pub fn evaluate_float(head: *const head_multi.Weights, l1_shift: head_multi.L1Shift, own: arch.AccumulatorPtr, opp: arch.AccumulatorPtr, bucket: usize, mode: FloatMode) f64 {
    const shifted: f64 = @floatFromInt(@as(u32, 1) << l1_shift);
    const one: f64 = @as(f64, @floatFromInt(head_multi.ONE)) * shifted;
    const l1_weight_one = head_multi.L1_WEIGHT_SCALE * shifted;
    const qa: f64 = @floatFromInt(arch.QA);

    var z1: [head_multi.L1_SIZE]f64 = undefined;
    for (&z1, head.l1_bias[bucket]) |*sum, bias| sum.* = @as(f64, @floatFromInt(bias)) / one;
    for ([_]arch.AccumulatorPtr{ own, opp }, 0..) |acc, side| {
        for (0..head_multi.PAIRS) |i| {
            const activation: f64 = switch (mode) {
                .exact_pairwise => blk: {
                    const a: f64 = @floatFromInt(std.math.clamp(acc[i], 0, arch.QA));
                    const b: f64 = @floatFromInt(std.math.clamp(acc[i + head_multi.PAIRS], 0, arch.QA));
                    break :blk (a / qa) * (b / qa);
                },
                .quantised_pairwise => @as(f64, @floatFromInt(head_multi.pairwise(acc[i], acc[i + head_multi.PAIRS]))) / head_multi.PAIRWISE_ONE,
            };
            const input = side * head_multi.PAIRS + i;
            for (&z1, &head.l1_weights[bucket][input / 4]) |*sum, *block_weights| {
                sum.* += activation * @as(f64, @floatFromInt(block_weights[input % 4])) / l1_weight_one;
            }
        }
    }
    return evaluate_float_from_l1(head, bucket, z1);
}

pub fn evaluate_float_from_l1(head: *const head_multi.Weights, bucket: usize, z1: [head_multi.L1_SIZE]f64) f64 {
    const weight_one: f64 = @floatFromInt(1 << head_multi.WEIGHT_BITS);
    const sum_one: f64 = @floatFromInt(1 << head_multi.SUM_BITS);

    var hidden: [head_multi.L2_INPUTS]f64 = undefined;
    for (z1, 0..) |sum, j| {
        const clipped = std.math.clamp(sum, 0.0, 1.0);
        hidden[j] = clipped;
        hidden[head_multi.L1_SIZE + j] = clipped * clipped;
    }

    var output: f64 = @as(f64, @floatFromInt(head.l3_bias[bucket])) / sum_one;
    for (0..head_multi.L2_SIZE) |o| {
        var sum: f64 = @as(f64, @floatFromInt(head.l2_bias[bucket][o])) / sum_one;
        for (hidden, &head.l2_weights[bucket]) |input, *column| {
            sum += input * @as(f64, @floatFromInt(column[o])) / weight_one;
        }
        output += std.math.clamp(sum, 0.0, 1.0) * @as(f64, @floatFromInt(head.l3_weights[bucket][o])) / weight_one;
    }
    return output * @as(f64, @floatFromInt(arch.SCALE));
}

pub const Evaluation = struct {
    integer: i32,
    float: f64,
    float_quantised_pairwise: f64,
};

pub fn evaluate(net: *const Net, pos: *const position.Position) Evaluation {
    var white: arch.Accumulator align(64) = undefined;
    var black: arch.Accumulator align(64) = undefined;
    accumulate(&net.layer_1, &net.layer_1_bias, pos, types.Color.White, &white);
    accumulate(&net.layer_1, &net.layer_1_bias, pos, types.Color.Black, &black);
    const own = if (pos.turn == types.Color.White) &white else &black;
    const opp = if (pos.turn == types.Color.White) &black else &white;
    const bucket = output_bucket(pos);
    const shift = weights.l1_shift(&net.header);
    return .{
        .integer = head_multi.evaluate(&net.head, &.init(&net.head, shift), own, opp, bucket),
        .float = evaluate_float(&net.head, shift, own, opp, bucket, .exact_pairwise),
        .float_quantised_pairwise = evaluate_float(&net.head, shift, own, opp, bucket, .quantised_pairwise),
    };
}

pub const Difference = struct {
    max: f64 = 0,
    sum: f64 = 0,
    count: usize = 0,

    pub fn add(self: *Difference, a: f64, b: f64) void {
        const diff = @abs(a - b);
        self.max = @max(self.max, diff);
        self.sum += diff;
        self.count += 1;
    }

    pub fn mean(self: Difference) f64 {
        return if (self.count == 0) 0 else self.sum / @as(f64, @floatFromInt(self.count));
    }
};

pub const RandomRange = struct {
    l1_weight: i8,
    l1_shift: head_multi.L1Shift,
    weight: i32,
    unshifted_l1_bias: i32,
    bias: i32,

    pub const full: RandomRange = .{
        .l1_weight = 127,
        .l1_shift = 0,
        .weight = head_multi.WEIGHT_LIMIT,
        .unshifted_l1_bias = head_multi.ONE,
        .bias = 1 << head_multi.SUM_BITS,
    };

    pub const trained_magnitude: RandomRange = .{
        .l1_weight = 96,
        .l1_shift = 3,
        .weight = 400,
        .unshifted_l1_bias = head_multi.ONE / 2,
        .bias = 1 << (head_multi.SUM_BITS - 2),
    };
};

pub fn fill_random_head(head: *head_multi.Weights, random: std.Random, range: RandomRange) void {
    for (std.mem.asBytes(&head.l1_weights)) |*byte| {
        byte.* = @bitCast(random.intRangeAtMost(i8, -range.l1_weight, range.l1_weight));
    }
    inline for (.{ "l2_weights", "l3_weights", "l1_bias", "l2_bias", "l3_bias" }, .{ range.weight, range.weight, range.unshifted_l1_bias << range.l1_shift, range.bias, range.bias }) |field, limit| {
        const values: *[@sizeOf(@FieldType(head_multi.Weights, field)) / 4]i32 = @ptrCast(&@field(head, field));
        for (values) |*value| value.* = random.intRangeAtMost(i32, -limit, limit);
    }
}

const RANDOM_FT_WEIGHT = 48;

pub const Activity = enum {
    dense,
    sparse,

    fn feature_bias_range(self: Activity) [2]i16 {
        return switch (self) {
            .dense => .{ 0, 128 },
            .sparse => .{ -144, -16 },
        };
    }
};

pub fn fill_random(net: *Net, random: std.Random, range: RandomRange, activity: Activity) void {
    @memset(std.mem.asBytes(net), 0);
    net.header = weights.multi_header(range.l1_shift);
    for (&net.layer_1) |*weight| weight.* = random.intRangeAtMost(i16, -RANDOM_FT_WEIGHT, RANDOM_FT_WEIGHT);
    const bias_range = activity.feature_bias_range();
    for (&net.layer_1_bias) |*bias| bias.* = random.intRangeAtMost(i16, bias_range[0], bias_range[1]);
    fill_random_head(&net.head, random, range);
}

fn load(path: []const u8) !*Net {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(platform.io, path, platform.allocator, .limited(@sizeOf(Net) + 1));
    defer platform.allocator.free(bytes);
    try weights.validate_as(.multi, bytes);
    const net = try platform.allocator.create(Net);
    @memcpy(std.mem.asBytes(net), bytes);
    return net;
}

const USAGE =
    \\usage: nnue-parity <net> [positions|bench] [verbose]
    \\                                       compare the integer head with the float forward pass
    \\       nnue-random <out> [seed] [full] [sparse]
    \\                                       write a random multi-layer network (full = whole weight
    \\                                       range, sparse = few non-zero pairwise activations)
    \\       nnue-speed                      time this build's head on the bench positions
    \\
    \\positions: one FEN per line, optionally followed by "| <centipawns>", the
    \\trainer's own evaluation of that position (training/: TRAIN_PARITY_FENS).
    \\"bench", or nothing, is the bench positions. verbose prints, per position,
    \\"fen | integer | float | float with quantised pairwise".
    \\
;

const Line = struct { fen: []const u8, expected: ?f64 };

fn parse_line(raw: []const u8) ?Line {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    var parts = std.mem.splitScalar(u8, line, '|');
    const fen = std.mem.trim(u8, parts.first(), " \t");
    const expected = if (parts.next()) |text| std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch null else null;
    return .{ .fen = fen, .expected = expected };
}

const Positions = struct {
    lines: std.ArrayList(Line) = .empty,
    file: ?[]u8 = null,

    const BENCH = "bench";
    const MAX_FILE_BYTES = 1 << 30;

    fn read(source: []const u8) !Positions {
        var self: Positions = .{};
        errdefer self.deinit();
        if (std.mem.eql(u8, source, BENCH)) {
            for (bench.FENS) |fen| try self.lines.append(platform.allocator, .{ .fen = fen, .expected = null });
            return self;
        }
        const file = try std.Io.Dir.cwd().readFileAlloc(platform.io, source, platform.allocator, .limited(MAX_FILE_BYTES));
        self.file = file;
        var raw_lines = std.mem.splitScalar(u8, file, '\n');
        while (raw_lines.next()) |raw| {
            if (parse_line(raw)) |line| try self.lines.append(platform.allocator, line);
        }
        return self;
    }

    fn deinit(self: *Positions) void {
        self.lines.deinit(platform.allocator);
        if (self.file) |file| platform.allocator.free(file);
    }
};

const Measurement = struct {
    float: Difference = .{},
    float_quantised_pairwise: Difference = .{},
    trainer_evaluations: Difference = .{},
    magnitude: Difference = .{},
    incremental_mismatches: usize = 0,
};

fn measure(net: *const Net, lines: []const Line, compare_incremental: bool, verbose: ?*std.Io.Writer) !Measurement {
    const pos = try platform.allocator.create(position.Position);
    defer platform.allocator.destroy(pos);
    pos.init();
    defer pos.deinit();

    var measured: Measurement = .{};
    for (lines) |line| {
        pos.set_fen(line.fen);
        const result = evaluate(net, pos);
        const integer: f64 = @floatFromInt(result.integer);
        measured.float.add(integer, result.float);
        measured.float_quantised_pairwise.add(integer, result.float_quantised_pairwise);
        measured.magnitude.add(integer, 0);
        if (line.expected) |value| measured.trainer_evaluations.add(integer, value);
        if (verbose) |out| try out.print("{s} | {d} | {d:.3} | {d:.3}\n", .{ line.fen, result.integer, result.float, result.float_quantised_pairwise });
        if (compare_incremental and hce.evaluate_nnue(pos) != result.integer) measured.incremental_mismatches += 1;
    }
    return measured;
}

fn max_abs(values: []const i32) u32 {
    var result: u32 = 0;
    for (values) |value| result = @max(result, @abs(value));
    return result;
}

fn report_parity(path: []const u8, net: *const Net, measured: *const Measurement, compare_incremental: bool, out: *std.Io.Writer) !void {
    try out.print("nnue-parity: {s}, {d} positions, mean |eval| {d:.1} cp, max |eval| {d:.1} cp\n", .{ path, measured.magnitude.count, measured.magnitude.mean(), measured.magnitude.max });
    try out.print("  integer vs float forward pass:        max {d:.3} cp, mean {d:.3} cp\n", .{ measured.float.max, measured.float.mean() });
    try out.print("  integer vs float, quantised pairwise: max {d:.3} cp, mean {d:.3} cp\n", .{ measured.float_quantised_pairwise.max, measured.float_quantised_pairwise.mean() });
    var l1_max: u32 = 0;
    for (std.mem.asBytes(&net.head.l1_weights)) |byte| l1_max = @max(l1_max, @abs(@as(i32, @as(i8, @bitCast(byte)))));
    try out.print("  L1 shift {d}; largest stored weight:    l1 {d}/127, l2 {d}/{d}, l3 {d}/{d}\n", .{
        weights.l1_shift(&net.header),
        l1_max,
        max_abs(std.mem.bytesAsSlice(i32, std.mem.asBytes(&net.head.l2_weights))),
        head_multi.WEIGHT_LIMIT,
        max_abs(std.mem.bytesAsSlice(i32, std.mem.asBytes(&net.head.l3_weights))),
        head_multi.WEIGHT_LIMIT,
    });
    if (measured.trainer_evaluations.count > 0) {
        try out.print("  integer vs trainer evaluations:       max {d:.3} cp, mean {d:.3} cp ({d} positions)\n", .{ measured.trainer_evaluations.max, measured.trainer_evaluations.mean(), measured.trainer_evaluations.count });
    }
    if (compare_incremental) {
        try out.print("  engine incremental evaluation:        {d} mismatches\n", .{measured.incremental_mismatches});
    }
}

fn run_parity(args: []const []const u8, out: *std.Io.Writer) !u8 {
    if (args.len < 1) {
        try out.writeAll(USAGE);
        return 1;
    }
    const path = args[0];
    const net = load(path) catch |err| {
        try out.print("nnue-parity: cannot use '{s}' ({s}): docs/NNUE.md specifies the multi-layer file\n", .{ path, @errorName(err) });
        return 1;
    };
    defer platform.allocator.destroy(net);

    const source = if (args.len >= 2) args[1] else Positions.BENCH;
    var positions = Positions.read(source) catch |err| {
        try out.print("nnue-parity: cannot read '{s}' ({s})\n", .{ source, @errorName(err) });
        return 1;
    };
    defer positions.deinit();

    const compare_incremental = weights.HEAD == .multi and weights.supports_eval_file;
    if (compare_incremental) try weights.load(path);

    const verbose = args.len >= 3 and std.mem.eql(u8, args[2], "verbose");
    const measured = try measure(net, positions.lines.items, compare_incremental, if (verbose) out else null);
    try report_parity(path, net, &measured, compare_incremental, out);
    return if (measured.incremental_mismatches == 0) 0 else 1;
}

fn run_random(args: []const []const u8, out: *std.Io.Writer) !u8 {
    if (args.len < 1) {
        try out.writeAll(USAGE);
        return 1;
    }
    var seed: u64 = 1;
    var range: RandomRange = .trained_magnitude;
    var activity: Activity = .dense;
    for (args[1..], 1..) |arg, index| {
        if (std.mem.eql(u8, arg, "full")) {
            range = .full;
        } else if (std.mem.eql(u8, arg, "sparse")) {
            activity = .sparse;
        } else if (index == 1) {
            seed = std.fmt.parseInt(u64, arg, 10) catch {
                try out.print("nnue-random: '{s}' is not a seed, 'full' or 'sparse'\n", .{arg});
                return 1;
            };
        } else {
            try out.print("nnue-random: unknown option '{s}'\n", .{arg});
            return 1;
        }
    }
    const net = try platform.allocator.create(Net);
    defer platform.allocator.destroy(net);
    var prng = std.Random.DefaultPrng.init(seed);
    fill_random(net, prng.random(), range, activity);
    try std.Io.Dir.cwd().writeFile(platform.io, .{ .sub_path = args[0], .data = std.mem.asBytes(net) });
    try out.print("nnue-random: wrote {s} ({d} bytes, seed {d})\n", .{ args[0], @sizeOf(Net), seed });
    return 0;
}

const SPEED_ROUNDS = 40_000;
const STAGE_BATCH = 4;

const SpeedSample = struct {
    white: arch.Accumulator align(64),
    black: arch.Accumulator align(64),
    bucket: usize,
    activations: head_multi.Activations align(64) = undefined,
    indices: head_multi.BlockIndices = undefined,
    sums: head_multi.L1Vector = undefined,
};

const MultiStage = enum {
    pairwise,
    nonzero_search,
    l1,
    l2_l3,

    fn run(comptime self: MultiStage, sample: *SpeedSample) void {
        const head = &weights.MODEL.head;
        switch (self) {
            .pairwise => {
                head_multi.activate(&sample.white, &sample.black, &sample.activations);
                std.mem.doNotOptimizeAway(&sample.activations);
            },
            .nonzero_search => std.mem.doNotOptimizeAway(head_multi.nonzero_blocks(&sample.activations, &sample.indices)),
            .l1 => {
                sample.sums = head_multi.l1_sums(head, &sample.activations, sample.bucket);
                std.mem.doNotOptimizeAway(&sample.sums);
            },
            .l2_l3 => std.mem.doNotOptimizeAway(head_multi.finish(head, &weights.prepared, sample.bucket, sample.sums)),
        }
    }

    fn nanoseconds(comptime self: MultiStage, samples: []SpeedSample) f64 {
        const timer = types.Timer.start();
        var first: usize = 0;
        while (first < samples.len) : (first += STAGE_BATCH) {
            const batch = samples[first..@min(first + STAGE_BATCH, samples.len)];
            for (0..SPEED_ROUNDS) |_| {
                for (batch) |*sample| self.run(sample);
            }
        }
        return @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(SPEED_ROUNDS * samples.len));
    }
};

fn report_multi_stages(samples: []SpeedSample, out: *std.Io.Writer) !void {
    // In this order: a stage reads what the one before it left in the samples.
    const pairwise = MultiStage.pairwise.nanoseconds(samples);
    const nonzero_search = MultiStage.nonzero_search.nanoseconds(samples);
    const l1 = MultiStage.l1.nanoseconds(samples);
    const l2_l3 = MultiStage.l2_l3.nanoseconds(samples);

    var nonzero: usize = 0;
    for (samples) |*sample| nonzero += head_multi.nonzero_blocks(&sample.activations, &sample.indices);
    try out.print("nnue-speed: {s}; {d:.1} of {d} L1 blocks non-zero\n", .{
        head_multi.SIMD_DESCRIPTION,
        @as(f64, @floatFromInt(nonzero)) / @as(f64, @floatFromInt(samples.len)),
        head_multi.L1_BLOCKS,
    });
    try out.print("nnue-speed: stages, inputs in cache: pairwise {d:.1} ns, L1 {d:.1} ns (of which the non-zero search {d:.1} ns), L2 and L3 {d:.1} ns\n", .{ pairwise, l1, nonzero_search, l2_l3 });
}

pub fn add_to_checksum(checksum: u64, evaluation: i32) u64 {
    return checksum +% @as(u64, @bitCast(@as(i64, evaluation)));
}

fn run_speed(out: *std.Io.Writer) !u8 {
    const samples = try platform.allocator.alloc(SpeedSample, bench.FENS.len);
    defer platform.allocator.free(samples);

    const pos = try platform.allocator.create(position.Position);
    defer platform.allocator.destroy(pos);
    pos.init();
    defer pos.deinit();
    for (bench.FENS, samples) |fen, *sample| {
        pos.set_fen(fen);
        sample.* = .{ .white = undefined, .black = undefined, .bucket = output_bucket(pos) };
        accumulate(&weights.MODEL.layer_1, &weights.MODEL.layer_1_bias, pos, types.Color.White, &sample.white);
        accumulate(&weights.MODEL.layer_1, &weights.MODEL.layer_1_bias, pos, types.Color.Black, &sample.black);
    }

    var checksum: u64 = 0;
    const timer = types.Timer.start();
    for (0..SPEED_ROUNDS) |_| {
        for (samples) |*sample| {
            checksum = add_to_checksum(checksum, weights.evaluate(&sample.white, &sample.black, sample.bucket));
        }
    }
    const elapsed = timer.read();
    const evals = SPEED_ROUNDS * samples.len;
    try out.print("nnue-speed: {s} head, {d} evaluations, {d:.1} ns each, {d} per second (checksum {d})\n", .{
        @tagName(weights.HEAD),
        evals,
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(evals)),
        evals * std.time.ns_per_s / elapsed,
        checksum,
    });
    if (comptime weights.HEAD == .multi) try report_multi_stages(samples, out);
    return 0;
}

const COMMAND_PREFIX = "nnue-";
const Command = enum { parity, random, speed };

fn parse_command(name: []const u8) ?Command {
    if (!std.mem.startsWith(u8, name, COMMAND_PREFIX)) return null;
    return std.meta.stringToEnum(Command, name[COMMAND_PREFIX.len..]);
}

pub fn execute(name: []const u8, args: []const []const u8, out: *std.Io.Writer) u8 {
    const command = parse_command(name) orelse {
        out.print("{s}: unknown command\n{s}", .{ name, USAGE }) catch {};
        return 1;
    };
    const result = switch (command) {
        .parity => run_parity(args, out),
        .random => run_random(args, out),
        .speed => run_speed(out),
    };
    return result catch |err| {
        out.print("{s}: {s}\n", .{ name, @errorName(err) }) catch {};
        return 2;
    };
}

pub fn run(name: []const u8, args: []const []const u8) u8 {
    var buffer: [1024]u8 = undefined;
    var stdout = platform.Stdout.init(&buffer);
    const out = stdout.writer();
    const code = execute(name, args, out);
    out.flush() catch {};
    return code;
}
