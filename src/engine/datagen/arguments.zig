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
