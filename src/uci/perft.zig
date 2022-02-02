const Position = @import("../board/position.zig");
const MoveGen = @import("../move/movegen.zig");
const Uci = @import("./uci.zig");
const TT = @import("../cache/tt.zig");
const std = @import("std");

const Value = struct {
    hash: u64,
    depth: u8,
    nodes: u64,
};

var tt_size: usize = 1 << 15;

pub fn perft_root(pos: *Position.Position, depth: usize) !usize {
    if (depth == 0) {
        return 1;
    }

    tt_size = (1 << 15) * depth;

    var map = std.ArrayList(Value).initCapacity(
        TT.TTArena.allocator(),
        tt_size,
    ) catch unreachable;
    map.expandToCapacity();
    for (map.items) |*ptr| {
        ptr.* = Value{
            .depth = 0,
            .nodes = 0,
            .hash = 0,
        };
    }

    std.debug.print("Perft TT allocated: {}KB\n", .{tt_size * @sizeOf(Value) / TT.KB});

    defer map.deinit();

    var nodes: usize = 0;

    var moves = MoveGen.generate_all_pseudo_legal_moves(pos);
    defer moves.deinit();

    for (moves.items) |x| {
        pos.*.make_move(x);
        if (pos.*.is_king_checked_for(pos.*.turn.invert())) {
            pos.*.undo_move(x);
            continue;
        }
        var k = perft(pos, depth - 1, &map);
        nodes += k;
        var s: []u8 = Uci.move_to_uci(x);
        std.debug.print("{s}: {}\n", .{ s, k });
        std.heap.page_allocator.free(s);
        pos.*.undo_move(x);
    }

    const stdout = std.io.getStdOut().writer();

    try stdout.print("nodes: {}\n", .{nodes});

    return nodes;
}

pub fn perft(pos: *Position.Position, depth: usize, map: *std.ArrayList(Value)) usize {
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

        if (depth <= 127 and depth > 1) {
            var ttentry: Value = map.*.items[pos.*.hash % tt_size];
            if (ttentry.depth == depth and ttentry.hash == pos.*.hash) {
                nodes += ttentry.nodes;
                pos.*.undo_move(x);
                continue;
            }
        }

        var res = perft(pos, depth - 1, map);
        nodes += res;

        if (depth <= 127 and depth > 1) {
            map.*.items[pos.*.hash % tt_size] = Value{
                .nodes = @intCast(u64, res),
                .depth = @intCast(u8, depth),
                .hash = pos.*.hash,
            };
        }

        pos.*.undo_move(x);
    }

    return nodes;
}
