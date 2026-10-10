//! See "Tablebase cleaning" in docs/DATAGEN.md.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const syzygy = @import("syzygy.zig");
const arguments = @import("datagen/arguments.zig");
const SideResult = @import("datagen/adjudicator.zig").SideResult;
const viri = @import("tbfilter/viri.zig");

const RECORD_SIZE: usize = 32;
const MIN_MEN: u32 = 2;
const MAX_MEN: u32 = 7;
const DEFAULT_MAX_MEN: u32 = 5;
const MAX_THREADS: usize = 256;
const MAX_AUTOMATIC_THREADS: usize = 32;
const WORKER_STACK_SIZE: usize = 8 * 1024 * 1024;
const BLOCK_RECS: usize = 1 << 17;
const BLOCK_BYTES: usize = BLOCK_RECS * RECORD_SIZE;
const SIDE_RESULTS = std.enums.values(SideResult).len;

pub const Rule50Mode = enum { keep, on, off };

pub const Format = @import("datagen/format.zig").Format;

pub const Config = struct {
    format: Format,
    input: []const u8,
    output: []const u8,
    tb_path: []const u8,
    threads: ?usize = null,
    max_men: u32 = DEFAULT_MAX_MEN,
    max_positions: ?u64 = null,
    rule50: Rule50Mode = .keep,
};

const Stats = struct {
    read: u64 = 0,
    over_men: u64 = 0,
    probed: u64 = 0,
    agree: u64 = 0,
    disagree: u64 = 0,
    ambiguous: u64 = 0,
    ep_skipped: u64 = 0,
    failed: u64 = 0,
    anomalies: u64 = 0,
    recorded_by_tablebase: [SIDE_RESULTS][SIDE_RESULTS]u64 = @splat(@splat(0)),
    probed_by_men: [MAX_MEN + 1]u64 = @splat(0),
    dropped_by_men: [MAX_MEN + 1]u64 = @splat(0),

    fn kept(self: Stats) u64 {
        return self.read - self.disagree;
    }

    fn merge(self: *Stats, o: Stats) void {
        self.read += o.read;
        self.over_men += o.over_men;
        self.probed += o.probed;
        self.agree += o.agree;
        self.disagree += o.disagree;
        self.ambiguous += o.ambiguous;
        self.ep_skipped += o.ep_skipped;
        self.failed += o.failed;
        self.anomalies += o.anomalies;
        for (&self.recorded_by_tablebase, o.recorded_by_tablebase) |*row, other_row| {
            for (row, other_row) |*cell, other_cell| cell.* += other_cell;
        }
        for (0..MAX_MEN + 1) |i| {
            self.probed_by_men[i] += o.probed_by_men[i];
            self.dropped_by_men[i] += o.dropped_by_men[i];
        }
    }
};

const Worker = struct {
    input: []const u8,
    part_path: []const u8,
    start_rec: u64,
    end_rec: u64,
    id: usize,
    max_men: u32,
    rule50: Rule50Mode,
    progress: *std.atomic.Value(u64),
    stats: Stats = .{},
    bytes_written: u64 = 0,
    ok: bool = true,
    err: []const u8 = "",
};

pub fn expectedResult(w: syzygy.WdlResult, mode: Rule50Mode) ?SideResult {
    switch (w) {
        .win => return .win,
        .loss => return .loss,
        .draw => return .draw,
        .cursed_win => switch (mode) {
            .keep => return null,
            .on => return .draw,
            .off => return .win,
        },
        .blessed_loss => switch (mode) {
            .keep => return null,
            .on => return .draw,
            .off => return .loss,
        },
    }
}

