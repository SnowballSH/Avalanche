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
    depth: u8,
    age: u6,
};

pub var TTArena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub const TranspositionTable = struct {
    data: std.ArrayList(i128),
    size: usize,
    age: u6,

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .data = std.ArrayList(i128).init(TTArena.allocator()),
            .size = 16 * MB / @sizeOf(Item),
            .age = 0,
        };
    }

    pub fn reset(self: *TranspositionTable, mb: u64) void {
        self.data.deinit();
        var tt = TranspositionTable{
            .data = std.ArrayList(i128).init(TTArena.allocator()),
            .size = mb * MB / @sizeOf(Item),
            .age = 0,
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

    pub inline fn do_age(self: *TranspositionTable) void {
        self.age +%= 1;
    }

    pub inline fn index(self: *TranspositionTable, hash: u64) u64 {
        return @intCast(u64, @intCast(u128, hash) * @intCast(u128, self.size) >> 64);
    }

    pub inline fn set(self: *TranspositionTable, entry: Item) void {
        var p = &self.data.items[self.index(entry.hash)];
        var p_val: Item = @ptrCast(*Item, p).*;
        // We overwrite entry if:
        // 1. It's empty
        // 2. New entry is exact
        // 3. Previous entry is from older search
        // 4. It is a different position
        // 5. Previous entry is from same search but has lower depth
        if (p.* == 0 or entry.flag == Bound.Exact or p_val.age != self.age or p_val.hash != entry.hash or p_val.depth <= entry.depth + 4) {
            //_ = @atomicRmw(i128, p, .Xchg, @ptrCast(*const i128, @alignCast(@alignOf(i128), &entry)).*, .Acquire);
            _ = @atomicRmw(i64, @intToPtr(*i64, @ptrToInt(p)), .Xchg, @intToPtr(*const i64, @ptrToInt(&entry)).*, .Acquire);
            _ = @atomicRmw(i64, @intToPtr(*i64, @ptrToInt(p) + 8), .Xchg, @intToPtr(*const i64, @ptrToInt(&entry) + 8).*, .Acquire);
        }
    }

    pub inline fn prefetch(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.data.items[self.index(hash)], .{
            .rw = .read,
            .locality = 1,
            .cache = .data,
        });
    }

    pub inline fn get(self: *TranspositionTable, hash: u64) ?Item {
        // self.data.items[hash % self.size].lock.lock();
        // defer self.data.items[hash % self.size].lock.unlock();
        var entry = @ptrCast(*Item, &self.data.items[self.index(hash)]);
        if (entry.flag != Bound.None and entry.hash == hash) {
            return entry.*;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
