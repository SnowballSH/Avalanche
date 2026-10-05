//! Large, long-lived, page-aligned memory: blocks straight from the OS, on
//! transparent huge pages where Linux provides them and on ordinary pages on
//! every other target. See docs/MEMORY.md.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");

pub const has_huge_pages = builtin.target.os.tag == .linux and !platform.is_wasm;

pub const HUGE_PAGE_SIZE: usize = 2 * 1024 * 1024;

/// Where a block starts. A block is also mapped as a whole number of these,
/// so with huge pages none of it is left on small ones.
pub const ALIGNMENT: usize = if (has_huge_pages)
    HUGE_PAGE_SIZE
else if (platform.is_wasm)
    std.atomic.cache_line
else
    std.heap.page_size_min;

pub const Error = std.mem.Allocator.Error;

/// `n` zeroed items. A page is backed on the first write to it, on the NUMA
/// node of the writing thread. Linux lists the block in /proc/<pid>/smaps as
/// `[anon:avalanche-<label>]`.
pub fn alloc(comptime T: type, n: usize, comptime label: [:0]const u8) Error![]align(ALIGNMENT) T {
    comptime std.debug.assert(@alignOf(T) <= ALIGNMENT);
    const len = std.math.mul(usize, n, @sizeOf(T)) catch return Error.OutOfMemory;
    if (len == 0) return @as([*]align(ALIGNMENT) T, @ptrFromInt(ALIGNMENT))[0..n];

    const block = try map(len);
    if (has_huge_pages) {
        const name: [*:0]const u8 = "avalanche-" ++ label;
        std.posix.madvise(block.ptr, block.len, std.os.linux.MADV.HUGEPAGE) catch {};
        _ = std.os.linux.prctl(PR_SET_VMA, PR_SET_VMA_ANON_NAME, @intFromPtr(block.ptr), block.len, @intFromPtr(name));
    }
    return @as([*]align(ALIGNMENT) T, @ptrCast(block.ptr))[0..n];
}

/// Like `alloc`, with every page backed before returning: up to `threads`
/// threads touch the block in parallel, which also spreads it over the NUMA
/// nodes they run on.
pub fn alloc_populated(comptime T: type, n: usize, comptime label: [:0]const u8, threads: usize) Error![]align(ALIGNMENT) T {
    const items = try alloc(T, n, label);
    if (!platform.is_wasm) in_parallel(std.mem.sliceAsBytes(items), threads, touch_pages);
    return items;
}

pub fn free(memory: anytype) void {
    const bytes: []align(ALIGNMENT) u8 = std.mem.sliceAsBytes(memory);
    if (bytes.len != 0) unmap(bytes);
}

/// One zeroed `T`, as from `alloc`.
pub fn create(comptime T: type, comptime label: [:0]const u8) Error!*align(ALIGNMENT) T {
    return &(try alloc(T, 1, label))[0];
}

pub fn destroy(ptr: anytype) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    const block: *align(ALIGNMENT) [1]T = @ptrCast(@alignCast(ptr));
    free(@as([]align(ALIGNMENT) T, block));
}

/// Zeroes `bytes` from up to `threads` threads at once.
pub fn zero(bytes: []u8, threads: usize) void {
    in_parallel(bytes, threads, zero_bytes);
}

/// How much of `bytes` the OS backs with huge pages right now. Blocks that
/// Linux merged into one mapping share its count, so the result is exact
/// where the kernel names anonymous mappings (5.17 and later) and an upper
/// bound, capped at the length of `bytes`, elsewhere.
pub fn huge_page_bytes(bytes: []const u8) u64 {
    if (!has_huge_pages or bytes.len == 0) return 0;
    const first = @intFromPtr(bytes.ptr);
    return @min(mapped_len(bytes.len), smaps_huge_bytes(first, first + bytes.len) catch 0);
}

const PR_SET_VMA = 0x53564d41;
const PR_SET_VMA_ANON_NAME = 0;

const KIB = 1024;
const WORKER_STACK_SIZE = 256 * KIB;
const MIN_BYTES_PER_THREAD = 32 * 1024 * KIB;
const MAX_PARALLEL = 512;

fn mapped_len(len: usize) usize {
    return if (platform.is_wasm) len else std.mem.alignForward(usize, len, ALIGNMENT);
}

/// A zeroed mapping of `mapped_len(len)` bytes.
fn map(len: usize) Error![]align(ALIGNMENT) u8 {
    if (len > std.math.maxInt(usize) - ALIGNMENT) return Error.OutOfMemory;
    if (platform.is_wasm) {
        const bytes = try platform.allocator.alignedAlloc(u8, .fromByteUnits(ALIGNMENT), len);
        @memset(bytes, 0);
        return bytes;
    }
    const ptr = std.heap.PageAllocator.map(mapped_len(len), .fromByteUnits(ALIGNMENT)) orelse return Error.OutOfMemory;
    return @as([*]align(ALIGNMENT) u8, @alignCast(ptr))[0..mapped_len(len)];
}

fn unmap(bytes: []align(ALIGNMENT) u8) void {
    if (platform.is_wasm) return platform.allocator.free(bytes);
    std.heap.PageAllocator.unmap(bytes.ptr[0..mapped_len(bytes.len)]);
}

/// Runs `work` over `bytes` with as many of `threads` as get at least
/// `MIN_BYTES_PER_THREAD` each.
fn in_parallel(bytes: []u8, threads: usize, comptime work: fn ([]u8) void) void {
    if (comptime !platform.has_threads) return work(bytes);
    in_parts(bytes, @max(1, @min(threads, bytes.len / MIN_BYTES_PER_THREAD, MAX_PARALLEL)), work);
}

