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
    eval: hce.Score,
    bestmove: types.Move,
    flag: Bound,
    depth: u14,
    hash: u64,
};

pub const TTItem = struct {
    item: Item,
    lock: std.Thread.Mutex,
};

pub var TTArena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub const TranspositionTable = struct {
    data: std.ArrayList(TTItem),
    size: usize,

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .data = std.ArrayList(TTItem).init(TTArena.allocator()),
            .size = 16 * MB / @sizeOf(TTItem),
        };
    }

    pub fn reset(self: *TranspositionTable, mb: u64) void {
        self.data.deinit();
        var tt = TranspositionTable{
            .data = std.ArrayList(TTItem).init(TTArena.allocator()),
            .size = mb * MB / @sizeOf(TTItem),
        };

        tt.data.ensureTotalCapacity(tt.size) catch {};
        tt.data.expandToCapacity();

        // std.debug.print("Allocated {} KB, {} items for TT\n", .{ tt.size * @sizeOf(Item) / KB, tt.size });

        self.* = tt;
    }

    pub inline fn clear(self: *TranspositionTable) void {
        for (self.data.items) |*ptr| {
            ptr.* = std.mem.zeroes(TTItem);
        }
    }

    pub inline fn set(self: *TranspositionTable, entry: Item) void {
        if (LOCK_GLOBAL_TT or search.NUM_THREADS != 1) {
            self.data.items[entry.hash % self.size].lock.lock();
            defer self.data.items[entry.hash % self.size].lock.unlock();
        }
        self.data.items[entry.hash % self.size].item = entry;
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
        var entry = self.data.items[hash % self.size].item;
        if (entry.flag != Bound.None and entry.hash == hash) {
            return entry;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
