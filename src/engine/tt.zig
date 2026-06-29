const std = @import("std");
const builtin = @import("builtin");
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

const tt_allocator = std.heap.c_allocator;

fn parallelMemset(data: []i128, num_threads: usize) void {
    const len = data.len;
    if (len == 0) return;

    const MIN_ENTRIES_PER_THREAD = 1024 * 1024 / @sizeOf(i128);
    const max_useful_threads = @max(1, len / MIN_ENTRIES_PER_THREAD);
    const threads_to_use = @max(1, @min(num_threads, @min(max_useful_threads, search.MAX_THREADS)));
    if (threads_to_use <= 1) {
        @memset(data, 0);
        return;
    }

    const chunk_size = len / threads_to_use;
    var thread_handles: [search.MAX_THREADS]?std.Thread = undefined;

    for (0..threads_to_use) |i| {
        const start = i * chunk_size;
        const end = if (i == threads_to_use - 1) len else (i + 1) * chunk_size;
        thread_handles[i] = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, memsetWorker, .{data[start..end]}) catch null;
        if (thread_handles[i] == null) {
            @memset(data[start..end], 0);
        }
    }

    for (0..threads_to_use) |i| {
        if (thread_handles[i]) |t| {
            t.join();
        }
    }
}

fn memsetWorker(slice: []i128) void {
    @memset(slice, 0);
}

fn adviseHugePages(ptr: [*]u8, len: usize) void {
    if (builtin.os.tag == .linux) {
        const MADV_HUGEPAGE = 14;
        const addr = @intFromPtr(ptr);
        if (addr & 4095 == 0) {
            const aligned_ptr: [*]align(4096) u8 = @ptrFromInt(addr);
            std.posix.madvise(aligned_ptr, len, MADV_HUGEPAGE) catch {};
        }
    }
}

pub const TranspositionTable = struct {
    data: std.array_list.Managed(i128),
    size: usize,
    age: u6,

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .data = std.array_list.Managed(i128).init(tt_allocator),
            .size = 0,
            .age = 0,
        };
    }

    pub fn reset(self: *TranspositionTable, mb: u64) void {
        self.data.deinit();
        const requested_size = @max(1, mb * MB / @sizeOf(Item));
        var new_tt = TranspositionTable{
            .data = std.array_list.Managed(i128).init(tt_allocator),
            .size = requested_size,
            .age = 0,
        };

        new_tt.data.ensureTotalCapacityPrecise(requested_size) catch {};
        new_tt.data.expandToCapacity();

        if (new_tt.data.items.len == 0) {
            new_tt.size = 0;
            self.* = new_tt;
            return;
        }

        new_tt.size = new_tt.data.items.len;

        const byte_len = new_tt.size * @sizeOf(i128);
        adviseHugePages(@as([*]u8, @ptrCast(new_tt.data.items.ptr)), byte_len);

        const num_threads = search.NUM_THREADS + 1;
        parallelMemset(new_tt.data.items, num_threads);

        self.* = new_tt;
    }

    pub inline fn clear(self: *TranspositionTable) void {
        const num_threads = search.NUM_THREADS + 1;
        parallelMemset(self.data.items, num_threads);
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
