const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");
const zobrist = @import("zobrist.zig");
const position = @import("position.zig");

const SIZE: usize = 8192;

var keys: [SIZE]u64 = std.mem.zeroes([SIZE]u64);
var moves: [SIZE]u16 = std.mem.zeroes([SIZE]u16);

fn h1(x: u64) usize {
    return @as(usize, @intCast(x % SIZE));
}

fn h2(x: u64) usize {
    return @as(usize, @intCast((x / SIZE) % SIZE));
}

inline fn encode_move(from: u8, to: u8) u16 {
    return @as(u16, from) | (@as(u16, to) << 6);
}

inline fn decode_from(m: u16) u8 {
    return @as(u8, @truncate(m & 0x3F));
}

inline fn decode_to(m: u16) u8 {
    return @as(u8, @truncate((m >> 6) & 0x3F));
}

pub fn init() void {
    @memset(&keys, 0);
    @memset(&moves, 0);
    var count: usize = 0;

    for ([_]types.Color{ .White, .Black }) |color| {
        const piece_types = [_]types.PieceType{ types.PieceType.Knight, types.PieceType.Bishop, types.PieceType.Rook, types.PieceType.Queen, types.PieceType.King };
        for (piece_types) |pt| {
            const piece = types.Piece.new(color, pt);
            const piece_idx = piece.index();

            for (0..types.N_SQUARES) |sq_a| {
                const attacks = tables.get_attacks(pt, @as(types.Square, @fromBackingInt(@intCast(sq_a))), 0);

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

pub fn has_upcoming_repetition(pos: *const position.Position, hash_history: []const u64, ply: u32) bool {
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
        if (pos.occupancy[@backingInt(pos.turn)] & move_sqs != 0) {
            return true;
        }
    }
    return false;
}

test "cuckoo: init is idempotent" {
    tables.init_all();
    zobrist.init_zobrist();
    init();
    const first_keys = keys;
    const first_moves = moves;
    init();
    try std.testing.expectEqualSlices(u64, &first_keys, &keys);
    try std.testing.expectEqualSlices(u16, &first_moves, &moves);
}
