const std = @import("std");
const types = @import("./chess/types.zig");
const tables = @import("./chess/tables.zig");
const expect = std.testing.expect;

test "Basic Piece and Color" {
    try expect(types.Color.White.invert() == types.Color.Black);
    try expect(types.Color.Black.invert() == types.Color.White);

    var p = types.Piece.new(types.Color.Black, types.PieceType.Knight);
    try expect(p.piece_type() == types.PieceType.Knight);
    try expect(p.color() == types.Color.Black);
}

test "Directions" {
    try expect(types.Direction.North.relative_dir(types.Color.Black) == types.Direction.South);
    try expect(types.Direction.SouthEast.relative_dir(types.Color.Black) == types.Direction.NorthWest);

    try expect(types.Direction.SouthSouth.relative_dir(types.Color.White) == types.Direction.SouthSouth);
}

test "Square" {
    var sq: types.Square = types.Square.d4;
    try expect(sq.inc().* == types.Square.e4);
    try expect(sq == types.Square.e4);

    try expect(sq.add(types.Direction.North) == types.Square.e5);
    try expect(sq.add(types.Direction.East) == types.Square.f4);
    try expect(sq.add(types.Direction.SouthWest) == types.Square.d3);
    try expect(sq.add(types.Direction.SouthSouth) == types.Square.e2);

    try expect(sq.sub(types.Direction.North) == types.Square.e3);
    try expect(sq.sub(types.Direction.SouthWest) == types.Square.f5);
}

test "Rank & File" {
    try expect(types.Rank.RANK2.relative_rank(types.Color.Black) == types.Rank.RANK7);
    try expect(types.Rank.RANK5.relative_rank(types.Color.Black) == types.Rank.RANK4);
    try expect(types.Rank.RANK8.relative_rank(types.Color.White) == types.Rank.RANK8);
}

test "Square & Rank & File" {
    try expect(types.Square.b2.rank() == types.Rank.RANK2);
    try expect(types.Square.b2.file() == types.File.BFILE);

    try expect(types.Square.new(types.File.EFILE, types.Rank.RANK4) == types.Square.e4);
    try expect(types.Square.e4.rank() == types.Rank.RANK4);
    try expect(types.Square.e4.file() == types.File.EFILE);
}

test "Bitboard general" {
    try expect(types.popcount(0b0110111010010) == 7);
    try expect(types.lsb(0b01101000) == 3);
    var b: types.Bitboard = 0b01101000;
    try expect(@enumToInt(types.pop_lsb(&b)) == 3);
    try expect(b == 0b01100000);

    var bb_i: types.Bitboard = 0x3c18183c0000;
    try expect(types.shift_bitboard(bb_i, types.Direction.North) == 0x3c18183c000000);
    try expect(types.shift_bitboard(bb_i, types.Direction.NorthNorth) == 0x3c18183c00000000);
    try expect(types.shift_bitboard(bb_i, types.Direction.South) == 0x3c18183c00);
    try expect(types.shift_bitboard(bb_i, types.Direction.SouthSouth) == 0x3c18183c);
    try expect(types.shift_bitboard(bb_i, types.Direction.East) == 0x783030780000);
    try expect(types.shift_bitboard(bb_i, types.Direction.West) == 0x1e0c0c1e0000);
    try expect(types.shift_bitboard(bb_i, types.Direction.SouthEast) == 0x7830307800);
    try expect(types.shift_bitboard(bb_i, types.Direction.NorthWest) == 0x1e0c0c1e000000);
}

