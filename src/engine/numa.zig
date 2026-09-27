//! NUMA topology and search-thread placement. See docs/THREADS.md.
//!
//! Topology comes from Linux sysfs and binding uses sched_setaffinity; on any
//! other target the machine is a single node and binding is a no-op.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");

pub const MAX_NODES = 64;
pub const MAX_CPUS = 1024;

pub const CpuSet = std.bit_set.StaticBitSet(MAX_CPUS);

pub const Policy = enum {
    /// Bind search threads to nodes when the machine has more than one.
    auto,
    /// Leave placement to the OS scheduler.
    none,
};

pub var policy: Policy = .auto;

const supported = builtin.os.tag == .linux and !platform.is_wasm;

pub const ParseError = error{ InvalidCpuList, TooManyCpus, TooManyNodes };

pub const Topology = struct {
    node_cpus: [MAX_NODES]CpuSet = [_]CpuSet{CpuSet.initEmpty()} ** MAX_NODES,
    node_count: usize = 0,

    pub fn single_node() Topology {
        return .{ .node_count = 1, .node_cpus = [_]CpuSet{CpuSet.initFull()} ++ [_]CpuSet{CpuSet.initEmpty()} ** (MAX_NODES - 1) };
    }

    pub fn add_node(self: *Topology, cpulist: []const u8) ParseError!void {
        if (self.node_count == MAX_NODES) return ParseError.TooManyNodes;
        self.node_cpus[self.node_count] = try parse_cpulist(cpulist);
        self.node_count += 1;
    }

    pub fn is_numa(self: *const Topology) bool {
        return self.node_count > 1;
    }

    /// Fills nodes in order, one thread per CPU, wrapping when threads
    /// outnumber CPUs, so small thread counts stay on one node.
    pub fn node_for_thread(self: *const Topology, thread_index: usize) usize {
        var total: usize = 0;
        for (self.node_cpus[0..self.node_count]) |cpus| total += cpus.count();
        if (total == 0) return 0;

        var slot = thread_index % total;
        for (self.node_cpus[0..self.node_count], 0..) |cpus, node| {
            if (slot < cpus.count()) return node;
            slot -= cpus.count();
        }
        unreachable;
    }
};

/// Parses the kernel cpulist format, e.g. "0-3,8-11\n".
pub fn parse_cpulist(text: []const u8) ParseError!CpuSet {
    var set = CpuSet.initEmpty();
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

/// Detected once and cached; falls back to a single node on any error.
pub fn topology() *const Topology {
    if (detected == null) {
        detected = if (supported) detect(SYSFS_NODES) catch Topology.single_node() else Topology.single_node();
    }
    return &detected.?;
}

/// Reads `<root>/online` and each online node's `<root>/node<N>/cpulist`.
pub fn detect(root: []const u8) !Topology {
    var buf: [4096]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.Io.Dir.cwd();
    const online_path = try std.fmt.bufPrint(&path_buf, "{s}/online", .{root});
    const online_nodes = try parse_cpulist(try dir.readFile(platform.io, online_path, &buf));

    var result = Topology{};
    var nodes = online_nodes.iterator(.{});
    while (nodes.next()) |node| {
        const path = try std.fmt.bufPrint(&path_buf, "{s}/node{}/cpulist", .{ root, node });
        try result.add_node(try dir.readFile(platform.io, path, &buf));
    }
    return if (result.node_count == 0) Topology.single_node() else result;
}

/// Binds the calling search thread (0 = main) to its node under the current policy.
pub fn place_current_thread(thread_index: usize) void {
    place_on(topology(), thread_index);
}

fn place_on(topo: *const Topology, thread_index: usize) void {
    if (!supported or policy == .none or !topo.is_numa()) return;
    bind_current_thread(&topo.node_cpus[topo.node_for_thread(thread_index)]);
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

test "numa: threads fill nodes in order and wrap" {
    var topo = Topology{};
    try topo.add_node("0-3");
    try topo.add_node("4-5");
    try std.testing.expect(topo.is_numa());
    const expected = [_]usize{ 0, 0, 0, 0, 1, 1, 0, 0 };
    for (expected, 0..) |node, thread| {
        try std.testing.expectEqual(node, topo.node_for_thread(thread));
    }
    try std.testing.expect(!Topology.single_node().is_numa());
    try std.testing.expectEqual(@as(usize, 0), Topology.single_node().node_for_thread(77));
}

test "numa: binding really restricts the thread's CPUs on Linux" {
    if (!supported) return error.SkipZigTest;
    platform.io = std.testing.io;
    const topo = topology();
    try std.testing.expect(topo.node_count >= 1);
    try std.testing.expect(topo.node_cpus[0].count() >= 1);

    var original: std.os.linux.cpu_set_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &original)));
    defer std.os.linux.sched_setaffinity(0, &original) catch {};

    var single = CpuSet.initEmpty();
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
    const topo = try detect(root);
    try std.testing.expectEqual(@as(usize, 2), topo.node_count);
    try std.testing.expect(topo.node_cpus[0].isSet(9) and !topo.node_cpus[0].isSet(4));
    try std.testing.expect(topo.node_cpus[1].isSet(12));
    try std.testing.expectEqual(@as(usize, 1), topo.node_for_thread(8));
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
    var cpus = std.bit_set.IntegerBitSet(@bitSizeOf(usize)).initEmpty();
    cpus.mask = original[0];
    var it = cpus.iterator(.{});
    for (0..2) |_| {
        var list_buf: [8]u8 = undefined;
        try topo.add_node(try std.fmt.bufPrint(&list_buf, "{}", .{it.next().?}));
    }

    for ([_]usize{ 0, 1 }) |thread| {
        place_on(&topo, thread);
        var now: std.os.linux.cpu_set_t = undefined;
        _ = std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &now);
        const expected_cpu = topo.node_cpus[topo.node_for_thread(thread)].findFirstSet().?;
        try std.testing.expectEqual(@as(usize, 1) << @intCast(expected_cpu), now[0]);
    }
}
