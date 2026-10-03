//! Parity checks for multi-layer networks: evaluates positions from a network
//! file with the engine's integer head and with a floating-point forward pass
//! reconstructed from the same file, and reports the difference.
//!
//! It works in every build: accumulators are rebuilt here from the file, with
//! the feature indexing of bullet's `ChessBucketsMirrored`, rather than taken
//! from the engine's incremental ones. docs/NNUE.md describes the commands.

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

/// The trainer's `BUCKET_LAYOUT_16`: king bucket by rank and by file a..d.
const KING_BUCKETS: [32]usize = .{
    0,  1,  2,  3,
    4,  5,  6,  7,
    8,  8,  9,  9,
    10, 10, 11, 11,
    12, 12, 13, 13,
    12, 12, 13, 13,
    14, 14, 15, 15,
    14, 14, 15, 15,
};

/// One perspective's accumulator, summed feature by feature. `net` is any
/// network with `layer_1` and `layer_1_bias`.
pub fn accumulate(net: anytype, pos: *const position.Position, perspective: types.Color, out: *arch.Accumulator) void {
    const rank_flip: usize = if (perspective == types.Color.White) 0 else 56;
    var king: usize = 0;
    for (pos.mailbox, 0..) |piece, sq| {
        if (piece == types.Piece.new(perspective, types.PieceType.King)) king = sq ^ rank_flip;
    }
    const bucketed = weights.NUM_INPUT_BUCKETS > 1;
    const mirrored = bucketed and king % 8 > 3;
    const bucket = if (bucketed) KING_BUCKETS[(king / 8) * 4 + (if (mirrored) 7 - king % 8 else king % 8)] else 0;

    out.* = net.layer_1_bias;
    for (pos.mailbox, 0..) |piece, sq| {
        if (piece == types.Piece.NO_PIECE) continue;
        const side: usize = if (piece.color() == perspective) 0 else 384;
        const oriented = sq ^ rank_flip ^ @as(usize, if (mirrored) 7 else 0);
        const feature = bucket * 768 + side + 64 * @as(usize, piece.piece_type().index()) + oriented;
        for (out, net.layer_1[feature * arch.HIDDEN_SIZE ..][0..arch.HIDDEN_SIZE]) |*sum, weight| sum.* += weight;
    }
}

pub const Evaluation = struct {
    /// The engine's integer head, in centipawns for the side to move.
    engine: i32,
    /// The trainer's forward pass in floating point, from the same quantised weights.
    trainer: f64,
    /// As `trainer`, but from the pairwise products the engine computes.
    quantised: f64,
};

