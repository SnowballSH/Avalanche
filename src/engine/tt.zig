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
    key: u32, // verification = @truncate(hash)
    eval: i32, // SEARCH score - used ONLY for alpha/beta cutoff
    static_eval: i16, // raw static eval for pruning
    bestmove: types.Move, // u16
    flag: Bound, // u2
    depth: u8,
    was_pv: u1, // PV node indicator
    age: u5,
    _padding: u16 = 0, // pad to 128 bits
};

// Verify Item fits in exactly 16 bytes (128 bits) for the two-i64 atomic scheme
comptime {
    if (@sizeOf(Item) != 16) {
        @compileError("tt.Item must be exactly 16 bytes");
    }
}

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
    age: u5,

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

    pub inline fn set(self: *TranspositionTable, hash: u64, entry: Item) void {
        const idx = self.index(hash);
        const p = &self.data.items[idx];

        // Read existing entry to check replacement policy
        const w0_raw = @as(*const i64, @ptrFromInt(@intFromPtr(p))).*;
        const w1_raw = @as(*const i64, @ptrFromInt(@intFromPtr(p) + 8)).*;
        // Reconstruct existing item from XOR scheme: stored_w0 = W0^W1, stored_w1 = W1
        // So W0 = stored_w0 ^ stored_w1
        const existing_w0 = w0_raw ^ w1_raw;
        const existing_combined: i128 = @as(i128, @bitCast([2]i64{ existing_w0, w1_raw }));
        const p_val: Item = @as(Item, @bitCast(existing_combined));

        // We overwrite entry if:
        // 1. It's empty
        // 2. New entry is exact
        // 3. Previous entry is from older search
        // 4. It is a different position
        // 5. Previous entry has lower depth (with +4 margin)
        if ((w0_raw == 0 and w1_raw == 0) or entry.flag == Bound.Exact or p_val.age != self.age or p_val.key != entry.key or p_val.depth <= entry.depth + 4) {
            // Lockless XOR store: slot[0] = W0^W1, slot[1] = W1
            const entry_as_i128: i128 = @as(i128, @bitCast(entry));
            const words: [2]i64 = @as([2]i64, @bitCast(entry_as_i128));
            const w0 = words[0];
            const w1 = words[1];
            _ = @atomicRmw(i64, @as(*i64, @ptrFromInt(@intFromPtr(p))), .Xchg, w0 ^ w1, .release);
            _ = @atomicRmw(i64, @as(*i64, @ptrFromInt(@intFromPtr(p) + 8)), .Xchg, w1, .release);
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
            const w0_raw = @as(*const i64, @ptrFromInt(@intFromPtr(p))).*;
            const w1_raw = @as(*const i64, @ptrFromInt(@intFromPtr(p) + 8)).*;
            if (w0_raw != 0 or w1_raw != 0) {
                const existing_w0 = w0_raw ^ w1_raw;
                const combined: i128 = @as(i128, @bitCast([2]i64{ existing_w0, w1_raw }));
                const entry: Item = @as(Item, @bitCast(combined));
                if (entry.age == self.age) {
                    count += 1;
                }
            }
        }
        return count * 1000 / @as(u64, sample);
    }

    pub inline fn get(self: *TranspositionTable, hash: u64) ?Item {
        const p = &self.data.items[self.index(hash)];
        // Lockless XOR read: stored slot[0] = W0^W1, slot[1] = W1
        // Reconstruct: W0 = slot[0] ^ slot[1]
        const w0_stored = @as(*const i64, @ptrFromInt(@intFromPtr(p))).*;
        const w1 = @as(*const i64, @ptrFromInt(@intFromPtr(p) + 8)).*;
        const w0 = w0_stored ^ w1;

        const combined: i128 = @as(i128, @bitCast([2]i64{ w0, w1 }));
        const entry: Item = @as(Item, @bitCast(combined));

        if (entry.flag != Bound.None and entry.key == @as(u32, @truncate(hash))) {
            return entry;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
