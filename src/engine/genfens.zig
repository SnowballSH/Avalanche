// genfens — generate opening FENs for OpenBench datagen workloads.
//
// OpenBench invokes the engine as:
//   ./engine "genfens N seed S book <None|path/to/book.epd>" "quit"
//
// We must print N lines to stdout in the form:
//   info string genfens <fen>
// then exit.  Each FEN is a random opening position produced by:
//   - picking a random book line (if a book is given), OR starting from startpos
//   - playing 9-12 random legal plies
//   - ensuring the position is not in check and is not drawn

const std = @import("std");
const types = @import("../chess/types.zig");
const utils = @import("../chess/utils.zig");
const position = @import("../chess/position.zig");

fn playRandomMoves(pos: *position.Position, prng: *utils.PRNG, n_plies: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var ply: usize = 0;
    while (ply < n_plies) : (ply += 1) {
        var movelist = std.array_list.Managed(types.Move).initCapacity(arena.allocator(), 32) catch return;
        defer movelist.deinit();
        if (pos.turn == types.Color.White) {
            pos.generate_legal_moves(types.Color.White, &movelist);
        } else {
            pos.generate_legal_moves(types.Color.Black, &movelist);
        }
        if (movelist.items.len == 0) return;
        const move = movelist.items[prng.rand64() % movelist.items.len];
        if (pos.turn == types.Color.White) {
            pos.play_move(types.Color.White, move);
        } else {
            pos.play_move(types.Color.Black, move);
        }
    }
}

fn positionIsUsable(pos: *position.Position) bool {
    const in_check = if (pos.turn == types.Color.White) pos.in_check(types.Color.White) else pos.in_check(types.Color.Black);
    if (in_check) return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var movelist = std.array_list.Managed(types.Move).initCapacity(arena.allocator(), 32) catch return false;
    defer movelist.deinit();
    if (pos.turn == types.Color.White) {
        pos.generate_legal_moves(types.Color.White, &movelist);
    } else {
        pos.generate_legal_moves(types.Color.Black, &movelist);
    }
    return movelist.items.len > 0;
}

pub fn run(args_in: []const []const u8) !void {
    const io = types.GLOBAL_IO;
    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_file.interface;

    // Parse: genfens <count> seed <S> book <None|path>
    // args_in[0] = "genfens", args_in[1] = count, then keyword pairs
    var n_fens: u64 = 1;
    var seed: u64 = 0;
    var book_path: ?[]const u8 = null;

    if (args_in.len >= 2) {
        n_fens = std.fmt.parseInt(u64, args_in[1], 10) catch 1;
    }

    var i: usize = 2;
    while (i < args_in.len) : (i += 1) {
        const tok = args_in[i];
        if (std.mem.eql(u8, tok, "seed")) {
            i += 1;
            if (i < args_in.len) seed = std.fmt.parseInt(u64, args_in[i], 10) catch seed;
        } else if (std.mem.eql(u8, tok, "book")) {
            i += 1;
            if (i < args_in.len and !std.mem.eql(u8, args_in[i], "None")) {
                book_path = args_in[i];
            }
        }
    }

    // Load book lines if provided
    var book_lines: []const []const u8 = &.{};
    if (book_path) |path| {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
        if (file) |f| {
            const file_len = f.length(io) catch 0;
            if (file_len > 0) {
                const content = std.heap.page_allocator.alloc(u8, @as(usize, @intCast(file_len))) catch null;
                if (content) |buf| {
                    _ = f.readPositionalAll(io, buf, 0) catch {};
                    var lines_list = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
                    var iter = std.mem.splitScalar(u8, buf, '\n');
                    while (iter.next()) |line| {
                        const trimmed = std.mem.trim(u8, line, " \t\r");
                        if (trimmed.len > 0) {
                            lines_list.append(trimmed) catch {};
                        }
                    }
                    book_lines = lines_list.items;
                }
            }
        }
    }

    var prng = utils.PRNG.new(@as(u128, seed) | (@as(u128, seed) << 64) ^ 0xdeadbeefcafe1234);

    var generated: u64 = 0;
    while (generated < n_fens) {
        var pos = position.Position.new();

        if (book_lines.len > 0) {
            const line = book_lines[prng.rand64() % book_lines.len];
            pos.set_fen(line);
            // 1-3 extra random plies on top of book position
            const extra_plies = 1 + (prng.rand64() % 3);
            playRandomMoves(&pos, &prng, extra_plies);
        } else {
            pos.set_fen(types.DEFAULT_FEN);
            const random_plies = 9 + (prng.rand64() % 4);
            playRandomMoves(&pos, &prng, random_plies);
        }

        if (!positionIsUsable(&pos)) continue;

        const fen = pos.basic_fen(std.heap.page_allocator);
        defer std.heap.page_allocator.free(fen);

        try out.print("info string genfens {s}\n", .{fen});
        try out.flush();

        generated += 1;
    }
}
