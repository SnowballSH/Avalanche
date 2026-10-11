//! The training-data formats and their file extensions; see "Output" in docs/DATAGEN.md.

const std = @import("std");

pub const Format = enum {
    bullet,
    viri,

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .bullet => ".bin",
            .viri => ".viribin",
        };
    }

    pub fn of_path(path: []const u8) ?Format {
        const extension_of_path = std.fs.path.extension(path);
        inline for (comptime std.enums.values(Format)) |format| {
            if (std.mem.eql(u8, extension_of_path, format.extension())) return format;
        }
        return null;
    }
};

const testing = std.testing;

test "format: each format is recognised by the extension datagen gives its files" {
    try testing.expectEqual(@as(?Format, .viri), Format.of_path("data/chunk-0001.viribin"));
    try testing.expectEqual(@as(?Format, .bullet), Format.of_path("shuffled.bin"));
    inline for (comptime std.enums.values(Format)) |format| {
        try testing.expectEqual(@as(?Format, format), Format.of_path("x" ++ comptime format.extension()));
    }
}

test "format: any other extension decides nothing" {
    for ([_][]const u8{ "chunk", "chunk.viribin.tmp", "chunk.vf", "chunk.BIN", ".bin", "bin" }) |path| {
        try testing.expectEqual(@as(?Format, null), Format.of_path(path));
    }
}
