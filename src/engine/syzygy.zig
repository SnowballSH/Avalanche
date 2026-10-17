//! The engine's view of Syzygy probing (src/syzygy, docs/SYZYGY.md): the UCI settings, and the
//! probes in terms of `position.Position`.

const std = @import("std");
const platform = @import("../platform.zig");
const types = @import("../chess/types.zig");
const position = @import("../chess/position.zig");
const tb = @import("../syzygy/tablebases.zig");

pub const supported = !platform.is_wasm;

pub const MAX_TB_MOVES: usize = tb.MAX_MOVES;

pub const DEFAULT_PROBE_DEPTH: i32 = 1;
pub const MAX_PROBE_DEPTH: i32 = 100;
pub const MAX_PROBE_LIMIT: i32 = 7;
pub const DEFAULT_PROBE_LIMIT: i32 = MAX_PROBE_LIMIT;
pub const DEFAULT_USE_RULE50 = true;

pub var enabled: bool = false;
pub var probe_depth: i32 = DEFAULT_PROBE_DEPTH;
pub var use_rule50: bool = DEFAULT_USE_RULE50;
pub var probe_limit: i32 = DEFAULT_PROBE_LIMIT;

var tablebases: tb.Tablebases = undefined;

pub inline fn active() bool {
    return supported and enabled;
}

pub inline fn max_pieces() i32 {
    if (!active()) return 0;
    return @min(@as(i32, tablebases.largest), probe_limit);
}

/// `paths` lists directories separated by ':' (';' on Windows).
pub fn init(paths: []const u8) bool {
    if (!supported) return false;
    deinit();
    tablebases = tb.Tablebases.open(platform.allocator, platform.io, paths) catch return false;
    if (tablebases.largest == 0) {
        tablebases.deinit();
        return false;
    }
    enabled = true;
    return true;
}

pub fn deinit() void {
    if (active()) {
        tablebases.deinit();
        enabled = false;
    }
}

pub const Wdl = enum { win, draw, loss };

pub const WdlResult = enum { loss, blessed_loss, draw, cursed_win, win };

pub const PromoKind = enum(u8) { none = 0, knight, bishop, rook, queen };

pub const RootMove = struct {
    from: u8,
    to: u8,
    promo: PromoKind,
};

pub const RootResult = struct {
    wdl: Wdl,
    count: usize = 0,
    moves: [MAX_TB_MOVES]RootMove = undefined,
};

inline fn bb(pos: *const position.Position, comptime p: types.Piece) u64 {
    return pos.piece_bitboards[comptime p.index()];
}

fn board_of(pos: *const position.Position) tb.Board {
    const white = bb(pos, .WHITE_PAWN) | bb(pos, .WHITE_KNIGHT) | bb(pos, .WHITE_BISHOP) |
        bb(pos, .WHITE_ROOK) | bb(pos, .WHITE_QUEEN) | bb(pos, .WHITE_KING);
    const black = bb(pos, .BLACK_PAWN) | bb(pos, .BLACK_KNIGHT) | bb(pos, .BLACK_BISHOP) |
        bb(pos, .BLACK_ROOK) | bb(pos, .BLACK_QUEEN) | bb(pos, .BLACK_KING);
    const ep_sq = pos.history[pos.game_ply].ep_sq;
    return .{
        .white = white,
        .black = black,
        .kings = bb(pos, .WHITE_KING) | bb(pos, .BLACK_KING),
        .queens = bb(pos, .WHITE_QUEEN) | bb(pos, .BLACK_QUEEN),
        .rooks = bb(pos, .WHITE_ROOK) | bb(pos, .BLACK_ROOK),
        .bishops = bb(pos, .WHITE_BISHOP) | bb(pos, .BLACK_BISHOP),
        .knights = bb(pos, .WHITE_KNIGHT) | bb(pos, .BLACK_KNIGHT),
        .pawns = bb(pos, .WHITE_PAWN) | bb(pos, .BLACK_PAWN),
        .rule50 = @intCast(@min(pos.history[pos.game_ply].fifty, std.math.maxInt(u8))),
        .ep = if (ep_sq == types.Square.NO_SQUARE) 0 else @intCast(ep_sq.index()),
        .white_to_move = pos.turn == types.Color.White,
    };
}

pub inline fn piece_count(pos: *const position.Position) i32 {
    return types.popcount(pos.all_all_pieces());
}

pub inline fn no_castling_rights(pos: *const position.Position) bool {
    return pos.castling_rights() == 0;
}

/// The tables hold positions with a zero fifty-move counter and no castling rights, of at most `max_pieces()`
/// pieces; the caller probes no other.
pub fn probe_wdl(pos: *const position.Position) ?Wdl {
    if (!enabled) return null;
    return switch (tablebases.probe_wdl(&board_of(pos)) orelse return null) {
        .win => .win,
        .loss => .loss,
        .draw => .draw,
        .cursed_win => if (use_rule50) .draw else .win,
        .blessed_loss => if (use_rule50) .draw else .loss,
    };
}

/// The piece bitboards hold both colours, `white_to_move` says who moves, and `ep` is 0 without an
/// en-passant square.
pub fn probe_wdl_bb(
    white: u64,
    black: u64,
    kings: u64,
    queens: u64,
    rooks: u64,
    bishops: u64,
    knights: u64,
    pawns: u64,
    ep: u6,
    white_to_move: bool,
) ?WdlResult {
    if (!enabled) return null;
    return probe_wdl_board(&.{
        .white = white,
        .black = black,
        .kings = kings,
        .queens = queens,
        .rooks = rooks,
        .bishops = bishops,
        .knights = knights,
        .pawns = pawns,
        .ep = ep,
        .white_to_move = white_to_move,
    });
}

/// Castling rights must be absent.
pub fn probe_wdl_position(pos: *const position.Position) ?WdlResult {
    if (!enabled) return null;
    return probe_wdl_board(&board_of(pos));
}

fn probe_wdl_board(board: *const tb.Board) ?WdlResult {
    return switch (tablebases.probe_wdl(board) orelse return null) {
        .win => .win,
        .cursed_win => .cursed_win,
        .draw => .draw,
        .blessed_loss => .blessed_loss,
        .loss => .loss,
    };
}

/// Returns the root moves that share the best DTZ rank. The caller ensures no castling rights and at most
/// `max_pieces()` pieces.
pub fn probe_root(pos: *const position.Position, has_repeated: bool) ?RootResult {
    if (!enabled) return null;
    var board = board_of(pos);
    if (!use_rule50) board.rule50 = 0;
    var ranked: tb.RootMoves = .{};
    tablebases.probe_root_dtz(&board, has_repeated, &ranked) catch {};
    if (ranked.len == 0) {
        tablebases.probe_root_wdl(&board, use_rule50, &ranked) catch return null;
        if (ranked.len == 0) return null;
    }

    var best_rank: i32 = std.math.minInt(i32);
    for (ranked.slice()) |root_move| best_rank = @max(best_rank, root_move.rank);

    var result = RootResult{ .wdl = if (best_rank > 0) .win else if (best_rank < 0) .loss else .draw };
    for (ranked.slice()) |root_move| {
        if (root_move.rank != best_rank) continue;
        const move = root_move.move;
        result.moves[result.count] = .{
            .from = move.from,
            .to = move.to,
            .promo = switch (move.promotion) {
                .none => .none,
                .queen => .queen,
                .rook => .rook,
                .bishop => .bishop,
                .knight => .knight,
            },
        };
        result.count += 1;
    }
    return result;
}
