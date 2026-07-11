// Offline Syzygy tablebase filter for self-play training data.
//
// Reads a bulletformat `.bin` file (fixed 32-byte `ChessBoard` records, as
// emitted by `datagen format=bullet`) and writes a new `.bin` that drops every
// position whose self-play WDL result contradicts the Syzygy tablebase.

const std = @import("std");
const types = @import("../chess/types.zig");
const syzygy = @import("syzygy.zig");

const RECORD_SIZE: usize = 32;
const MAX_MEN: u32 = 7;
const BLOCK_RECS: usize = 1 << 17;
const BLOCK_BYTES: usize = BLOCK_RECS * RECORD_SIZE;

/// How to treat a tablebase cursed-win / blessed-loss
pub const Rule50Mode = enum {
    keep, // never drop on cursed/blessed (default)
    on, // 50-move-rule aware: both count as a draw
    off, // ignore the 50-move rule: cursed win = win, blessed loss = loss
};

const Config = struct {
    input: []const u8 = "",
    output: []const u8 = "",
    tb_path: []const u8 = "",
    threads: usize = 0, // 0 => auto-detect
    max_men: u32 = 5,
    max_positions: u64 = 0, // 0 => whole file
    rule50: Rule50Mode = .keep,
};

const Stats = struct {
    read: u64 = 0, // records examined
    over_men: u64 = 0, // men > max_men, copied through unprobed
    probed: u64 = 0, // men <= max_men (sum of the categories below)
    agree: u64 = 0, // tablebase matches recorded result -> kept
    disagree: u64 = 0, // tablebase contradicts recorded result -> dropped
    ambiguous: u64 = 0, // cursed/blessed under `keep` -> kept
    ep_skipped: u64 = 0, // en passant could matter -> kept
    failed: u64 = 0, // probe failed / table missing -> kept
    anomalies: u64 = 0, // corrupt / undecodable record -> kept
    // Confusion matrix over decisively-probed positions:
    // matrix[recorded_result][tablebase_result], indices 0=loss,1=draw,2=win.
    matrix: [3][3]u64 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },
    probed_by_men: [MAX_MEN + 1]u64 = .{0} ** (MAX_MEN + 1),
    dropped_by_men: [MAX_MEN + 1]u64 = .{0} ** (MAX_MEN + 1),

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
        for (0..3) |i| for (0..3) |j| {
            self.matrix[i][j] += o.matrix[i][j];
        };
        for (0..MAX_MEN + 1) |i| {
            self.probed_by_men[i] += o.probed_by_men[i];
            self.dropped_by_men[i] += o.dropped_by_men[i];
        }
    }
};

const Worker = struct {
    input: []const u8,
    out_path: []const u8, // this worker's part file (or the final output when single-threaded)
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

/// Map a raw tablebase WDL to the recorded-result encoding (0=loss,1=draw,
/// 2=win). Returns null when the outcome is ambiguous and should be kept.
fn expectedResult(w: syzygy.WdlResult, mode: Rule50Mode) ?u8 {
    switch (w) {
        .win => return 2,
        .loss => return 0,
        .draw => return 1,
        .cursed_win => switch (mode) {
            .keep => return null,
            .on => return 1,
            .off => return 2,
        },
        .blessed_loss => switch (mode) {
            .keep => return null,
            .on => return 1,
            .off => return 0,
        },
    }
}

/// True if an en-passant capture could be legal for the side to move, i.e. a
/// friendly pawn on the 5th rank is horizontally adjacent to an enemy pawn on
/// the 5th rank. The record stores no en-passant square, so such positions are
/// kept rather than risk a wrong drop.
///
/// Both e.p. pawns always sit on the same rank (the double-push landing rank),
/// which is rank 5 in the side-to-move-normalized frame: for a white-to-move
/// record they are on rank 5 directly; for a black-to-move record the encoder's
/// vertical flip maps black's 4th rank (where they sit) to rank 5 here. So a
/// single RANK5 check covers both, and the vertical flip preserves files.
fn enPassantPossible(white: u64, black: u64, pawns: u64) bool {
    const RANK5: u64 = 0x0000_00FF_0000_0000;
    const FILE_A: u64 = 0x0101_0101_0101_0101;
    const FILE_H: u64 = 0x8080_8080_8080_8080;
    const wp5 = pawns & white & RANK5;
    const bp5 = pawns & black & RANK5;
    const adjacent = ((bp5 & ~FILE_A) >> 1) | ((bp5 & ~FILE_H) << 1);
    return (wp5 & adjacent) != 0;
}

/// Classify one 32-byte record at `buf[base..]`. Updates `st` and returns true
/// if the record should be kept (copied to the output).
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
    var bad = false;
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
            else => bad = true, // invalid piece type for bulletformat
        }
    }

    if (bad or @popCount(kings) != 2 or @popCount(kings & white) != 1 or @popCount(kings & black) != 1 or white == 0 or black == 0) {
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

    const recorded = buf[base + 26];
    if (recorded > 2) {
        st.anomalies += 1;
        return true;
    }

    const expected = expectedResult(wdl, mode) orelse {
        st.ambiguous += 1;
        return true;
    };

    st.matrix[recorded][expected] += 1;
    if (expected == recorded) {
        st.agree += 1;
        return true;
    }
    st.disagree += 1;
    st.dropped_by_men[men] += 1;
    return false;
}

