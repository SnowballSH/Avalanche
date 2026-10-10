//! See docs/WASM.md.

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

pub const panic = std.debug.FullPanic(report_panic);

fn report_panic(msg: []const u8, _: ?usize) noreturn {
    platform.print("info string panic: {s}\n", .{msg});
    @trap();
}

const INPUT_CAPACITY = 1 << 16;

var input_buf: [INPUT_CAPACITY]u8 = undefined;
var output_buf: [1 << 16]u8 = undefined;
var output: platform.Stdout = undefined;
var engine: *interface.UciInterface = undefined;

export fn avalanche_init() void {
    tables.init_all();
    zobrist.init_zobrist();
    cuckoo.init();
    tt.GlobalTT.reset(tt.DEFAULT_HASH_MB);
    weights.use_embedded();
    search.init_lmr();

    output = platform.Stdout.init(&output_buf);
    engine = platform.allocator.create(interface.UciInterface) catch platform.fatal("out of memory: UCI interface", .{});
    engine.init();
}

export fn avalanche_input_ptr() [*]u8 {
    return &input_buf;
}

export fn avalanche_input_cap() usize {
    return INPUT_CAPACITY;
}

export fn avalanche_command(len: usize) bool {
    const w = output.writer();
    const running = engine.handle_command(input_buf[0..@min(len, INPUT_CAPACITY)], w) catch |err| blk: {
        w.print("info string error: {s}\n", .{@errorName(err)}) catch {};
        break :blk true;
    };
    w.flush() catch {};
    return running;
}

export fn avalanche_bench() void {
    bench.bench() catch {};
}
