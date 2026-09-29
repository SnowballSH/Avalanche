const std = @import("std");
const tables = @import("../chess/tables.zig");
const zobrist = @import("../chess/zobrist.zig");
const position = @import("../chess/position.zig");
const weights = @import("../engine/weights.zig");
const cuckoo = @import("../chess/cuckoo.zig");
const search = @import("../engine/search.zig");

pub fn init_tables() void {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
}

var search_initialized = false;

/// `cuckoo.init` is not idempotent, so search tables are built once per test binary.
pub fn init_search() void {
    init_tables();
    if (search_initialized) return;
    cuckoo.init();
    search.init_lmr();
    search_initialized = true;
}

pub fn new_position() !*position.Position {
    const pos = try std.testing.allocator.create(position.Position);
    pos.init();
    return pos;
}

pub fn destroy_position(pos: *position.Position) void {
    pos.deinit();
    std.testing.allocator.destroy(pos);
}
