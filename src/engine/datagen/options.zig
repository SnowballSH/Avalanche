//! See "Command line" in docs/DATAGEN.md.

const std = @import("std");
const arguments = @import("arguments.zig");
const tt = @import("../tt.zig");

pub const Format = @import("format.zig").Format;

const MAX_THREADS: usize = 4096;
const MAX_RANDOM_PLIES: u64 = 500;
const RANDOM_SEE_LIMIT: i32 = 10_000;
const MAX_TT_MB: u64 = tt.MAX_HASH_MB;

pub const PlySpan = struct {
    min: u64,
    range: u64,

    fn parse(text: []const u8) arguments.ValueError!PlySpan {
        const separator = std.mem.findScalar(u8, text, '-') orelse text.len;
        const min = try arguments.integer(u64, text[0..separator], 0, MAX_RANDOM_PLIES);
        const max = if (separator == text.len) min else try arguments.integer(u64, text[separator + 1 ..], min, MAX_RANDOM_PLIES);
        return .{ .min = min, .range = max - min + 1 };
    }
};

pub const Options = struct {
    threads: usize,
    book: ?[]const u8 = null,
    format: Format = .viri,
    soft_nodes: u32 = 10000,
    hard_multiplier: u32 = 8,
    plies: PlySpan = .{ .min = 8, .range = 3 },
    book_plies: PlySpan = .{ .min = 0, .range = 3 },
    random_see: i32 = -200,
    tt_mb: u64 = 4,
    positions: u64 = 0,
    seed: ?u64 = null,
    raw_eval: bool = false,
    out: ?[]const u8 = null,
};

pub const Diagnostic = arguments.Diagnostic;

pub const ParseError = arguments.KeyError || arguments.ValueError || error{MissingThreads};

const Key = enum { book, format, nodes, hardmult, plies, bookplies, randsee, ttmb, positions, seed, raweval, out };

pub fn parse(args: []const []const u8, diag: *Diagnostic) ParseError!Options {
    if (args.len == 0) return error.MissingThreads;
    diag.* = .{ .key = "threads", .value = args[0] };
    var options: Options = .{ .threads = try arguments.integer(usize, args[0], 1, MAX_THREADS) };

    var given: arguments.KeyValues(Key) = .{};
    for (args[1..]) |arg| {
        const option = try given.next(arg, .book, diag);
        const value = option.value;
        switch (option.key) {
            .book => options.book = value,
            .format => options.format = try arguments.choice(Format, value),
            .nodes => options.soft_nodes = try positive(u32, value),
            .hardmult => options.hard_multiplier = try positive(u32, value),
            .plies => options.plies = try PlySpan.parse(value),
            .bookplies => options.book_plies = try PlySpan.parse(value),
            .randsee => options.random_see = try arguments.integer(i32, value, -RANDOM_SEE_LIMIT, RANDOM_SEE_LIMIT),
            .ttmb => options.tt_mb = try arguments.integer(u64, value, 1, MAX_TT_MB),
            .positions => options.positions = try positive(u64, value),
            .seed => options.seed = std.fmt.parseInt(u64, value, 0) catch return error.InvalidValue,
            .raweval => options.raw_eval = try arguments.boolean(value),
            .out => options.out = try arguments.non_empty(value),
        }
    }
    return options;
}

fn positive(comptime T: type, value: []const u8) arguments.ValueError!T {
    return arguments.integer(T, value, 1, std.math.maxInt(T));
}

const testing = std.testing;

fn parse_ok(args: []const []const u8) !Options {
    var diag: Diagnostic = .{};
    return parse(args, &diag);
}

test "datagen options: defaults with only a thread count" {
    const o = try parse_ok(&.{"4"});
    try testing.expectEqual(@as(usize, 4), o.threads);
    try testing.expectEqual(@as(u32, 10000), o.soft_nodes);
    try testing.expectEqual(@as(u64, 0), o.positions);
    try testing.expectEqual(@as(?u64, null), o.seed);
    try testing.expectEqual(Format.viri, o.format);
    try testing.expectEqual(PlySpan{ .min = 8, .range = 3 }, o.plies);
    try testing.expect(!o.raw_eval);
}

