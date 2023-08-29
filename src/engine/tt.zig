const std = @import("std");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");
const hce = @import("hce.zig");

pub const MB: usize = 1 << 20;
pub const KB: usize = 1 << 10;

pub var LOCK_GLOBAL_TT = false;

pub const Bound = enum(u2) {
    None,
    Exact, // PV Nodes
    Lower, // Cut Nodes
    Upper, // All Nodes
};

pub const Item = packed struct {
    hash: u64,
    eval: hce.Score,
    bestmove: types.Move,
    flag: Bound,
    depth: u14,
};

pub var TTArena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub const TranspositionTable = struct {
    data: std.ArrayList(i128),
    size: usize,

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .data = std.ArrayList(i128).init(TTArena.allocator()),
            .size = 16 * MB / @sizeOf(Item),
        };
    }

    pub fn reset(self: *TranspositionTable, mb: u64) void {
        self.data.deinit();
        var tt = TranspositionTable{
            .data = std.ArrayList(i128).init(TTArena.allocator()),
            .size = mb * MB / @sizeOf(Item),
        };

        tt.data.ensureTotalCapacity(tt.size) catch {};
        tt.data.expandToCapacity();

        // std.debug.print("{}\n", .{@sizeOf(Item)});
        // std.debug.print("Allocated {} KB, {} items for TT\n", .{ tt.size * @sizeOf(Item) / KB, tt.size });

        self.* = tt;
    }

    pub inline fn clear(self: *TranspositionTable) void {
        for (self.data.items) |*ptr| {
            ptr.* = 0;
        }
    }

    pub inline fn set(self: *TranspositionTable, entry: Item) void {
        _ = @atomicRmw(i128, &self.data.items[entry.hash % self.size], .Xchg, @ptrCast(*const i128, @alignCast(@alignOf(i128), &entry)).*, .Acquire);
    }

    pub inline fn prefetch(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.data.items[hash % self.size], .{
            .rw = .read,
            .locality = 1,
            .cache = .data,
        });
    }

    pub inline fn get(self: *TranspositionTable, hash: u64) ?Item {
        // self.data.items[hash % self.size].lock.lock();
        // defer self.data.items[hash % self.size].lock.unlock();
        var entry = @ptrCast(*Item, &self.data.items[hash % self.size]);
        if (entry.flag != Bound.None and entry.hash == hash) {
            return entry.*;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
