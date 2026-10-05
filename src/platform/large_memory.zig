//! Large, long-lived memory in blocks straight from the OS: on transparent
//! huge pages on Linux, on ordinary pages elsewhere. See docs/MEMORY.md.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");

pub const has_huge_pages = builtin.target.os.tag == .linux and !platform.is_wasm;

pub const HUGE_PAGE_SIZE: usize = 2 * 1024 * 1024;

/// Where a block starts; natively it is mapped as a whole number of these.
pub const ALIGNMENT: usize = if (has_huge_pages)
    HUGE_PAGE_SIZE
else if (platform.is_wasm)
    std.atomic.cache_line
else
    std.heap.page_size_min;

pub const Error = std.mem.Allocator.Error;

/// Runs on a thread before it backs part `index` of the `parts` of a block,
/// to move the thread to where that part should live.
pub const Placement = *const fn (index: usize, parts: usize) void;

pub fn empty(comptime T: type) []align(ALIGNMENT) T {
    return @as([*]align(ALIGNMENT) T, @ptrFromInt(ALIGNMENT))[0..0];
}

/// `n` zeroed items; a page is backed when it is first written. Linux lists
/// the block as `[anon:avalanche-<label>]`.
pub fn alloc(comptime T: type, n: usize, comptime label: [:0]const u8) Error![]align(ALIGNMENT) T {
    comptime std.debug.assert(@alignOf(T) <= ALIGNMENT and @sizeOf(T) != 0);
    if (n == 0) return empty(T);
    const len = std.math.mul(usize, n, @sizeOf(T)) catch return Error.OutOfMemory;

    const block = try map(len);
    if (has_huge_pages) {
        const name: [*:0]const u8 = "avalanche-" ++ label;
        std.posix.madvise(block.ptr, block.len, std.os.linux.MADV.HUGEPAGE) catch {};
        _ = std.os.linux.prctl(PR_SET_VMA, PR_SET_VMA_ANON_NAME, @intFromPtr(block.ptr), block.len, @intFromPtr(name));
    }
    return @as([*]align(ALIGNMENT) T, @ptrCast(block.ptr))[0..n];
}

/// `alloc` with every page backed on return. Up to `threads` parts are backed
/// at once; with a `placement`, each on a thread of its own that it has placed.
pub fn alloc_populated(comptime T: type, n: usize, comptime label: [:0]const u8, threads: usize, placement: ?Placement) Error![]align(ALIGNMENT) T {
    const items = try alloc(T, n, label);
    if (!platform.is_wasm) in_parallel(std.mem.sliceAsBytes(items), threads, placement, touch_pages);
    return items;
}

pub fn free(comptime T: type, memory: []align(ALIGNMENT) T) void {
    if (memory.len == 0) return;
    const bytes: []align(ALIGNMENT) u8 = std.mem.sliceAsBytes(memory);
    unmap(bytes.ptr[0..mapped_len(bytes.len)]);
}

pub fn create(comptime T: type, comptime label: [:0]const u8) Error!*align(ALIGNMENT) T {
    return &(try alloc(T, 1, label))[0];
}

pub fn destroy(comptime T: type, item: *align(ALIGNMENT) T) void {
    const one: *align(ALIGNMENT) [1]T = item;
    free(T, one);
}

/// Zeroes `bytes` in up to `threads` parts at once.
pub fn zero(bytes: []u8, threads: usize) void {
    in_parallel(bytes, threads, null, zero_bytes);
}

/// How much of `bytes` is on huge pages right now; an upper bound where Linux
/// has merged the block with its neighbours.
pub fn huge_page_bytes(bytes: []const u8) u64 {
    if (!has_huge_pages or bytes.len == 0) return 0;
    const file = std.Io.Dir.cwd().openFile(platform.io, "/proc/self/smaps", .{}) catch return 0;
    defer file.close(platform.io);
    var buffer: [1 << 15]u8 = undefined;
    var stream = file.readerStreaming(platform.io, &buffer);
    return smaps_huge_bytes(&stream.interface, @intFromPtr(bytes.ptr), bytes.len);
}

/// Bytes mapped and not yet freed. Counted in Debug builds and in tests.
pub fn live_bytes() usize {
    return platform.atomicLoad(usize, &live, .monotonic);
}

