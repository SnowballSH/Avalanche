const std = @import("std");
const types = @import("chess/types.zig");
const platform = @import("platform.zig");
const tables = @import("chess/tables.zig");
const zobrist = @import("chess/zobrist.zig");
const cuckoo = @import("chess/cuckoo.zig");
const position = @import("chess/position.zig");
const search = @import("engine/search.zig");
const tt = @import("engine/tt.zig");
const interface = @import("engine/interface.zig");
const weights = @import("engine/weights.zig");
const bench = @import("engine/bench.zig");
const datagen = @import("engine/datagen.zig");
const datagen_options = @import("engine/datagen/options.zig");
const tbfilter = @import("engine/tbfilter.zig");

const arch = @import("build_options");

const DATAGEN_USAGE =
    \\Usage: datagen <threads> [book.epd | book=path] [key=value ...]
    \\  nodes=N       soft node limit per move (default 10000)
    \\  hardmult=N    hard limit = nodes * N (default 8)
    \\  plies=A-B     random plies without a book (default 8-10)
    \\  bookplies=A-B random plies after a book line (default 0-2)
    \\  randsee=N     SEE threshold for random moves (default -200)
    \\  ttmb=N        TT MiB per side per thread (default 4)
    \\  positions=N   stop after at least N positions, at a game boundary (default: unbounded)
    \\  seed=N        deterministic seed (default: random)
    \\  out=PATH      output file, must not exist (default data_<seed>.viribin)
    \\  format=viri|bullet (default viri)
    \\
;

fn run_datagen(args: []const []const u8) !void {
    var diag: datagen_options.Diagnostic = .{};
    const opts = datagen_options.parse(args, &diag) catch |err| {
        std.debug.print("datagen: {s} for '{s}={s}'\n{s}", .{ @errorName(err), diag.key, diag.value, DATAGEN_USAGE });
        std.process.exit(2);
    };

    const seed = opts.seed orelse blk: {
        var random: u64 = undefined;
        std.Io.random(platform.io, std.mem.asBytes(&random));
        break :blk random;
    };
    var gen = datagen.Datagen.new(datagen.DatagenConfig.from_options(opts), seed);
    defer gen.deinit();
    if (opts.book) |path| {
        var book_diag: datagen.BookDiagnostic = .{};
        gen.openings = datagen.loadEpdFile(path, &book_diag) catch |err| {
            if (err == error.InvalidBookLine) {
                std.debug.print("datagen: book '{s}' line {}: {s}\n", .{ path, book_diag.line, book_diag.reason });
            } else {
                std.debug.print("datagen: cannot load book '{s}': {s}\n", .{ path, @errorName(err) });
            }
            std.process.exit(2);
        };
        std.debug.print("Loaded {} openings from {s}\n", .{ gen.openings.?.len, path });
    }

    var path_buf: [64]u8 = undefined;
    const out = opts.out orelse datagen.default_output_path(&path_buf, seed, opts.format);
    gen.print_banner(opts.threads, out);
    gen.start(opts.threads, out) catch |err| {
        if (err == error.WorkerFailed) std.process.exit(1);
        std.debug.print("datagen: cannot write '{s}': {s}\n", .{ out, @errorName(err) });
        std.process.exit(2);
    };

    var buffer: [512]u8 = undefined;
    var stdout = platform.Stdout.init(&buffer);
    try stdout.writer().print("{f}\n", .{std.json.fmt(gen.summary(), .{})});
    try stdout.writer().flush();
}

pub fn main(init: std.process.Init) anyerror!void {
    platform.io = init.io;

    tables.init_all();
    zobrist.init_zobrist();
    cuckoo.init();
    tt.GlobalTT.reset(16);
    defer tt.GlobalTT.deinit();
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
            return run_datagen(args[2..]);
        }

        if (std.mem.eql(u8, second, "tbfilter")) {
            // Usage: tbfilter <input.bin> <output.bin> tb=<path> [threads=..] [men=5] [max=..] [rule50=keep|on|off]
            const code = tbfilter.run(args[2..]);
            if (code != 0) std.process.exit(code);
            return;
        }
    }

    const inter = std.heap.c_allocator.create(interface.UciInterface) catch unreachable;
    inter.init();
    defer std.heap.c_allocator.destroy(inter);
    return inter.main_loop();
}
