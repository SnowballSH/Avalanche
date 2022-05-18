const std = @import("std");
const types = @import("./chess/types.zig");
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

test "Bitboards" {
    try expect(types.popcount(0b0110111010010) == 7);
    try expect(types.lsb(0b01101000) == 3);
    var b: types.Bitboard = 0b01101000;
    try expect(@enumToInt(types.pop_lsb(&b)) == 3);
    try expect(b == 0b01100000);
}
