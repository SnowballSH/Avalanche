// Syzygy endgame tablebase probing for Avalanche.
//
// Thin Zig wrapper around the vendored Pyrrhic C library (Andrew Grant's
// maintained fork of Ronald de Man's Fathom / `tbprobe`). Pyrrhic is compiled
// into the binary by build.zig (`Pyrrhic/tbprobe.c`); the attack / popcount
// primitives it needs are exported with C ABI at the bottom of this file and
// routed through Avalanche's own tables, so there is no duplicated movegen.
//
// Everything here is a no-op until `init()` succeeds with a non-empty
// `SyzygyPath`. With probing disabled, `enabled == false`, every probe gate in
// the search short-circuits, and the `bench` node count is unchanged.

const std = @import("std");
const types = @import("../chess/types.zig");
const tables = @import("../chess/tables.zig");
const position = @import("../chess/position.zig");

const c = @cImport({
    @cInclude("tbprobe.h");
});

pub const MAX_TB_MOVES: usize = 256; // == Pyrrhic TB_MAX_MOVES

pub var enabled: bool = false;
pub var probe_depth: i32 = 1;
pub var use_rule50: bool = true;
pub var probe_limit: i32 = 7;

pub inline fn max_pieces() i32 {
    return @min(@as(i32, @intCast(c.TB_LARGEST)), probe_limit);
}

pub fn init(path: [*:0]const u8) bool {
    if (enabled) {
        c.tb_free();
        enabled = false;
    }
    if (c.tb_init(path) and c.TB_LARGEST > 0) {
        enabled = true;
    }
    return enabled;
}

pub fn deinit() void {
    if (enabled) {
        c.tb_free();
        enabled = false;
    }
}

pub const Wdl = enum { win, draw, loss };

/// Full 5-valued WDL outcome, preserving the 50-move-rule-dependent
/// `cursed_win` / `blessed_loss` distinctions that `probe_wdl` collapses via
/// `use_rule50`.
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

// ---------------------------------------------------------------------------
// Position -> Pyrrhic argument decomposition.
// ---------------------------------------------------------------------------
const Probe = struct {
    white: u64,
    black: u64,
    kings: u64,
    queens: u64,
    rooks: u64,
    bishops: u64,
    knights: u64,
    pawns: u64,
    ep: c_uint,
    turn: bool,
};

inline fn bb(pos: *const position.Position, comptime p: types.Piece) u64 {
    return pos.piece_bitboards[comptime p.index()];
}

fn decompose(pos: *const position.Position) Probe {
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
        .ep = if (ep_sq == types.Square.NO_SQUARE) 0 else @intCast(ep_sq.index()),
        .turn = pos.turn == types.Color.White,
    };
}

pub inline fn piece_count(pos: *const position.Position) i32 {
    return types.popcount(pos.all_all_pieces());
}

pub inline fn no_castling_rights(pos: *const position.Position) bool {
    const e = pos.history[pos.game_ply].entry;
    return (e & types.WhiteOOMask) != 0 and (e & types.WhiteOOOMask) != 0 and
        (e & types.BlackOOMask) != 0 and (e & types.BlackOOOMask) != 0;
}

/// WDL probe for interior search nodes. The caller must ensure: not the root,
/// 50-move counter == 0, no castling rights, and `piece_count <= max_pieces()`.
/// Returns null on probe failure.
pub fn probe_wdl(pos: *const position.Position) ?Wdl {
    if (!enabled) return null;
    const p = decompose(pos);
    const r = c.tb_probe_wdl(
        p.white,
        p.black,
        p.kings,
        p.queens,
        p.rooks,
        p.bishops,
        p.knights,
        p.pawns,
        p.ep,
        p.turn,
    );
    return switch (r) {
        c.TB_WIN => Wdl.win,
        c.TB_LOSS => Wdl.loss,
        c.TB_DRAW => Wdl.draw,
        c.TB_CURSED_WIN => if (use_rule50) Wdl.draw else Wdl.win,
        c.TB_BLESSED_LOSS => if (use_rule50) Wdl.draw else Wdl.loss,
        else => null, // TB_RESULT_FAILED
    };
}

/// Raw 5-valued WDL probe taking the Pyrrhic bitboard arguments directly,
/// bypassing `Position`. `white`/`black` are the occupancy of White/Black and
/// `turn` is true when White is to move; the piece-type bitboards are
/// colour-agnostic. `ep` is the en-passant square, or 0 when there is none.
/// Returns null on probe failure or a missing table. The WDL tables are
/// independent of the 50-move counter, so the caller interprets `cursed_win` /
/// `blessed_loss` itself.
pub fn probe_wdl_bb(
    white: u64,
    black: u64,
    kings: u64,
    queens: u64,
    rooks: u64,
    bishops: u64,
    knights: u64,
    pawns: u64,
    ep: c_uint,
    turn: bool,
) ?WdlResult {
    if (!enabled) return null;
    const r = c.tb_probe_wdl(white, black, kings, queens, rooks, bishops, knights, pawns, ep, turn);
    return switch (r) {
        c.TB_WIN => WdlResult.win,
        c.TB_CURSED_WIN => WdlResult.cursed_win,
        c.TB_DRAW => WdlResult.draw,
        c.TB_BLESSED_LOSS => WdlResult.blessed_loss,
        c.TB_LOSS => WdlResult.loss,
        else => null, // TB_RESULT_FAILED
    };
}

