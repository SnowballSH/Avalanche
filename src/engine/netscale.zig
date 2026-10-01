// Rescales a candidate network's output layer so that its mean |eval| over a
// set of positions matches a reference network's. Search margins are tuned to
// the reference's eval scale, so a rescaled candidate is measured fairly.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const weights = @import("weights.zig");
const datagen = @import("datagen.zig");

const USAGE =
    \\Usage: Avalanche netscale net=<candidate.nnue> ref=<reference.nnue> positions=<file.epd> out=<scaled.nnue> [limit=<n>]
    \\  net=PATH        network to rescale
    \\  ref=PATH        network whose eval scale is the target
    \\  positions=PATH  EPD/FEN file, one position per line; positions in check are skipped
    \\  out=PATH        where the rescaled copy of net is written
    \\  limit=N         use at most the first N positions not in check (default: all)
    \\
;

pub const Options = struct {
    net: []const u8,
    ref: []const u8,
    positions: []const u8,
    out: []const u8,
    limit: usize = 0, // 0 => every position
};

pub const Diagnostic = struct {
    key: []const u8 = "",
    value: []const u8 = "",
};

pub const ParseError = error{ InvalidValue, UnknownKey, DuplicateKey, MissingKey };

/// `args` are the `key=value` arguments after `netscale`.
pub fn parse(args: []const []const u8, diag: *Diagnostic) ParseError!Options {
    const Key = enum { net, ref, positions, out, limit };
    var values: std.enums.EnumArray(Key, ?[]const u8) = .initFill(null);

    for (args) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
        diag.* = .{ .key = arg[0..eq], .value = arg[@min(eq + 1, arg.len)..] };
        const key = std.meta.stringToEnum(Key, diag.key) orelse return error.UnknownKey;
        if (values.get(key) != null) return error.DuplicateKey;
        if (diag.value.len == 0) return error.InvalidValue;
        if (key == .limit and (std.fmt.parseInt(usize, diag.value, 10) catch 0) == 0) return error.InvalidValue;
        values.set(key, diag.value);
    }

    var paths: [4][]const u8 = undefined;
    inline for (.{ Key.net, Key.ref, Key.positions, Key.out }, &paths) |key, *path| {
        path.* = values.get(key) orelse {
            diag.* = .{ .key = @tagName(key) };
            return error.MissingKey;
        };
    }
    return .{
        .net = paths[0],
        .ref = paths[1],
        .positions = paths[2],
        .out = paths[3],
        .limit = if (values.get(.limit)) |text| std.fmt.parseInt(usize, text, 10) catch unreachable else 0,
    };
}

pub const Mean = struct {
    positions: usize,
    abs_eval: f64,
};

/// Mean absolute raw evaluation of the network file `net`, in centipawns for the side to move, over the positions
/// of `fens` that are not in check (the first `limit` of them when it is non-zero). Raw is the network's output
/// alone, before any eval post-scaling or correction. `net` is left installed as the active network.
pub fn mean_abs_eval(net: []const u8, fens: []const []const u8, limit: usize) !Mean {
    try weights.install(net);
    const pos = try platform.allocator.create(position.Position);
    defer platform.allocator.destroy(pos);
    pos.init();
    defer pos.deinit();

    var total: u64 = 0;
    var count: usize = 0;
    for (fens) |fen| {
        if (limit != 0 and count == limit) break;
        pos.set_fen(fen);
        const in_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);
        if (in_check) continue;
        // Drops the cached accumulators, so the position is built from scratch with `net`.
        pos.refresh_evaluation();
        total += @abs(hce.evaluate_nnue(pos));
        count += 1;
    }
    if (count == 0) return error.NoPositions;
    return .{ .positions = count, .abs_eval = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count)) };
}

pub const ScaleError = error{ InvalidFactor, OutputWeightOutOfRange, OutputBiasOverflow };