/// Runs `work` over at most `parts` consecutive parts of `bytes`, each a whole
/// number of huge pages, the last one on the calling thread.
fn in_parts(bytes: []u8, parts: usize, comptime work: fn ([]u8) void) void {
    std.debug.assert(parts >= 1 and parts <= MAX_PARALLEL);
    const part_len = @max(HUGE_PAGE_SIZE, std.mem.alignForward(usize, bytes.len / parts, HUGE_PAGE_SIZE));

    var spawned: [MAX_PARALLEL]std.Thread = undefined;
    var spawned_count: usize = 0;
    var rest = bytes;
    while (rest.len > part_len and spawned_count + 1 < parts) {
        const part = rest[0..part_len];
        rest = rest[part_len..];
        if (std.Thread.spawn(.{ .stack_size = WORKER_STACK_SIZE }, work, .{part})) |thread| {
            spawned[spawned_count] = thread;
            spawned_count += 1;
        } else |_| work(part);
    }
    work(rest);
    for (spawned[0..spawned_count]) |thread| thread.join();
}

fn zero_bytes(bytes: []u8) void {
    @memset(bytes, 0);
}

/// Writes the zero that a page straight from the OS already holds: a read
/// would only map the kernel's shared zero page.
fn touch_pages(bytes: []u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += std.heap.page_size_min) {
        const byte: *volatile u8 = &bytes[offset];
        byte.* = 0;
    }
}

fn smaps_huge_bytes(first: usize, end: usize) !u64 {
    const file = try std.Io.Dir.cwd().openFile(platform.io, "/proc/self/smaps", .{});
    defer file.close(platform.io);

    var buf: [1 << 15]u8 = undefined;
    var stream = file.readerStreaming(platform.io, &buf);
    const reader = &stream.interface;
    const HUGE_FIELD = "AnonHugePages:";
    var total: u64 = 0;
    var overlaps = false;
    while (reader.takeDelimiterInclusive('\n') catch null) |line| {
        if (mapping_range(line)) |range| {
            if (range.first >= end) break;
            overlaps = range.end > first;
        } else if (overlaps and std.mem.startsWith(u8, line, HUGE_FIELD)) {
            var fields = std.mem.tokenizeAny(u8, line[HUGE_FIELD.len..], " \tkB\r\n");
            total += (std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0) * KIB;
        }
    }
    return total;
}

const Range = struct { first: usize, end: usize };

/// The address range of an smaps mapping header, `<first>-<end> <perms> ...` in hexadecimal.
fn mapping_range(line: []const u8) ?Range {
    const dash = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const space = std.mem.indexOfScalarPos(u8, line, dash, ' ') orelse return null;
    return .{
        .first = std.fmt.parseInt(usize, line[0..dash], 16) catch return null,
        .end = std.fmt.parseInt(usize, line[dash + 1 .. space], 16) catch return null,
    };
}

test "large_memory: blocks are zeroed, aligned and writable to the last byte" {
    const items = try alloc(u64, 100_000, "test");
    defer free(items);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(items.ptr), ALIGNMENT));
    try std.testing.expect(std.mem.allEqual(u64, items, 0));
    items[items.len - 1] = 7;

    const populated = try alloc_populated(u8, 5 * HUGE_PAGE_SIZE + 3, "test", 4);
    defer free(populated);
    try std.testing.expect(std.mem.allEqual(u8, populated, 0));

    @memset(populated, 0xff);
    zero(populated, 4);
    try std.testing.expect(std.mem.allEqual(u8, populated, 0));

    const empty = try alloc(u64, 0, "test");
    defer free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "large_memory: work split over threads covers every byte once" {
    if (comptime !platform.has_threads) return error.SkipZigTest;
    const bytes = try alloc(u8, 5 * HUGE_PAGE_SIZE + 3, "test");
    defer free(bytes);
    const increment = struct {
        fn run(part: []u8) void {
            for (part) |*byte| byte.* += 1;
        }
    }.run;
    for ([_]usize{ 1, 2, 3, 6, 64 }, 1..) |parts, pass| {
        in_parts(bytes, parts, increment);
        try std.testing.expect(std.mem.allEqual(u8, bytes, @intCast(pass)));
    }
}

test "large_memory: create and destroy one item" {
    const Table = [3][1 << 16]i16;
    const table: *Table = try create(Table, "test");
    defer destroy(table);
    try std.testing.expectEqual(@as(i16, 0), table[2][(1 << 16) - 1]);
    table[2][(1 << 16) - 1] = -1;
}

test "large_memory: smaps mapping headers" {
    const range = mapping_range("ffffa7e00000-ffffa8e00000 rw-p 00000000 00:00 0  [anon:avalanche-hash]\n").?;
    try std.testing.expectEqual(@as(usize, 0xffffa7e00000), range.first);
    try std.testing.expectEqual(@as(usize, 0xffffa8e00000), range.end);
    try std.testing.expectEqual(@as(?Range, null), mapping_range("AnonHugePages:     16384 kB\n"));
    try std.testing.expectEqual(@as(?Range, null), mapping_range("VmFlags: rd wr mr mw me ac hg\n"));
}

test "large_memory: a populated block is on huge pages where Linux grants them" {
    if (!has_huge_pages) return error.SkipZigTest;
    platform.io = std.testing.io;
    const bytes = try alloc_populated(u8, 4 * HUGE_PAGE_SIZE, "test", 1);
    defer free(bytes);
    const huge = huge_page_bytes(bytes);
    try std.testing.expect(huge <= bytes.len);
    try std.testing.expectEqual(@as(u64, 0), huge % HUGE_PAGE_SIZE);
}
