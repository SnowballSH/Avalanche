//! Syzygy WDL and DTZ probing: the tables on disk, how they are found and loaded, and the probes
//! the engine makes. A port of the parts of Pyrrhic that Avalanche uses; see docs/SYZYGY.md.

const std = @import("std");
const builtin = @import("builtin");
const board = @import("board.zig");
const encoding = @import("encoding.zig");
const pairs = @import("pairs.zig");

pub const Board = board.Board;
pub const Move = board.Move;
pub const Promotion = board.Promotion;
pub const PieceType = board.PieceType;
pub const MAX_MOVES = board.MAX_MOVES;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Kind = pairs.Kind;
const MoveList = board.MoveList;

/// From the point of view of the side to move.
pub const Wdl = enum(i8) { loss = -2, blessed_loss = -1, draw = 0, cursed_win = 1, win = 2 };

/// `rank` orders the root moves: higher is better, a winning move ranks above 0, a drawing move at
/// 0 and a losing move below.
pub const RootMove = struct {
    move: Move,
    rank: i32,
};

pub const RootMoves = struct {
    buffer: [MAX_MOVES]RootMove = undefined,
    len: usize = 0,

    pub fn slice(self: *const RootMoves) []const RootMove {
        return self.buffer[0..self.len];
    }
};

pub const ProbeError = error{TableMissing};

const MAX_DTZ: i32 = 0x40000;
const WDL_TO_DTZ = [5]i32{ -1, -101, 0, 101, 1 };
const WDL_TO_RANK = [5]i32{ -MAX_DTZ, -MAX_DTZ + 101, 0, MAX_DTZ - 101, MAX_DTZ };
const WDL_TO_MAP = [5]u2{ 1, 3, 0, 2, 0 };
const PA_FLAGS = [5]u8{ 8, 0, 0, 0, 4 };

const HASH_BITS = 12;
const HASH_SIZE = 1 << HASH_BITS;
const MAX_ENTRIES = blk: {
    @setEvalBranchQuota(1_000_000);
    var count: usize = 0;
    for_each_table_name(&count, struct {
        fn visit(counter: *usize, _: Name) void {
            counter.* += 1;
        }
    }.visit);
    break :blk count;
};

const PATH_SEPARATOR = if (builtin.os.tag == .windows) ';' else ':';

const SUFFIX = std.enums.EnumArray(Kind, []const u8).init(.{ .wdl = ".rtbw", .dtz = ".rtbz" });
const MAGIC = std.enums.EnumArray(Kind, u32).init(.{ .wdl = 0x5d23e871, .dtz = 0xa50c66d7 });

/// Indexed by `[black][piece type]`: the material key of a position is the wrapping sum of the
/// primes of its pieces, kings excluded.
const PRIMES = [2][7]u64{
    .{ 0, 17008651141875982339, 15202887380319082783, 12311744257139811149, 10979190538029446137, 11811845319353239651, 0 },
    .{ 0, 11695583624105689831, 13469005675588064321, 15394650811035483107, 18264461213049635989, 15484752644942473553, 0 },
};

/// The piece letters of a table name, queen first, in the order Pyrrhic enumerates them.
const PIECE_LETTERS = "QRBNP";

fn piece_type_of_letter(letter: u8) ?PieceType {
    return switch (letter) {
        'P' => .pawn,
        'N' => .knight,
        'B' => .bishop,
        'R' => .rook,
        'Q' => .queen,
        'K' => .king,
        else => null,
    };
}

/// The material key of `b`, with the colours exchanged when `mirror` is set.
fn board_key(b: *const Board, mirror: bool) u64 {
    const sides = if (mirror) [2]u64{ b.black, b.white } else [2]u64{ b.white, b.black };
    const by_type = [_]u64{ b.pawns, b.knights, b.bishops, b.rooks, b.queens };
    var key: u64 = 0;
    inline for (sides, 0..) |side, colour| {
        inline for (by_type, 1..) |pieces, piece_type| {
            key +%= @popCount(side & pieces) *% PRIMES[colour][piece_type];
        }
    }
    return key;
}

/// `counts[black][piece type]`.
fn counts_key(counts: *const [2][7]u8, mirror: bool) u64 {
    var key: u64 = 0;
    for (0..2) |colour| {
        for (1..6) |piece_type| {
            key +%= counts[colour ^ @intFromBool(mirror)][piece_type] *% PRIMES[colour][piece_type];
        }
    }
    return key;
}

