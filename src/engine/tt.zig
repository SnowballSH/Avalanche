const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const search = @import("search.zig");
const hce = @import("hce.zig");

pub const MB: usize = 1 << 20;
pub const MAX_HASH_MB: usize = 1048576;

pub const Bound = enum(u2) {
    None,
    Exact, // PV Nodes
    Lower, // Cut Nodes
    Upper, // All Nodes
};

pub const EVAL_NONE: i16 = -32768;

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

const large_memory = platform.large_memory;

fn first_touch_threads() usize {
    if (comptime !platform.has_threads) return 1;
    if (search.THREADS_CONFIGURED) return search.NUM_THREADS + 1;
    return std.Thread.getCpuCount() catch 1;
}

pub const TT_ALIGN: usize = large_memory.ALIGNMENT;

// `&.{}` would carry @alignOf(i128), contradicting the declared alignment.
var empty_table: [0]i128 align(TT_ALIGN) = .{};

pub const TranspositionTable = struct {
    data: []align(TT_ALIGN) i128,
    size: usize,
    age: u5,

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .data = &empty_table,
            .size = 0,
            .age = 0,
        };
    }

    pub fn deinit(self: *TranspositionTable) void {
        large_memory.free(self.data);
        self.data = &empty_table;
        self.size = 0;
    }

    pub fn reset(self: *TranspositionTable, mb: u64) void {
        const bytes = mb *% MB;
        if (mb != 0 and bytes / MB != mb) {
            return;
        }
        const requested_size: usize = @intCast(@max(1, @min(bytes / @sizeOf(Item), std.math.maxInt(usize))));

        const new_data = large_memory.alloc_populated(i128, requested_size, "hash", first_touch_threads()) catch return;

        self.deinit();
        self.data = new_data;
        self.size = new_data.len;
    }

    pub fn clear(self: *TranspositionTable) void {
        large_memory.zero(std.mem.sliceAsBytes(self.data), first_touch_threads());
    }

    /// How much of the table the OS backs with huge pages right now.
    pub fn huge_page_bytes(self: *const TranspositionTable) u64 {
        return large_memory.huge_page_bytes(std.mem.sliceAsBytes(self.data));
    }

    pub inline fn do_age(self: *TranspositionTable) void {
        self.age +%= 1;
    }

    pub inline fn index(self: *TranspositionTable, hash: u64) usize {
        if (comptime @bitSizeOf(usize) <= 32) {
            // Same result as the u128 form using only 64-bit multiplies, since
            // 128-bit products lower to a slow libcall on 32-bit targets.
            const size: u64 = self.size;
            const hi = (hash >> 32) * size;
            const lo = ((hash & 0xFFFF_FFFF) * size) >> 32;
            return @intCast((hi + lo) >> 32);
        }
        return @as(usize, @intCast(@as(u128, @intCast(hash)) * @as(u128, @intCast(self.size)) >> 64));
    }

    const LOCK_BIT: i64 = @bitCast(@as(u64, 1) << 63);

    const Snapshot = struct {
        item: Item,
        w1: i64,
    };

    inline fn loadSnapshot(p: *i128) ?Snapshot {
        const w1_before = platform.atomicLoad(i64, @as(*i64, @ptrFromInt(@intFromPtr(p) + 8)), .acquire);
        if (w1_before & LOCK_BIT != 0) return null;

        const w0 = platform.atomicLoad(i64, @as(*i64, @ptrFromInt(@intFromPtr(p))), .acquire);
        const w1_after = platform.atomicLoad(i64, @as(*i64, @ptrFromInt(@intFromPtr(p) + 8)), .acquire);
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
        const p = &self.data[idx];

        // Slot lock in the high bit of word1; remaining padding bits are a sequence.
        const w1_ptr = @as(*i64, @ptrFromInt(@intFromPtr(p) + 8));
        const old_w1 = platform.atomicRmw(i64, w1_ptr, .Or, LOCK_BIT, .acquire);
        if (old_w1 & LOCK_BIT != 0) return;

        const w0_ptr = @as(*i64, @ptrFromInt(@intFromPtr(p)));
        const old_w0 = platform.atomicLoad(i64, w0_ptr, .acquire);
        const existing_combined: i128 = @as(i128, @bitCast([2]i64{ old_w0, old_w1 }));
        const p_val: Item = @as(Item, @bitCast(existing_combined));

        // We overwrite entry if:
        // 1. It's empty
        // 2. New entry is exact
        // 3. Previous entry is from older search
        // 4. It is a different position
        // 5. Previous entry has lower depth (with +4 margin)
        if ((old_w0 == 0 and old_w1 == 0) or entry.flag == Bound.Exact or p_val.age != self.age or p_val.key != entry.key or @as(u16, p_val.depth) <= @as(u16, entry.depth) + 4) {
            var stored_entry = entry;
            stored_entry._padding = (p_val._padding +% 1) & 0x7fff;
            const entry_as_i128: i128 = @as(i128, @bitCast(stored_entry));
            const words: [2]i64 = @as([2]i64, @bitCast(entry_as_i128));
            platform.atomicStore(i64, w0_ptr, words[0], .monotonic);
            platform.atomicStore(i64, w1_ptr, words[1], .release);
        } else {
            platform.atomicStore(i64, w1_ptr, old_w1, .release);
        }
    }

    pub inline fn prefetch(self: *TranspositionTable, hash: u64) void {
        if (self.size == 0) return;
        @prefetch(&self.data[self.index(hash)], .{
            .rw = .read,
            .locality = 3,
            .cache = .data,
        });
    }

    pub fn hashfull(self: *TranspositionTable) u64 {
        const sample = @min(@as(usize, 1000), self.size);
        if (sample == 0) return 0;
        var count: u64 = 0;
        var i: usize = 0;
        while (i < sample) : (i += 1) {
            const p = &self.data[i];
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
        const p = &self.data[self.index(hash)];
        const snapshot = loadSnapshot(p) orelse return null;
        const entry = snapshot.item;

        if (entry.flag != Bound.None and entry.key == @as(u32, @truncate(hash))) {
            return entry;
        }
        return null;
    }
};

pub var GlobalTT = TranspositionTable.new();
