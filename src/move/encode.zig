const Piece = @import("../board/piece.zig");

pub inline fn move(arg_source: u6, arg_target: u6, arg_pt: u4, arg_promote: u4, arg_capture: u1, comptime arg_double: u1, comptime arg_enpassant: u1, comptime arg_castling: u1) u24 {
    return @intCast(u24, arg_source) | (@intCast(u24, arg_target) << 6) | (@intCast(u24, arg_pt) << 12) | (@intCast(u24, arg_promote) << 16) | (@intCast(u24, arg_capture) << 20) | (@intCast(u24, comptime arg_double) << 21) | (@intCast(u24, comptime arg_enpassant) << 22) | (@intCast(u24, comptime arg_castling) << 23);
}

pub inline fn source(arg_move: u24) u6 {
    return @truncate(u6, arg_move);
}

pub inline fn target(arg_move: u24) u6 {
    return @truncate(u6, arg_move >> 6);
}

pub inline fn pt(arg_move: u24) u4 {
    return @truncate(u4, arg_move >> 12);
}

pub inline fn promote(arg_move: u24) u4 {
    return @truncate(u4, arg_move >> 16);
}

pub inline fn capture(arg_move: u24) u1 {
    return @truncate(u1, arg_move >> 20);
}

pub inline fn double(arg_move: u24) u1 {
    return @truncate(u1, arg_move >> 21);
}

pub inline fn enpassant(arg_move: u24) u1 {
    return @truncate(u1, arg_move >> 22);
}

pub inline fn castling(arg_move: u24) u1 {
    return @truncate(u1, arg_move >> 23);
}
