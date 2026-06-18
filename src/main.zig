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

pub fn main(init: std.process.Init) anyerror!void {
    types.GLOBAL_IO = init.io;

    tables.init_all();
    zobrist.init_zobrist();
    tt.GlobalTT.reset(16);
    defer tt.GlobalTT.data.deinit();
    weights.do_nnue();
    search.init_lmr();

    // toSlice works on all targets (Args.Iterator.init is a Windows compile error).
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2) {
        const second = args[1];
        if (std.mem.eql(u8, second, "bench")) {
            try bench.bench();
            return;
        }
        if (std.mem.eql(u8, second, "datagen")) {
            // Usage: datagen [threads] [book.epd] [format=viri|bullet] [nodes=5000]
            var config = datagen.DatagenConfig{};

            const num_threads: usize = if (args.len >= 3)
                std.fmt.parseInt(usize, args[2], 10) catch 7
            else
                7;

            // Parse optional keyword args
            var book_path: ?[]const u8 = null;
            for (args[@min(3, args.len)..]) |arg| {
                if (std.mem.startsWith(u8, arg, "format=")) {
                    const val = arg[7..];
                    if (std.mem.eql(u8, val, "bullet")) {
                        config.format = .bullet;
                    } else {
                        config.format = .viri;
                    }
                } else if (std.mem.startsWith(u8, arg, "nodes=")) {
                    config.soft_nodes = std.fmt.parseInt(u64, arg[6..], 10) catch 5000;
                } else {
                    book_path = arg;
                }
            }

            var gen = datagen.Datagen.new(config);
            defer gen.deinit();

            tt.LOCK_GLOBAL_TT = true;
            tt.GlobalTT.reset(2048);

            if (book_path) |path| {
                gen.openings = try datagen.loadEpdFile(path);
            }

            try gen.start(num_threads);
            return;
        }

        if (std.mem.eql(u8, second, "datagen_single")) {
            var gen = datagen.Datagen.new(.{});
            defer gen.deinit();

            tt.LOCK_GLOBAL_TT = true;
            tt.GlobalTT.reset(256);
            try gen.startSingleThreaded();
            return;
        }
    }

    var inter = interface.UciInterface.new();
    return inter.main_loop();
}