const Name = struct {
    buffer: [16]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const Name) []const u8 {
        return self.buffer[0..self.len];
    }

    fn append(self: *Name, letter: u8) void {
        self.buffer[self.len] = letter;
        self.len += 1;
    }

    /// "K" and the pieces of `white`, "vK" and those of `black`, each a list of indices into
    /// `PIECE_LETTERS`.
    fn of(white: []const u8, black: []const u8) Name {
        var name: Name = .{};
        name.append('K');
        for (white) |i| name.append(PIECE_LETTERS[i]);
        name.append('v');
        name.append('K');
        for (black) |i| name.append(PIECE_LETTERS[i]);
        return name;
    }
};

/// Every table name of up to seven pieces, in Pyrrhic's order and with the stronger side first.
fn for_each_table_name(context: anytype, comptime visit: fn (@TypeOf(context), Name) void) void {
    for (0..5) |i| visit(context, Name.of(&.{@intCast(i)}, &.{}));

    for (0..5) |i| for (i..5) |j| visit(context, Name.of(&.{@intCast(i)}, &.{@intCast(j)}));
    for (0..5) |i| for (i..5) |j| visit(context, Name.of(&.{ @intCast(i), @intCast(j) }, &.{}));

    for (0..5) |i| for (i..5) |j| for (0..5) |k|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j) }, &.{@intCast(k)}));
    for (0..5) |i| for (i..5) |j| for (j..5) |k|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j), @intCast(k) }, &.{}));

    for (0..5) |i| for (i..5) |j| for (i..5) |k| for ((if (i == k) j else k)..5) |l|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j) }, &.{ @intCast(k), @intCast(l) }));
    for (0..5) |i| for (i..5) |j| for (j..5) |k| for (0..5) |l|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j), @intCast(k) }, &.{@intCast(l)}));
    for (0..5) |i| for (i..5) |j| for (j..5) |k| for (k..5) |l|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j), @intCast(k), @intCast(l) }, &.{}));

    for (0..5) |i| for (i..5) |j| for (j..5) |k| for (k..5) |l| for (l..5) |m|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j), @intCast(k), @intCast(l), @intCast(m) }, &.{}));
    for (0..5) |i| for (i..5) |j| for (j..5) |k| for (k..5) |l| for (0..5) |m|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j), @intCast(k), @intCast(l) }, &.{@intCast(m)}));
    for (0..5) |i| for (i..5) |j| for (j..5) |k| for (0..5) |l| for (l..5) |m|
        visit(context, Name.of(&.{ @intCast(i), @intCast(j), @intCast(k) }, &.{ @intCast(l), @intCast(m) }));
}

/// A loaded table file: the mapping and the parameters of its subtables.
const Table = struct {
    arena: std.heap.ArenaAllocator,
    map: Io.File.MemoryMap,
    /// WDL: `[side]` without pawns, `[file + 4 * side]` with. DTZ: `[file]`, one side only.
    ei: [8]encoding.EncInfo,
    dtz_flags: [4]u8,
    /// The value maps of a DTZ table, which start at `dtz_map`; an index counts bytes, or u16s
    /// when flag 16 is set.
    dtz_map: []const u8,
    dtz_map_idx: [4][4]u32,
};

const SlotState = enum(u8) { unloaded, ready, failed };

const Slot = struct {
    state: std.atomic.Value(SlotState) = .init(.unloaded),
    /// Valid once `state` is `.ready`.
    table: *const Table = undefined,
};

const Entry = struct {
    name: Name,
    key: u64,
    material: encoding.Material,
    symmetric: bool,
    has_pawns: bool,
    has_dtz: bool,
    slots: std.enums.EnumArray(Kind, Slot) = .initFill(.{}),
};

const HashSlot = struct {
    key: u64 = 0,
    entry: ?*Entry = null,
};