const PR_SET_VMA = 0x53564d41;
const PR_SET_VMA_ANON_NAME = 0;

const KIB = 1024;
const WORKER_STACK_SIZE = 2 * 1024 * KIB;
const MIN_BYTES_PER_PART = 32 * 1024 * KIB;
const MAX_PARTS = 512;

const counts_live_bytes = builtin.is_test or builtin.mode == .debug;
var live: usize = 0;

fn mapped_len(len: usize) usize {
    return if (platform.is_wasm) len else std.mem.alignForward(usize, len, ALIGNMENT);
}

fn map(len: usize) Error![]align(ALIGNMENT) u8 {
    if (len > std.math.maxInt(usize) - ALIGNMENT) return Error.OutOfMemory;
    const block = if (platform.is_wasm) zeroed: {
        const bytes = try platform.allocator.alignedAlloc(u8, .fromByteUnits(ALIGNMENT), len);
        @memset(bytes, 0);
        break :zeroed bytes;
    } else mapped: {
        const ptr = std.heap.PageAllocator.map(mapped_len(len), .fromByteUnits(ALIGNMENT)) orelse return Error.OutOfMemory;
        break :mapped @as([*]align(ALIGNMENT) u8, @alignCast(ptr))[0..mapped_len(len)];
    };
    if (counts_live_bytes) _ = platform.atomicRmw(usize, &live, .Add, block.len, .monotonic);
    return block;
}

fn unmap(block: []align(ALIGNMENT) u8) void {
    if (counts_live_bytes) _ = platform.atomicRmw(usize, &live, .Sub, block.len, .monotonic);
    if (platform.is_wasm) return platform.allocator.free(block);
    std.heap.PageAllocator.unmap(block);
}

fn part_count(len: usize, threads: usize) usize {
    return @max(1, @min(threads, len / MIN_BYTES_PER_PART, MAX_PARTS));
}

fn in_parallel(bytes: []u8, threads: usize, placement: ?Placement, comptime work: fn ([]u8) void) void {
    if (comptime !platform.has_threads) return work(bytes);
    in_parts(bytes, part_count(bytes.len, threads), placement, work);
}

/// Runs `work` over at most `parts` consecutive parts of `bytes`, each a whole
/// number of huge pages. The calling thread takes the last part unless there
/// is a `placement`.
fn in_parts(bytes: []u8, parts: usize, placement: ?Placement, comptime work: fn ([]u8) void) void {
    std.debug.assert(parts >= 1 and parts <= MAX_PARTS);
    const placed_work = struct {
        fn run(part: []u8, index: usize, part_total: usize, place: Placement) void {
            place(index, part_total);
            work(part);
        }
    }.run;
    const part_len = @max(HUGE_PAGE_SIZE, std.mem.alignForward(usize, bytes.len / parts, HUGE_PAGE_SIZE));

    var spawned: [MAX_PARTS]std.Thread = undefined;
    var spawned_count: usize = 0;
    var rest = bytes;
    var index: usize = 0;
    while (rest.len != 0) : (index += 1) {
        const part = rest[0..if (index + 1 == parts) rest.len else @min(part_len, rest.len)];
        rest = rest[part.len..];
        const config: std.Thread.SpawnConfig = .{ .stack_size = WORKER_STACK_SIZE };
        const thread: ?std.Thread = if (placement) |place|
            std.Thread.spawn(config, placed_work, .{ part, index, parts, place }) catch null
        else if (rest.len != 0)
            std.Thread.spawn(config, work, .{part}) catch null
        else
            null;
        if (thread) |running| {
            spawned[spawned_count] = running;
            spawned_count += 1;
        } else work(part);
    }
    for (spawned[0..spawned_count]) |thread| thread.join();
}

fn zero_bytes(bytes: []u8) void {
    @memset(bytes, 0);
}

fn touch_pages(bytes: []u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += std.heap.page_size_min) {
        // A store of the zero the fresh page already holds: a load would only map the kernel's shared zero page.
        const byte: *volatile u8 = &bytes[offset];
        byte.* = 0;
    }
}

