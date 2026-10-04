const std = @import("std");

pub const Format = enum { bullet, viri };

pub const PlySpan = struct {
    min: u64,
    range: u64,

    fn parse(text: []const u8) ?PlySpan {
        const sep = std.mem.indexOfScalar(u8, text, '-') orelse {
            const plies = std.fmt.parseInt(u64, text, 10) catch return null;
            return .{ .min = plies, .range = 1 };
        };
        const min = std.fmt.parseInt(u64, text[0..sep], 10) catch return null;
        const max = std.fmt.parseInt(u64, text[sep + 1 ..], 10) catch return null;
        if (max < min) return null;
        return .{ .min = min, .range = max - min + 1 };
    }
};

pub const Options = struct {
    threads: usize,
    book: ?[]const u8 = null,
    format: Format = .viri,
    soft_nodes: u64 = 10000,
    hard_multiplier: u64 = 8,
    plies: PlySpan = .{ .min = 8, .range = 3 },
    book_plies: PlySpan = .{ .min = 0, .range = 3 },
    random_see: i32 = -200,
    tt_mb: u64 = 4,
    positions: u64 = 0,
    seed: ?u64 = null,
    raw_eval: bool = false,
    out: ?[]const u8 = null,
};

pub const Diagnostic = struct {
    key: []const u8 = "",
    value: []const u8 = "",
};

pub const ParseError = error{ InvalidValue, UnknownKey, DuplicateKey, MissingThreads };

const Key = enum { book, format, nodes, hardmult, plies, bookplies, randsee, ttmb, positions, seed, raweval, out };

/// `args` are the arguments after `datagen`: a thread count, then at most one book path and `key=value` options, each key once.
pub fn parse(args: []const []const u8, diag: *Diagnostic) ParseError!Options {
    if (args.len == 0) return error.MissingThreads;
    const threads = std.fmt.parseInt(usize, args[0], 10) catch return invalid(diag, "threads", args[0]);
    if (threads == 0) return invalid(diag, "threads", args[0]);

    var options: Options = .{ .threads = threads };
    var seen: std.EnumSet(Key) = .empty;
    for (args[1..]) |arg| {
        // A bare argument is the book path.
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const key = if (eq) |at| arg[0..at] else "book";
        const value = if (eq) |at| arg[at + 1 ..] else arg;
        diag.* = .{ .key = key, .value = value };
        const known = std.meta.stringToEnum(Key, key) orelse return error.UnknownKey;
        if (seen.contains(known)) return error.DuplicateKey;
        seen.insert(known);
        switch (known) {
            .book => options.book = value,
            .format => options.format = std.meta.stringToEnum(Format, value) orelse return error.InvalidValue,
            .nodes => options.soft_nodes = try positive(u64, value),
            .hardmult => options.hard_multiplier = try positive(u64, value),
            .plies => options.plies = PlySpan.parse(value) orelse return error.InvalidValue,
            .bookplies => options.book_plies = PlySpan.parse(value) orelse return error.InvalidValue,
            .randsee => options.random_see = std.fmt.parseInt(i32, value, 10) catch return error.InvalidValue,
            .ttmb => options.tt_mb = try positive(u64, value),
            .positions => options.positions = try positive(u64, value),
            .seed => options.seed = std.fmt.parseInt(u64, value, 0) catch return error.InvalidValue,
            .raweval => options.raw_eval = boolean(value) orelse return error.InvalidValue,
            .out => {
                if (value.len == 0) return error.InvalidValue;
                options.out = value;
            },
        }
    }
    return options;
}

fn positive(comptime T: type, value: []const u8) ParseError!T {
    const n = std.fmt.parseInt(T, value, 10) catch return error.InvalidValue;
    if (n == 0) return error.InvalidValue;
    return n;
}

fn boolean(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn invalid(diag: *Diagnostic, key: []const u8, value: []const u8) ParseError {
    diag.* = .{ .key = key, .value = value };
    return error.InvalidValue;
}

const testing = std.testing;

fn parse_ok(args: []const []const u8) !Options {
    var diag: Diagnostic = .{};
    return parse(args, &diag);
}

test "datagen options: defaults with only a thread count" {
    const o = try parse_ok(&.{"4"});
    try testing.expectEqual(@as(usize, 4), o.threads);
    try testing.expectEqual(@as(u64, 10000), o.soft_nodes);
    try testing.expectEqual(@as(u64, 0), o.positions);
    try testing.expectEqual(@as(?u64, null), o.seed);
    try testing.expectEqual(Format.viri, o.format);
    try testing.expectEqual(PlySpan{ .min = 8, .range = 3 }, o.plies);
    try testing.expect(!o.raw_eval);
}

test "datagen options: every key parses" {
    const o = try parse_ok(&.{ "8", "books/x.epd", "nodes=6000", "hardmult=8", "plies=8-9", "bookplies=6-8", "randsee=-150", "ttmb=16", "positions=2000000", "seed=42", "out=/tmp/c.viribin", "format=viri" });
    try testing.expectEqualStrings("books/x.epd", o.book.?);
    try testing.expectEqual(@as(u64, 6000), o.soft_nodes);
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