/// A record is stored from the side to move's point of view (`white` here), flipped vertically when that side is
/// Black, so the pawns of a possible en-passant capture stand side by side on rank 5 whichever colour is to move.
fn enPassantPossible(white: u64, black: u64, pawns: u64) bool {
    const RANK5: u64 = 0x0000_00FF_0000_0000;
    const FILE_A: u64 = 0x0101_0101_0101_0101;
    const FILE_H: u64 = 0x8080_8080_8080_8080;
    const wp5 = pawns & white & RANK5;
    const bp5 = pawns & black & RANK5;
    const adjacent = ((bp5 & ~FILE_A) >> 1) | ((bp5 & ~FILE_H) << 1);
    return (wp5 & adjacent) != 0;
}

fn classify(buf: []const u8, base: usize, max_men: u32, mode: Rule50Mode, st: *Stats) bool {
    st.read += 1;

    const occ = std.mem.readInt(u64, buf[base..][0..8], .little);
    const men: u32 = @popCount(occ);
    if (men > max_men) {
        st.over_men += 1;
        return true;
    }

    st.probed += 1;
    st.probed_by_men[men] += 1;

    var white: u64 = 0;
    var black: u64 = 0;
    var kings: u64 = 0;
    var queens: u64 = 0;
    var rooks: u64 = 0;
    var bishops: u64 = 0;
    var knights: u64 = 0;
    var pawns: u64 = 0;

    var occ_it = occ;
    var idx: usize = 0;
    var unknown_piece = false;
    while (occ_it != 0) {
        const sq: u6 = @intCast(@ctz(occ_it));
        const bit = @as(u64, 1) << sq;
        occ_it &= occ_it - 1;

        const byte = buf[base + 8 + idx / 2];
        const nib: u8 = if (idx & 1 == 0) (byte & 0x0F) else (byte >> 4);
        idx += 1;

        if ((nib & 0x08) != 0) {
            black |= bit;
        } else {
            white |= bit;
        }
        switch (nib & 0x07) {
            0 => pawns |= bit,
            1 => knights |= bit,
            2 => bishops |= bit,
            3 => rooks |= bit,
            4 => queens |= bit,
            5 => kings |= bit,
            else => unknown_piece = true,
        }
    }

    if (unknown_piece or @popCount(kings) != 2 or @popCount(kings & white) != 1 or @popCount(kings & black) != 1 or white == 0 or black == 0) {
        st.anomalies += 1;
        return true;
    }

    if (enPassantPossible(white, black, pawns)) {
        st.ep_skipped += 1;
        return true;
    }

    const wdl = syzygy.probe_wdl_bb(white, black, kings, queens, rooks, bishops, knights, pawns, 0, true) orelse {
        st.failed += 1;
        return true;
    };

    const recorded = std.enums.fromInt(SideResult, buf[base + 26]) orelse {
        st.anomalies += 1;
        return true;
    };

    const expected = expectedResult(wdl, mode) orelse {
        st.ambiguous += 1;
        return true;
    };

    st.recorded_by_tablebase[@backingInt(recorded)][@backingInt(expected)] += 1;
    if (expected == recorded) {
        st.agree += 1;
        return true;
    }
    st.disagree += 1;
    st.dropped_by_men[men] += 1;
    return false;
}