pub fn evaluate(net: *const Net, pos: *const position.Position) Evaluation {
    var white: arch.Accumulator align(64) = undefined;
    var black: arch.Accumulator align(64) = undefined;
    accumulate(net, pos, types.Color.White, &white);
    accumulate(net, pos, types.Color.Black, &black);
    const own = if (pos.turn == types.Color.White) &white else &black;
    const opp = if (pos.turn == types.Color.White) &black else &white;
    const pieces = types.popcount_usize(pos.all_all_pieces());
    const bucket = @min((pieces -| 2) / 4, arch.OUTPUT_SIZE - 1);
    const shift = weights.l1_shift(&net.header);
    return .{
        .engine = head_multi.evaluate(&net.head, &.init(&net.head, shift), own, opp, bucket),
        .trainer = head_multi.evaluate_float(&net.head, shift, own, opp, bucket, .trainer),
        .quantised = head_multi.evaluate_float(&net.head, shift, own, opp, bucket, .quantised_pairwise),
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

/// How feature-transformer weights are drawn by `fill_random`: small enough
/// that 32 pieces cannot overflow an i16 accumulator.
const RANDOM_FT_WEIGHT = 48;

/// How many pairwise activations of a random network are non-zero, which is
/// what the cost of the sparse L1 depends on.
pub const Activity = enum {
    /// About nine L1 blocks in ten are non-zero on the bench positions.
    dense,
    /// About one in four, as a sparsity penalty in training aims for.
    sparse,

    /// Range of the feature-transformer biases: the lower they are, the fewer
    /// accumulator values are positive.
    fn bias_range(self: Activity) [2]i16 {
        return switch (self) {
            .dense => .{ 0, 128 },
            .sparse => .{ -144, -16 },
        };
    }
};

/// A random network with a valid header. `range` bounds the head's weights.
pub fn fill_random(net: *Net, random: std.Random, range: head_multi.RandomRange, activity: Activity) void {
    @memset(std.mem.asBytes(net), 0);
    net.header = weights.multi_header(range.l1_shift);
    for (&net.layer_1) |*weight| weight.* = random.intRangeAtMost(i16, -RANDOM_FT_WEIGHT, RANDOM_FT_WEIGHT);
    const bias_range = activity.bias_range();
    for (&net.layer_1_bias) |*bias| bias.* = random.intRangeAtMost(i16, bias_range[0], bias_range[1]);
    head_multi.fill_random(&net.head, random, range);
}

/// Head weights of the magnitude a trained network has, where the comparison
/// with the float forward pass is meaningful: with weights spread over the
/// whole integer range the rounding of 1024 activations is amplified to
/// hundreds of centipawns in both directions.
pub const REALISTIC_RANGE: head_multi.RandomRange = .{
    // As the trainer saves such a net: |w| <= 0.19, stored with three extra bits.
    .l1_weight = 96,
    .l1_shift = 3,
    .weight = 400,
    .l1_bias = head_multi.ONE / 2,
    .bias = 1 << (head_multi.SUM_BITS - 2),
};

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

fn max_abs(values: []const i32) u32 {
    var result: u32 = 0;
    for (values) |value| result = @max(result, @abs(value));
    return result;
}

fn run_parity(args: []const []const u8, out: *std.Io.Writer) !u8 {
    if (args.len < 1) {
        try out.writeAll(USAGE);
        return 1;
    }
    const net = load(args[0]) catch |err| {
        try out.print("nnue-parity: cannot use '{s}' ({s}): docs/NNUE.md specifies the multi-layer file\n", .{ args[0], @errorName(err) });
        return 1;
    };
    defer platform.allocator.destroy(net);

    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(platform.allocator);
    var file_bytes: ?[]u8 = null;
    defer if (file_bytes) |bytes| platform.allocator.free(bytes);
    if (args.len >= 2 and !std.mem.eql(u8, args[1], "bench")) {
        file_bytes = std.Io.Dir.cwd().readFileAlloc(platform.io, args[1], platform.allocator, .limited(1 << 30)) catch |err| {
            try out.print("nnue-parity: cannot read '{s}' ({s})\n", .{ args[1], @errorName(err) });
            return 1;
        };
        var it = std.mem.splitScalar(u8, file_bytes.?, '\n');
        while (it.next()) |raw| {
            if (parse_line(raw)) |line| try lines.append(platform.allocator, line);
        }
    } else {
        for (bench.FENS) |fen| try lines.append(platform.allocator, .{ .fen = fen, .expected = null });
    }

    // In a multi-layer build, also check the engine's incremental evaluation.
    const check_engine = weights.HEAD == .multi and weights.supports_eval_file;
    if (check_engine) try weights.load(args[0]);

    const pos = try platform.allocator.create(position.Position);
    defer platform.allocator.destroy(pos);
    pos.init();
    defer pos.deinit();

    const verbose = args.len >= 3 and std.mem.eql(u8, args[2], "verbose");
    var trainer: Difference = .{};
    var quantised: Difference = .{};
    var expected: Difference = .{};
    var magnitude: Difference = .{};
    var engine_mismatches: usize = 0;
    for (lines.items) |line| {
        pos.set_fen(line.fen);
        const result = evaluate(net, pos);
        const engine: f64 = @floatFromInt(result.engine);
        trainer.add(engine, result.trainer);
        quantised.add(engine, result.quantised);
        magnitude.add(engine, 0);
        if (line.expected) |value| expected.add(engine, value);
        if (verbose) try out.print("{s} | {d} | {d:.3} | {d:.3}\n", .{ line.fen, result.engine, result.trainer, result.quantised });
        if (check_engine and hce.evaluate_nnue(pos) != result.engine) engine_mismatches += 1;
    }

    try out.print("nnue-parity: {s}, {d} positions, mean |eval| {d:.1} cp, max |eval| {d:.1} cp\n", .{ args[0], lines.items.len, magnitude.mean(), magnitude.max });
    try out.print("  integer vs float forward pass:        max {d:.3} cp, mean {d:.3} cp\n", .{ trainer.max, trainer.mean() });
    try out.print("  integer vs float, quantised pairwise: max {d:.3} cp, mean {d:.3} cp\n", .{ quantised.max, quantised.mean() });
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
    if (expected.count > 0) {
        try out.print("  integer vs trainer evaluations:       max {d:.3} cp, mean {d:.3} cp ({d} positions)\n", .{ expected.max, expected.mean(), expected.count });
    }
    if (check_engine) {
        try out.print("  engine incremental evaluation:        {d} mismatches\n", .{engine_mismatches});
    }
    return if (engine_mismatches == 0) 0 else 1;
}

fn run_random(args: []const []const u8, out: *std.Io.Writer) !u8 {
    if (args.len < 1) {
        try out.writeAll(USAGE);
        return 1;
    }
    const seed = if (args.len >= 2) std.fmt.parseInt(u64, args[1], 10) catch 1 else 1;
    var full = false;
    var activity: Activity = .dense;
    for (args[@min(args.len, 2)..]) |flag| {
        if (std.mem.eql(u8, flag, "full")) full = true;
        if (std.mem.eql(u8, flag, "sparse")) activity = .sparse;
    }
    const net = try platform.allocator.create(Net);
    defer platform.allocator.destroy(net);
    var prng = std.Random.DefaultPrng.init(seed);
    fill_random(net, prng.random(), if (full) .{} else REALISTIC_RANGE, activity);
    try std.Io.Dir.cwd().writeFile(platform.io, .{ .sub_path = args[0], .data = std.mem.asBytes(net) });
    try out.print("nnue-random: wrote {s} ({d} bytes, seed {d})\n", .{ args[0], @sizeOf(Net), seed });
    return 0;
}

const SPEED_ROUNDS = 40_000;
/// Samples per batch of a stage timing: about 6 KiB each.
const STAGE_BATCH = 4;

/// The accumulators of one bench position, and for the multi-layer head what
/// each of its stages produces from them, so that a stage can be timed alone.
const SpeedSample = struct {
    white: arch.Accumulator align(64),
    black: arch.Accumulator align(64),
    bucket: usize,
    activations: head_multi.Activations align(64) = undefined,
    indices: head_multi.BlockIndices = undefined,
    sums: head_multi.L1Vector = undefined,
};

/// The stages of `head_multi.evaluate_simd`, each from the stored output of
/// the one before it.
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

    /// Per call, with the samples taken a few at a time so that a stage finds
    /// its input in the first-level cache, as it does in the search.
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

/// Where the time of the multi-layer head goes. The stages are timed in
/// order, so each one finds the output of the one before it in the samples.
fn report_multi_stages(samples: []SpeedSample, out: *std.Io.Writer) !void {
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

/// Times the active build's head on the accumulators of the bench positions.
fn run_speed(out: *std.Io.Writer) !u8 {
    const samples = try platform.allocator.alloc(SpeedSample, bench.FENS.len);
    defer platform.allocator.free(samples);

    const pos = try platform.allocator.create(position.Position);
    defer platform.allocator.destroy(pos);
    pos.init();
    defer pos.deinit();
    for (bench.FENS, samples) |fen, *sample| {
        pos.set_fen(fen);
        sample.* = .{
            .white = undefined,
            .black = undefined,
            .bucket = @min((types.popcount_usize(pos.all_all_pieces()) -| 2) / 4, arch.OUTPUT_SIZE - 1),
        };
        accumulate(weights.MODEL, pos, types.Color.White, &sample.white);
        accumulate(weights.MODEL, pos, types.Color.Black, &sample.black);
    }

    var checksum: i64 = 0;
    const timer = types.Timer.start();
    for (0..SPEED_ROUNDS) |_| {
        for (samples) |*sample| {
            checksum += weights.evaluate(&sample.white, &sample.black, sample.bucket);
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

/// Entry point of the `nnue-parity`, `nnue-random` and `nnue-speed` commands.
pub fn run(command: []const u8, args: []const []const u8) u8 {
    var buffer: [1024]u8 = undefined;
    var stdout = platform.Stdout.init(&buffer);
    const out = stdout.writer();
    const result = if (std.mem.eql(u8, command, "nnue-parity"))
        run_parity(args, out)
    else if (std.mem.eql(u8, command, "nnue-random"))
        run_random(args, out)
    else
        run_speed(out);
    const code = result catch |err| blk: {
        out.print("{s}: {s}\n", .{ command, @errorName(err) }) catch {};
        break :blk 2;
    };
    out.flush() catch {};
    return code;
}