pub const Tablebases = struct {
    gpa: Allocator,
    io: Io,
    directories: []Io.Dir,
    entries: std.ArrayList(Entry),
    hash: *[HASH_SIZE]HashSlot,
    /// Serializes the loading of tables on first use.
    mutex: Io.Mutex = .init,
    /// The most pieces of any table found.
    largest: u8 = 0,

    /// Finds the tables in the directories `paths` lists, separated by ':' (';' on Windows). A
    /// table is mapped when it is first probed.
    pub fn open(gpa: Allocator, io: Io, paths: []const u8) Allocator.Error!Tablebases {
        var directories: std.ArrayList(Io.Dir) = .empty;
        errdefer {
            for (directories.items) |dir| dir.close(io);
            directories.deinit(gpa);
        }
        var tokens = std.mem.tokenizeScalar(u8, paths, PATH_SEPARATOR);
        while (tokens.next()) |path| {
            const dir = Io.Dir.cwd().openDir(io, path, .{}) catch continue;
            directories.append(gpa, dir) catch |err| {
                dir.close(io);
                return err;
            };
        }

        const hash = try gpa.create([HASH_SIZE]HashSlot);
        errdefer gpa.destroy(hash);
        hash.* = @splat(.{});

        var self: Tablebases = .{
            .gpa = gpa,
            .io = io,
            .directories = try directories.toOwnedSlice(gpa),
            .entries = try .initCapacity(gpa, MAX_ENTRIES),
            .hash = hash,
        };
        for_each_table_name(&self, register);
        return self;
    }

    pub fn deinit(self: *Tablebases) void {
        for (self.entries.items) |*entry| {
            for (&entry.slots.values) |*slot| {
                if (slot.state.load(.monotonic) != .ready) continue;
                const table: *Table = @constCast(slot.table);
                table.map.destroy(self.io);
                var arena = table.arena;
                arena.deinit();
            }
        }
        self.entries.deinit(self.gpa);
        self.gpa.destroy(self.hash);
        for (self.directories) |dir| dir.close(self.io);
        self.gpa.free(self.directories);
        self.* = undefined;
    }

    /// The WDL value of a position with no castling rights; `b.rule50` is not used.
    pub fn probe_wdl(self: *Tablebases, b: *const Board) ?Wdl {
        const result = self.probe_wdl_resolved(b) catch return null;
        return @fromBackingInt(@intCast(result.value));
    }

    /// Ranks every legal root move by DTZ: a win that the fifty-move rule cannot spoil ranks
    /// highest, then wins in fewer plies. `out` is empty after an error.
    pub fn probe_root_dtz(self: *Tablebases, b: *const Board, has_repeated: bool, out: *RootMoves) ProbeError!void {
        errdefer out.len = 0;
        const cnt50: i32 = b.rule50;
        var legal: MoveList(MAX_MOVES) = .{};
        b.generate_legal(&legal);
        out.len = 0;
        for (legal.slice()) |move| {
            const next = b.play(move).?;
            var v: i32 = undefined;
            if (next.rule50 == 0) {
                v = WDL_TO_DTZ[@intCast(2 - (try self.probe_wdl_resolved(&next)).value)];
            } else {
                v = -try self.probe_dtz(&next);
                if (v > 0) v += 1 else if (v < 0) v -= 1;
            }
            if (v == 2 and next.is_mate()) v = 1;

            // A move whose dtz plus the counter is exactly 100 may fail to win, dtz being one off.
            const rank: i32 = if (v > 0)
                (if (v + cnt50 <= 99 and !has_repeated) MAX_DTZ else MAX_DTZ - (v + cnt50))
            else if (v < 0)
                (if (-v * 2 + cnt50 < 100) -MAX_DTZ else -MAX_DTZ + (-v + cnt50))
            else
                0;
            out.buffer[out.len] = .{ .move = move, .rank = rank };
            out.len += 1;
        }
    }

    /// Ranks every legal root move by WDL alone, for when DTZ tables are missing.
    pub fn probe_root_wdl(self: *Tablebases, b: *const Board, use_rule50: bool, out: *RootMoves) ProbeError!void {
        errdefer out.len = 0;
        var legal: MoveList(MAX_MOVES) = .{};
        b.generate_legal(&legal);
        out.len = 0;
        for (legal.slice()) |move| {
            const next = b.play(move).?;
            var v = -(try self.probe_wdl_resolved(&next)).value;
            if (!use_rule50) v = if (v > 0) 2 else if (v < 0) -2 else 0;
            out.buffer[out.len] = .{ .move = move, .rank = WDL_TO_RANK[@intCast(v + 2)] };
            out.len += 1;
        }
    }

    fn register(self: *Tablebases, name: Name) void {
        if (!self.table_exists(name, .wdl)) return;

        var counts: [2][7]u8 = @splat(@splat(0));
        var black: u1 = 0;
        for (name.slice()) |letter| {
            if (letter == 'v') {
                black = 1;
            } else if (piece_type_of_letter(letter)) |piece_type| {
                counts[black][@backingInt(piece_type)] += 1;
            }
        }

        const key = counts_key(&counts, false);
        const mirrored_key = counts_key(&counts, true);
        const white_pawns = counts[0][@backingInt(PieceType.pawn)];
        const black_pawns = counts[1][@backingInt(PieceType.pawn)];
        const has_pawns = white_pawns + black_pawns > 0;

        var num: u8 = 0;
        var unique: u8 = 0;
        for (counts) |side| {
            for (side) |count| {
                num += count;
                unique += @intFromBool(count == 1);
            }
        }
        const leading_black = black_pawns != 0 and (white_pawns == 0 or white_pawns > black_pawns);

        const entry = self.entries.addOneAssumeCapacity();
        entry.* = .{
            .name = name,
            .key = key,
            .material = .{
                .num = num,
                .kk_enc = !has_pawns and unique == 2,
                .pawns = if (leading_black) .{ black_pawns, white_pawns } else .{ white_pawns, black_pawns },
            },
            .symmetric = key == mirrored_key,
            .has_pawns = has_pawns,
            .has_dtz = self.table_exists(name, .dtz),
        };
        self.largest = @max(self.largest, num);

        self.add_to_hash(entry, key);
        if (key != mirrored_key) self.add_to_hash(entry, mirrored_key);
    }

    fn add_to_hash(self: *Tablebases, entry: *Entry, key: u64) void {
        var i = key >> (64 - HASH_BITS);
        while (self.hash[i].entry != null) i = (i + 1) & (HASH_SIZE - 1);
        self.hash[i] = .{ .key = key, .entry = entry };
    }

    fn file_name(name: Name, kind: Kind) Name {
        var result = name;
        for (SUFFIX.get(kind)) |c| result.append(c);
        return result;
    }

    /// A complete table file is 16 bytes longer than a multiple of 64.
    fn table_exists(self: *const Tablebases, name: Name, kind: Kind) bool {
        const path = file_name(name, kind);
        for (self.directories) |dir| {
            const stat = dir.statFile(self.io, path.slice(), .{}) catch continue;
            if (stat.size % 64 == 16) return true;
            std.debug.print("Incomplete tablebase file {s}\n", .{path.slice()});
            return false;
        }
        return false;
    }

    fn open_file(self: *const Tablebases, name: Name, kind: Kind) ?Io.File {
        const path = file_name(name, kind);
        for (self.directories) |dir| {
            return dir.openFile(self.io, path.slice(), .{}) catch continue;
        }
        return null;
    }

    fn table_of(self: *Tablebases, entry: *Entry, comptime kind: Kind) ProbeError!*const Table {
        const slot = entry.slots.getPtr(kind);
        switch (slot.state.load(.acquire)) {
            .ready => return slot.table,
            .failed => return error.TableMissing,
            .unloaded => {},
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (slot.state.load(.monotonic)) {
            .ready => return slot.table,
            .failed => return error.TableMissing,
            .unloaded => {},
        }
        const table = self.load(entry, kind) catch |err| {
            std.debug.print("Could not load tablebase file {s}: {t}\n", .{ file_name(entry.name, kind).slice(), err });
            slot.state.store(.failed, .release);
            return error.TableMissing;
        };
        slot.table = table;
        slot.state.store(.ready, .release);
        return table;
    }

    fn load(self: *Tablebases, entry: *const Entry, comptime kind: Kind) !*const Table {
        const file = self.open_file(entry.name, kind) orelse return error.FileNotFound;
        defer file.close(self.io);
        const size = try file.length(self.io);
        var map = try file.createMemoryMap(self.io, .{
            .len = @intCast(size),
            .protection = .{ .read = true, .write = false },
            .populate = false,
        });
        errdefer map.destroy(self.io);
        if (builtin.os.tag != .windows and map.section != null) {
            std.posix.madvise(map.memory.ptr, map.memory.len, std.posix.MADV.RANDOM) catch {};
        }

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const table = try arena.allocator().create(Table);
        table.* = .{
            .arena = undefined,
            .map = map,
            .ei = @splat(.{ .pairs = .{}, .factor = @splat(0), .pieces = @splat(0), .norm = @splat(0) }),
            .dtz_flags = @splat(0),
            .dtz_map = &.{},
            .dtz_map_idx = @splat(@splat(0)),
        };
        try parse(table, arena.allocator(), map.memory, entry, kind);
        table.arena = arena;
        return table;
    }

    fn parse(table: *Table, arena: Allocator, data: []const u8, entry: *const Entry, comptime kind: Kind) !void {
        if (data.len < 5 or std.mem.readInt(u32, data[0..4], .little) != MAGIC.get(kind)) return error.CorruptTable;

        const split = kind == .wdl and data[4] & 0x01 != 0;
        const num: usize = if (entry.has_pawns) 4 else 1;
        const material = entry.material;
        var cursor: usize = 5;

        var tb_size: [4][2]u64 = undefined;
        for (0..num) |t| {
            const header = data[cursor..];
            const file: u2 = @intCast(t);
            if (entry.has_pawns) {
                tb_size[t][0] = encoding.init_enc_info(&table.ei[t], material, header, 0, file, .file);
                if (split) tb_size[t][1] = encoding.init_enc_info(&table.ei[num + t], material, header, 4, file, .file);
            } else {
                tb_size[t][0] = encoding.init_enc_info(&table.ei[t], material, header, 0, file, .piece);
                if (split) tb_size[t][1] = encoding.init_enc_info(&table.ei[num + t], material, header, 4, file, .piece);
            }
            cursor += material.num + 1 + @intFromBool(entry.has_pawns and material.pawns[1] != 0);
        }
        cursor += cursor & 1;

        var sizes: [4][2]pairs.Sizes = undefined;
        for (0..num) |t| {
            const first = try pairs.setup(arena, data, &cursor, tb_size[t][0], kind);
            table.ei[t].pairs = first.pairs;
            sizes[t][0] = first.sizes;
            if (kind == .dtz) table.dtz_flags[t] = first.flags;
            if (split) {
                const second = try pairs.setup(arena, data, &cursor, tb_size[t][1], kind);
                table.ei[num + t].pairs = second.pairs;
                sizes[t][1] = second.sizes;
            }
        }

        if (kind == .dtz) {
            const map_start = cursor;
            table.dtz_map = data[map_start..];
            for (0..num) |t| {
                const flags = table.dtz_flags[t];
                if (flags & 2 == 0) continue;
                if (flags & 16 == 0) {
                    for (&table.dtz_map_idx[t]) |*idx| {
                        idx.* = @intCast(cursor + 1 - map_start);
                        cursor += 1 + @as(usize, data[cursor]);
                    }
                } else {
                    cursor += cursor & 1;
                    for (&table.dtz_map_idx[t]) |*idx| {
                        idx.* = @intCast((cursor - map_start) / 2 + 1);
                        cursor += 2 + 2 * @as(usize, std.mem.readInt(u16, data[cursor..][0..2], .little));
                    }
                }
            }
            cursor += cursor & 1;
        }

        const sides: usize = if (split) 2 else 1;
        inline for (.{ "index_table", "size_table", "data" }, 0..) |field, region| {
            for (0..num) |t| {
                for (0..sides) |side| {
                    if (region == 2) cursor = std.mem.alignForward(usize, cursor, 64);
                    const len = sizes[t][side][region];
                    if (cursor + len > data.len) return error.CorruptTable;
                    @field(table.ei[side * num + t].pairs, field) = data[cursor..][0..len];
                    cursor += len;
                }
            }
        }
    }

    fn lookup(self: *const Tablebases, key: u64) ?*Entry {
        var i = key >> (64 - HASH_BITS);
        while (self.hash[i].key != 0 and self.hash[i].key != key) i = (i + 1) & (HASH_SIZE - 1);
        return self.hash[i].entry;
    }

    fn probe_wdl_table(self: *Tablebases, b: *const Board) ProbeError!i32 {
        return self.probe_table(b, .wdl, 0) catch |err| switch (err) {
            error.TableMissing => return error.TableMissing,
            error.WrongSide => unreachable,
        };
    }

    /// `wdl` is the WDL value of the position. `error.WrongSide`: the table holds the other side
    /// to move only.
    fn probe_dtz_table(self: *Tablebases, b: *const Board, wdl: i32) (ProbeError || error{WrongSide})!i32 {
        return self.probe_table(b, .dtz, wdl);
    }

    fn probe_table(self: *Tablebases, b: *const Board, comptime kind: Kind, wdl: i32) (ProbeError || error{WrongSide})!i32 {
        const key = board_key(b, false);
        if (kind == .wdl and key == 0) return 0;

        const entry = self.lookup(key) orelse return error.TableMissing;
        if (kind == .dtz and !entry.has_dtz) return error.TableMissing;
        const table = try self.table_of(entry, kind);

        var flip: bool = undefined;
        var bside: bool = undefined;
        if (entry.symmetric) {
            flip = !b.white_to_move;
            bside = false;
        } else {
            flip = key != entry.key;
            bside = b.white_to_move == flip;
        }

        var squares: [encoding.MAX_PIECES]u8 = undefined;
        var file: u2 = 0;
        var flags: u8 = 0;
        var ei: *const encoding.EncInfo = undefined;
        var idx: u64 = undefined;
        const num = entry.material.num;
        if (!entry.has_pawns) {
            if (kind == .dtz) {
                flags = table.dtz_flags[0];
                if ((flags & 1 != 0) != bside and !entry.symmetric) return error.WrongSide;
            }
            ei = &table.ei[if (kind == .wdl) @intFromBool(bside) else 0];
            var i: usize = 0;
            while (i < num) i = fill_squares(b, &ei.pieces, flip, 0, &squares, i);
            idx = encoding.encode(&squares, ei, entry.material, .piece);
        } else {
            const mirror: u8 = if (flip) 0x38 else 0;
            var i = fill_squares(b, &table.ei[0].pieces, flip, mirror, &squares, 0);
            file = encoding.leading_pawn(&squares, entry.material);
            if (kind == .dtz) {
                flags = table.dtz_flags[file];
                if ((flags & 1 != 0) != bside and !entry.symmetric) return error.WrongSide;
            }
            ei = &table.ei[if (kind == .wdl) @as(usize, file) + 4 * @as(usize, @intFromBool(bside)) else file];
            while (i < num) i = fill_squares(b, &ei.pieces, flip, mirror, &squares, i);
            idx = encoding.encode(&squares, ei, entry.material, .file);
        }

        const w = ei.pairs.decompress(idx);
        if (kind == .wdl) return @as(i32, w[0]) - 2;

        var v: i32 = @as(i32, w[0]) + (@as(i32, w[1] & 0x0f) << 8);
        if (flags & 2 != 0) {
            const at = table.dtz_map_idx[file][WDL_TO_MAP[@intCast(wdl + 2)]] + @as(usize, @intCast(v));
            v = if (flags & 16 == 0)
                table.dtz_map[at]
            else
                std.mem.readInt(u16, table.dtz_map[2 * at ..][0..2], .little);
        }
        if (flags & PA_FLAGS[@intCast(wdl + 2)] == 0 or wdl & 1 != 0) v *= 2;
        return v;
    }

    fn probe_ab(self: *Tablebases, b: *const Board, alpha_in: i32, beta: i32) ProbeError!i32 {
        std.debug.assert(b.ep == 0);
        var alpha = alpha_in;
        var captures: MoveList(board.MAX_CAPTURES) = .{};
        b.generate_captures(&captures);
        for (captures.slice()) |move| {
            if (!b.is_capture(move)) continue;
            const next = b.play(move) orelse continue;
            const v = -try self.probe_ab(&next, -beta, -alpha);
            if (v > alpha) {
                if (v >= beta) return v;
                alpha = v;
            }
        }
        return @max(alpha, try self.probe_wdl_table(b));
    }

    const Resolved = struct {
        /// -2 to 2, as `Wdl`.
        value: i32,
        /// The value is that of a capture: a winning one, a cursed winning one in a cursed win, or
        /// an en-passant capture that is the only best move.
        by_capture: bool,
    };

    /// The WDL value with every capture resolved.
    fn probe_wdl_resolved(self: *Tablebases, b: *const Board) ProbeError!Resolved {
        var captures: MoveList(board.MAX_CAPTURES) = .{};
        b.generate_captures(&captures);
        var best_cap: i32 = -3;
        var best_ep: i32 = -3;

        // `best_cap` is the best capture without en passant, `best_ep` a better en-passant one.
        for (captures.slice()) |move| {
            if (!b.is_capture(move)) continue;
            const next = b.play(move) orelse continue;
            const v = -try self.probe_ab(&next, -2, -best_cap);
            if (v > best_cap) {
                if (v == 2) return .{ .value = 2, .by_capture = true };
                if (!b.is_en_passant(move)) {
                    best_cap = v;
                } else if (v > best_ep) {
                    best_ep = v;
                }
            }
        }

        const v = try self.probe_wdl_table(b);

        // max(v, best_cap) is the value without en-passant rights; with them it is
        // max(v, best_cap, best_ep), unless the position without them is stalemate.
        if (best_ep > best_cap) {
            if (best_ep > v) return .{ .value = best_ep, .by_capture = true };
            best_cap = best_ep;
        }
        if (best_cap >= v) return .{ .value = best_cap, .by_capture = best_cap > 0 };

        if (best_ep > -3 and v == 0) {
            var moves: MoveList(MAX_MOVES) = .{};
            b.generate_moves(&moves);
            const has_other_move = for (moves.slice()) |move| {
                if (!b.is_en_passant(move) and b.play(move) != null) break true;
            } else false;
            if (!has_other_move and !b.is_check()) return .{ .value = best_ep, .by_capture = true };
        }
        return .{ .value = v, .by_capture = false };
    }

    /// The distance to zeroing in plies from the side to move's point of view: n < -100 a loss
    /// that the fifty-move rule draws, -100 <= n < -1 a loss, 0 a draw, 1 < n <= 100 a win and
    /// n > 100 a win that the rule draws. -1 is a mate. A value can be one ply short.
    fn probe_dtz(self: *Tablebases, b: *const Board) ProbeError!i32 {
        const resolved = try self.probe_wdl_resolved(b);
        const wdl = resolved.value;
        if (wdl == 0) return 0;
        const zeroing = WDL_TO_DTZ[@intCast(wdl + 2)];
        if (resolved.by_capture) return zeroing;

        var moves: MoveList(MAX_MOVES) = .{};
        if (wdl > 0) {
            b.generate_legal(&moves);
            for (moves.slice()) |move| {
                if (!b.is_pawn_move(move) or b.is_capture(move)) continue;
                const next = b.play(move) orelse continue;
                if (-(try self.probe_wdl_resolved(&next)).value == wdl) return zeroing;
            }
        }

        // The best move is not an en-passant capture, so `wdl` is also the value without
        // en-passant rights, which the DTZ table is indexed by.
        if (self.probe_dtz_table(b, wdl)) |dtz| {
            return zeroing + (if (wdl > 0) dtz else -dtz);
        } else |err| switch (err) {
            error.TableMissing => return error.TableMissing,
            error.WrongSide => {},
        }

        var best: i32 = undefined;
        if (wdl > 0) {
            best = std.math.maxInt(i32);
        } else {
            // The worst a loss can do is a zeroing move, which `zeroing` already counts, as it
            // does a mate.
            best = zeroing;
            b.generate_moves(&moves);
        }
        for (moves.slice()) |move| {
            if (b.is_capture(move) or b.is_pawn_move(move)) continue;
            const next = b.play(move) orelse continue;
            const v = -try self.probe_dtz(&next);
            if (v == 1 and next.is_mate()) {
                best = 1;
            } else if (wdl > 0) {
                if (v > 0 and v + 1 < best) best = v + 1;
            } else if (v - 1 < best) {
                best = v - 1;
            }
        }
        return best;
    }
};

/// Fills `squares[i..]` with the squares of the piece `pieces[i]` names, colours exchanged when
/// `flip` is set and squares XORed with `mirror`, and returns the index after them.
inline fn fill_squares(b: *const Board, pieces: *const [encoding.MAX_PIECES]u8, flip: bool, mirror: u8, squares: *[encoding.MAX_PIECES]u8, start: usize) usize {
    const piece = pieces[start];
    const white = (piece >> 3 == 0) != flip;
    var bb = b.pieces(white, @fromBackingInt(@intCast(piece & 0x07)));
    var i = start;
    while (true) {
        squares[i] = @as(u8, @ctz(bb)) ^ mirror;
        i += 1;
        bb &= bb - 1;
        if (bb == 0) return i;
    }
}

test "every table of up to seven pieces has a name" {
    try std.testing.expectEqual(@as(usize, 650 + 861), MAX_ENTRIES);
}
