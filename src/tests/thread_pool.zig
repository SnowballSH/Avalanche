const std = @import("std");
const platform = @import("../platform.zig");
const search = @import("../engine/search.zig");
const thread_pool = @import("../engine/thread_pool.zig");
const support = @import("support.zig");
const expectEqual = std.testing.expectEqual;

test "thread pool: grows, resets in parallel, shrinks and shuts down" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    platform.io = std.testing.io;
    support.init_tables();
    search.init_lmr();

    var pool: thread_pool.ThreadPool = .{};
    defer pool.deinit();

    pool.resize(3);
    try expectEqual(@as(usize, 3), pool.count());
    for (0..3) |i| {
        try expectEqual(i, pool.worker(i).helper_index);
        pool.worker(i).searcher.history[0][1][2] = 99;
        pool.worker(i).searcher.has_searched = true;
    }

    pool.reset_heuristics();
    for (0..3) |i| {
        try expectEqual(@as(i32, 0), pool.worker(i).searcher.history[0][1][2]);
        try std.testing.expect(!pool.worker(i).searcher.has_searched);
    }

    pool.resize(1);
    try expectEqual(@as(usize, 1), pool.count());
    pool.resize(4);
    try expectEqual(@as(usize, 4), pool.count());
    pool.resize(0);
    try expectEqual(@as(usize, 0), pool.count());
}