fn scale_values(bytes: []u8, factor: f64, min: i16, max: i16, commit: bool) bool {
    var i: usize = 0;
    while (i < bytes.len) : (i += 2) {
        const cell = bytes[i..][0..2];
        const scaled = @round(@as(f64, @floatFromInt(std.mem.readInt(i16, cell, .little))) * factor);
        if (scaled < @as(f64, @floatFromInt(min)) or scaled > @as(f64, @floatFromInt(max))) return false;
        if (commit) std.mem.writeInt(i16, cell, @intFromFloat(scaled), .little);
    }
    return true;
}

/// Multiplies every output-layer weight and bias of the network file `net` by `factor`, rounding to nearest.
/// Weights must stay in the range `weights.validate` accepts and biases must fit an i16; `net` is untouched on error.
pub fn scale_output_layer(net: []u8, factor: f64) ScaleError!void {
    if (!std.math.isFinite(factor) or factor <= 0) return error.InvalidFactor;
    const file = net[0..@sizeOf(weights.NNUEWeights)];
    for ([_]bool{ false, true }) |commit| {
        if (!scale_values(weights.OUTPUT_WEIGHT_BYTES.of(file), factor, weights.OUTPUT_WEIGHT_MIN, weights.OUTPUT_WEIGHT_MAX, commit)) return error.OutputWeightOutOfRange;
        if (!scale_values(weights.OUTPUT_BIAS_BYTES.of(file), factor, std.math.minInt(i16), std.math.maxInt(i16), commit)) return error.OutputBiasOverflow;
    }
}

pub const Result = struct {
    positions: usize,
    ref_mean_abs: f64,
    candidate_mean_abs: f64,
    factor: f64,
    scaled_mean_abs: f64,
};

/// Scales the network file `candidate` in place to the eval scale of `reference` over `fens`.
pub fn rescale(candidate: []u8, reference: []const u8, fens: []const []const u8, limit: usize) !Result {
    const ref_mean = try mean_abs_eval(reference, fens, limit);
    const candidate_mean = try mean_abs_eval(candidate, fens, limit);
    if (candidate_mean.abs_eval == 0) return error.ZeroCandidateEval;
    const factor = ref_mean.abs_eval / candidate_mean.abs_eval;
    try scale_output_layer(candidate, factor);
    return .{
        .positions = ref_mean.positions,
        .ref_mean_abs = ref_mean.abs_eval,
        .candidate_mean_abs = candidate_mean.abs_eval,
        .factor = factor,
        .scaled_mean_abs = (try mean_abs_eval(candidate, fens, limit)).abs_eval,
    };
}

fn read_network(path: []const u8) ?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(platform.io, path, platform.allocator, .limited(@sizeOf(weights.NNUEWeights) + 1)) catch |err| {
        std.debug.print("netscale: cannot read network '{s}': {s}\n", .{ path, @errorName(err) });
        return null;
    };
    weights.validate(bytes) catch |err| {
        std.debug.print("netscale: '{s}' is not a {s} network this build can run: {s}\n", .{ path, weights.ARCHITECTURE, @errorName(err) });
        platform.allocator.free(bytes);
        return null;
    };
    return bytes;
}

