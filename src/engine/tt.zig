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
    eval: i32,
    bestmove: types.Move,
    flag: Bound,
    depth: u8,
    age: u6,
};

pub var TTArena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub const TranspositionTable = struct {
    data: std.array_list.Managed(i128),
    size: usize,
    age: u6,

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .data = std.array_list.Managed(i128).init(TTArena.allocator()),
            .size = 16 * MB / @sizeOf(Item),
            .age = 0,
        };
    }

    pub fn reset(self: *TranspositionTable, mb: u64) void {
        self.data.deinit();
        var tt = TranspositionTable{
            .data = std.array_list.Managed(i128).init(TTArena.allocator()),
            .size = @max(1, mb * MB / @sizeOf(Item)),
            .age = 0,
        };

        tt.data.ensureTotalCapacity(tt.size) catch {};
        tt.data.expandToCapacity();
        @memset(tt.data.items, 0);

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
        return @as(u64, @intCast(@as(u128, @intCast(hash)) * @as(u128, @intCast(self.size)) >> 64));
    }

    pub inline fn set(self: *TranspositionTable, entry: Item) void {
        const p = &self.data.items[self.index(entry.hash)];
        const p_val: Item = @as(*Item, @ptrCast(p)).*;
        // We overwrite entry if:
        // 1. It's empty
        // 2. New entry is exact
        // 3. Previous entry is from older search
        // 4. It is a different position
        // 5. Previous entry is from same search but has lower depth
        if (p.* == 0 or entry.flag == Bound.Exact or p_val.age != self.age or p_val.hash != entry.hash or p_val.depth <= entry.depth + 4) {
            //_ = @atomicRmw(i128, p, .Xchg, @as(*const i128, @ptrCast(@alignCast(@alignOf(i128), &entry))).*, .acquire);
            _ = @atomicRmw(i64, @as(*i64, @ptrFromInt(@intFromPtr(p))), .Xchg, @as(*const i64, @ptrFromInt(@intFromPtr(&entry))).*, .acquire);
            _ = @atomicRmw(i64, @as(*i64, @ptrFromInt(@intFromPtr(p) + 8)), .Xchg, @as(*const i64, @ptrFromInt(@intFromPtr(&entry) + 8)).*, .acquire);
        }
    }

    pub inline fn prefetch(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.data.items[self.index(hash)], .{
            .rw = .read,
            .locality = 1,
            .cache = .data,
        });
    }

    pub fn hashfull(self: *TranspositionTable) u64 {
        const sample = @min(@as(usize, 1000), self.size);
        if (sample == 0) return 0;
        var count: u64 = 0;
        var i: usize = 0;
        while (i < sample) : (i += 1) {
            const p = &self.data.items[i];
            if (p.* != 0) {
                const entry: Item = @as(*Item, @ptrCast(p)).*;
                if (entry.age == self.age) {
                    count += 1;
                }
            }
        }
        return count * 1000 / @as(u64, sample);
    }

    pub inline fn get(self: *TranspositionTable, hash: u64) ?Item {
        // self.data.items[hash % self.size].lock.lock();
        // defer self.data.items[hash % self.size].lock.unlock();
        const entry = @as(*Item, @ptrCast(&self.data.items[self.index(hash)]));
        if (entry.flag != Bound.None and entry.hash == hash) {
            return entry.*;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
