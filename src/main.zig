const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");
const zobrist = @import("./chess/zobrist.zig");
const position = @import("./chess/position.zig");

pub fn main() anyerror!void {
    tables.init_all();
    zobrist.init_zobrist();

    var pos = position.Position.new();
    pos.set_fen(types.KIWIPETE[0..]);
    pos.debug_print();
    var list = std.ArrayList(types.Move).initCapacity(std.heap.page_allocator, 16) catch unreachable;
    pos.generate_legal_moves(types.Color.White, &list);
    for (list.items) |move| {
        move.debug_print();
    }
    std.debug.print("Total Size: {}\n", .{list.items.len});
}
