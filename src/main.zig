const std = @import("std");
const types = @import("chess/types.zig");
const tables = @import("chess/tables.zig");
const zobrist = @import("chess/zobrist.zig");
const position = @import("chess/position.zig");
const search = @import("engine/search.zig");
const tt = @import("engine/tt.zig");
const interface = @import("engine/interface.zig");
const weights = @import("engine/weights.zig");
const bench = @import("engine/bench.zig");
const datagen = @import("engine/datagen.zig");

const arch = @import("build_options");

pub fn main() anyerror!void {
    tables.init_all();
    zobrist.init_zobrist();
    tt.GlobalTT.reset(16);
    defer tt.GlobalTT.data.deinit();
    weights.do_nnue();
    search.init_lmr();

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);

    _ = args.next();
    var second = args.next();
    if (second != null) {
        if (std.mem.eql(u8, second.?, "bench")) {
            try bench.bench();
            return;
        }
        if (std.mem.eql(u8, second.?, "datagen")) {
            var gen = datagen.Datagen.new();
            defer gen.deinit();

            var pos = position.Position.new();
            pos.set_fen(types.DEFAULT_FEN);
            tt.LOCK_GLOBAL_TT = true;
            tt.GlobalTT.reset(2048);
            try gen.start(12);
            return;
        }
    }

    var inter = interface.UciInterface.new();
    return inter.main_loop();
}
