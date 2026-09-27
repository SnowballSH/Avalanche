//! wasm32-freestanding entry point. The host ABI is specified in docs/WASM.md.

const std = @import("std");
const platform = @import("platform.zig");
const tables = @import("chess/tables.zig");
const zobrist = @import("chess/zobrist.zig");
const cuckoo = @import("chess/cuckoo.zig");
const search = @import("engine/search.zig");
const tt = @import("engine/tt.zig");
const interface = @import("engine/interface.zig");
const weights = @import("engine/weights.zig");
const bench = @import("engine/bench.zig");

comptime {
    if (!platform.is_wasm) @compileError("src/wasm.zig must be built for a wasm32 target");
}

pub const panic = std.debug.FullPanic(reportPanic);

fn reportPanic(msg: []const u8, _: ?usize) noreturn {
    platform.print("info string panic: {s}\n", .{msg});
    @trap();
}

const input_capacity = 1 << 16;

var input_buf: [input_capacity]u8 = undefined;
var output_buf: [1 << 16]u8 = undefined;
var output: platform.Stdout = undefined;
var engine: *interface.UciInterface = undefined;

export fn avalanche_init() void {
    tables.init_all();
    zobrist.init_zobrist();
    cuckoo.init();
    tt.GlobalTT.reset(16);
    weights.do_nnue();
    search.init_lmr();

    output = platform.Stdout.init(&output_buf);
    engine = platform.allocator.create(interface.UciInterface) catch @panic("out of memory");
    engine.init();
}

export fn avalanche_input_ptr() [*]u8 {
    return &input_buf;
}

export fn avalanche_input_cap() usize {
    return input_capacity;
}

export fn avalanche_command(len: usize) bool {
    const w = output.writer();
    const running = engine.handle_command(input_buf[0..@min(len, input_capacity)], w) catch |err| blk: {
        w.print("info string error: {s}\n", .{@errorName(err)}) catch {};
        break :blk true;
    };
    w.flush() catch {};
    return running;
}

export fn avalanche_bench() void {
    bench.bench() catch {};
}
