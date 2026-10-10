//! OS services the engine depends on. See docs/WASM.md.

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.target.cpu.arch.isWasm();
pub const is_linux = builtin.target.os.tag == .linux and !is_wasm;
pub const has_threads = !builtin.single_threaded;

pub var io: std.Io = undefined;

pub const allocator: std.mem.Allocator = if (is_wasm) std.heap.wasm_allocator else std.heap.c_allocator;

pub const large_memory = @import("platform/large_memory.zig");
pub const affinity = @import("platform/affinity.zig");

const host = if (is_wasm) struct {
    extern "env" fn avalanche_write(ptr: [*]const u8, len: usize) void;
    extern "env" fn avalanche_now_ms() f64;
    extern "env" fn avalanche_stop_requested() bool;
    extern "env" fn avalanche_ponderhit_requested() bool;
} else struct {};

pub fn now_ns() i96 {
    if (is_wasm) return @intFromFloat(host.avalanche_now_ms() * std.time.ns_per_ms);
    return std.Io.Clock.awake.now(io).nanoseconds;
}

pub inline fn host_stop_requested() bool {
    return is_wasm and host.avalanche_stop_requested();
}

pub inline fn host_ponderhit_requested() bool {
    return is_wasm and host.avalanche_ponderhit_requested();
}

pub fn sleep_ms(ms: i64) void {
    if (is_wasm) return;
    io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

pub const Stdout = if (is_wasm) HostStdout else FileStdout;

const FileStdout = struct {
    file_writer: std.Io.File.Writer,

    pub fn init(buffer: []u8) FileStdout {
        return .{ .file_writer = std.Io.File.stdout().writerStreaming(io, buffer) };
    }

    pub fn writer(self: *FileStdout) *std.Io.Writer {
        return &self.file_writer.interface;
    }
};

const HostStdout = struct {
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    pub fn init(buffer: []u8) HostStdout {
        return .{ .interface = .{ .vtable = &vtable, .buffer = buffer } };
    }

    pub fn writer(self: *HostStdout) *std.Io.Writer {
        return &self.interface;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        write(w.buffered());
        w.end = 0;

        for (data[0 .. data.len - 1]) |bytes| write(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| write(pattern);

        var consumed = pattern.len * splat;
        for (data[0 .. data.len - 1]) |bytes| consumed += bytes.len;
        return consumed;
    }

    fn write(bytes: []const u8) void {
        if (bytes.len > 0) host.avalanche_write(bytes.ptr, bytes.len);
    }
};

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!is_wasm) return std.debug.print(fmt, args);
    var buf: [1024]u8 = undefined;
    var out = Stdout.init(&buf);
    const w = out.writer();
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    std.debug.panic(format, args);
}

pub inline fn atomic_load(comptime T: type, ptr: *const T, comptime order: std.lang.AtomicOrder) T {
    if (comptime has_threads) return @atomicLoad(T, ptr, order);
    return ptr.*;
}

pub inline fn atomic_store(comptime T: type, ptr: *T, value: T, comptime order: std.lang.AtomicOrder) void {
    if (comptime has_threads) return @atomicStore(T, ptr, value, order);
    ptr.* = value;
}

pub inline fn atomic_rmw(comptime T: type, ptr: *T, comptime op: std.lang.AtomicRmwOp, operand: T, comptime order: std.lang.AtomicOrder) T {
    if (comptime has_threads) return @atomicRmw(T, ptr, op, operand, order);
    const old = ptr.*;
    ptr.* = apply_rmw(T, op, old, operand);
    return old;
}

fn apply_rmw(comptime T: type, comptime op: std.lang.AtomicRmwOp, old: T, operand: T) T {
    return switch (op) {
        .Xchg => operand,
        .Add => old +% operand,
        .Sub => old -% operand,
        .And => old & operand,
        .Or => old | operand,
        .Xor => old ^ operand,
        .Nand => ~(old & operand),
        .Max => @max(old, operand),
        .Min => @min(old, operand),
    };
}

test {
    _ = affinity;
}

test "apply_rmw matches @atomicRmw for every operation" {
    const cases = [_][2]i64{ .{ 0, 0 }, .{ 5, -3 }, .{ std.math.maxInt(i64), 1 }, .{ std.math.minInt(i64), -1 }, .{ -7, 7 } };
    inline for (comptime std.enums.values(std.lang.AtomicRmwOp)) |op| {
        for (cases) |case| {
            var cell = case[0];
            const previous = @atomicRmw(i64, &cell, op, case[1], .monotonic);
            try std.testing.expectEqual(case[0], previous);
            try std.testing.expectEqual(cell, apply_rmw(i64, op, case[0], case[1]));
        }
    }
}
