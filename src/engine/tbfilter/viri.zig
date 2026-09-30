const std = @import("std");
const types = @import("../../chess/types.zig");
const position = @import("../../chess/position.zig");
const syzygy = @import("../syzygy.zig");
const viriformat = @import("../datagen/viriformat.zig");
const tbfilter = @import("../tbfilter.zig");
const platform = @import("../../platform.zig");

pub const Rule50Mode = tbfilter.Rule50Mode;

/// Stored in place of a contradicted position's eval. Datagen clamps evals to ±32000, and the trainer's filter drops
/// every position whose |eval| reaches its `max_eval`.
pub const MASKED_EVAL: i16 = std.math.maxInt(i16);

pub const Prober = *const fn (pos: *const position.Position) ?syzygy.WdlResult;

pub const Stats = struct {
    games: u64 = 0,
    positions: u64 = 0,
    over_men: u64 = 0,
    castling: u64 = 0,
    failed: u64 = 0,
    ambiguous: u64 = 0,
    agree: u64 = 0,
    masked: u64 = 0,
};

/// Replays viriformat games and masks every position of at most `max_men` whose tablebase result contradicts the
/// game result. Masking edits only the eval of that position, so the output replays exactly like the input.
pub const Cleaner = struct {
    probe: Prober,
    max_men: u32,
    mode: Rule50Mode,
    stats: Stats = .{},

    pub fn clean_buffer(self: *Cleaner, pos: *position.Position, bytes: []u8) !void {
        var reader = viriformat.Reader.init(bytes);
        while (try reader.next()) |game| try self.clean_game(pos, game);
    }

    pub fn clean_game(self: *Cleaner, pos: *position.Position, game: viriformat.Game) !void {
        viriformat.set_position(pos, game.header.*);
        const white_result = game.header.wdl;
        for (game.pairs) |*pair| {
            self.stats.positions += 1;
            const mover_result = if (pos.turn == types.Color.White) white_result else 2 - white_result;
            if (self.contradicts(pos, mover_result)) {
                pair.score = MASKED_EVAL;
                self.stats.masked += 1;
            }
            const move = try viriformat.decode_move(pos, pair.move);
            if (pos.turn == types.Color.White) pos.play_move(types.Color.White, move) else pos.play_move(types.Color.Black, move);
        }
        self.stats.games += 1;
    }

    fn contradicts(self: *Cleaner, pos: *const position.Position, mover_result: u8) bool {
        if (@popCount(pos.all_all_pieces()) > self.max_men) {
            self.stats.over_men += 1;
            return false;
        }
        if (pos.castling_rights() != 0) {
            self.stats.castling += 1;
            return false;
        }
        const wdl = self.probe(pos) orelse {
            self.stats.failed += 1;
            return false;
        };
        const expected = tbfilter.expectedResult(wdl, self.mode) orelse {
            self.stats.ambiguous += 1;
            return false;
        };
        if (expected == mover_result) {
            self.stats.agree += 1;
            return false;
        }
        return true;
    }
};

/// `tbfilter format=viri`: cleans one viriformat file into a new file and prints the statistics as one JSON line.
pub fn run_file(cfg: tbfilter.Config) u8 {
    const tb_max = tbfilter.load_tablebases(cfg.tb_path) orelse return 1;
    defer syzygy.deinit();
    const io = platform.io;
    const cwd = std.Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, cfg.input, std.heap.page_allocator, .unlimited) catch |err| {
        std.debug.print("tbfilter: cannot read '{s}': {s}\n", .{ cfg.input, @errorName(err) });
        return 1;
    };
    defer std.heap.page_allocator.free(bytes);

    const pos = std.heap.page_allocator.create(position.Position) catch return 1;
    defer std.heap.page_allocator.destroy(pos);
    pos.init();
    defer pos.deinit();
    var cleaner = Cleaner{ .probe = syzygy.probe_wdl_position, .max_men = @min(cfg.max_men, tb_max), .mode = cfg.rule50 };
    cleaner.clean_buffer(pos, bytes) catch |err| {
        std.debug.print("tbfilter: '{s}' is not valid viriformat: {s}\n", .{ cfg.input, @errorName(err) });
        return 1;
    };

    write_new_file(io, cwd, cfg.output, bytes) catch |err| {
        std.debug.print("tbfilter: cannot write '{s}': {s}\n", .{ cfg.output, @errorName(err) });
        return 1;
    };

    var buffer: [512]u8 = undefined;
    var stdout = platform.Stdout.init(&buffer);
    stdout.writer().print("{f}\n", .{std.json.fmt(cleaner.stats, .{})}) catch return 1;
    stdout.writer().flush() catch return 1;
    return 0;
}

/// Creates `path`, which must not exist yet, holding exactly `bytes`; a failed write leaves no file behind.
pub fn write_new_file(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const out = try dir.createFile(io, path, .{ .exclusive = true });
    errdefer dir.deleteFile(io, path) catch {};
    defer out.close(io);
    try out.writeStreamingAll(io, bytes);
}
