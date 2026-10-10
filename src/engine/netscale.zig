//! See "Network eval scale" in docs/DATAGEN.md.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const hce = @import("hce.zig");
const weights = @import("weights.zig");
const arguments = @import("datagen/arguments.zig");
const book = @import("datagen/book.zig");

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
    limit: ?usize = null,
};

pub const Diagnostic = arguments.Diagnostic;

pub const ParseError = arguments.KeyError || arguments.ValueError || error{MissingKey};

const Key = enum { net, ref, positions, limit };
const PATH_KEYS = [_]Key{ .net, .ref, .positions };

pub fn parse(args: []const []const u8, diag: *Diagnostic) ParseError!Options {
    var given: arguments.KeyValues(Key) = .{};
    var paths: std.enums.EnumArray(Key, []const u8) = .initUndefined();
    var limit: ?usize = null;

    for (args) |arg| {
        const option = try given.next(arg, null, diag);
        switch (option.key) {
            .limit => limit = try arguments.integer(usize, option.value, 1, std.math.maxInt(usize)),
            .net, .ref, .positions => paths.set(option.key, try arguments.non_empty(option.value)),
        }
    }

    for (PATH_KEYS) |key| {
        if (!given.given(key)) {
            diag.* = .{ .key = @tagName(key) };
            return error.MissingKey;
        }
    }
    return .{ .net = paths.get(.net), .ref = paths.get(.ref), .positions = paths.get(.positions), .limit = limit };
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

pub fn mean_abs_eval(fens: []const []const u8, limit: ?usize) !Mean {
    // A new position has no cached accumulators, so each one is built from scratch with the active network.
    const pos = try platform.allocator.create(position.Position);
    defer platform.allocator.destroy(pos);
    pos.init();
    defer pos.deinit();

    var total: u64 = 0;
    var count: usize = 0;
    for (fens) |fen| {
        if (count == limit) break;
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

pub fn measure(candidate: []const u8, reference: []const u8, fens: []const []const u8, limit: ?usize) !Result {
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

    var book_diag: book.Diagnostic = .{};
    var positions = book.Book.load(platform.allocator, options.positions, &book_diag) catch |failure| {
        if (failure == error.InvalidBookLine) {
            try err.print("netscale: positions '{s}' line {}: {s}\n", .{ options.positions, book_diag.line, book_diag.reason });
        } else {
            try err.print("netscale: cannot load positions '{s}': {s}\n", .{ options.positions, @errorName(failure) });
        }
        return 1;
    };
    defer positions.deinit();

    const result = measure(candidate, reference, positions.lines, options.limit) catch |failure| {
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
    try testing.expectEqual(@as(?usize, 500), o.limit);
    try testing.expectEqual(@as(?usize, null), (try parse_ok(&.{ "net=c", "ref=r", "positions=p" })).limit);
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
