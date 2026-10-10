//! NUMA topology and search-thread placement. See docs/THREADS.md.
//!
//! Topology comes from Linux sysfs and binding uses sched_setaffinity; on any
//! other target the machine is a single node and binding is a no-op.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");

pub const MAX_NODES = 64;
pub const MAX_CPUS = 1024;

pub const CpuSet = std.bit_set.Static(MAX_CPUS);

const SMALL_NODE_PERCENT = 60;
const THREADS_PER_NODE_WORTH_BINDING = 4;

pub const Policy = enum { auto, none };

pub var policy: Policy = .auto;

const supported = builtin.target.os.tag == .linux and !platform.is_wasm;

pub const ParseError = error{ InvalidCpuList, TooManyCpus, TooManyNodes };

pub const Topology = struct {
    node_cpus: [MAX_NODES]CpuSet = @splat(.empty),
    node_count: usize = 0,

    pub fn single_node() Topology {
        var single: Topology = .{ .node_count = 1 };
        single.node_cpus[0] = .full;
        return single;
    }

    pub fn add_node(self: *Topology, cpulist: []const u8) ParseError!void {
        try self.add_cpus(try parse_cpulist(cpulist));
    }

    fn add_cpus(self: *Topology, cpus: CpuSet) ParseError!void {
        if (self.node_count == MAX_NODES) return ParseError.TooManyNodes;
        self.node_cpus[self.node_count] = cpus;
        self.node_count += 1;
    }

    pub fn is_numa(self: *const Topology) bool {
        return self.node_count > 1;
    }

    fn node_sizes(self: *const Topology) [MAX_NODES]usize {
        var sizes: [MAX_NODES]usize = @splat(0);
        for (self.node_cpus[0..self.node_count], sizes[0..self.node_count]) |cpus, *size| size.* = cpus.count();
        return sizes;
    }

    pub fn needs_binding(self: *const Topology, thread_count: usize) bool {
        if (!self.is_numa()) return false;
        const sizes = self.node_sizes();
        const largest = std.mem.max(usize, sizes[0..self.node_count]);
        var full_size_nodes: usize = 0;
        for (sizes[0..self.node_count]) |size| {
            if (size * 100 > largest * SMALL_NODE_PERCENT) full_size_nodes += 1;
        }
        return thread_count > largest / 2 or thread_count >= full_size_nodes * THREADS_PER_NODE_WORTH_BINDING;
    }

    pub fn node_for_thread(self: *const Topology, thread_index: usize) usize {
        const sizes = self.node_sizes();
        var threads_on: [MAX_NODES]usize = @splat(0);
        var chosen: usize = 0;
        for (0..thread_index + 1) |_| {
            chosen = 0;
            for (1..self.node_count) |node| {
                // (threads_on[node] + 1) / sizes[node] < (threads_on[chosen] + 1) / sizes[chosen]
                if ((threads_on[node] + 1) * sizes[chosen] < (threads_on[chosen] + 1) * sizes[node]) chosen = node;
            }
            threads_on[chosen] += 1;
        }
        return chosen;
    }
};

/// Parses the kernel cpulist format, e.g. "0-3,8-11\n".
pub fn parse_cpulist(text: []const u8) ParseError!CpuSet {
    var set = CpuSet.empty;
    var ranges = std.mem.tokenizeAny(u8, text, ", \t\r\n");
    while (ranges.next()) |range| {
        var bounds = std.mem.splitScalar(u8, range, '-');
        const first = std.fmt.parseUnsigned(usize, bounds.first(), 10) catch return ParseError.InvalidCpuList;
        const last = if (bounds.next()) |hi| std.fmt.parseUnsigned(usize, hi, 10) catch return ParseError.InvalidCpuList else first;
        if (bounds.next() != null or last < first) return ParseError.InvalidCpuList;
        if (last >= MAX_CPUS) return ParseError.TooManyCpus;
        set.setRangeValue(.{ .start = first, .end = last + 1 }, true);
    }
    return set;
}

var detected: ?Topology = null;

const SYSFS_NODES = "/sys/devices/system/node";

/// Detects the topology once. Must run before any search thread is placed and
/// on a thread that still has the process's CPU mask (the UCI thread), since
/// placement stays within the CPUs the process was started with.
pub fn init() void {
    if (detected != null) return;
    detected = if (supported)
        detect(SYSFS_NODES, allowed_cpus()) catch Topology.single_node()
    else
        Topology.single_node();
}

pub fn topology() *const Topology {
    std.debug.assert(detected != null);
    return &detected.?;
}

