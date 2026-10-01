// Measures how a candidate network's eval scale differs from a reference
// network's: the mean |eval| of both over a set of positions, and the UCI
// `EvalScale` value that brings the candidate onto the reference's scale.
// Search margins are tuned to the reference, so a candidate tested with that
// value is measured fairly.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const weights = @import("weights.zig");
const datagen = @import("datagen.zig");

const USAGE =
    \\Usage: Avalanche netscale net=<candidate.nnue> ref=<reference.nnue> positions=<file.epd> [limit=<n>]
    \\  net=PATH        network to measure
    \\  ref=PATH        network whose eval scale is the target; both networks must have
    \\                  this build's architecture,
++ " " ++ weights.ARCHITECTURE ++ "\n" ++
    \\  positions=PATH  EPD/FEN file, one position per line; positions the engine does not
    \\                  evaluate with the network (in check, bare endgames) are skipped
    \\  limit=N         use at most the first N remaining positions (default: all)
    \\
;

pub const Options = struct {
    net: []const u8,
    ref: []const u8,
    positions: []const u8,
    limit: usize = 0, // 0 => every position
};

pub const Diagnostic = struct {
    key: []const u8 = "",
    value: []const u8 = "",
};

pub const ParseError = error{ InvalidValue, UnknownKey, DuplicateKey, MissingKey };

/// `args` are the `key=value` arguments after `netscale`.
pub fn parse(args: []const []const u8, diag: *Diagnostic) ParseError!Options {
    const Key = enum { net, ref, positions, limit };
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

    var paths: [3][]const u8 = undefined;
    inline for (.{ Key.net, Key.ref, Key.positions }, &paths) |key, *path| {
        path.* = values.get(key) orelse {
            diag.* = .{ .key = @tagName(key) };
            return error.MissingKey;
        };
    }
    return .{
        .net = paths[0],
        .ref = paths[1],
        .positions = paths[2],
        .limit = if (values.get(.limit)) |text| std.fmt.parseInt(usize, text, 10) catch unreachable else 0,
    };
}

fn report_parse_error(failure: ParseError, diag: Diagnostic, err: *std.Io.Writer) !void {
    switch (failure) {
        error.UnknownKey => try err.print("netscale: unknown option '{s}'\n", .{diag.key}),
        error.DuplicateKey => try err.print("netscale: option {s} is given more than once\n", .{diag.key}),
        error.MissingKey => try err.print("netscale: missing required option {s}\n", .{diag.key}),
        error.InvalidValue => try err.print("netscale: invalid value '{s}' for option {s}\n", .{ diag.value, diag.key }),
    }
    try err.print("{s}", .{USAGE});
}

pub const Mean = struct {
    positions: usize,
    abs_eval: f64,
};

/// Mean absolute raw evaluation of the active network, in centipawns for the side to move, over the positions of
/// `fens` that the engine evaluates with the network (the first `limit` of them when it is non-zero). Raw is the
/// network's output alone, before `EvalScale`, any eval post-scaling or correction.
pub fn mean_abs_eval(fens: []const []const u8, limit: usize) !Mean {
    // A new position has no cached accumulators, so each one is built from scratch with the active network.
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
        if (in_check or !hce.network_evaluates(pos)) continue;
        total += @abs(hce.evaluate_nnue(pos));
        count += 1;
    }
    if (count == 0) return error.NoPositions;
    return .{ .positions = count, .abs_eval = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count)) };
}

pub const Result = struct {
    positions: usize,
    ref_mean_abs: f64,
    candidate_mean_abs: f64,
    factor: f64,
    eval_scale: i64,

    pub fn eval_scale_in_range(self: Result) bool {
        return self.eval_scale >= hce.MIN_EVAL_SCALE and self.eval_scale <= hce.MAX_EVAL_SCALE;
    }
};

/// Compares the network files `candidate` and `reference` over `fens`. The active network is the same afterwards.
pub fn measure(candidate: []const u8, reference: []const u8, fens: []const []const u8, limit: usize) !Result {
    const active = try platform.allocator.dupe(u8, std.mem.asBytes(weights.MODEL));
    defer platform.allocator.free(active);
    defer weights.install(active) catch unreachable;

    try weights.install(reference);
    const ref_mean = try mean_abs_eval(fens, limit);
    try weights.install(candidate);
    const candidate_mean = try mean_abs_eval(fens, limit);
    if (candidate_mean.abs_eval == 0) return error.ZeroCandidateEval;

    const factor = ref_mean.abs_eval / candidate_mean.abs_eval;
    return .{
        .positions = ref_mean.positions,
        .ref_mean_abs = ref_mean.abs_eval,
        .candidate_mean_abs = candidate_mean.abs_eval,
        .factor = factor,
        .eval_scale = std.math.lossyCast(i64, @round(factor * @as(f64, @floatFromInt(hce.DEFAULT_EVAL_SCALE)))),
    };
}

