//! See "Opening generation for OpenBench" in docs/DATAGEN.md.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const utils = @import("../chess/utils.zig");
const position = @import("../chess/position.zig");
const frc = @import("../chess/frc.zig");
const book = @import("datagen/book.zig");

pub const Variant = enum { standard, frc, dfrc };

const NO_BOOK = "None";
const MAX_CONSECUTIVE_UNUSABLE_OPENINGS = 10_000;

const PlyRange = struct {
    min: usize,
    count: usize,

    fn pick(self: PlyRange, prng: *utils.PRNG) usize {
        return self.min + @as(usize, @intCast(prng.rand64() % self.count));
    }
};

const PLIES_AFTER_BOOK: PlyRange = .{ .min = 1, .count = 3 };
const PLIES_WITHOUT_BOOK: PlyRange = .{ .min = 9, .count = 4 };

pub const Options = struct {
    count: u64 = 1,
    seed: u64 = 0,
    book_path: ?[]const u8 = null,
    variant: Variant = .standard,
};

pub const ParseError = error{ InvalidValue, MissingValue, UnknownArgument };

pub fn parse(args: []const []const u8, offending: *[]const u8) ParseError!Options {
    var options: Options = .{};
    if (args.len == 0) return options;
    offending.* = args[0];
    options.count = std.fmt.parseInt(u64, args[0], 10) catch return error.InvalidValue;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        offending.* = args[index];
        if (std.meta.stringToEnum(Variant, args[index])) |variant| {
            options.variant = variant;
            continue;
        }
        const keyword = std.meta.stringToEnum(enum { seed, book }, args[index]) orelse return error.UnknownArgument;
        index += 1;
        if (index == args.len) return error.MissingValue;
        const value = args[index];
        offending.* = value;
        switch (keyword) {
            .seed => options.seed = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue,
            .book => options.book_path = if (std.mem.eql(u8, value, NO_BOOK)) null else value,
        }
    }
    return options;
}

fn play_random_moves(pos: *position.Position, prng: *utils.PRNG, n_plies: usize) void {
    for (0..n_plies) |_| {
        const movelist = pos.legal_moves();
        if (movelist.len == 0) return;
        const move = movelist.items()[prng.rand64() % movelist.len];
        if (pos.turn == types.Color.White) {
            pos.play_move(types.Color.White, move);
        } else {
            pos.play_move(types.Color.Black, move);
        }
    }
}

fn random_start(prng: *utils.PRNG) u16 {
    return @intCast(prng.rand64() % frc.N_POSITIONS);
}

fn position_is_usable(pos: *position.Position) bool {
    const in_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);
    if (in_check) return false;
    return pos.legal_moves().len > 0;
}

pub fn generate(options: Options, book_lines: []const []const u8, out: *std.Io.Writer) !void {
    const seed = options.seed;
    var prng = utils.PRNG.new(@as(u128, seed) | (@as(u128, seed) << 64) ^ 0xdeadbeefcafe1234);

    var pos: position.Position = undefined;
    pos.init();
    defer pos.deinit();

    var generated: u64 = 0;
    var consecutive_unusable: usize = 0;
    while (generated < options.count) {
        if (book_lines.len > 0) {
            const line = book_lines[prng.rand64() % book_lines.len];
            pos.set_fen(line);
            play_random_moves(&pos, &prng, PLIES_AFTER_BOOK.pick(&prng));
        } else {
            var fen_buf: [frc.FEN_CAPACITY]u8 = undefined;
            pos.set_fen(switch (options.variant) {
                .standard => types.DEFAULT_FEN,
                .frc => frc.frc_fen(random_start(&prng), &fen_buf),
                .dfrc => frc.dfrc_fen(random_start(&prng), random_start(&prng), &fen_buf),
            });
            play_random_moves(&pos, &prng, PLIES_WITHOUT_BOOK.pick(&prng));
        }

        if (!position_is_usable(&pos)) {
            consecutive_unusable += 1;
            if (consecutive_unusable == MAX_CONSECUTIVE_UNUSABLE_OPENINGS) return error.NoUsableOpening;
            continue;
        }
        consecutive_unusable = 0;

        const fen = pos.basic_fen(std.heap.page_allocator);
        defer std.heap.page_allocator.free(fen);

        try out.print("info string genfens {s}\n", .{fen});
        try out.flush();

        generated += 1;
    }
}

pub fn write_openings(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    var offending: []const u8 = "";
    const options = parse(args, &offending) catch |failure| {
        try err.print("genfens: {s} at '{s}'\n", .{ @errorName(failure), offending });
        return failure;
    };

    var diag: book.Diagnostic = .{};
    var openings: ?book.Book = if (options.book_path) |path|
        book.Book.load(platform.allocator, path, &diag) catch |failure| {
            if (failure == error.InvalidBookLine) {
                try err.print("genfens: book '{s}' line {}: {s}\n", .{ path, diag.line, diag.reason });
            } else {
                try err.print("genfens: cannot load book '{s}': {s}\n", .{ path, @errorName(failure) });
            }
            return failure;
        }
    else
        null;
    defer if (openings) |*loaded| loaded.deinit();

    generate(options, if (openings) |loaded| loaded.lines else &.{}, out) catch |failure| {
        if (failure == error.NoUsableOpening) {
            try err.print("genfens: {} consecutive openings ended in check or without a legal move\n", .{MAX_CONSECUTIVE_UNUSABLE_OPENINGS});
        }
        return failure;
    };
}

pub fn run(args_in: []const []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout().writerStreaming(platform.io, &out_buf);
    var err_buf: [512]u8 = undefined;
    var err_file = std.Io.File.stderr().writerStreaming(platform.io, &err_buf);
    defer err_file.interface.flush() catch {};
    return write_openings(args_in[1..], &out_file.interface, &err_file.interface);
}
