const Position = @import("../board/position.zig");
const MoveGen = @import("../move/movegen.zig");
const Uci = @import("./uci.zig");
const Encode = @import("../move/encode.zig");
const TT = @import("../cache/tt.zig");
const std = @import("std");
const SEE = @import("../search/see.zig");

const Value = packed struct {
    hash: u64,
    depth: u8,
    nodes: u64,
};

var tt_size: usize = 1 << 15;

pub fn see_perft(pos: *Position.Position) void {
    const stdout = std.io.getStdOut().writer();

    var moves = MoveGen.generate_all_pseudo_legal_capture_moves(pos);

    for (moves.items) |mm| {
        var x = mm.m;
        pos.*.make_move(x, null);
        if (pos.*.is_king_checked_for(pos.*.turn.invert())) {
            pos.*.undo_move(x, null);
            continue;
        }

        pos.*.undo_move(x, null);

        stdout.print("{s}: {}\n", .{ Uci.move_to_uci(x), SEE.see(32, pos, x) }) catch {};
    }

    moves.deinit();
}

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

    std.debug.print("Perft TT allocated: {}KB\n", .{tt_size * @sizeOf(Value) / TT.KB});

    defer map.deinit();

    var nodes: usize = 0;

    var moves = MoveGen.generate_all_pseudo_legal_moves(pos);
    defer moves.deinit();

    for (moves.items) |mm| {
        var x = mm.m;
        pos.*.make_move(x, null);
        if (pos.*.is_king_checked_for(pos.*.turn.invert())) {
            pos.*.undo_move(x, null);
            continue;
        }
        var k = perft(pos, depth - 1, &map);
        nodes += k;
        var s: []u8 = Uci.move_to_uci(x);
        std.debug.print("{s}: {}\n", .{ s, k });
        std.heap.page_allocator.free(s);
        pos.*.undo_move(x, null);
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

    for (moves.items) |mm| {
        var x = mm.m;
        pos.*.make_move(x, null);
        if (pos.*.is_king_checked_for(pos.*.turn.invert())) {
            pos.*.undo_move(x, null);
            continue;
        }

        if (depth <= 127 and depth > 1) {
            var ttentry: Value = map.*.items[pos.*.hash % tt_size];
            if (ttentry.depth == depth and ttentry.hash == pos.*.hash) {
                nodes += ttentry.nodes;
                pos.*.undo_move(x, null);
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

        pos.*.undo_move(x, null);
    }

    return nodes;
}
