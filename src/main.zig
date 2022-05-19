const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");

pub fn main() anyerror!void {
    std.debug.print("{}", .{tables.reverse_bitboard(0x24180000000000)});
}
