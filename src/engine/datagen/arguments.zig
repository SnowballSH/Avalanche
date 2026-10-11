//! `key=value` command-line arguments of the data tools; see "Command line" in docs/DATAGEN.md.

const std = @import("std");

pub const Diagnostic = struct {
    key: []const u8 = "",
    value: []const u8 = "",
};

pub const KeyError = error{ UnknownKey, DuplicateKey };
pub const ValueError = error{InvalidValue};

pub fn is_key_value(arg: []const u8) bool {
    return std.mem.findScalar(u8, arg, '=') != null;
}

pub fn KeyValues(comptime Key: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { key: Key, value: []const u8 };

        seen: std.EnumSet(Key) = .empty,

        pub fn next(self: *Self, arg: []const u8, key_of_bare_argument: ?Key, diag: *Diagnostic) KeyError!Entry {
            diag.* = if (std.mem.findScalar(u8, arg, '=')) |eq|
                .{ .key = arg[0..eq], .value = arg[eq + 1 ..] }
            else if (key_of_bare_argument) |key|
                .{ .key = @tagName(key), .value = arg }
            else
                .{ .key = arg };
            const key = std.meta.stringToEnum(Key, diag.key) orelse return error.UnknownKey;
            if (self.seen.contains(key)) return error.DuplicateKey;
            self.seen.insert(key);
            return .{ .key = key, .value = diag.value };
        }

        pub fn given(self: Self, key: Key) bool {
            return self.seen.contains(key);
        }
    };
}

pub fn integer(comptime T: type, text: []const u8, min: T, max: T) ValueError!T {
    const value = std.fmt.parseInt(T, text, 10) catch return error.InvalidValue;
    if (value < min or value > max) return error.InvalidValue;
    return value;
}

pub fn choice(comptime E: type, text: []const u8) ValueError!E {
    return std.meta.stringToEnum(E, text) orelse error.InvalidValue;
}

pub fn boolean(text: []const u8) ValueError!bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidValue;
}

pub fn non_empty(text: []const u8) ValueError![]const u8 {
    return if (text.len == 0) error.InvalidValue else text;
}

const testing = std.testing;

const Fruit = enum { apple, pear };

test "arguments: a key=value argument splits at the first equals sign" {
    var diag: Diagnostic = .{};
    var options: KeyValues(Fruit) = .{};
    const entry = try options.next("apple=a=b", null, &diag);
    try testing.expectEqual(Fruit.apple, entry.key);
    try testing.expectEqualStrings("a=b", entry.value);
    try testing.expect(options.given(.apple));
    try testing.expect(!options.given(.pear));
}

test "arguments: a bare argument is the value of the bare key, or a key without a value" {
    var diag: Diagnostic = .{};
    var with_bare_key: KeyValues(Fruit) = .{};
    const entry = try with_bare_key.next("conference", .pear, &diag);
    try testing.expectEqual(Fruit.pear, entry.key);
    try testing.expectEqualStrings("conference", entry.value);

    var without: KeyValues(Fruit) = .{};
    try testing.expectEqualStrings("", (try without.next("pear", null, &diag)).value);
    try testing.expectError(error.UnknownKey, without.next("conference", null, &diag));
    try testing.expectEqualStrings("conference", diag.key);
}

test "arguments: unknown and repeated keys are errors naming the key and value" {
    var diag: Diagnostic = .{};
    var options: KeyValues(Fruit) = .{};
    try testing.expectError(error.UnknownKey, options.next("plum=1", null, &diag));
    try testing.expectEqualStrings("plum", diag.key);
    _ = try options.next("apple=1", null, &diag);
    try testing.expectError(error.DuplicateKey, options.next("apple=2", null, &diag));
    try testing.expectEqualStrings("apple", diag.key);
    try testing.expectEqualStrings("2", diag.value);
}

test "arguments: values outside their range or their set of choices are invalid" {
    try testing.expectEqual(@as(u32, 7), try integer(u32, "7", 2, 7));
    for ([_][]const u8{ "1", "8", "", "7,", "-3", "seven", "99999999999999999999" }) |text| {
        try testing.expectError(error.InvalidValue, integer(u32, text, 2, 7));
    }
    try testing.expectEqual(Fruit.pear, try choice(Fruit, "pear"));
    try testing.expectError(error.InvalidValue, choice(Fruit, "Pear"));
    try testing.expectError(error.InvalidValue, non_empty(""));
    try testing.expect(try boolean("true"));
    try testing.expect(!try boolean("false"));
    try testing.expectError(error.InvalidValue, boolean("1"));
}
