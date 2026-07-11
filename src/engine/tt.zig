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
        // Allocate the replacement first so a failed resize keeps the old table usable.
        const bytes = mb *% MB;
        if (mb != 0 and bytes / MB != mb) {
            // Overflow: refuse the resize and keep the existing table.
            return;
        }
        const requested_size = @max(@as(usize, 1), bytes / @sizeOf(Item));

        var new_data = std.array_list.Managed(i128).init(tt_allocator);
        new_data.ensureTotalCapacityPrecise(requested_size) catch {
            new_data.deinit();
            return;
        };
        new_data.expandToCapacity();
        if (new_data.items.len == 0) {
            new_data.deinit();
            return;
        }

        const new_size = new_data.items.len;
        const byte_len = new_size * @sizeOf(i128);
        adviseHugePages(@as([*]u8, @ptrCast(new_data.items.ptr)), byte_len);

        const num_threads = search.NUM_THREADS + 1;
        parallelMemset(new_data.items, num_threads);

        self.data.deinit();
        self.data = new_data;
        self.size = new_size;
        // Keep age so existing search generation continues to make sense.
    }

    pub inline fn clear(self: *TranspositionTable) void {
        if (self.size == 0) return;
        const num_threads = search.NUM_THREADS + 1;
        parallelMemset(self.data.items, num_threads);
    }

    pub inline fn do_age(self: *TranspositionTable) void {
        self.age +%= 1;
    }

    pub inline fn index(self: *TranspositionTable, hash: u64) u64 {
        return @as(u64, @intCast(@as(u128, @intCast(hash)) * @as(u128, @intCast(self.size)) >> 64));
    }

    const LOCK_BIT: i64 = @bitCast(@as(u64, 1) << 63);

    const Snapshot = struct {
        item: Item,
        w1: i64,
    };

    inline fn loadSnapshot(p: *i128) ?Snapshot {
        const w1_before = @atomicLoad(i64, @as(*i64, @ptrFromInt(@intFromPtr(p) + 8)), .acquire);
        if (w1_before & LOCK_BIT != 0) return null;

        const w0 = @atomicLoad(i64, @as(*i64, @ptrFromInt(@intFromPtr(p))), .acquire);
        const w1_after = @atomicLoad(i64, @as(*i64, @ptrFromInt(@intFromPtr(p) + 8)), .acquire);
        if (w1_before != w1_after or w1_after & LOCK_BIT != 0) return null;

        const combined: i128 = @as(i128, @bitCast([2]i64{ w0, w1_after }));
        return .{
            .item = @as(Item, @bitCast(combined)),
            .w1 = w1_after,
        };
    }

    pub inline fn set(self: *TranspositionTable, hash: u64, entry: Item) void {
        if (self.size == 0) return;
        const idx = self.index(hash);
        const p = &self.data.items[idx];

        // The high padding bit is a writer lock; the remaining padding bits are
        // a sequence number. Writers serialize per slot and readers accept only
        // snapshots whose sequence word is unchanged around the payload load.
        const w1_ptr = @as(*i64, @ptrFromInt(@intFromPtr(p) + 8));
        const old_w1 = @atomicRmw(i64, w1_ptr, .Or, LOCK_BIT, .acquire);
        if (old_w1 & LOCK_BIT != 0) return;

        const w0_ptr = @as(*i64, @ptrFromInt(@intFromPtr(p)));
        const old_w0 = @atomicLoad(i64, w0_ptr, .acquire);
        const existing_combined: i128 = @as(i128, @bitCast([2]i64{ old_w0, old_w1 }));
        const p_val: Item = @as(Item, @bitCast(existing_combined));

        // We overwrite entry if:
        // 1. It's empty
        // 2. New entry is exact
        // 3. Previous entry is from older search
        // 4. It is a different position
        // 5. Previous entry has lower depth (with +4 margin)
        if ((old_w0 == 0 and old_w1 == 0) or entry.flag == Bound.Exact or p_val.age != self.age or p_val.key != entry.key or p_val.depth <= entry.depth + 4) {
            var stored_entry = entry;
            stored_entry._padding = (p_val._padding +% 1) & 0x7fff;
            const entry_as_i128: i128 = @as(i128, @bitCast(stored_entry));
            const words: [2]i64 = @as([2]i64, @bitCast(entry_as_i128));
            @atomicStore(i64, w0_ptr, words[0], .monotonic);
            @atomicStore(i64, w1_ptr, words[1], .release);
        } else {
            // No replacement: release the slot without changing its sequence.
            @atomicStore(i64, w1_ptr, old_w1, .release);
        }
    }

    pub inline fn prefetch(self: *TranspositionTable, hash: u64) void {
        if (self.size == 0) return;
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
            if (loadSnapshot(p)) |snapshot| {
                const entry = snapshot.item;
                if (entry.flag != .None and entry.age == self.age) {
                    count += 1;
                }
            }
        }
        return count * 1000 / @as(u64, sample);
    }

    pub inline fn get(self: *TranspositionTable, hash: u64) ?Item {
        if (self.size == 0) return null;
        const p = &self.data.items[self.index(hash)];
        const snapshot = loadSnapshot(p) orelse return null;
        const entry = snapshot.item;

        if (entry.flag != Bound.None and entry.key == @as(u32, @truncate(hash))) {
            return entry;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