/// The `AnonHugePages` of every mapping in the `smaps` text that overlaps the
/// `len` bytes at `first`, capped at `len`.
fn smaps_huge_bytes(smaps: *std.Io.Reader, first: usize, len: usize) u64 {
    const HUGE_FIELD = "AnonHugePages:";
    var total: u64 = 0;
    var overlaps = false;
    while (smaps.takeDelimiterInclusive('\n') catch null) |line| {
        if (mapping_range(line)) |range| {
            if (range.first >= first + len) break;
            overlaps = range.end > first;
        } else if (overlaps and std.mem.startsWith(u8, line, HUGE_FIELD)) {
            var fields = std.mem.tokenizeAny(u8, line[HUGE_FIELD.len..], " \tkB\r\n");
            total += (std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0) * KIB;
        }
    }
    return @min(len, total);
}

const Range = struct { first: usize, end: usize };

/// The address range of an smaps mapping header, `<first>-<end> <perms> ...` in hexadecimal.
fn mapping_range(line: []const u8) ?Range {
    const dash = std.mem.findScalar(u8, line, '-') orelse return null;
    const space = std.mem.findScalarPos(u8, line, dash, ' ') orelse return null;
    return .{
        .first = std.fmt.parseInt(usize, line[0..dash], 16) catch return null,
        .end = std.fmt.parseInt(usize, line[dash + 1 .. space], 16) catch return null,
    };
}

const testing = std.testing;
const MIB = 1024 * KIB;

fn increment_bytes(part: []u8) void {
    for (part) |*byte| byte.* += 1;
}

const PlacementRecorder = struct {
    var calls: [8]std.atomic.Value(u32) = @splat(.init(0));
    var calls_off_caller: std.atomic.Value(u32) = .init(0);
    var caller: std.Thread.Id = undefined;

    fn start() void {
        for (&calls) |*count| count.store(0, .monotonic);
        calls_off_caller.store(0, .monotonic);
        caller = std.Thread.getCurrentId();
    }

    var parts_announced: std.atomic.Value(usize) = .init(0);

    fn place(index: usize, parts: usize) void {
        parts_announced.store(parts, .monotonic);
        _ = calls[index].fetchAdd(1, .monotonic);
        if (std.Thread.getCurrentId() != caller) _ = calls_off_caller.fetchAdd(1, .monotonic);
    }

    fn expect_parts_placed(parts: usize) !void {
        for (&calls, 0..) |*count, index| {
            try testing.expectEqual(@as(u32, @intFromBool(index < parts)), count.load(.monotonic));
        }
        try testing.expectEqual(@as(u32, @intCast(parts)), calls_off_caller.load(.monotonic));
        try testing.expectEqual(parts, parts_announced.load(.monotonic));
    }
};

/// How many OS pages of `block` are in memory, by `mincore`.
fn resident_pages(block: []align(ALIGNMENT) u8) !usize {
    const vec = try testing.allocator.alloc(u8, page_count(block.len));
    defer testing.allocator.free(vec);
    try std.posix.mincore(block.ptr, block.len, vec.ptr);
    var resident: usize = 0;
    for (vec) |entry| resident += entry & 1;
    return resident;
}

fn page_count(len: usize) usize {
    return std.mem.alignForward(usize, len, std.heap.pageSize()) / std.heap.pageSize();
}

fn is_mapped(address: usize) bool {
    var entry: [1]u8 = undefined;
    std.posix.mincore(@ptrFromInt(address), std.heap.pageSize(), &entry) catch return false;
    return true;
}

fn system_grants_huge_pages() bool {
    var buffer: [64]u8 = undefined;
    const modes = std.Io.Dir.cwd().readFile(platform.io, "/sys/kernel/mm/transparent_hugepage/enabled", &buffer) catch return false;
    return std.mem.find(u8, modes, "[always]") != null or std.mem.find(u8, modes, "[madvise]") != null;
}

test "large_memory: a block is zeroed, aligned, writable to its last byte and counted until freed" {
    const live_before = live_bytes();
    const items = try alloc(u64, 100_000, "test");
    try testing.expect(std.mem.isAligned(@intFromPtr(items.ptr), ALIGNMENT));
    try testing.expect(std.mem.allEqual(u64, items, 0));
    items[items.len - 1] = 7;
    try testing.expectEqual(live_before + mapped_len(items.len * @sizeOf(u64)), live_bytes());

    free(u64, items);
    try testing.expectEqual(live_before, live_bytes());
}

