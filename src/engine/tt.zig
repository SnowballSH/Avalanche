const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const hce = @import("./hce.zig");

pub const Bound = enum(u2) {
    None,
    Exact,
    Lower,
    Upper,
};

pub const Item = packed struct {
    eval: hce.Score,
    bestmove: types.Move,
    flag: Bound,
    depth: u14,
    hash: u64,
};

pub const TranspositionTable = struct {
    items: std.ArrayList(Item),

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .items = std.ArrayList(Item).init(std.heap.c_allocator),
        };
    }

    pub fn reset(self: *TranspositionTable, mb: u64) void {
        self.items.clearAndFree();
        var size = mb * 1024 * 1024 / @sizeOf(Item);
        self.items.ensureTotalCapacity(size) catch {};
        self.items.expandToCapacity();
    }

    pub fn clear(self: *TranspositionTable) void {
        var size = self.items.items.len;
        self.items.clearAndFree();
        self.items.ensureTotalCapacity(size) catch {};
        self.items.expandToCapacity();
    }

    pub fn set(self: *TranspositionTable, entry: Item) void {
        self.items.items[entry.hash % self.items.items.len] = entry;
    }

    pub fn get(self: *TranspositionTable, hash: u64, depth: usize) ?Item {
        var entry = self.items.items[hash % self.items.items.len];
        if (entry.hash == hash and @intCast(usize, entry.depth) >= depth) {
            return entry;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