/// CPUs the calling thread may run on, e.g. as restricted by taskset or a cpuset.
fn allowed_cpus() CpuSet {
    if (!supported) return CpuSet.full;
    var mask: std.os.linux.cpu_set_t = undefined;
    if (std.os.linux.errno(std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &mask)) != .SUCCESS) {
        return CpuSet.full;
    }
    var set = CpuSet.empty;
    for (mask, 0..) |word, i| {
        var bits = word;
        while (bits != 0) : (bits &= bits - 1) set.set(i * @bitSizeOf(usize) + @ctz(bits));
    }
    return set;
}

/// Reads `<root>/online` and each online node's `<root>/node<N>/cpulist`,
/// keeping only `allowed` CPUs and dropping nodes left without any.
pub fn detect(root: []const u8, allowed: CpuSet) !Topology {
    var buf: [4096]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.Io.Dir.cwd();
    const online_path = try std.fmt.bufPrint(&path_buf, "{s}/online", .{root});
    const online_nodes = try parse_cpulist(try dir.readFile(platform.io, online_path, &buf));

    var result = Topology{};
    var nodes = online_nodes.iterator(.{});
    while (nodes.next()) |node| {
        const path = try std.fmt.bufPrint(&path_buf, "{s}/node{}/cpulist", .{ root, node });
        var cpus = try parse_cpulist(try dir.readFile(platform.io, path, &buf));
        cpus.setIntersection(allowed);
        if (cpus.count() > 0) try result.add_cpus(cpus);
    }
    return if (result.node_count == 0) Topology.single_node() else result;
}

pub fn place_current_thread(thread_index: usize, thread_count: usize) void {
    place_on(topology(), thread_index, thread_count);
}

pub fn binds_threads(thread_count: usize) bool {
    return binds_on(topology(), thread_count);
}

fn binds_on(topo: *const Topology, thread_count: usize) bool {
    return supported and policy != .none and topo.needs_binding(thread_count);
}

fn place_on(topo: *const Topology, thread_index: usize, thread_count: usize) void {
    if (binds_on(topo, thread_count)) bind_current_thread(&topo.node_cpus[topo.node_for_thread(thread_index)]);
}

fn bind_current_thread(cpus: *const CpuSet) void {
    if (!supported) return;
    var mask: std.os.linux.cpu_set_t = @splat(0);
    var it = cpus.iterator(.{});
    while (it.next()) |cpu| {
        if (cpu >= @sizeOf(std.os.linux.cpu_set_t) * 8) break;
        mask[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    }
    std.os.linux.sched_setaffinity(0, &mask) catch {};
}

test "numa: cpulist parsing" {
    const set = try parse_cpulist("0-3,8,10-11\n");
    try std.testing.expectEqual(@as(usize, 7), set.count());
    for ([_]usize{ 0, 1, 2, 3, 8, 10, 11 }) |cpu| try std.testing.expect(set.isSet(cpu));
    try std.testing.expect(!set.isSet(9));
    try std.testing.expectEqual(@as(usize, 0), (try parse_cpulist("\n")).count());
    try std.testing.expectError(ParseError.InvalidCpuList, parse_cpulist("3-1"));
    try std.testing.expectError(ParseError.InvalidCpuList, parse_cpulist("a-b"));
    try std.testing.expectError(ParseError.TooManyCpus, parse_cpulist("0-4096"));
}

fn test_topology(comptime cpulists: []const []const u8) !Topology {
    var topo = Topology{};
    for (cpulists) |cpulist| try topo.add_node(cpulist);
    return topo;
}

fn expect_nodes(topo: *const Topology, expected: []const usize) !void {
    for (expected, 0..) |node, thread| try std.testing.expectEqual(node, topo.node_for_thread(thread));
}

test "numa: threads go to the node with the most room left for its size" {
    try expect_nodes(&try test_topology(&.{ "0-3", "4-7" }), &.{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 });
    try expect_nodes(&try test_topology(&.{ "0-3", "4-5" }), &.{ 0, 0, 1, 0, 0, 1, 0, 0, 1 });
    try expect_nodes(&try test_topology(&.{ "0-1", "2-9", "10-11" }), &.{ 1, 1, 1, 0, 1, 2, 1 });
    try std.testing.expectEqual(@as(usize, 0), Topology.single_node().node_for_thread(77));
}

test "numa: hyperthreads of one node do not fill before the cores of the next" {
    const two_sockets_with_smt = try test_topology(&.{ "0-31,64-95", "32-63,96-127" });
    var per_node = [_]usize{ 0, 0 };
    for (0..64) |thread| per_node[two_sockets_with_smt.node_for_thread(thread)] += 1;
    try std.testing.expectEqual([_]usize{ 32, 32 }, per_node);
}

test "numa: only thread counts that one node cannot hold comfortably are bound" {
    const two_sockets = try test_topology(&.{ "0-31,64-95", "32-63,96-127" });
    for ([_]usize{ 1, 2, 4, 7 }) |threads| try std.testing.expect(!two_sockets.needs_binding(threads));
    for ([_]usize{ 8, 33, 64, 128, 512 }) |threads| try std.testing.expect(two_sockets.needs_binding(threads));

    const large_and_small = try test_topology(&.{ "0-63", "64-71" });
    try std.testing.expect(!large_and_small.needs_binding(3));
    try std.testing.expect(large_and_small.needs_binding(4));

    try std.testing.expect(!Topology.single_node().needs_binding(MAX_CPUS));
}

test "numa: binding really restricts the thread's CPUs on Linux" {
    if (!supported) return error.SkipZigTest;
    platform.io = std.testing.io;
    init();
    const topo = topology();
    try std.testing.expect(topo.node_count >= 1);
    try std.testing.expect(topo.node_cpus[0].count() >= 1);

    var original: std.os.linux.cpu_set_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &original)));
    defer std.os.linux.sched_setaffinity(0, &original) catch {};

    var single = CpuSet.empty;
    single.set(topo.node_cpus[0].findFirstSet().?);
    bind_current_thread(&single);

    var now: std.os.linux.cpu_set_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &now)));
    var bound: usize = 0;
    for (now) |word| bound += @popCount(word);
    try std.testing.expectEqual(@as(usize, 1), bound);
}

