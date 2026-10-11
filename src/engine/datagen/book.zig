//! Opening books and position files; see "Openings" in docs/DATAGEN.md.

const std = @import("std");
const platform = @import("../../platform.zig");
const fen = @import("../../chess/fen.zig");
const viriformat = @import("viriformat.zig");

pub const Diagnostic = struct {
    line: usize = 0,
    reason: []const u8 = "",
};

pub const LineError = fen.FenError || error{ TooManyPieces, MoveNumberTooLarge };

pub const Book = struct {
    lines: []const []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn load(allocator: std.mem.Allocator, path: []const u8, diag: *Diagnostic) !Book {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const text = try std.Io.Dir.cwd().readFileAlloc(platform.io, path, arena.allocator(), .unlimited);
        const lines = try parse(arena.allocator(), text, diag);
        return .{ .lines = lines, .arena = arena };
    }

    pub fn deinit(self: *Book) void {
        self.arena.deinit();
    }
};

fn parse(arena: std.mem.Allocator, text: []const u8, diag: *Diagnostic) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (rows.next()) |row| {
        number += 1;
        const line = std.mem.trim(u8, row, " \t\r");
        if (line.len == 0) continue;
        validate_line(line) catch |err| {
            diag.* = .{ .line = number, .reason = @errorName(err) };
            return error.InvalidBookLine;
        };
        try lines.append(arena, line);
    }
    if (lines.items.len == 0) return error.EmptyBook;
    return lines.toOwnedSlice(arena);
}

pub fn validate_line(line: []const u8) LineError!void {
    try fen.validate(line);
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    if (piece_count(fields.next().?) > viriformat.MAX_PIECES) return error.TooManyPieces;

    const FIELDS_BETWEEN_BOARD_AND_MOVE_NUMBER = 4;
    for (0..FIELDS_BETWEEN_BOARD_AND_MOVE_NUMBER) |_| _ = fields.next() orelse return;
    const move_number = std.fmt.parseUnsigned(u64, fields.next() orelse return, 10) catch |failure| switch (failure) {
        error.Overflow => return error.MoveNumberTooLarge,
        error.InvalidCharacter => return,
    };
    if (move_number > std.math.maxInt(viriformat.MoveNumber)) return error.MoveNumberTooLarge;
}

fn piece_count(board_field: []const u8) usize {
    var count: usize = 0;
    for (board_field) |char| count += @intFromBool(std.ascii.isAlphabetic(char));
    return count;
}