fn workerRun(w: *Worker) void {
    const io = platform.io;

    const in_file = std.Io.Dir.cwd().openFile(io, w.input, .{}) catch {
        w.ok = false;
        w.err = "could not open input file";
        return;
    };
    defer in_file.close(io);

    const out_file = std.Io.Dir.cwd().createFile(io, w.part_path, .{ .read = true }) catch {
        w.ok = false;
        w.err = "could not create output/part file";
        return;
    };
    defer out_file.close(io);

    const read_buf = std.heap.page_allocator.alloc(u8, BLOCK_BYTES) catch {
        w.ok = false;
        w.err = "out of memory (read buffer)";
        return;
    };
    defer std.heap.page_allocator.free(read_buf);
    const out_buf = std.heap.page_allocator.alloc(u8, BLOCK_BYTES) catch {
        w.ok = false;
        w.err = "out of memory (write buffer)";
        return;
    };
    defer std.heap.page_allocator.free(out_buf);

    var rec = w.start_rec;
    var woff: u64 = 0;
    var block_index: u64 = 0;
    while (rec < w.end_rec) {
        const this_recs: usize = @intCast(@min(@as(u64, BLOCK_RECS), w.end_rec - rec));
        const want = this_recs * RECORD_SIZE;
        const n = in_file.readPositionalAll(io, read_buf[0..want], rec * RECORD_SIZE) catch {
            w.ok = false;
            w.err = "read error";
            return;
        };
        const got: usize = n / RECORD_SIZE;

        var out_len: usize = 0;
        for (0..got) |i| {
            const base = i * RECORD_SIZE;
            if (classify(read_buf, base, w.max_men, w.rule50, &w.stats)) {
                @memcpy(out_buf[out_len .. out_len + RECORD_SIZE], read_buf[base .. base + RECORD_SIZE]);
                out_len += RECORD_SIZE;
            }
        }

        if (out_len > 0) {
            out_file.writePositionalAll(io, out_buf[0..out_len], woff) catch {
                w.ok = false;
                w.err = "write error";
                return;
            };
            woff += out_len;
        }

        rec += got;
        _ = w.progress.fetchAdd(got, .monotonic);
        block_index += 1;

        if (w.id == 0 and (block_index & 0x3F) == 0) {
            std.debug.print("  ... {} positions processed\n", .{w.progress.load(.monotonic)});
        }

        if (got < this_recs) break;
    }

    if (rec < w.end_rec) {
        w.ok = false;
        w.err = "short read (input truncated?)";
        return;
    }

    w.bytes_written = woff;
}

fn copyPart(out_file: std.Io.File, part: []const u8, buf: []u8, woff: u64) !u64 {
    const io = platform.io;
    const pf = try std.Io.Dir.cwd().openFile(io, part, .{});
    defer pf.close(io);
    const plen = try pf.length(io);
    var off: u64 = 0;
    while (off < plen) {
        const chunk: usize = @intCast(@min(@as(u64, BLOCK_BYTES), plen - off));
        const n = try pf.readPositionalAll(io, buf[0..chunk], off);
        if (n == 0) break;
        try out_file.writePositionalAll(io, buf[0..n], woff + off);
        off += n;
    }
    if (off != plen) return error.PartialRead;
    return off;
}

fn concatParts(output: []const u8, parts: []const []const u8) !u64 {
    const io = platform.io;
    const out_file = try std.Io.Dir.cwd().createFile(io, output, .{ .read = true });
    defer out_file.close(io);

    const buf = try std.heap.page_allocator.alloc(u8, BLOCK_BYTES);
    defer std.heap.page_allocator.free(buf);

    var woff: u64 = 0;
    for (parts) |part| {
        woff += try copyPart(out_file, part, buf, woff);
        std.Io.Dir.cwd().deleteFile(io, part) catch {};
    }
    return woff;
}

