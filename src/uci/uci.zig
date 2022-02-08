const std = @import("std");
const Encode = @import("../move/encode.zig");
const Piece = @import("../board/piece.zig");
const Position = @import("../board/position.zig");
const Bitboard = @import("../board/bitboard.zig");
const Movegen = @import("../move/movegen.zig");

pub const alphabets = "abcdefgh";
pub const pieces = "PNBRQKpnbrqk";
pub const pieces_lower = "pnbrqkpnbrqk";
pub const numbers = "12345678";

pub fn move_to_uci(move: u24) []u8 {
    const source = Encode.source(move);
    const target = Encode.target(move);
    const promop = Encode.promote(move);
    if (promop != 0) {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "{c}{c}{c}{c}{c}",
            .{
                alphabets[Bitboard.file_of(source)],
                numbers[Bitboard.rank_of(source)],
                alphabets[Bitboard.file_of(target)],
                numbers[Bitboard.rank_of(target)],
                pieces_lower[promop],
            },
        ) catch unreachable;
    } else {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "{c}{c}{c}{c}",
            .{
                alphabets[Bitboard.file_of(source)],
                numbers[Bitboard.rank_of(source)],
                alphabets[Bitboard.file_of(target)],
                numbers[Bitboard.rank_of(target)],
            },
        ) catch unreachable;
    }
}

pub fn uci_to_move(uci: []const u8, position: *Position.Position) ?u24 {
    if (std.mem.len(uci) < 4) {
        return null;
    }

    var source_file = uci[0] - 'a';
    var source_rank = uci[1] - '1';
    var target_file = uci[2] - 'a';
    var target_rank = uci[3] - '1';

    var promop: u4 = 0;

    if (std.mem.len(uci) == 5) {
        var promo = uci[4];
        promop = switch (promo) {
            'n' => @enumToInt(Piece.Piece.WhiteKnight),
            'b' => @enumToInt(Piece.Piece.WhiteBishop),
            'r' => @enumToInt(Piece.Piece.WhiteRook),
            'q' => @enumToInt(Piece.Piece.WhiteQueen),
            else => return null,
        };
        if (position.turn == Piece.Color.Black) {
            promop += 6;
        }
    }

    var valid_moves = Movegen.generate_all_pseudo_legal_moves(position);
    defer valid_moves.deinit();

    for (valid_moves.items) |m| {
        if (Encode.source(m) == source_file + source_rank * 8 and
            Encode.target(m) == target_file + target_rank * 8 and
            Encode.promote(m) == promop)
        {
            return m;
        }
    }

    return null;
}

pub fn move_to_detailed(move: u24) []u8 {
    const source = Encode.source(move);
    const target = Encode.target(move);
    const promop = Encode.promote(move);
    const cpc = init: {
        if (Encode.capture(move) == 0) {
            break :init @as(u8, '-');
        } else {
            break :init @as(u8, 'x');
        }
    };
    const dbl = init: {
        if (Encode.double(move) == 0) {
            break :init @as(u8, ' ');
        } else {
            break :init @as(u8, '^');
        }
    };
    const ep = init: {
        if (Encode.enpassant(move) == 0) {
            break :init @as(u8, ' ');
        } else {
            break :init @as(u8, 'E');
        }
    };
    if (promop != 0) {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "{c} {c}{c}{c}{c}{c}={c} {c}{c}",
            .{
                pieces[Encode.pt(move)],
                alphabets[Bitboard.file_of(source)],
                numbers[Bitboard.rank_of(source)],
                cpc,
                alphabets[Bitboard.file_of(target)],
                numbers[Bitboard.rank_of(target)],
                pieces_lower[promop],
                dbl,
                ep,
            },
        ) catch unreachable;
    } else {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "{c} {c}{c}{c}{c}{c} {c}{c}",
            .{
                pieces[Encode.pt(move)],
                alphabets[Bitboard.file_of(source)],
                numbers[Bitboard.rank_of(source)],
                cpc,
                alphabets[Bitboard.file_of(target)],
                numbers[Bitboard.rank_of(target)],
                dbl,
                ep,
            },
        ) catch unreachable;
    }
}
