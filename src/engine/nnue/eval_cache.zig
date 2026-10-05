//! Remembers the network's output per position; see "Evaluation cache" in docs/NNUE.md.

const std = @import("std");

pub const ENTRY_BITS = 17;
pub const ENTRY_COUNT = 1 << ENTRY_BITS;

const Output = i24;
const VACANT = std.math.minInt(Output);

const Entry = packed struct(u64) {
    output: Output,
    check: Check,

    const Check = @Int(.unsigned, 64 - @bitSizeOf(Output));

    inline fn check_of(key: u64) Check {
        return @truncate(key >> ENTRY_BITS);
    }
};

pub const EvalCache = struct {
    entries: [ENTRY_COUNT]Entry,

    inline fn slot(key: u64) usize {
        return @intCast(key & (ENTRY_COUNT - 1));
    }

    pub fn clear(self: *EvalCache) void {
        @memset(&self.entries, .{ .output = VACANT, .check = 0 });
    }

    pub inline fn get(self: *const EvalCache, key: u64) ?i32 {
        const entry = self.entries[slot(key)];
        return if (entry.check == Entry.check_of(key) and entry.output != VACANT) entry.output else null;
    }

    /// `output` must lie strictly inside the range of `Output`; every network head does.
    pub inline fn put(self: *EvalCache, key: u64, output: i32) void {
        std.debug.assert(output > VACANT and output <= std.math.maxInt(Output));
        self.entries[slot(key)] = .{ .output = @intCast(output), .check = Entry.check_of(key) };
    }
};

test "an empty cache misses every key, including the ones whose check bits are zero" {
    const cache = try std.testing.allocator.create(EvalCache);
    defer std.testing.allocator.destroy(cache);
    cache.clear();
    for ([_]u64{ 0, 1, ENTRY_COUNT, ENTRY_COUNT - 1, std.math.maxInt(u64) }) |key| {
        try std.testing.expectEqual(@as(?i32, null), cache.get(key));
    }
}

test "a stored output is returned for its key only, and the newer key takes a shared slot" {
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

test "outputs at both ends of the stored range survive, and zero is not mistaken for vacant" {
    const cache = try std.testing.allocator.create(EvalCache);
    defer std.testing.allocator.destroy(cache);
    cache.clear();

    const extremes = [_]i32{ VACANT + 1, -1, 0, 1, std.math.maxInt(Output) };
    for (extremes, 0..) |output, key| cache.put(key, output);
    for (extremes, 0..) |output, key| try std.testing.expectEqual(@as(?i32, output), cache.get(key));
}