const USAGE = std.fmt.comptimePrint(
    \\Usage: Avalanche tbfilter <input> <output> tb=<path> [options]
    \\
    \\The input's extension names its format ({s} bulletformat, {s} viriformat)
    \\unless format= does. The output is written in the same format, and its
    \\extension must not name the other one.
    \\bulletformat: drops every <=N-man position whose recorded WDL contradicts
    \\the Syzygy tablebase.
    \\viriformat: replays each game and masks such positions with an out-of-range
    \\eval that training filters drop; prints JSON stats.
    \\
    \\Required:
    \\  tb=<path>           Syzygy tablebase directory
    \\
    \\Options:
    \\  in=<path> out=<path>
    \\                      <input> and <output> by name, for a path with '=' in it
    \\  format=bullet|viri  Input format (default: by the input's extension)
    \\  threads=<n>         Worker threads, 1-{d}, bulletformat only
    \\                      (default: CPU count, at most {d})
    \\  men=<n>             Max men to probe, {d}-{d} (default {d})
    \\  max=<n>             Position limit, bulletformat only (default: whole file)
    \\  rule50=keep|on|off  Cursed-win / blessed-loss handling (default keep):
    \\                        keep = never drop on these (ambiguous)
    \\                        on   = treat both as a draw (50-move-rule aware)
    \\                        off  = cursed win=win, blessed loss=loss
    \\
, .{ Format.bullet.extension(), Format.viri.extension(), MAX_THREADS, MAX_AUTOMATIC_THREADS, MIN_MEN, MAX_MEN, DEFAULT_MAX_MEN });

pub fn load_tablebases(tb_path: []const u8) ?u32 {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, tb_path, 0) catch {
        std.debug.print("tbfilter: out of memory\n", .{});
        return null;
    };
    defer std.heap.page_allocator.free(path_z);
    if (!syzygy.init(path_z.ptr)) {
        std.debug.print("tbfilter: failed to load Syzygy tablebases from '{s}' -- aborting\n", .{tb_path});
        return null;
    }
    return @intCast(@max(@as(i32, 0), syzygy.max_pieces()));
}

pub const ParseError = arguments.KeyError || arguments.ValueError ||
    error{ MissingArgument, UnexpectedArgument, UndecidedFormat, OutputExtensionOfOtherFormat, BulletOnlyOption };

const Key = enum { in, out, tb, format, threads, men, max, rule50 };
const PATH_KEYS = [_]Key{ .in, .out };
const BULLET_ONLY_KEYS = [_]Key{ .threads, .max };

fn first_path_not_given(options: arguments.KeyValues(Key)) ?Key {
    for (PATH_KEYS) |key| {
        if (!options.given(key)) return key;
    }
    return null;
}

pub fn parse_config(args: []const []const u8, diag: *arguments.Diagnostic) ParseError!Config {
    var options: arguments.KeyValues(Key) = .{};
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var tablebase_path: ?[]const u8 = null;
    var named_format: ?Format = null;
    var threads: ?usize = null;
    var max_men: u32 = DEFAULT_MAX_MEN;
    var max_positions: ?u64 = null;
    var rule50: Rule50Mode = .keep;

    for (args) |arg| {
        const key_of_bare_argument: ?Key = if (arguments.is_key_value(arg)) null else first_path_not_given(options) orelse {
            diag.* = .{ .value = arg };
            return error.UnexpectedArgument;
        };
        const option = try options.next(arg, key_of_bare_argument, diag);
        switch (option.key) {
            .in => input_path = try arguments.non_empty(option.value),
            .out => output_path = try arguments.non_empty(option.value),
            .tb => tablebase_path = try arguments.non_empty(option.value),
            .format => named_format = try arguments.choice(Format, option.value),
            .threads => threads = try arguments.integer(usize, option.value, 1, MAX_THREADS),
            .men => max_men = try arguments.integer(u32, option.value, MIN_MEN, MAX_MEN),
            .max => max_positions = try arguments.integer(u64, option.value, 1, std.math.maxInt(u64)),
            .rule50 => rule50 = try arguments.choice(Rule50Mode, option.value),
        }
    }

    const input = input_path orelse return error.MissingArgument;
    const output = output_path orelse return error.MissingArgument;
    const tb_path = tablebase_path orelse return error.MissingArgument;
    const format = named_format orelse Format.of_path(input) orelse {
        diag.* = .{ .value = input };
        return error.UndecidedFormat;
    };
    if (Format.of_path(output)) |named_by_output| {
        if (named_by_output != format) {
            diag.* = .{ .value = output };
            return error.OutputExtensionOfOtherFormat;
        }
    }
    if (format == .viri) {
        for (BULLET_ONLY_KEYS) |key| {
            if (options.given(key)) {
                diag.* = .{ .key = @tagName(key) };
                return error.BulletOnlyOption;
            }
        }
    }
    return .{
        .format = format,
        .input = input,
        .output = output,
        .tb_path = tb_path,
        .threads = threads,
        .max_men = max_men,
        .max_positions = max_positions,
        .rule50 = rule50,
    };
}