test "large_memory: an empty block is aligned, costs nothing and can be freed" {
    const live_before = live_bytes();
    const none = try alloc(u64, 0, "test");
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expect(std.mem.isAligned(@intFromPtr(none.ptr), ALIGNMENT));
    try testing.expectEqual(live_before, live_bytes());
    free(u64, none);
    try testing.expectEqual(live_before, live_bytes());
}

test "large_memory: create and destroy one item" {
    const Table = [3][1 << 16]i16;
    const live_before = live_bytes();
    const table = try create(Table, "test");
    try testing.expectEqual(@as(i16, 0), table[2][(1 << 16) - 1]);
    table[2][(1 << 16) - 1] = -1;
    destroy(Table, table);
    try testing.expectEqual(live_before, live_bytes());
}

test "large_memory: Linux maps whole huge pages and free unmaps all of them" {
    if (!has_huge_pages) return error.SkipZigTest;
    const bytes = try alloc(u8, HUGE_PAGE_SIZE + 5, "test");
    const first = @intFromPtr(bytes.ptr);
    const last_page = first + 2 * HUGE_PAGE_SIZE - std.heap.pageSize();
    try testing.expect(is_mapped(first) and is_mapped(last_page));

    free(u8, bytes);
    try testing.expect(!is_mapped(first) and !is_mapped(last_page));
}

test "large_memory: alloc backs no page until it is written, alloc_populated backs every page" {
    if (!has_huge_pages) return error.SkipZigTest;
    const lazy = try alloc(u8, 3 * HUGE_PAGE_SIZE + 5, "test");
    defer free(u8, lazy);
    try testing.expectEqual(@as(usize, 0), try resident_pages(lazy));

    const populated = try alloc_populated(u8, 3 * HUGE_PAGE_SIZE + 5, "test", 1, null);
    defer free(u8, populated);
    try testing.expectEqual(page_count(populated.len), try resident_pages(populated));
    try testing.expect(std.mem.allEqual(u8, populated, 0));
}

test "large_memory: one part per thread, never smaller than the minimum" {
    try testing.expectEqual(@as(usize, 1), part_count(0, 8));
    try testing.expectEqual(@as(usize, 1), part_count(16 * MIB, 8));
    try testing.expectEqual(@as(usize, 1), part_count(2 * MIN_BYTES_PER_PART - 1, 8));
    try testing.expectEqual(@as(usize, 2), part_count(2 * MIN_BYTES_PER_PART, 8));
    try testing.expectEqual(@as(usize, 8), part_count(1024 * MIB, 8));
    try testing.expectEqual(@as(usize, 1), part_count(1024 * MIB, 0));
    try testing.expectEqual(@as(usize, MAX_PARTS), part_count(1024 * 1024 * MIB, 100_000));
}

test "large_memory: work split into parts covers every byte once" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    const bytes = try alloc(u8, 5 * HUGE_PAGE_SIZE + 3, "test");
    defer free(u8, bytes);
    for ([_]usize{ 1, 2, 3, 6, 64 }, 1..) |parts, pass| {
        in_parts(bytes, parts, null, increment_bytes);
        try testing.expect(std.mem.allEqual(u8, bytes, @intCast(pass)));
    }
}

test "large_memory: with a placement every part runs on a placed thread of its own" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    const bytes = try alloc(u8, 5 * HUGE_PAGE_SIZE + 3, "test");
    defer free(u8, bytes);
    for ([_]usize{ 1, 3, 6 }, 1..) |parts, pass| {
        PlacementRecorder.start();
        in_parts(bytes, parts, PlacementRecorder.place, increment_bytes);
        try PlacementRecorder.expect_parts_placed(parts);
        try testing.expect(std.mem.allEqual(u8, bytes, @intCast(pass)));
    }
}

test "large_memory: a block of several parts is populated and zeroed in parallel" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    const len = 2 * MIN_BYTES_PER_PART + 5;

    PlacementRecorder.start();
    const bytes = try alloc_populated(u8, len, "test", 2, PlacementRecorder.place);
    defer free(u8, bytes);
    try PlacementRecorder.expect_parts_placed(2);
    if (has_huge_pages) try testing.expectEqual(page_count(len), try resident_pages(bytes));

    @memset(bytes, 0xff);
    zero(bytes, 2);
    try testing.expect(std.mem.allEqual(u8, bytes, 0));
}

