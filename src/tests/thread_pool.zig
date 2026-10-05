const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const hce = @import("../engine/hce.zig");
const search = @import("../engine/search.zig");
const thread_pool = @import("../engine/thread_pool.zig");
const tt = @import("../engine/tt.zig");
const support = @import("support.zig");
const expect = std.testing.expect;
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

const STRESS_HELPERS = 3;
const STRESS_CYCLES = 2000;
const STRESS_RESET_EVERY = 500;

const StopTiming = enum { before_the_job_is_posted, right_after_posting, during_the_search };

test "thread pool: every posted job runs and stops, whenever the stop flag is raised" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    platform.io = std.testing.io;
    support.init_search();
    tt.GlobalTT.reset(16);

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN);
    var main = search.Searcher.new();
    defer main.deinit();
    try main.hash_history.append(pos.hash);
    main.root_history_len = main.hash_history.items.len;

    var pool: thread_pool.ThreadPool = .{};
    defer pool.deinit();
    pool.resize(STRESS_HELPERS);
    try expectEqual(@as(usize, STRESS_HELPERS), pool.count());
    for (0..STRESS_HELPERS) |i| pool.worker(i).searcher.adopt_root(&main, pos);

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    for (0..STRESS_CYCLES) |cycle| {
        const timing = random.enumValue(StopTiming);
        for (0..STRESS_HELPERS) |i| {
            @atomicStore(bool, &pool.worker(i).searcher.shared.stop, timing == .before_the_job_is_posted, .monotonic);
            pool.start_search(i, .{ .color = .White, .mode = .scaled, .depth = 8, .alpha = -hce.MateScore, .beta = hce.MateScore });
        }
        if (timing == .during_the_search) {
            for (0..random.uintLessThan(usize, 2000)) |_| std.atomic.spinLoopHint();
        }
        for (0..STRESS_HELPERS) |i| @atomicStore(bool, &pool.worker(i).searcher.shared.stop, true, .monotonic);
        pool.wait_all();

        try expect(pool.all_idle());
        for (0..STRESS_HELPERS) |i| {
            const helper = pool.worker(i).searcher;
            try expect(helper.has_searched);
            try expectEqual(pos.hash, helper.root_board.hash);
            try expectEqual(main.hash_history.items.len, helper.hash_history.items.len);
        }

        if (cycle % STRESS_RESET_EVERY == STRESS_RESET_EVERY - 1) {
            pool.reset_heuristics();
            for (0..STRESS_HELPERS) |i| try expect(!pool.worker(i).searcher.has_searched);
        }
    }
}
