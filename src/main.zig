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
const tbfilter = @import("engine/tbfilter.zig");

const arch = @import("build_options");

fn parsePlySpan(value: []const u8, min_out: *u64, range_out: *u64) void {
    if (std.mem.indexOfScalar(u8, value, '-')) |sep| {
        const min = std.fmt.parseInt(u64, value[0..sep], 10) catch return;
        const max = std.fmt.parseInt(u64, value[sep + 1 ..], 10) catch return;
        min_out.* = min;
        range_out.* = if (max >= min) max - min + 1 else 1;
    } else if (std.mem.indexOfScalar(u8, value, ':')) |sep| {
        const min = std.fmt.parseInt(u64, value[0..sep], 10) catch return;
        const range = std.fmt.parseInt(u64, value[sep + 1 ..], 10) catch return;
        min_out.* = min;
        range_out.* = range;
    } else if (std.mem.indexOfScalar(u8, value, ',')) |sep| {
        const min = std.fmt.parseInt(u64, value[0..sep], 10) catch return;
        const range = std.fmt.parseInt(u64, value[sep + 1 ..], 10) catch return;
        min_out.* = min;
        range_out.* = range;
    } else {
        const plies = std.fmt.parseInt(u64, value, 10) catch return;
        min_out.* = plies;
        range_out.* = 1;
    }
}

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
            // Usage: datagen [threads] [book.epd] [format=viri|bullet] [nodes=5000] [plies=8-10] [bookplies=0-2] [randsee=-200] [ttmb=4]
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
                } else if (std.mem.startsWith(u8, arg, "hardmult=")) {
                    config.hard_node_multiplier = std.fmt.parseInt(u64, arg[9..], 10) catch config.hard_node_multiplier;
                } else if (std.mem.startsWith(u8, arg, "plies=")) {
                    parsePlySpan(arg[6..], &config.random_plies_min, &config.random_plies_range);
                } else if (std.mem.startsWith(u8, arg, "bookplies=")) {
                    parsePlySpan(arg[10..], &config.book_random_plies_min, &config.book_random_plies_range);
                } else if (std.mem.startsWith(u8, arg, "randsee=")) {
                    config.random_move_see_threshold = std.fmt.parseInt(i32, arg[8..], 10) catch config.random_move_see_threshold;
                } else if (std.mem.startsWith(u8, arg, "ttmb=")) {
                    config.datagen_tt_mb = std.fmt.parseInt(u64, arg[5..], 10) catch config.datagen_tt_mb;
                } else {
                    book_path = arg;
                }
            }

            var gen = datagen.Datagen.new(config);
            defer gen.deinit();

            if (book_path) |path| {
                gen.openings = try datagen.loadEpdFile(path);
            }

            try gen.start(num_threads);
            return;
        }

        if (std.mem.eql(u8, second, "datagen_single")) {
            var gen = datagen.Datagen.new(.{});
            defer gen.deinit();

            try gen.startSingleThreaded();
            return;
        }

        if (std.mem.eql(u8, second, "tbfilter")) {
            // Usage: tbfilter <input.bin> <output.bin> tb=<path> [threads=..] [men=5] [max=..] [rule50=keep|on|off]
            const code = tbfilter.run(args[2..]);
            if (code != 0) std.process.exit(code);
            return;
        }
    }

    var inter = interface.UciInterface.new();
    return inter.main_loop();
}
