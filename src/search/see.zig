const std = @import("std");

const PT_TO_IDX: [6]u3 = .{ 0, 1, 1, 4, 6, 7 };
const PT_VAL: [8]i16 = .{ 100, 300, 300, 300, 510, 510, 920, 10000 };

inline fn get_lsb(x: u64) u64 {
    return x & -%x;
}

fn evaluate(target_piece: u8, attackers: u8, defenders: u8) i16 {
    if (attackers == 0) {
        return 0;
    }

    var attacking_piece_index = @intCast(u8, @ctz(u64, get_lsb(@intCast(u64, attackers))));
    var target = PT_TO_IDX[target_piece];

    return evaluate_internal(attacking_piece_index, target, attackers, defenders);
}

fn evaluate_internal(attacking_piece: u8, target_piece: u8, attackers: u8, defenders: u8) i16 {
    if (attackers == 0) {
        return 0;
    }

    var target_value = PT_VAL[target_piece];
    var new_attackers = attackers & ~@intCast(u8, (@as(u64, 1) << @intCast(u6, attacking_piece)));
    var new_attacking_piece = if (defenders == 0) 0 else @intCast(u8, @ctz(u64, get_lsb(@intCast(u64, defenders))));

    var score = evaluate_internal(new_attacking_piece, attacking_piece, defenders, new_attackers);
    return @maximum(0, target_value - score);
}

pub var SEE_TABLE: [6][256][256]i16 = undefined;

pub fn init_see() void {
    var a: u8 = 0;
    while (a < 6) : (a += 1) {
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            var c: usize = 0;
            while (c < 256) : (c += 1) {
                SEE_TABLE[a][b][c] = evaluate(a, @intCast(u8, b), @intCast(u8, c));
            }
        }
    }
}

pub fn get_see(attacking_piece: u8, target_piece: u8, attackers: u8, defenders: u8) i16 {
    const attacking_idx = PT_TO_IDX[attacking_piece];
    const target_idx = PT_TO_IDX[target_piece];
    const new_attackers = attackers & ~@intCast(u8, (@as(u64, 1) << attacking_idx));

    const score = SEE_TABLE[attacking_piece][defenders][new_attackers];
    return PT_VAL[target_idx] - score;
}