/// Root DTZ probe. Ranks every legal root move by distance-to-zero and returns
/// the WDL plus the set of moves sharing the best rank (the DTZ-optimal set).
/// The caller restricts the root move list to this set so the search only
/// explores tablebase-optimal moves. Returns null on probe failure.
///
/// The caller must ensure no castling rights and `piece_count <= max_pieces()`.
pub fn probe_root(pos: *const position.Position, has_repeated: bool) ?RootResult {
    if (!enabled) return null;
    const p = decompose(pos);
    var tb: c.struct_TbRootMoves = std.mem.zeroes(c.struct_TbRootMoves);
    const rule50: c_uint = if (use_rule50) @intCast(pos.history[pos.game_ply].fifty) else 0;
    const ret = c.tb_probe_root_dtz(
        p.white,
        p.black,
        p.kings,
        p.queens,
        p.rooks,
        p.bishops,
        p.knights,
        p.pawns,
        rule50,
        p.ep,
        p.turn,
        has_repeated,
        &tb,
    );
    var size: usize = @intCast(tb.size);
    if (ret == 0 or size == 0) {
        // Fall back to WDL-only root ranking when DTZ files are missing/incomplete.
        const wdl_ret = c.tb_probe_root_wdl(
            p.white,
            p.black,
            p.kings,
            p.queens,
            p.rooks,
            p.bishops,
            p.knights,
            p.pawns,
            rule50,
            p.ep,
            p.turn,
            use_rule50,
            &tb,
        );
        size = @intCast(tb.size);
        if (wdl_ret == 0 or size == 0) return null;
    }

    // tbRank: positive for wins (larger = closer to a guaranteed win), 0 for
    // draws, negative for losses. The DTZ-optimal moves are those with the
    // maximal rank.
    var best_rank: i32 = std.math.minInt(i32);
    {
        var i: usize = 0;
        while (i < size) : (i += 1) {
            if (tb.moves[i].tbRank > best_rank) best_rank = tb.moves[i].tbRank;
        }
    }

    var result = RootResult{ .wdl = if (best_rank > 0) .win else if (best_rank < 0) .loss else .draw };
    var i: usize = 0;
    while (i < size) : (i += 1) {
        if (tb.moves[i].tbRank != best_rank) continue;
        const m = tb.moves[i].move;
        // PyrrhicMove packing: bits 0-5 = to, 6-11 = from, 12-15 = flags.
        // Promotion flag values: Q=1, R=2, B=3, N=4 (0 = none).
        const promo: PromoKind = switch ((m >> 12) & 0x0F) {
            1 => .queen,
            2 => .rook,
            3 => .bishop,
            4 => .knight,
            else => .none,
        };
        result.moves[result.count] = .{
            .from = @intCast((m >> 6) & 0x3F),
            .to = @intCast(m & 0x3F),
            .promo = promo,
        };
        result.count += 1;
    }
    return result;
}

// ---------------------------------------------------------------------------
// C-ABI callbacks required by Pyrrhic (declared `extern` in tbconfig.h).
// Routed through Avalanche's attack tables. Pyrrhic uses White=1/Black=0; the
// pawn-attack colour is inverted in tbconfig.h, so `col` here is Avalanche's
// convention (0 = white, 1 = black).
// ---------------------------------------------------------------------------
pub export fn popcount(x: u64) u8 {
    return @popCount(x);
}

pub export fn getlsb(x: u64) u8 {
    return @ctz(x);
}

pub export fn poplsb(x: *u64) u8 {
    const r: u8 = @ctz(x.*);
    x.* &= x.* -% 1;
    return r;
}

pub export fn pawnAttacks(col: u8, sq: u8) u64 {
    return if (col == 0) tables.WhitePawnAttacks[sq] else tables.BlackPawnAttacks[sq];
}

pub export fn knightAttacks(sq: u8) u64 {
    return tables.KnightAttacks[sq];
}

pub export fn kingAttacks(sq: u8) u64 {
    return tables.KingAttacks[sq];
}

pub export fn bishopAttacks(sq: u8, occ: u64) u64 {
    return tables.get_attacks(types.PieceType.Bishop, @enumFromInt(sq), occ);
}

pub export fn rookAttacks(sq: u8, occ: u64) u64 {
    return tables.get_attacks(types.PieceType.Rook, @enumFromInt(sq), occ);
}

pub export fn queenAttacks(sq: u8, occ: u64) u64 {
    return tables.get_attacks(types.PieceType.Bishop, @enumFromInt(sq), occ) |
        tables.get_attacks(types.PieceType.Rook, @enumFromInt(sq), occ);
}
