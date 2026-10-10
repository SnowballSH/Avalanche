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
