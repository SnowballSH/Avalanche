const std = @import("std");
const types = @import("./chess/types.zig");

pub fn main() anyerror!void {
    std.debug.print("{}", .{types.lsb(0b01101000)});
}