/// Entry point for the `netscale` subcommand. Returns the process exit code.
pub fn run(args: []const []const u8) !u8 {
    var diag: Diagnostic = .{};
    const options = parse(args, &diag) catch |err| {
        std.debug.print("netscale: {s} for '{s}={s}'\n{s}", .{ @errorName(err), diag.key, diag.value, USAGE });
        return 2;
    };
    if (std.mem.eql(u8, options.out, options.net) or std.mem.eql(u8, options.out, options.ref)) {
        std.debug.print("netscale: out must differ from net and ref\n", .{});
        return 2;
    }

    const candidate = read_network(options.net) orelse return 1;
    defer platform.allocator.free(candidate);
    const reference = read_network(options.ref) orelse return 1;
    defer platform.allocator.free(reference);

    var book_diag: datagen.BookDiagnostic = .{};
    const fens = datagen.loadEpdFile(options.positions, &book_diag) catch |err| {
        if (err == error.InvalidBookLine) {
            std.debug.print("netscale: positions '{s}' line {}: {s}\n", .{ options.positions, book_diag.line, book_diag.reason });
        } else {
            std.debug.print("netscale: cannot load positions '{s}': {s}\n", .{ options.positions, @errorName(err) });
        }
        return 1;
    };

    const result = rescale(candidate, reference, fens, options.limit) catch |err| {
        switch (err) {
            error.NoPositions => std.debug.print("netscale: every position in '{s}' is in check\n", .{options.positions}),
            error.ZeroCandidateEval => std.debug.print("netscale: '{s}' evaluates every position as 0, so no factor exists\n", .{options.net}),
            error.OutputWeightOutOfRange => std.debug.print("netscale: refusing to scale: an output weight would leave [{}, {}], the range inference requires\n", .{ weights.OUTPUT_WEIGHT_MIN, weights.OUTPUT_WEIGHT_MAX }),
            error.OutputBiasOverflow => std.debug.print("netscale: refusing to scale: an output bias would overflow i16\n", .{}),
            else => std.debug.print("netscale: {s}\n", .{@errorName(err)}),
        }
        return 1;
    };

    std.Io.Dir.cwd().writeFile(platform.io, .{ .sub_path = options.out, .data = candidate }) catch |err| {
        std.debug.print("netscale: cannot write '{s}': {s}\n", .{ options.out, @errorName(err) });
        return 1;
    };

    var buffer: [512]u8 = undefined;
    var stdout = platform.Stdout.init(&buffer);
    try stdout.writer().print("{f}\n", .{std.json.fmt(result, .{})});
    try stdout.writer().flush();
    return 0;
}

const testing = std.testing;

fn parse_ok(args: []const []const u8) !Options {
    var diag: Diagnostic = .{};
    return parse(args, &diag);
}

test "netscale options: every key parses, in any order" {
    const o = try parse_ok(&.{ "out=o.nnue", "limit=500", "net=c.nnue", "positions=b.epd", "ref=r.nnue" });
    try testing.expectEqualStrings("c.nnue", o.net);
    try testing.expectEqualStrings("r.nnue", o.ref);
    try testing.expectEqualStrings("b.epd", o.positions);
    try testing.expectEqualStrings("o.nnue", o.out);
    try testing.expectEqual(@as(usize, 500), o.limit);
    try testing.expectEqual(@as(usize, 0), (try parse_ok(&.{ "net=c", "ref=r", "positions=p", "out=o" })).limit);
}

test "netscale options: unknown, duplicate, missing and malformed keys are errors naming the key" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownKey, parse(&.{ "net=c", "reff=r" }, &diag));
    try testing.expectEqualStrings("reff", diag.key);
    try testing.expectError(error.UnknownKey, parse(&.{"c.nnue"}, &diag));
    try testing.expectError(error.DuplicateKey, parse(&.{ "net=c", "ref=r", "net=d" }, &diag));
    try testing.expectEqualStrings("net", diag.key);
    try testing.expectError(error.MissingKey, parse(&.{ "net=c", "ref=r", "positions=p" }, &diag));
    try testing.expectEqualStrings("out", diag.key);
    try testing.expectError(error.MissingKey, parse(&.{}, &diag));
    try testing.expectError(error.InvalidValue, parse(&.{ "net=c", "ref=r", "positions=p", "out=o", "limit=0" }, &diag));
    try testing.expectError(error.InvalidValue, parse(&.{ "net=c", "ref=r", "positions=p", "out=o", "limit=x" }, &diag));
    try testing.expectEqualStrings("limit", diag.key);
    try testing.expectError(error.InvalidValue, parse(&.{"net="}, &diag));
    try testing.expectError(error.InvalidValue, parse(&.{"net"}, &diag));
}