fn report_parse_error(failure: ParseError, diag: arguments.Diagnostic) void {
    switch (failure) {
        error.MissingArgument => {},
        error.UnexpectedArgument => std.debug.print("tbfilter: unexpected argument '{s}'\n", .{diag.value}),
        error.UnknownKey => std.debug.print("tbfilter: unknown option '{s}'\n", .{diag.key}),
        error.DuplicateKey => std.debug.print("tbfilter: option {s} is given more than once\n", .{diag.key}),
        error.InvalidValue => std.debug.print("tbfilter: invalid value '{s}' for option {s}\n", .{ diag.value, diag.key }),
        error.UndecidedFormat => std.debug.print("tbfilter: the extension of '{s}' names no format; give format=bullet or format=viri\n", .{diag.value}),
        error.OutputExtensionOfOtherFormat => std.debug.print("tbfilter: the extension of output '{s}' names the other format; the output is written in the format of the input\n", .{diag.value}),
        error.BulletOnlyOption => std.debug.print("tbfilter: option {s} is not supported for viriformat\n", .{diag.key}),
    }
    std.debug.print("{s}", .{USAGE});
}

pub fn whole_records(input_bytes: u64) error{PartialRecord}!u64 {
    if (input_bytes % RECORD_SIZE != 0) return error.PartialRecord;
    return input_bytes / RECORD_SIZE;
}