test "large_memory: a small block has one part, which a placement still places" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    PlacementRecorder.start();
    const bytes = try alloc_populated(u8, 3 * HUGE_PAGE_SIZE, "test", 8, PlacementRecorder.place);
    defer free(u8, bytes);
    try PlacementRecorder.expect_parts_placed(1);
}

const SMAPS =
    \\10000000-10200000 rw-p 00000000 00:00 0
    \\Size:               2048 kB
    \\Rss:                2048 kB
    \\AnonHugePages:      2048 kB
    \\VmFlags: rd wr mr mw me ac hg
    \\20000000-20400000 rw-p 00000000 00:00 0                          [anon:avalanche-hash]
    \\Size:               4096 kB
    \\AnonHugePages:      4096 kB
    \\ShmemPmdMapped:        0 kB
    \\VmFlags: rd wr mr mw me ac hg
    \\20400000-20800000 rw-p 00000000 00:00 0                          [anon:avalanche-search]
    \\Size:               4096 kB
    \\AnonHugePages:      2048 kB
    \\VmFlags: rd wr mr mw me ac hg
    \\30000000-32000000 rw-p 00000000 00:00 0
    \\Size:              32768 kB
    \\AnonHugePages:     30720 kB
    \\VmFlags: rd wr mr mw me ac hg
    \\7f0000000000-7f0000200000 r-xp 00000000 fd:01 1234                 /usr/lib/libc.so.6
    \\Size:               2048 kB
    \\AnonHugePages:         0 kB
    \\
;

fn canned_huge_bytes(first: usize, len: usize) u64 {
    var smaps = std.Io.Reader.fixed(SMAPS);
    return smaps_huge_bytes(&smaps, first, len);
}

test "large_memory: huge pages are summed over the mappings a block overlaps" {
    try testing.expectEqual(@as(u64, 4 * MIB), canned_huge_bytes(0x20000000, 4 * MIB));
    try testing.expectEqual(@as(u64, 6 * MIB), canned_huge_bytes(0x20000000, 8 * MIB));
    try testing.expectEqual(@as(u64, 2 * MIB), canned_huge_bytes(0x20400000, 4 * MIB));
    try testing.expectEqual(@as(u64, 2 * MIB), canned_huge_bytes(0x10000000, 2 * MIB));
    try testing.expectEqual(@as(u64, 0), canned_huge_bytes(0x28000000, 2 * MIB));
    try testing.expectEqual(@as(u64, 0), canned_huge_bytes(0x7f0000000000, 2 * MIB));
    try testing.expectEqual(@as(u64, 0), canned_huge_bytes(0x7f8000000000, 2 * MIB));
}

test "large_memory: huge pages of a block are capped at its length" {
    try testing.expectEqual(@as(u64, 16 * MIB), canned_huge_bytes(0x30200000, 16 * MIB));
    try testing.expectEqual(@as(u64, 1 * MIB), canned_huge_bytes(0x20000000, 1 * MIB));
    try testing.expectEqual(@as(u64, 4 * MIB + 5), canned_huge_bytes(0x20000000, 4 * MIB + 5));
}

test "large_memory: smaps mapping headers" {
    const range = mapping_range("ffffa7e00000-ffffa8e00000 rw-p 00000000 00:00 0  [anon:avalanche-hash]\n").?;
    try testing.expectEqual(@as(usize, 0xffffa7e00000), range.first);
    try testing.expectEqual(@as(usize, 0xffffa8e00000), range.end);
    try testing.expectEqual(@as(?Range, null), mapping_range("AnonHugePages:     16384 kB\n"));
    try testing.expectEqual(@as(?Range, null), mapping_range("VmFlags: rd wr mr mw me ac hg\n"));
}

test "large_memory: a populated block is on huge pages where the system grants them" {
    if (!has_huge_pages) return error.SkipZigTest;
    platform.io = testing.io;
    const bytes = try alloc_populated(u8, 3 * HUGE_PAGE_SIZE + 12345, "test", 1, null);
    defer free(u8, bytes);
    const huge = huge_page_bytes(bytes);
    try testing.expect(huge <= bytes.len);
    if (system_grants_huge_pages()) try testing.expect(huge >= HUGE_PAGE_SIZE);
}
