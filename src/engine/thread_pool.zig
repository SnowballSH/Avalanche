//! Persistent helper threads for Lazy SMP. See docs/THREADS.md.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const numa = @import("numa.zig");
const Searcher = @import("search.zig").Searcher;

const STACK_SIZE = 64 * 1024 * 1024;

pub const SearchJob = struct {
    color: types.Color,
    depth: usize,
    alpha: i32,
    beta: i32,
};

const Job = union(enum) {
    idle,
    reset_heuristics,
    search: SearchJob,
    quit,
};

/// One parked helper thread and the searcher it owns. The searcher is
/// allocated and initialised on the worker's own thread after NUMA placement,
/// so its tables are first touched on the worker's node.
pub const Worker = struct {
    helper_index: usize,
    searcher: *Searcher = undefined,
    thread: std.Thread = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    job: Job = .idle,
    busy: bool = true,

    fn submit(self: *Worker, job: Job) void {
        self.mutex.lockUncancelable(platform.io);
        std.debug.assert(!self.busy);
        self.job = job;
        self.busy = true;
        self.mutex.unlock(platform.io);
        self.cond.broadcast(platform.io);
    }

    pub fn wait_idle(self: *Worker) void {
        self.mutex.lockUncancelable(platform.io);
        while (self.busy) self.cond.waitUncancelable(platform.io, &self.mutex);
        self.mutex.unlock(platform.io);
    }

    fn finish(self: *Worker) void {
        self.mutex.lockUncancelable(platform.io);
        self.job = .idle;
        self.busy = false;
        self.mutex.unlock(platform.io);
        self.cond.broadcast(platform.io);
    }

    fn next_job(self: *Worker) Job {
        self.mutex.lockUncancelable(platform.io);
        defer self.mutex.unlock(platform.io);
        while (self.job == .idle) self.cond.waitUncancelable(platform.io, &self.mutex);
        return self.job;
    }

    fn main(self: *Worker) void {
        numa.place_current_thread(self.helper_index + 1);
        self.searcher = platform.allocator.create(Searcher) catch @panic("out of memory for helper searcher");
        self.searcher.init();
        self.finish();

        while (true) {
            switch (self.next_job()) {
                .idle => unreachable,
                .reset_heuristics => {
                    self.searcher.age_pending = false;
                    self.searcher.has_searched = false;
                    self.searcher.reset_heuristics(true);
                },
                .search => |job| self.searcher.start_helper(job.color, job.depth, job.alpha, job.beta),
                .quit => {
                    self.searcher.deinit();
                    platform.allocator.destroy(self.searcher);
                    self.finish();
                    return;
                },
            }
            self.finish();
        }
    }
};

pub const ThreadPool = struct {
    workers: std.array_list.Managed(*Worker) = std.array_list.Managed(*Worker).init(platform.allocator),

    pub fn count(self: *const ThreadPool) usize {
        return self.workers.items.len;
    }

    pub fn worker(self: *ThreadPool, index: usize) *Worker {
        return self.workers.items[index];
    }

    /// Grows or shrinks to `target` helpers; stops early if a thread cannot be created.
    pub fn resize(self: *ThreadPool, target: usize) void {
        if (comptime !platform.has_threads) return;
        while (self.workers.items.len > target) {
            const w = self.workers.pop().?;
            w.submit(.quit);
            w.thread.join();
            platform.allocator.destroy(w);
        }

        const old_len = self.workers.items.len;
        self.workers.ensureTotalCapacity(target) catch return;
        while (self.workers.items.len < target) {
            const w = platform.allocator.create(Worker) catch break;
            w.* = .{ .helper_index = self.workers.items.len };
            w.thread = std.Thread.spawn(.{ .stack_size = STACK_SIZE }, Worker.main, .{w}) catch {
                platform.allocator.destroy(w);
                break;
            };
            self.workers.appendAssumeCapacity(w);
        }
        for (self.workers.items[old_len..]) |w| w.wait_idle();
    }

    pub fn start_search(self: *ThreadPool, index: usize, job: SearchJob) void {
        self.worker(index).submit(.{ .search = job });
    }

    /// Runs a job on every worker in parallel and waits for all of them.
    pub fn reset_heuristics(self: *ThreadPool) void {
        for (self.workers.items) |w| w.submit(.reset_heuristics);
        self.wait_all();
    }

    pub fn wait_all(self: *ThreadPool) void {
        for (self.workers.items) |w| w.wait_idle();
    }

    pub fn deinit(self: *ThreadPool) void {
        self.resize(0);
        self.workers.deinit();
    }
};