pub fn run(args: []const []const u8) u8 {
    const io = platform.io;
    var diag: arguments.Diagnostic = .{};
    const cfg = parse_config(args, &diag) catch |failure| {
        report_parse_error(failure, diag);
        return 1;
    };

    if (std.mem.eql(u8, cfg.input, cfg.output)) {
        std.debug.print("tbfilter: input and output must differ\n", .{});
        return 1;
    }
    {
        const in_base = std.fs.path.basename(cfg.input);
        const out_base = std.fs.path.basename(cfg.output);
        if (std.mem.eql(u8, in_base, out_base) and (std.mem.eql(u8, cfg.input, out_base) or std.mem.eql(u8, cfg.output, in_base) or std.mem.endsWith(u8, cfg.input, cfg.output) or std.mem.endsWith(u8, cfg.output, cfg.input))) {
            if (std.mem.findScalar(u8, cfg.input, '/') == null or std.mem.findScalar(u8, cfg.output, '/') == null) {
                std.debug.print("tbfilter: refusing potentially aliased input/output paths\n", .{});
                return 1;
            }
        }
    }

    if (cfg.format == .viri) return viri.run_file(cfg);

    const in_file = std.Io.Dir.cwd().openFile(io, cfg.input, .{}) catch {
        std.debug.print("tbfilter: cannot open input '{s}'\n", .{cfg.input});
        return 1;
    };
    const in_len = in_file.length(io) catch {
        in_file.close(io);
        std.debug.print("tbfilter: cannot stat input '{s}'\n", .{cfg.input});
        return 1;
    };
    in_file.close(io);

    const file_records = whole_records(in_len) catch {
        std.debug.print(
            "tbfilter: '{s}' is not bulletformat: its size {} is not a multiple of {} bytes (a viriformat file needs format=viri)\n",
            .{ cfg.input, in_len, RECORD_SIZE },
        );
        return 1;
    };
    const num_records = if (cfg.max_positions) |limit| @min(file_records, limit) else file_records;
    if (num_records == 0) {
        std.debug.print("tbfilter: no records in input\n", .{});
        return 1;
    }

    const tb_max = load_tablebases(cfg.tb_path) orelse return 1;
    defer syzygy.deinit();
    const eff_max_men = @min(@min(cfg.max_men, tb_max), MAX_MEN);

    const automatic_threads = @min(std.Thread.getCpuCount() catch 4, MAX_AUTOMATIC_THREADS);
    const threads: usize = @intCast(@min(cfg.threads orelse automatic_threads, num_records));

    std.debug.print("=== Avalanche Syzygy Filter ===\n", .{});
    std.debug.print("Input:   {s} ({} positions", .{ cfg.input, file_records });
    if (num_records != file_records) {
        std.debug.print(", limited to {}", .{num_records});
    }
    std.debug.print(")\n", .{});
    std.debug.print("Output:  {s}\n", .{cfg.output});
    std.debug.print("TB:      {s} (supports up to {}-man)\n", .{ cfg.tb_path, tb_max });
    std.debug.print("Probe:   positions with <= {}-man\n", .{eff_max_men});
    std.debug.print("Rule50:  {s}\n", .{@tagName(cfg.rule50)});
    std.debug.print("Threads: {}\n", .{threads});
    std.debug.print("===============================\n\n", .{});

    var progress = std.atomic.Value(u64).init(0);

    const workers = std.heap.page_allocator.alloc(Worker, threads) catch {
        std.debug.print("tbfilter: out of memory (workers)\n", .{});
        return 1;
    };
    defer std.heap.page_allocator.free(workers);

    var part_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (part_paths.items) |p| std.heap.page_allocator.free(p);
        part_paths.deinit(std.heap.page_allocator);
    }
    part_paths.ensureTotalCapacity(std.heap.page_allocator, threads) catch {
        std.debug.print("tbfilter: out of memory (part paths)\n", .{});
        return 1;
    };

    const base_records = num_records / threads;
    const remainder = num_records % threads;
    var start: u64 = 0;
    for (0..threads) |t| {
        const extra: u64 = if (t < remainder) 1 else 0;
        const count = base_records + extra;
        const path = std.heap.page_allocator.print("{s}.part{}.tmp", .{ cfg.output, t }) catch {
            std.debug.print("tbfilter: out of memory (part path)\n", .{});
            return 1;
        };
        part_paths.appendAssumeCapacity(path);
        workers[t] = Worker{
            .input = cfg.input,
            .part_path = path,
            .start_rec = start,
            .end_rec = start + count,
            .id = t,
            .max_men = eff_max_men,
            .rule50 = cfg.rule50,
            .progress = &progress,
        };
        start += count;
    }

    const timer = types.Timer.start();

    var handles: std.ArrayList(std.Thread) = .empty;
    defer handles.deinit(std.heap.page_allocator);
    handles.ensureTotalCapacity(std.heap.page_allocator, threads) catch {
        std.debug.print("tbfilter: out of memory (thread handles)\n", .{});
        return 1;
    };
    for (1..threads) |t| {
        const h = std.Thread.spawn(.{ .stack_size = WORKER_STACK_SIZE }, workerRun, .{&workers[t]}) catch {
            std.debug.print("tbfilter: could not spawn worker {}; running it inline\n", .{t});
            workerRun(&workers[t]);
            continue;
        };
        handles.appendAssumeCapacity(h);
    }
    workerRun(&workers[0]);
    for (handles.items) |h| h.join();

    const elapsed_ns = timer.read();

    var total = Stats{};
    var any_fail = false;
    for (workers) |wk| {
        total.merge(wk.stats);
        if (!wk.ok) {
            any_fail = true;
            std.debug.print("tbfilter: worker {} failed: {s}\n", .{ wk.id, wk.err });
        }
    }

    if (any_fail or total.read != num_records) {
        if (total.read != num_records) {
            std.debug.print(
                "tbfilter: processed {} of {} records -- aborting\n",
                .{ total.read, num_records },
            );
        }
        for (part_paths.items) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
        return 1;
    }

    var out_bytes: u64 = 0;
    out_bytes = concatParts(cfg.output, part_paths.items) catch |e| {
        std.debug.print("tbfilter: concatenation failed: {} -- output deleted\n", .{e});
        std.Io.Dir.cwd().deleteFile(io, cfg.output) catch {};
        for (part_paths.items) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
        return 1;
    };
    for (part_paths.items) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};

    if (out_bytes / RECORD_SIZE != total.kept()) {
        std.debug.print(
            "tbfilter: output has {} records, expected {} kept -- output deleted\n",
            .{ out_bytes / RECORD_SIZE, total.kept() },
        );
        std.Io.Dir.cwd().deleteFile(io, cfg.output) catch {};
        return 1;
    }

    report(total, out_bytes, elapsed_ns, eff_max_men);
    return 0;
}

