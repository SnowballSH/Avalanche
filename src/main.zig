const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");

pub fn main() anyerror!void {
    tables.init_all();

    std.debug.print("{}", .{tables.LineOf[types.Square.e3.index()][types.Square.e7.index()]});
}
