const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");

pub fn main() anyerror!void {
    tables.init_rook_attacks();
    tables.init_bishop_attacks();

    std.debug.print("{}", .{tables.get_bishop_attacks(types.Square.e4, 0x80124622004420)});
}
