const std = @import("std");
const types = @import("./types.zig");
const tables = @import("./tables.zig");
const zobrist = @import("./zobrist.zig");
const position = @import("./position.zig");

pub fn perft(comptime color: types.Color, pos: *position.Position, depth: u32) usize {
    var nodes: usize = 0;
    comptime var opp = if (color == types.Color.White) types.Color.Black else types.Color.White;

    var list = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
    defer list.deinit();

    pos.generate_legal_moves(color, &list);
    if (depth == 1) {
        return @intCast(usize, list.items.len);
    }

    for (list.items) |move| {
        pos.play_move(color, move);
        nodes += perft(opp, pos, depth - 1);
        pos.undo_move(color, move);
    }

    return nodes;
}

pub fn perft_div(comptime color: types.Color, pos: *position.Position, depth: u32) void {
    var nodes: usize = 0;
    var branch: usize = 0;
    comptime var opp = if (color == types.Color.White) types.Color.Black else types.Color.White;

    var list = std.ArrayList(types.Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
    defer list.deinit();

    pos.generate_legal_moves(color, &list);

    for (list.items) |move| {
        pos.play_move(color, move);
        branch = perft(opp, pos, depth - 1);
        nodes += branch;
        pos.undo_move(color, move);

        move.debug_print();
        std.debug.print(": {}\n", .{branch});
    }

    std.debug.print("\nTotal: {}\n", .{nodes});
}

pub fn perft_test(pos: *position.Position, depth: u32) void {
    pos.debug_print();

    std.debug.print("Running Perft {}:\n", .{depth});

    var timer = std.time.Timer.start() catch unreachable;
    var nodes: usize = 0;

    if (pos.turn == types.Color.White) {
        nodes = perft(types.Color.White, pos, depth);
    } else {
        nodes = perft(types.Color.Black, pos, depth);
    }

    var elapsed = timer.read();
    std.debug.print("\n", .{});
    std.debug.print("Nodes: {}\n", .{nodes});
    var mcs = @intToFloat(f64, elapsed) / 1000.0;
    std.debug.print("Elapsed: {d:.2} microseconds (or {d:.6} seconds)\n", .{ mcs, mcs / 1000.0 / 1000.0 });
    var nps = @intToFloat(f64, nodes) / (@intToFloat(f64, elapsed) / 1000.0 / 1000.0 / 1000.0);
    std.debug.print("NPS: {d:.2} nodes/s (or {d:.4} mn/s)\n", .{ nps, nps / 1000.0 / 1000.0 });
}
