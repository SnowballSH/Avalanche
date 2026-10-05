const std = @import("std");
const platform = @import("../platform.zig");
const tt = @import("../engine/tt.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const SLOTS = 4;
const KEYS_PER_SLOT = 3;
const VARIANTS = 64;
const THREADS = 4;
const ROUNDS = 200_000;

/// The table indexes by the high bits of the hash and verifies by the low 32,
/// so these hashes crowd `KEYS_PER_SLOT` positions into each of `SLOTS` entries.
fn hash_of(table: *const tt.TranspositionTable, slot: usize, position: usize) u64 {
    const slot_width = std.math.maxInt(u64) / table.size + 1;
    return slot * slot_width + 0x9E37_79B9 * (slot * KEYS_PER_SLOT + position + 1);
}

fn bound_of(variant: u8) tt.Bound {
    return switch (variant % 3) {
        0 => .Exact,
        1 => .Lower,
        else => .Upper,
    };
}

/// Every field is a function of the hash and the variant, which is also the
/// stored depth, so words taken from two different stores never add up to an
/// entry this function returns.
fn entry_of(table: *const tt.TranspositionTable, hash: u64, variant: u8) tt.Item {
    const key: u32 = @truncate(hash);
    const mixed = (hash ^ variant) *% 0xD6E8_FEB8_6659_FD93;
    return .{
        .key = key,
        .eval = @bitCast(@as(u32, @truncate(mixed >> 32))),
        .static_eval = @bitCast(@as(u16, @truncate(mixed >> 16))),
        .bestmove = @bitCast(@as(u16, @truncate(mixed))),
        .flag = bound_of(variant),
        .depth = variant,
        .was_pv = @truncate(variant >> 3),
        .age = table.age,
    };
}

fn same_payload(a: tt.Item, b: tt.Item) bool {
    var x = a;
    var y = b;
    x._padding = 0;
    y._padding = 0;
    return @as(u128, @bitCast(x)) == @as(u128, @bitCast(y));
}

const Hammer = struct {
    table: *tt.TranspositionTable,
    seed: u64,
    hits: u64 = 0,
    foreign: u64 = 0,

    fn run(self: *Hammer) void {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const random = prng.random();
        for (0..ROUNDS) |_| {
            const hash = hash_of(self.table, random.uintLessThan(usize, SLOTS), random.uintLessThan(usize, KEYS_PER_SLOT));
            if (random.boolean()) {
                self.table.set(hash, entry_of(self.table, hash, random.uintLessThan(u8, VARIANTS)));
            } else if (self.table.get(hash)) |found| {
                self.hits += 1;
                if (!same_payload(found, entry_of(self.table, hash, found.depth))) self.foreign += 1;
            }
        }
    }
};

test "tt: a stored entry reads back and replacement follows depth, bound and position" {
    platform.io = std.testing.io;
    var table = tt.TranspositionTable.new();
    defer table.deinit();
    table.reset(1);

    const lower_bound_at_depth_31: u8 = 31;
    const lower_bound_at_depth_25: u8 = 25;
    const lower_bound_at_depth_28: u8 = 28;
    const exact_at_depth_3: u8 = 3;
    for ([_]u8{ lower_bound_at_depth_31, lower_bound_at_depth_25, lower_bound_at_depth_28 }) |variant| {
        try expectEqual(tt.Bound.Lower, bound_of(variant));
    }
    try expectEqual(tt.Bound.Exact, bound_of(exact_at_depth_3));

    const hash = hash_of(&table, 1, 0);
    try expect(table.get(hash) == null);

    table.set(hash, entry_of(&table, hash, lower_bound_at_depth_31));
    try expect(same_payload(table.get(hash).?, entry_of(&table, hash, lower_bound_at_depth_31)));

    table.set(hash, entry_of(&table, hash, lower_bound_at_depth_25));
    try expectEqual(lower_bound_at_depth_31, table.get(hash).?.depth);
    table.set(hash, entry_of(&table, hash, lower_bound_at_depth_28));
    try expectEqual(lower_bound_at_depth_28, table.get(hash).?.depth);
    table.set(hash, entry_of(&table, hash, exact_at_depth_3));
    try expectEqual(exact_at_depth_3, table.get(hash).?.depth);

    const other = hash_of(&table, 1, 1);
    try expectEqual(table.index(hash), table.index(other));
    try expect(table.get(other) == null);
    table.set(other, entry_of(&table, other, 1));
    try expect(table.get(hash) == null);
    try expect(same_payload(table.get(other).?, entry_of(&table, other, 1)));
}

test "tt: concurrent probes only return entries some thread stored for that key" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    platform.io = std.testing.io;
    var table = tt.TranspositionTable.new();
    defer table.deinit();
    table.reset(1);

    var hammers: [THREADS]Hammer = undefined;
    {
        var threads: [THREADS]std.Thread = undefined;
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (&hammers, &threads, 0..) |*hammer, *thread, i| {
            hammer.* = .{ .table = &table, .seed = 0x5EED + i };
            thread.* = try std.Thread.spawn(.{}, Hammer.run, .{hammer});
            started += 1;
        }
    }

    var hits: u64 = 0;
    for (&hammers) |*hammer| {
        hits += hammer.hits;
        try expectEqual(@as(u64, 0), hammer.foreign);
    }
    try expect(hits > 0);
}