test "datagen options: every key parses" {
    const o = try parse_ok(&.{ "8", "books/x.epd", "nodes=6000", "hardmult=8", "plies=8-9", "bookplies=6-8", "randsee=-150", "ttmb=16", "positions=2000000", "seed=42", "out=/tmp/c.viribin", "format=viri" });
    try testing.expectEqualStrings("books/x.epd", o.book.?);
    try testing.expectEqual(@as(u32, 6000), o.soft_nodes);
    try testing.expectEqual(PlySpan{ .min = 8, .range = 2 }, o.plies);
    try testing.expectEqual(PlySpan{ .min = 6, .range = 3 }, o.book_plies);
    try testing.expectEqual(@as(i32, -150), o.random_see);
    try testing.expectEqual(@as(u64, 16), o.tt_mb);
    try testing.expectEqual(@as(u64, 2_000_000), o.positions);
    try testing.expectEqual(@as(?u64, 42), o.seed);
    try testing.expectEqualStrings("/tmp/c.viribin", o.out.?);
}

test "datagen options: book= key is equivalent to a bare path" {
    const o = try parse_ok(&.{ "2", "book=books/y.epd" });
    try testing.expectEqualStrings("books/y.epd", o.book.?);
}

test "datagen options: malformed values are errors naming the key" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, parse(&.{ "4", "nodes=abc" }, &diag));
    try testing.expectEqualStrings("nodes", diag.key);
    try testing.expectError(error.InvalidValue, parse(&.{ "4", "plies=9-8" }, &diag));
    try testing.expectError(error.InvalidValue, parse(&.{"0"}, &diag));
    try testing.expectError(error.UnknownKey, parse(&.{ "4", "nodez=5" }, &diag));
    try testing.expectError(error.MissingThreads, parse(&.{}, &diag));
}

test "datagen options: a repeated key is an error, whatever its values" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.DuplicateKey, parse(&.{ "4", "raweval=true", "raweval=false" }, &diag));
    try testing.expectEqualStrings("raweval", diag.key);
    try testing.expectEqualStrings("false", diag.value);
    try testing.expectError(error.DuplicateKey, parse(&.{ "4", "nodes=5000", "seed=1", "nodes=5000" }, &diag));
    try testing.expectEqualStrings("nodes", diag.key);
    try testing.expectError(error.DuplicateKey, parse(&.{ "4", "a.epd", "b.epd" }, &diag));
    try testing.expectError(error.DuplicateKey, parse(&.{ "4", "a.epd", "book=b.epd" }, &diag));
    try testing.expectEqualStrings("book", diag.key);
    try testing.expectEqualStrings("b.epd", diag.value);
}

test "datagen options: raweval takes exactly true or false" {
    try testing.expect((try parse_ok(&.{ "4", "raweval=true" })).raw_eval);
    try testing.expect(!(try parse_ok(&.{ "4", "raweval=false" })).raw_eval);

    var diag: Diagnostic = .{};
    for ([_][]const u8{ "raweval=", "raweval=1", "raweval=True", "raweval=yes", "raweval=true " }) |arg| {
        try testing.expectError(error.InvalidValue, parse(&.{ "4", arg }, &diag));
        try testing.expectEqualStrings("raweval", diag.key);
    }
}

test "datagen options: values outside their documented range are errors, not overflows" {
    var diag: Diagnostic = .{};
    const too_big = "18446744073709551615";
    inline for (.{ "plies=0-" ++ too_big, "plies=" ++ too_big, "plies=0-501", "bookplies=501", "nodes=4294967296", "hardmult=4294967296", "ttmb=1048577", "ttmb=" ++ too_big, "randsee=-2147483648", "randsee=10001", "positions=0" }) |arg| {
        try testing.expectError(error.InvalidValue, parse(&.{ "4", arg }, &diag));
    }
    try testing.expectError(error.InvalidValue, parse(&.{"4097"}, &diag));
    try testing.expectEqualStrings("threads", diag.key);

    const widest = try parse_ok(&.{ "4096", "plies=0-500", "bookplies=500", "nodes=4294967295", "hardmult=4294967295", "ttmb=1048576", "randsee=-10000", "positions=" ++ too_big });
    try testing.expectEqual(PlySpan{ .min = 0, .range = 501 }, widest.plies);
    try testing.expectEqual(PlySpan{ .min = 500, .range = 1 }, widest.book_plies);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), widest.positions);
}
