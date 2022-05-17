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

test "Bitboards" {}