fn pct(n: u64, d: u64) f64 {
    if (d == 0) return 0.0;
    return 100.0 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
}

fn report(s: Stats, out_bytes: u64, elapsed_ns: u64, max_men: u32) void {
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const rate = if (secs > 0) @as(f64, @floatFromInt(s.read)) / secs else 0.0;
    const mb = @as(f64, @floatFromInt(s.read * RECORD_SIZE)) / (1024.0 * 1024.0);
    const mbps = if (secs > 0) mb / secs else 0.0;
    const out_records = out_bytes / RECORD_SIZE;

    std.debug.print("\n=== Filter Results ===\n", .{});
    std.debug.print("Positions read:       {}\n", .{s.read});
    std.debug.print("  > {}-man (kept):     {} ({d:.2}%)\n", .{ max_men, s.over_men, pct(s.over_men, s.read) });
    std.debug.print("  <= {}-man (probed):  {} ({d:.2}%)\n", .{ max_men, s.probed, pct(s.probed, s.read) });
    std.debug.print("    agree   (kept):    {} ({d:.2}% of probed)\n", .{ s.agree, pct(s.agree, s.probed) });
    std.debug.print("    disagree(dropped): {} ({d:.2}% of probed)\n", .{ s.disagree, pct(s.disagree, s.probed) });
    std.debug.print("    cursed/blessed:    {} (kept)\n", .{s.ambiguous});
    std.debug.print("    en-passant maybe:  {} (kept)\n", .{s.ep_skipped});
    std.debug.print("    probe failed:      {} (kept)\n", .{s.failed});
    std.debug.print("    anomalies:         {} (kept)\n", .{s.anomalies});
    std.debug.print("\n", .{});
    std.debug.print("Positions dropped:    {} ({d:.4}% of all)\n", .{ s.disagree, pct(s.disagree, s.read) });
    std.debug.print("Positions kept:       {} ({d:.4}% of all)\n", .{ s.kept(), pct(s.kept(), s.read) });
    std.debug.print("Output records:       {}\n", .{out_records});

    std.debug.print("\nProbed by man count (probed / dropped):\n", .{});
    var m: usize = MIN_MEN;
    while (m <= max_men) : (m += 1) {
        if (s.probed_by_men[m] > 0) {
            std.debug.print("  {}-man: {} / {}\n", .{ m, s.probed_by_men[m], s.dropped_by_men[m] });
        }
    }

    std.debug.print("\nConfusion matrix (rows = recorded WDL, cols = tablebase WDL):\n", .{});
    std.debug.print("             tb loss    tb draw     tb win\n", .{});
    const labels = [_][]const u8{ "rec loss", "rec draw", "rec win " };
    for (labels, s.recorded_by_tablebase) |label, row| {
        std.debug.print("  {s}  {d:>10} {d:>10} {d:>10}\n", .{ label, row[0], row[1], row[2] });
    }

    std.debug.print("\nTime: {d:.2}s  ({d:.0} pos/s, {d:.1} MB/s)\n", .{ secs, rate, mbps });
    std.debug.print("Done.\n", .{});
}