test "numa: detection reads the sysfs node layout" {
    platform.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "online", .data = "0-1\n" });
    try tmp.dir.createDirPath(io, "node0");
    try tmp.dir.createDirPath(io, "node1");
    try tmp.dir.writeFile(io, .{ .sub_path = "node0/cpulist", .data = "0-3,8-11\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node1/cpulist", .data = "4-7,12-15\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const topo = try detect(root, CpuSet.full);
    try std.testing.expectEqual(@as(usize, 2), topo.node_count);
    try std.testing.expect(topo.node_cpus[0].isSet(9) and !topo.node_cpus[0].isSet(4));
    try std.testing.expect(topo.node_cpus[1].isSet(12));
    try std.testing.expectEqual(@as(usize, 1), topo.node_for_thread(1));

    // A process restricted to CPUs 2-5 (taskset/cpuset) never leaves them.
    const restricted = try detect(root, try parse_cpulist("2-5"));
    try std.testing.expectEqual(@as(usize, 2), restricted.node_count);
    try std.testing.expectEqual(@as(usize, 2), restricted.node_cpus[0].count());
    try std.testing.expect(restricted.node_cpus[0].isSet(2) and restricted.node_cpus[0].isSet(3));
    try std.testing.expect(restricted.node_cpus[1].isSet(4) and restricted.node_cpus[1].isSet(5));

    // Restricted to one node: nothing left to spread across.
    try std.testing.expect(!(try detect(root, try parse_cpulist("8-11"))).is_numa());
}

test "numa: placement binds each thread to its node's CPUs on Linux" {
    if (!supported) return error.SkipZigTest;
    var original: std.os.linux.cpu_set_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &original)));
    defer std.os.linux.sched_setaffinity(0, &original) catch {};
    var available: usize = 0;
    for (original) |word| available += @popCount(word);
    if (available < 2) return error.SkipZigTest;

    // Two single-CPU "nodes" on the first two CPUs this process may use.
    var topo = Topology{};
    var cpus = std.bit_set.Integer(@bitSizeOf(usize)).empty;
    cpus.mask = original[0];
    var it = cpus.iterator(.{});
    for (0..2) |_| {
        var list_buf: [8]u8 = undefined;
        try topo.add_node(try std.fmt.bufPrint(&list_buf, "{}", .{it.next().?}));
    }

    const thread_count = THREADS_PER_NODE_WORTH_BINDING * topo.node_count;
    for ([_]usize{ 0, 1 }) |thread| {
        place_on(&topo, thread, thread_count);
        var now: std.os.linux.cpu_set_t = undefined;
        _ = std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &now);
        const expected_cpu = topo.node_cpus[topo.node_for_thread(thread)].findFirstSet().?;
        try std.testing.expectEqual(@as(usize, 1) << @intCast(expected_cpu), now[0]);
    }
}