/// A network file this build can run. Both networks are evaluated by the build's own head, so each must have the
/// build's architecture; the loader's checks say so when one does not.
fn read_network(path: []const u8, err: *std.Io.Writer) !?[]u8 {
    const bytes = weights.read_file(path) catch |failure| {
        try err.print("netscale: cannot read network '{s}': {s}\n", .{ path, @errorName(failure) });
        return null;
    };
    weights.validate(bytes) catch |failure| {
        try err.print("netscale: cannot use network '{s}' ({s}: {s})\n", .{ path, @errorName(failure), weights.explain(failure) });
        platform.allocator.free(bytes);
        return null;
    };
    return bytes;
}

/// Entry point for the `netscale` subcommand: writes the result line to `out` and diagnostics to `err`, and returns
/// the process exit code (2 for bad options, 1 for any other failure).
pub fn run(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var diag: Diagnostic = .{};
    const options = parse(args, &diag) catch |failure| {
        try report_parse_error(failure, diag, err);
        return 2;
    };

    const candidate = try read_network(options.net, err) orelse return 1;
    defer platform.allocator.free(candidate);
    const reference = try read_network(options.ref, err) orelse return 1;
    defer platform.allocator.free(reference);

    var book_diag: datagen.BookDiagnostic = .{};
    const fens = datagen.loadEpdFile(options.positions, &book_diag) catch |failure| {
        if (failure == error.InvalidBookLine) {
            try err.print("netscale: positions '{s}' line {}: {s}\n", .{ options.positions, book_diag.line, book_diag.reason });
        } else {
            try err.print("netscale: cannot load positions '{s}': {s}\n", .{ options.positions, @errorName(failure) });
        }
        return 1;
    };

    const result = measure(candidate, reference, fens, options.limit) catch |failure| {
        switch (failure) {
            error.NoPositions => try err.print("netscale: '{s}' has no position the engine evaluates with the network\n", .{options.positions}),
            error.ZeroCandidateEval => try err.print("netscale: '{s}' evaluates every position as 0, so no factor exists\n", .{options.net}),
            else => try err.print("netscale: {s}\n", .{@errorName(failure)}),
        }
        return 1;
    };

    try out.print("{f}\n", .{std.json.fmt(result, .{})});
    if (!result.eval_scale_in_range()) {
        try err.print("netscale: eval_scale {} is outside the EvalScale range {}-{}\n", .{ result.eval_scale, hce.MIN_EVAL_SCALE, hce.MAX_EVAL_SCALE });
        return 1;
    }
    return 0;
}

const testing = std.testing;

fn parse_ok(args: []const []const u8) !Options {
    var diag: Diagnostic = .{};
    return parse(args, &diag);
}

test "netscale options: every key parses, in any order" {
    const o = try parse_ok(&.{ "limit=500", "net=c.nnue", "positions=b.epd", "ref=r.nnue" });
    try testing.expectEqualStrings("c.nnue", o.net);
    try testing.expectEqualStrings("r.nnue", o.ref);
    try testing.expectEqualStrings("b.epd", o.positions);
    try testing.expectEqual(@as(usize, 500), o.limit);
    try testing.expectEqual(@as(usize, 0), (try parse_ok(&.{ "net=c", "ref=r", "positions=p" })).limit);
}

test "netscale options: unknown, duplicate, missing and malformed keys are errors naming the key" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownKey, parse(&.{ "net=c", "reff=r" }, &diag));
    try testing.expectEqualStrings("reff", diag.key);
    try testing.expectError(error.UnknownKey, parse(&.{ "net=c", "ref=r", "positions=p", "out=o" }, &diag));
    try testing.expectError(error.UnknownKey, parse(&.{"c.nnue"}, &diag));
    try testing.expectError(error.DuplicateKey, parse(&.{ "net=c", "ref=r", "net=d" }, &diag));
    try testing.expectEqualStrings("net", diag.key);
    try testing.expectError(error.MissingKey, parse(&.{ "net=c", "ref=r" }, &diag));
    try testing.expectEqualStrings("positions", diag.key);
    try testing.expectError(error.MissingKey, parse(&.{}, &diag));
    try testing.expectError(error.InvalidValue, parse(&.{ "net=c", "ref=r", "positions=p", "limit=0" }, &diag));
    try testing.expectError(error.InvalidValue, parse(&.{ "net=c", "ref=r", "positions=p", "limit=x" }, &diag));
    try testing.expectEqualStrings("limit", diag.key);
    try testing.expectError(error.InvalidValue, parse(&.{"net="}, &diag));
    try testing.expectError(error.InvalidValue, parse(&.{"net"}, &diag));
}