test "Move" {
    try expect(@sizeOf(types.Move) == 2);
    try expect(@bitSizeOf(types.Move) == 16);

    {
        var m = types.Move.empty();
        try expect(m.get_from() == types.Square.a1);
        try expect(m.get_to() == types.Square.a1);
    }

    {
        var m = types.Move.new_from_to(types.Square.g1, types.Square.f3);
        try expect(m.get_from() == types.Square.g1);
        try expect(m.get_to() == types.Square.f3);
        try expect(m.get_flags() == types.MoveFlags.QUIET);
    }

    {
        var m = types.Move.new_from_string("g1f3");
        try expect(m.get_from() == types.Square.g1);
        try expect(m.get_to() == types.Square.f3);
        try expect(m.get_flags() == types.MoveFlags.QUIET);
    }

    {
        var m = types.Move.new_from_to_flag(types.Square.e2, types.Square.e4, types.MoveFlags.DOUBLE_PUSH);
        try expect(m.get_from() == types.Square.e2);
        try expect(m.get_to() == types.Square.e4);
        try expect(m.get_flags() == types.MoveFlags.DOUBLE_PUSH);
    }

    {
        var m = types.Move.new_from_to_flag(types.Square.e4, types.Square.e5, types.MoveFlags.CAPTURE);
        try expect(m.is_capture());
        try expect(m.equals_to(m));
    }
}

test "Bitboard operations" {
    try expect(tables.reverse_bitboard(0x24180000000000) == 0x182400);
    try expect(tables.reverse_bitboard(0x40040000200200) == 0x40040000200200);
}

test "Magic Bitboard Slidng Pieces" {
    tables.init_rook_attacks();
    tables.init_bishop_attacks();

    try expect(tables.get_rook_attacks(types.Square.a1, 0x80124622004420) == 0x10101010101013e);
    try expect(tables.get_rook_attacks(types.Square.e4, 0x80124622004420) == 0x10102e101010);

    try expect(tables.get_bishop_attacks(types.Square.e4, 0x80124622004420) == 0x182442800284400);
    try expect(tables.get_bishop_attacks(types.Square.a1, 0x80124622004420) == 0x8040201008040200);

    try expect(tables.get_xray_rook_attacks(types.Square.e4, 0x11014004a10d3d0, 0x100048100000) == 0x10000086001000);
    try expect(tables.get_xray_bishop_attacks(types.Square.e4, 0x108a48c0c1294500, 0x2400000280000) == 0x180000000004400);
}

test "Squares and Line Between" {
    tables.init_squares_between();
    tables.init_line_between();
    try expect(tables.SquaresBetween[types.Square.b4.index()][types.Square.f4.index()] == 0x1c000000);
    try expect(tables.SquaresBetween[types.Square.e3.index()][types.Square.e7.index()] == 0x101010000000);
    try expect(tables.SquaresBetween[types.Square.b2.index()][types.Square.g7.index()] == 0x201008040000);
    try expect(tables.SquaresBetween[types.Square.b7.index()][types.Square.g2.index()] == 0x40810200000);
    try expect(tables.SquaresBetween[types.Square.a1.index()][types.Square.g4.index()] == 0);

    try expect(tables.LineOf[types.Square.b4.index()][types.Square.f4.index()] == 0xff000000);
    try expect(tables.LineOf[types.Square.e3.index()][types.Square.e7.index()] == 0x1010101010101010);
    try expect(tables.LineOf[types.Square.b2.index()][types.Square.g7.index()] == 0x8040201008040201);
    try expect(tables.LineOf[types.Square.b7.index()][types.Square.g2.index()] == 0x102040810204080);
    try expect(tables.LineOf[types.Square.a1.index()][types.Square.g4.index()] == 0);
}

test "Pawn Attacks" {
    tables.init_pseudo_legal();

    try expect(tables.get_pawn_attacks(types.Color.Black, types.Square.e5) == 0x28000000);
    try expect(tables.get_pawn_attacks(types.Color.White, types.Square.e4) == 0x2800000000);
    try expect(tables.get_pawn_attacks(types.Color.White, types.Square.a5) == 0x20000000000);

    try expect(tables.get_pawn_attacks_bb(types.Color.White, 0x2800000200400) == 0x5400000500a0000);
    try expect(tables.get_pawn_attacks_bb(types.Color.Black, 0x2800000200400) == 0x5400000500a);
}
