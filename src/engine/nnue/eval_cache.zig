//! Remembers the network's output per position; see "Evaluation cache" in docs/NNUE.md.

const std = @import("std");

pub const ENTRY_BITS = 16;
pub const ENTRY_COUNT = 1 << ENTRY_BITS;

const Entry = struct {
    key: u64,
    value: i32,
};

pub const EvalCache = struct {
    entries: [ENTRY_COUNT]Entry,

    inline fn slot(key: u64) usize {
        return @intCast(key & (ENTRY_COUNT - 1));
    }

    /// Leaves every slot holding a key that belongs to another slot, so no key can hit.
    pub fn clear(self: *EvalCache) void {
        for (&self.entries, 0..) |*entry, index| {
            entry.* = .{ .key = @intFromBool(index == 0), .value = 0 };
        }
    }

    pub inline fn get(self: *const EvalCache, key: u64) ?i32 {
        const entry = &self.entries[slot(key)];
        return if (entry.key == key) entry.value else null;
    }

    pub inline fn put(self: *EvalCache, key: u64, value: i32) void {
        self.entries[slot(key)] = .{ .key = key, .value = value };
    }
};

test "an empty cache misses every key, including the ones that are zero in a slot's bits" {
    const cache = try std.testing.allocator.create(EvalCache);
    defer std.testing.allocator.destroy(cache);
    cache.clear();
    for ([_]u64{ 0, 1, ENTRY_COUNT, ENTRY_COUNT - 1, std.math.maxInt(u64) }) |key| {
        try std.testing.expectEqual(@as(?i32, null), cache.get(key));
    }
}

test "a stored value is returned for its key only, and the newer key takes a shared slot" {
    const cache = try std.testing.allocator.create(EvalCache);
    defer std.testing.allocator.destroy(cache);
    cache.clear();

    const key: u64 = 0x1234_5678_9abc_def0;
    const same_slot = key ^ (1 << 40);
    cache.put(key, -77);
    try std.testing.expectEqual(@as(?i32, -77), cache.get(key));
    try std.testing.expectEqual(@as(?i32, null), cache.get(same_slot));

    cache.put(same_slot, 12);
    try std.testing.expectEqual(@as(?i32, 12), cache.get(same_slot));
    try std.testing.expectEqual(@as(?i32, null), cache.get(key));
}
