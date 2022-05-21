const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");

pub fn main() anyerror!void {
    tables.init_all();

    std.debug.print("{}", .{tables.get_pawn_attacks(types.Color.Black, types.Square.e5)});
}