fn workerRun(w: *Worker) void {
    const io = types.GLOBAL_IO;

    const in_file = std.Io.Dir.cwd().openFile(io, w.input, .{}) catch {
        w.ok = false;
        w.err = "could not open input file";
        return;
    };
    defer in_file.close(io);

    const out_file = std.Io.Dir.cwd().createFile(io, w.out_path, .{ .read = true }) catch {
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
        var i: usize = 0;
        while (i < got) : (i += 1) {
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

        if (got < this_recs) break; // short block -> stop and let the caller detect it
    }

    // The read count was derived from the file length up front; reading fewer
    // records than assigned means the file changed underneath us.
    if (rec < w.end_rec) {
        w.ok = false;
        w.err = "short read (input truncated?)";
        return;
    }

    w.bytes_written = woff;
}

/// Copy one part file fully into `out_file` starting at byte offset `woff`,
/// returning the number of bytes copied. Errors (incl. a short read) leave the
/// part on disk for inspection; the handle is always closed.
fn copyPart(out_file: std.Io.File, part: []const u8, buf: []u8, woff: u64) !u64 {
    const io = types.GLOBAL_IO;
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

/// Concatenate `parts` in order into a freshly created `output`, deleting each
/// part once fully copied. Returns total bytes written.
fn concatParts(output: []const u8, parts: []const []const u8) !u64 {
    const io = types.GLOBAL_IO;
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

fn parseUsize(s: []const u8, default: usize) usize {
    return std.fmt.parseInt(usize, s, 10) catch default;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: Avalanche tbfilter <input.bin> <output.bin> tb=<path> [options]
        \\
        \\Filters a bulletformat .bin of self-play positions, dropping every
        \\<=N-man position whose recorded WDL contradicts the Syzygy tablebase.
        \\
        \\Required:
        \\  tb=<path>        Syzygy tablebase directory
        \\
        \\Options:
        \\  threads=<n>      Worker threads               (default: CPU count)
        \\  men=<n>          Max men to probe             (default 5)
        \\  max=<n>          Process at most n positions  (default: whole file)
        \\  rule50=keep|on|off
        \\                   Cursed-win / blessed-loss handling (default keep):
        \\                     keep = never drop on these (ambiguous)
        \\                     on   = treat both as a draw (50-move-rule aware)
        \\                     off  = cursed win=win, blessed loss=loss
        \\
    , .{});
}

/// Entry point for the `tbfilter` subcommand. Returns a process exit code
/// (0 = success, non-zero = failure) so callers and scripts can detect errors.
pub fn run(args: []const []const u8) u8 {
    const io = types.GLOBAL_IO;

    var cfg = Config{};
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "tb=")) {
            cfg.tb_path = arg[3..];
        } else if (std.mem.startsWith(u8, arg, "threads=")) {
            cfg.threads = parseUsize(arg[8..], 0);
        } else if (std.mem.startsWith(u8, arg, "men=")) {
            cfg.max_men = std.fmt.parseInt(u32, arg[4..], 10) catch 5;
        } else if (std.mem.startsWith(u8, arg, "max=")) {
            cfg.max_positions = std.fmt.parseInt(u64, arg[4..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "rule50=")) {
            const v = arg[7..];
            if (std.mem.eql(u8, v, "on")) {
                cfg.rule50 = .on;
            } else if (std.mem.eql(u8, v, "off")) {
                cfg.rule50 = .off;
            } else {
                cfg.rule50 = .keep;
            }
        } else if (input == null) {
            input = arg;
        } else if (output == null) {
            output = arg;
        } else {
            std.debug.print("tbfilter: unexpected argument '{s}'\n", .{arg});
        }
    }

    if (input == null or output == null or cfg.tb_path.len == 0) {
        printUsage();
        return 1;
    }
    cfg.input = input.?;
    cfg.output = output.?;

    if (std.mem.eql(u8, cfg.input, cfg.output)) {
        std.debug.print("tbfilter: input and output must differ\n", .{});
        return 1;
    }
    {
        const in_base = std.fs.path.basename(cfg.input);
        const out_base = std.fs.path.basename(cfg.output);
        if (std.mem.eql(u8, in_base, out_base) and (std.mem.eql(u8, cfg.input, out_base) or std.mem.eql(u8, cfg.output, in_base) or std.mem.endsWith(u8, cfg.input, cfg.output) or std.mem.endsWith(u8, cfg.output, cfg.input))) {
            if (std.mem.indexOfScalar(u8, cfg.input, '/') == null or std.mem.indexOfScalar(u8, cfg.output, '/') == null) {
                std.debug.print("tbfilter: refusing potentially aliased input/output paths\n", .{});
                return 1;
            }
        }
    }

    // Discover the input size / record count.
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

    if (in_len % RECORD_SIZE != 0) {
        std.debug.print(
            "tbfilter: WARNING input size {} is not a multiple of {} bytes; {} trailing bytes ignored\n",
            .{ in_len, RECORD_SIZE, in_len % RECORD_SIZE },
        );
    }
    const file_records = in_len / RECORD_SIZE;
    const num_records = if (cfg.max_positions > 0) @min(file_records, cfg.max_positions) else file_records;
    if (num_records == 0) {
        std.debug.print("tbfilter: no complete records in input\n", .{});
        return 1;
    }

    // Bring up the tablebase before doing any work.
    const path_z = std.heap.page_allocator.dupeZ(u8, cfg.tb_path) catch {
        std.debug.print("tbfilter: out of memory\n", .{});
        return 1;
    };
    defer std.heap.page_allocator.free(path_z);
    if (!syzygy.init(path_z.ptr)) {
        std.debug.print(
            "tbfilter: failed to load Syzygy tablebases from '{s}' -- aborting\n",
            .{cfg.tb_path},
        );
        return 1;
    }
    defer syzygy.deinit();

    // Cap the men gate at what the loaded tablebases cover, and never above
    // MAX_MEN so the decode loop and per-man-count arrays stay in bounds.
    const tb_max: u32 = @intCast(@max(@as(i32, 0), syzygy.max_pieces()));
    const eff_max_men = @min(@min(cfg.max_men, tb_max), MAX_MEN);

    // Auto-detect defaults to a modest cap: the job is largely I/O-bound, so a
    // few dozen concurrent streams saturate the disk without thrashing. An
    // explicit threads= overrides this (up to 256).
    const auto_threads = @min(std.Thread.getCpuCount() catch 4, 32);
    var threads = if (cfg.threads > 0) cfg.threads else auto_threads;
    if (threads < 1) threads = 1;
    if (threads > 256) threads = 256;
    if (threads > num_records) threads = @intCast(num_records);

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

    var part_paths = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer {
        for (part_paths.items) |p| std.heap.page_allocator.free(p);
        part_paths.deinit();
    }
    part_paths.ensureTotalCapacity(threads) catch {
        std.debug.print("tbfilter: out of memory (part paths)\n", .{});
        return 1;
    };

    const base_records = num_records / threads;
    const remainder = num_records % threads;
    var start: u64 = 0;
    for (0..threads) |t| {
        const extra: u64 = if (t < remainder) 1 else 0;
        const count = base_records + extra;
        const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}.part{}.tmp", .{ cfg.output, t }) catch {
            std.debug.print("tbfilter: out of memory (part path)\n", .{});
            return 1;
        };
        part_paths.appendAssumeCapacity(path);
        workers[t] = Worker{
            .input = cfg.input,
            .out_path = path,
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

    var handles = std.array_list.Managed(std.Thread).init(std.heap.page_allocator);
    defer handles.deinit();
    handles.ensureTotalCapacity(threads) catch {
        std.debug.print("tbfilter: out of memory (thread handles)\n", .{});
        return 1;
    };
    for (1..threads) |t| {
        const h = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, workerRun, .{&workers[t]}) catch {
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

    // Abort without producing a partial output if anything went wrong.
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

    // Final integrity gate: the output must hold exactly the kept records.
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
    var m: usize = 2;
    while (m <= max_men) : (m += 1) {
        if (s.probed_by_men[m] > 0) {
            std.debug.print("  {}-man: {} / {}\n", .{ m, s.probed_by_men[m], s.dropped_by_men[m] });
        }
    }

    std.debug.print("\nConfusion matrix (rows = recorded WDL, cols = tablebase WDL):\n", .{});
    std.debug.print("             tb loss    tb draw     tb win\n", .{});
    const labels = [_][]const u8{ "rec loss", "rec draw", "rec win " };
    for (0..3) |i| {
        std.debug.print("  {s}  {d:>10} {d:>10} {d:>10}\n", .{ labels[i], s.matrix[i][0], s.matrix[i][1], s.matrix[i][2] });
    }

    std.debug.print("\nTime: {d:.2}s  ({d:.0} pos/s, {d:.1} MB/s)\n", .{ secs, rate, mbps });
    std.debug.print("Done.\n", .{});
}
