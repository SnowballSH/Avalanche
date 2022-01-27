const Position = @import("../board/position.zig");
const MoveGen = @import("../move/movegen.zig");
const Uci = @import("./uci.zig");
const std = @import("std");

pub fn perft_root(pos: *Position.Position, depth: usize) !usize {
    if (depth == 0) {
        return 1;
    }

    var nodes: usize = 0;

    var moves = MoveGen.generate_all_pseudo_legal_moves(pos);
    defer moves.deinit();

    for (moves.items) |x| {
        pos.*.make_move(x);
        if (pos.*.is_king_checked_for(pos.*.turn.invert())) {
            pos.*.undo_move(x);
            continue;
        }
        var k = perft(pos, depth - 1);
        nodes += k;
        var s: []u8 = Uci.move_to_uci(x);
        std.debug.print("{s}: {}\n", .{ s, k });
        std.heap.page_allocator.free(s);
        pos.*.undo_move(x);
    }

    const stdout = std.io.getStdOut().writer();

    try stdout.print("nodes: {}", .{nodes});

    return nodes;
}

pub fn perft(pos: *Position.Position, depth: usize) usize {
    if (depth == 0) {
        return 1;
    }

    var nodes: usize = 0;

    var moves = MoveGen.generate_all_pseudo_legal_moves(pos);
    defer moves.deinit();

    for (moves.items) |x| {
        pos.*.make_move(x);
        if (pos.*.is_king_checked_for(pos.*.turn.invert())) {
            pos.*.undo_move(x);
            continue;
        }
        nodes += perft(pos, depth - 1);
        pos.*.undo_move(x);
    }

    return nodes;
}
