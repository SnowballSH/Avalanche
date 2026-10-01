//! Persistent helper threads for Lazy SMP. See docs/THREADS.md.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const numa = @import("numa.zig");
const Searcher = @import("search.zig").Searcher;

const STACK_SIZE = 64 * 1024 * 1024;

pub const SearchJob = struct {
    main: *Searcher,
    root_hash: u64,
    color: types.Color,
    depth: usize,
    alpha: i32,
    beta: i32,
};

const Job = union(enum) {
    reset_heuristics,
    search: SearchJob,
    quit,
};

/// A job for the workers in [first, end). Every worker acknowledges every
/// posting, so it stays untouched until the pool is idle again.
const Posting = struct {
    job: Job,
    first: usize,
    end: usize,
};

/// One parked helper thread and the searcher it owns. The searcher is
/// allocated and initialised on the worker's own thread after NUMA placement,
/// so its tables are first touched on the worker's node.
pub const Worker = struct {
    pool: *ThreadPool,
    helper_index: usize,
    seen_generation: u32,
    searcher: *Searcher = undefined,
    thread: std.Thread = undefined,

    fn next_posting(self: *Worker) *const Posting {
        const generation = &self.pool.generation;
        while (true) {
            const current = generation.load(.acquire);
            if (current != self.seen_generation) {
                self.seen_generation = current;
                return &self.pool.posting;
            }
            platform.io.futexWaitUncancelable(u32, &generation.raw, current);
        }
    }

    fn main(self: *Worker) void {
        numa.place_current_thread(self.helper_index + 1);
        self.searcher = platform.allocator.create(Searcher) catch @panic("out of memory for helper searcher");
        self.searcher.init();
        self.pool.acknowledge(1);

        while (true) {
            const posting = self.next_posting();
            const addressed = self.helper_index >= posting.first and self.helper_index < posting.end;
            if (addressed) switch (posting.job) {
                .reset_heuristics => {
                    self.searcher.age_pending = false;
                    self.searcher.has_searched = false;
                    self.searcher.reset_heuristics(true);
                },
                .search => |job| self.searcher.start_helper(self.helper_index + 1, job),
                .quit => {
                    self.searcher.deinit();
                    platform.allocator.destroy(self.searcher);
                    self.pool.acknowledge(1);
                    return;
                },
            };
            self.pool.acknowledge(1);
        }
    }
};

/// The pool's owner posts one job at a time and waits for the pool to go idle
/// before posting the next. Either step costs the owner one wake or one wait,
/// whatever the number of workers.
pub const ThreadPool = struct {
    workers: std.array_list.Managed(*Worker) = std.array_list.Managed(*Worker).init(platform.allocator),
    posting: Posting = undefined,
    /// Bumped once per posting; workers sleep on it.
    generation: std.atomic.Value(u32) = .init(0),
    /// Workers that have not yet acknowledged the posting (or their start-up).
    pending: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    /// 1 when `pending` is zero; the owner sleeps on it.
    idle: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(1),

    pub fn count(self: *const ThreadPool) usize {
        return self.workers.items.len;
    }

    pub fn worker(self: *ThreadPool, index: usize) *Worker {
        return self.workers.items[index];
    }

    fn expect_acknowledgements(self: *ThreadPool, n: usize) void {
        std.debug.assert(self.idle.load(.acquire) == 1);
        self.pending.store(@intCast(n), .monotonic);
        self.idle.store(0, .monotonic);
    }

    fn acknowledge(self: *ThreadPool, n: u32) void {
        if (n == 0) return;
        if (self.pending.fetchSub(n, .acq_rel) == n) {
            self.idle.store(1, .release);
            platform.io.futexWake(u32, &self.idle.raw, 1);
        }
    }

    fn post(self: *ThreadPool, job: Job, first: usize, end: usize) void {
        if (self.workers.items.len == 0) return;
        self.expect_acknowledgements(self.workers.items.len);
        self.posting = .{ .job = job, .first = first, .end = end };
        // Publishes the posting and the latch: a worker that has not gone to
        // sleep yet sees the new generation, a sleeping one is woken.
        self.generation.store(self.generation.load(.monotonic) +% 1, .release);
        platform.io.futexWake(u32, &self.generation.raw, std.math.maxInt(u32));
    }

    pub fn wait_idle(self: *ThreadPool) void {
        while (self.idle.load(.acquire) == 0) platform.io.futexWaitUncancelable(u32, &self.idle.raw, 0);
    }

    /// Grows or shrinks to `target` helpers; stops early if a thread cannot be created.
    pub fn resize(self: *ThreadPool, target: usize) void {
        if (comptime !platform.has_threads) return;
        numa.init();
        if (self.workers.items.len > target) {
            self.post(.quit, target, self.workers.items.len);
            self.wait_idle();
            while (self.workers.items.len > target) {
                const w = self.workers.pop().?;
                w.thread.join();
                platform.allocator.destroy(w);
            }
        }
        if (self.workers.items.len >= target) return;

        self.workers.ensureTotalCapacity(target) catch return;
        var missing: u32 = @intCast(target - self.workers.items.len);
        self.expect_acknowledgements(missing);
        while (missing > 0) : (missing -= 1) {
            const w = platform.allocator.create(Worker) catch break;
            w.* = .{
                .pool = self,
                .helper_index = self.workers.items.len,
                .seen_generation = self.generation.load(.monotonic),
            };
            w.thread = std.Thread.spawn(.{ .stack_size = STACK_SIZE }, Worker.main, .{w}) catch {
                platform.allocator.destroy(w);
                break;
            };
            self.workers.appendAssumeCapacity(w);
        }
        self.acknowledge(missing);
        self.wait_idle();
    }

    /// Starts `job` on the first `helpers` workers; `wait_idle` joins them.
    pub fn start_search(self: *ThreadPool, helpers: usize, job: SearchJob) void {
        self.post(.{ .search = job }, 0, helpers);
    }

    /// Resets every worker in parallel, each on its own thread.
    pub fn reset_heuristics(self: *ThreadPool) void {
        self.post(.reset_heuristics, 0, self.workers.items.len);
        self.wait_idle();
    }

    pub fn deinit(self: *ThreadPool) void {
        self.resize(0);
        self.workers.deinit();
    }
};
