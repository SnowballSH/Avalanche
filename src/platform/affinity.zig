//! The CPUs the calling thread may run on. See docs/THREADS.md.

const std = @import("std");
const platform = @import("../platform.zig");
const linux = std.os.linux;

pub const supported = platform.is_linux;

pub const MAX_CPUS = @bitSizeOf(linux.cpu_set_t);

pub const CpuSet = std.bit_set.Static(MAX_CPUS);

pub fn current() CpuSet {
    if (!supported) return .full;
    var cpus: CpuSet = undefined;
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpus.masks)) != .SUCCESS) return .full;
    return cpus;
}

pub fn bind(cpus: *const CpuSet) void {
    if (!supported) return;
    linux.sched_setaffinity(0, &cpus.masks) catch {};
}

test "affinity: a thread bound to one CPU may run only there" {
    if (!supported) return error.SkipZigTest;
    const original = current();
    defer bind(&original);

    var one: CpuSet = .empty;
    one.set(original.findFirstSet().?);
    bind(&one);
    try std.testing.expect(current().eql(one));
}

test "affinity: where threads cannot be bound every CPU stays allowed" {
    if (supported) return error.SkipZigTest;
    var one: CpuSet = .empty;
    one.set(0);
    bind(&one);
    try std.testing.expect(current().eql(.full));
}
