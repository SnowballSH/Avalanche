const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");
const zobrist = @import("zobrist.zig");

const SIZE: usize = 8192;

var keys: [SIZE]u64 = std.mem.zeroes([SIZE]u64);
var moves: [SIZE]u16 = std.mem.zeroes([SIZE]u16);

fn h1(x: u64) usize {
    return @as(usize, @intCast(x % SIZE));
}

fn h2(x: u64) usize {
    return @as(usize, @intCast((x / SIZE) % SIZE));
}

/// Encode from/to squares into a u16 (from in low 6 bits, to in bits 6-11).
inline fn encode_move(from: u8, to: u8) u16 {
    return @as(u16, from) | (@as(u16, to) << 6);
}

/// Decode from square from the encoded u16.
inline fn decode_from(m: u16) u8 {
    return @as(u8, @truncate(m & 0x3F));
}

/// Decode to square from the encoded u16.
inline fn decode_to(m: u16) u8 {
    return @as(u8, @truncate((m >> 6) & 0x3F));
}

pub fn init() void {
    var count: usize = 0;

    var color: usize = 0;
    while (color < 2) : (color += 1) {
        const piece_types = [_]types.PieceType{ types.PieceType.Knight, types.PieceType.Bishop, types.PieceType.Rook, types.PieceType.Queen, types.PieceType.King };
        for (piece_types) |pt| {
            const piece = types.Piece.new(@as(types.Color, @enumFromInt(color)), pt);
            const piece_idx = piece.index();

            var sq_a: usize = 0;
            while (sq_a < 64) : (sq_a += 1) {
                const attacks = tables.get_attacks(pt, @as(types.Square, @enumFromInt(sq_a)), 0);

                var atk_bb = attacks;
                while (atk_bb != 0) {
                    const sq_b = @as(usize, @intCast(@ctz(atk_bb)));
                    atk_bb &= atk_bb - 1;

                    if (sq_b <= sq_a) continue;

                    var key = zobrist.ZobristTable[piece_idx][sq_a] ^ zobrist.ZobristTable[piece_idx][sq_b] ^ zobrist.TurnHash;
                    var move = encode_move(@as(u8, @intCast(sq_a)), @as(u8, @intCast(sq_b)));
                    var slot = h1(key);
                    while (true) {
                        std.mem.swap(u64, &keys[slot], &key);
                        std.mem.swap(u16, &moves[slot], &move);

                        if (move == 0) {
                            break;
                        }

                        slot = if (slot == h1(key)) h2(key) else h1(key);
                    }

                    count += 1;
                }
            }
        }
    }
    std.debug.assert(count == 3668);
}

/// Detect whether the side to move can force a repetition via one reversible move.
pub fn has_upcoming_repetition(pos: anytype, hash_history: []const u64, ply: u32) bool {
    const occ = pos.all_all_pieces();
    const original = pos.hash;
    const fifty = pos.history[pos.game_ply].fifty;

    const hist_len = hash_history.len;
    if (hist_len < 4) return false;

    const max_back: usize = @min(@as(usize, @intCast(fifty)), hist_len - 1);
    if (max_back < 3) return false;

    const ply_usize = @as(usize, @intCast(ply));
    if (ply_usize >= hist_len) return false;
    const root_index: usize = hist_len - 1 - ply_usize;

    var i: usize = 3;
    while (i <= max_back) : (i += 2) {
        const idx = hist_len - 1 - i;
        const cur = hash_history[idx];

        const diff = original ^ cur;
        var slot = h1(diff);
        if (diff != keys[slot]) {
            slot = h2(diff);
        }

        if (diff != keys[slot]) {
            continue;
        }

        const move = moves[slot];
        const from_sq = decode_from(move);
        const to_sq = decode_to(move);

        if (occ & tables.SquaresBetween[from_sq][to_sq] != 0) {
            continue;
        }

        if (idx > root_index) {
            return true;
        }

        const move_sqs = types.SquareIndexBB[from_sq] | types.SquareIndexBB[to_sq];
        const stm_occ = if (pos.turn == types.Color.White)
            (pos.piece_bitboards[types.Piece.WHITE_PAWN.index()] | pos.piece_bitboards[types.Piece.WHITE_KNIGHT.index()] | pos.piece_bitboards[types.Piece.WHITE_BISHOP.index()] | pos.piece_bitboards[types.Piece.WHITE_ROOK.index()] | pos.piece_bitboards[types.Piece.WHITE_QUEEN.index()] | pos.piece_bitboards[types.Piece.WHITE_KING.index()])
        else
            (pos.piece_bitboards[types.Piece.BLACK_PAWN.index()] | pos.piece_bitboards[types.Piece.BLACK_KNIGHT.index()] | pos.piece_bitboards[types.Piece.BLACK_BISHOP.index()] | pos.piece_bitboards[types.Piece.BLACK_ROOK.index()] | pos.piece_bitboards[types.Piece.BLACK_QUEEN.index()] | pos.piece_bitboards[types.Piece.BLACK_KING.index()]);
        if (stm_occ & move_sqs != 0) {
            return true;
        }
    }
    return false;
}
