const std = @import("std");
const types = @import("chess/types.zig");
const tables = @import("chess/tables.zig");
const position = @import("chess/position.zig");
const zobrist = @import("chess/zobrist.zig");
const hce = @import("engine/hce.zig");
const weights = @import("engine/weights.zig");
const perft = @import("chess/perft.zig");
const see = @import("engine/see.zig");
const search = @import("engine/search.zig");
const tt = @import("engine/tt.zig");
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
    try expect(@intFromEnum(types.pop_lsb(&b)) == 3);
    try expect(b == 0b01100000);

    const bb_i: types.Bitboard = 0x3c18183c0000;
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

test "Position" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    // Position is large (NNUE accumulator stack); keep it off the test stack.
    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();

    try expect(pos.hash == 0);
    try expect(pos.turn == types.Color.White);
    try expect(pos.game_ply == 0);
    try expect(pos.mailbox[0] == types.Piece.NO_PIECE);

    pos.add_piece(types.Piece.WHITE_KNIGHT, types.Square.f3);
    try expect(pos.mailbox[types.Square.f3.index()] == types.Piece.WHITE_KNIGHT);
    try expect(pos.piece_bitboards[types.Piece.WHITE_KNIGHT.index()] == 0x200000);

    pos.remove_piece(types.Square.f3);
    try expect(pos.mailbox[types.Square.f3.index()] == types.Piece.NO_PIECE);
    try expect(pos.piece_bitboards[types.Piece.WHITE_KNIGHT.index()] == 0);

    pos.* = position.Position.new();

    pos.set_fen("rnbqkbnr/1ppp1pp1/p6p/4p3/8/1P3N2/PBPPPPPP/RN1QKB1R w KQkq -"[0..]);
    try expect(pos.attackers_from(types.Color.White, types.Square.e5, 0) == 0x200200);
    try expect(!pos.in_check(types.Color.White));

    // queen check
    pos.set_fen("rnb1kbnr/pppp1ppp/8/4p3/4PP1q/8/PPPP2PP/RNBQKBNR w KQkq -"[0..]);
    try expect(pos.attackers_from(types.Color.Black, types.Square.e1, 0) == 0x80000000);
    try expect(pos.in_check(types.Color.White));
    try expect(!pos.in_check(types.Color.Black));

    // blocked
    pos.set_fen("rnb1kbnr/pppp1ppp/8/4p3/4PP1q/6P1/PPPP3P/RNBQKBNR b KQkq -"[0..]);
    try expect(!pos.in_check(types.Color.White));

    pos.set_fen(types.DEFAULT_FEN[0..]);
    const score = hce.evaluate_comptime(pos, types.Color.White);

    const m1 = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m1);
    const m2 = types.Move.new_from_string(pos, "d7d5"[0..]);
    pos.play_move(types.Color.Black, m2);
    const m3 = types.Move.new_from_string(pos, "e4d5"[0..]);
    pos.play_move(types.Color.White, m3);

    pos.undo_move(types.Color.White, m3);
    pos.undo_move(types.Color.Black, m2);
    pos.undo_move(types.Color.White, m1);

    try expect(score == hce.evaluate_comptime(pos, types.Color.White));
}

// Move generation correctness (perft) + zobrist hashing

test "movegen: startpos perft 1-5" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 20);
    try expect(perft.perft(types.Color.White, pos, 2) == 400);
    try expect(perft.perft(types.Color.White, pos, 3) == 8902);
    try expect(perft.perft(types.Color.White, pos, 4) == 197281);
    try expect(perft.perft(types.Color.White, pos, 5) == 4865609);
}

test "movegen: kiwipete perft 1-4" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -"[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 48);
    try expect(perft.perft(types.Color.White, pos, 2) == 2039);
    try expect(perft.perft(types.Color.White, pos, 3) == 97862);
    try expect(perft.perft(types.Color.White, pos, 4) == 4085603);
}

test "movegen: endgame perft suite position 3" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    // Classic perft "position 3": rook + pawn endgame, rich in en-passant.
    pos.set_fen("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -"[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 14);
    try expect(perft.perft(types.Color.White, pos, 2) == 191);
    try expect(perft.perft(types.Color.White, pos, 3) == 2812);
    try expect(perft.perft(types.Color.White, pos, 4) == 43238);
    try expect(perft.perft(types.Color.White, pos, 5) == 674624);
}

test "movegen: en-passant position perft 1-4" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    // Black just played c7-c5, so White has an immediate en-passant capture (d5xc6).
    pos.set_fen("rnbqkbnr/pp1ppppp/8/2pP4/8/8/PPP1PPPP/RNBQKBNR w KQkq c6"[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 30);
    try expect(perft.perft(types.Color.White, pos, 2) == 631);
    try expect(perft.perft(types.Color.White, pos, 3) == 18825);
    try expect(perft.perft(types.Color.White, pos, 4) == 437149);
}

test "zobrist: make/unmake restores hash and board state" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);

    const fens = [_][]const u8{
        types.DEFAULT_FEN[0..],
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -"[0..],
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -"[0..],
        "rnbqkbnr/pp1ppppp/8/2pP4/8/8/PPP1PPPP/RNBQKBNR w KQkq c6"[0..],
    };

    for (fens) |fen| {
        pos.* = position.Position.new();
        pos.set_fen(fen);

        const orig_hash = pos.hash;
        const orig_bitboards = pos.piece_bitboards;
        const orig_mailbox = pos.mailbox;

        var list = std.array_list.Managed(types.Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        defer list.deinit();
        pos.generate_legal_moves(types.Color.White, &list);

        for (list.items) |move| {
            pos.play_move(types.Color.White, move);
            pos.undo_move(types.Color.White, move);

            try expect(pos.hash == orig_hash);

            var p: usize = 0;
            while (p < types.N_PIECES) : (p += 1) {
                try expect(pos.piece_bitboards[p] == orig_bitboards[p]);
            }
            var s: usize = 0;
            while (s < types.N_SQUARES) : (s += 1) {
                try expect(pos.mailbox[s] == orig_mailbox[s]);
            }
        }
    }
}

test "zobrist: hash differs after a real move" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);

    const orig_hash = pos.hash;
    const m = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m);
    try expect(pos.hash != orig_hash);
    pos.undo_move(types.Color.White, m);
    try expect(pos.hash == orig_hash);
}

test "zobrist: null-move hash symmetry" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);

    const fens = [_][]const u8{
        // No en-passant square: null move only flips turn hash.
        types.DEFAULT_FEN[0..],
        // En-passant square set: null move must also clear/restore the EP hash.
        "rnbqkbnr/pp1ppppp/8/2pP4/8/8/PPP1PPPP/RNBQKBNR w KQkq c6"[0..],
    };

    for (fens) |fen| {
        pos.* = position.Position.new();
        pos.set_fen(fen);

        const orig_hash = pos.hash;
        pos.play_null_move();
        try expect(pos.hash != orig_hash); // turn flipped -> hash changed
        pos.undo_null_move();
        try expect(pos.hash == orig_hash);
    }
}

// Core types, Move packing, and FEN parsing

test "types-move: packed layout and to_u16 bit ordering" {
    // packed struct is LSB-first: flags occupy bits 0-3, from bits 4-9, to bits 10-15.
    {
        // e2(12) -> e4(28), DOUBLE_PUSH (flag 1)
        const m = types.Move.new_from_to_flag(types.Square.e2, types.Square.e4, types.MoveFlags.DOUBLE_PUSH);
        try expect(m.get_from() == types.Square.e2);
        try expect(m.get_to() == types.Square.e4);
        try expect(m.get_flags() == types.MoveFlags.DOUBLE_PUSH);
        try expect(m.from == 12);
        try expect(m.to == 28);
        try expect(m.flags == 1);
        // 1 | (12<<4) | (28<<10) = 28865
        try expect(m.to_u16() == 28865);
        // Reconstruct field order explicitly from the bits of to_u16.
        const bits: u16 = m.to_u16();
        try expect(@as(u4, @truncate(bits)) == 1); // low 4 bits = flags
        try expect(@as(u6, @truncate(bits >> 4)) == 12); // next 6 bits = from
        try expect(@as(u6, @truncate(bits >> 10)) == 28); // top 6 bits = to
        try expect(!m.is_capture());
        try expect(!m.is_promotion());
    }
    {
        // g1(6) -> f3(21), QUIET
        const m = types.Move.new_from_to(types.Square.g1, types.Square.f3);
        try expect(m.get_flags() == types.MoveFlags.QUIET);
        try expect(m.to_u16() == 21600); // 0 | (6<<4) | (21<<10)
        try expect(!m.is_capture());
    }
    {
        // e4(28) -> d5(35), CAPTURE (flag 8)
        const m = types.Move.new_from_to_flag(types.Square.e4, types.Square.d5, types.MoveFlags.CAPTURE);
        try expect(m.is_capture());
        try expect(!m.is_promotion());
        try expect(m.to_u16() == 36296); // 8 | (28<<4) | (35<<10)
    }
    {
        // h7(55) -> h8(63), quiet queen promotion (PR_QUEEN = 0b0111 = 7)
        const m = types.Move.new_from_to_flag(types.Square.h7, types.Square.h8, @as(types.MoveFlags, @enumFromInt(types.PR_QUEEN)));
        try expect(m.is_promotion());
        try expect(!m.is_capture());
        try expect(m.flags == 7);
        try expect(m.to_u16() == 65399); // 7 | (55<<4) | (63<<10)
    }
    {
        // h7 -> h8, queen promotion-capture (PC_QUEEN = 0b1111 = 15): both capture and promotion.
        const m = types.Move.new_from_to_flag(types.Square.h7, types.Square.h8, @as(types.MoveFlags, @enumFromInt(types.PC_QUEEN)));
        try expect(m.is_promotion());
        try expect(m.is_capture());
        try expect(m.flags == 15);
    }
    {
        // empty move round-trips to all-zero a1/a1/QUIET.
        const m = types.Move.empty();
        try expect(m.to_u16() == 0);
        try expect(m.get_from() == types.Square.a1);
        try expect(m.get_to() == types.Square.a1);
        try expect(m.get_flags() == types.MoveFlags.QUIET);
    }
}

test "types-dir: relative_dir edge cases" {
    try expect(types.Direction.North.relative_dir(types.Color.Black) == types.Direction.South);
    try expect(types.Direction.NorthEast.relative_dir(types.Color.Black) == types.Direction.SouthWest);
    try expect(types.Direction.West.relative_dir(types.Color.Black) == types.Direction.East);
    try expect(types.Direction.NorthNorth.relative_dir(types.Color.Black) == types.Direction.SouthSouth);
    // White is identity.
    try expect(types.Direction.NorthEast.relative_dir(types.Color.White) == types.Direction.NorthEast);
    try expect(types.Direction.SouthSouth.relative_dir(types.Color.White) == types.Direction.SouthSouth);
}

test "types-square: add/sub/new arithmetic" {
    // e4(28) + NorthEast(9) = 37 = f5
    try expect(types.Square.e4.add(types.Direction.NorthEast) == types.Square.f5);
    // e4(28) - NorthEast(9) = 19 = d3
    try expect(types.Square.e4.sub(types.Direction.NorthEast) == types.Square.d3);
    // c5(34) + SouthSouth(-16) = 18 = c3
    try expect(types.Square.c5.add(types.Direction.SouthSouth) == types.Square.c3);
    // b2(9) - West(-1) = 10 = c2
    try expect(types.Square.b2.sub(types.Direction.West) == types.Square.c2);

    // new(file, rank) composition and inverse via rank()/file().
    try expect(types.Square.new(types.File.HFILE, types.Rank.RANK8) == types.Square.h8);
    try expect(types.Square.h8.rank() == types.Rank.RANK8);
    try expect(types.Square.h8.file() == types.File.HFILE);
    try expect(types.Square.a1.index() == 0);
    try expect(types.Square.h8.index() == 63);
}

test "types-rank: relative_rank edge cases" {
    try expect(types.Rank.RANK1.relative_rank(types.Color.Black) == types.Rank.RANK8);
    try expect(types.Rank.RANK4.relative_rank(types.Color.Black) == types.Rank.RANK5);
    // White is identity.
    try expect(types.Rank.RANK6.relative_rank(types.Color.White) == types.Rank.RANK6);
}

test "fen: starting position parse" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();

    pos.set_fen(types.DEFAULT_FEN[0..]);

    try expect(pos.turn == types.Color.White);
    try expect(pos.game_ply == 0);

    // Mailbox spot checks.
    try expect(pos.mailbox[types.Square.e1.index()] == types.Piece.WHITE_KING);
    try expect(pos.mailbox[types.Square.d1.index()] == types.Piece.WHITE_QUEEN);
    try expect(pos.mailbox[types.Square.a1.index()] == types.Piece.WHITE_ROOK);
    try expect(pos.mailbox[types.Square.e8.index()] == types.Piece.BLACK_KING);
    try expect(pos.mailbox[types.Square.b8.index()] == types.Piece.BLACK_KNIGHT);
    try expect(pos.mailbox[types.Square.e4.index()] == types.Piece.NO_PIECE);

    // Piece bitboards (index = file + rank*8).
    try expect(pos.piece_bitboards[types.Piece.WHITE_PAWN.index()] == 0xff00);
    try expect(pos.piece_bitboards[types.Piece.BLACK_PAWN.index()] == 0xff000000000000);
    try expect(pos.piece_bitboards[types.Piece.WHITE_KING.index()] == 0x10);
    try expect(pos.piece_bitboards[types.Piece.BLACK_KING.index()] == 0x1000000000000000);
    try expect(pos.piece_bitboards[types.Piece.WHITE_ROOK.index()] == 0x81);

    // "KQkq" clears all four castling mask bits in entry -> 0.
    try expect(pos.history[pos.game_ply].entry == 0);
    // No en-passant target.
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.NO_SQUARE);
}

test "fen: black-to-move and partial castling rights" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();

    // Black to move, only black kingside castling available ("k").
    pos.set_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b k -"[0..]);
    try expect(pos.turn == types.Color.Black);
    // AllCastlingMask(0x9100000000000091) with only BlackOOMask(0x9000000000000000) cleared.
    try expect(pos.history[pos.game_ply].entry == 0x100000000000091);
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.NO_SQUARE);

    // No castling rights at all: entry stays at full AllCastlingMask.
    pos.set_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - -"[0..]);
    try expect(pos.turn == types.Color.White);
    try expect(pos.history[pos.game_ply].entry == types.AllCastlingMask);
}

test "fen: en-passant target square stored" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);

    // Capturable en passant: a black pawn on d4 can answer e3, so the square is
    // recorded (and folded into the hash).
    pos.* = position.Position.new();
    pos.set_fen("rnbqkbnr/pppp1ppp/8/8/3pP3/8/PPPP1PPP/RNBQKBNR b KQkq e3"[0..]);
    try expect(pos.turn == types.Color.Black);
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.e3);
    // The pushed pawn is on e4; e2 is now empty.
    try expect(pos.mailbox[types.Square.e4.index()] == types.Piece.WHITE_PAWN);
    try expect(pos.mailbox[types.Square.e2.index()] == types.Piece.NO_PIECE);

    // Phantom en passant: after 1.e4 no black pawn can capture e3, so the FEN's
    // EP target is dropped (matches the FIDE/Zobrist definition of equality — the
    // position must not be distinguished from the same one with the EP right gone).
    pos.* = position.Position.new();
    pos.set_fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3"[0..]);
    try expect(pos.turn == types.Color.Black);
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.NO_SQUARE);
    // The board is still parsed correctly; only the idle EP marker is dropped.
    try expect(pos.mailbox[types.Square.e4.index()] == types.Piece.WHITE_PAWN);
    try expect(pos.mailbox[types.Square.e2.index()] == types.Piece.NO_PIECE);
    try expect(pos.piece_bitboards[types.Piece.WHITE_PAWN.index()] == 0x1000ef00);
}

test "fen: basic_fen board round-trips" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();

    // basic_fen returns a sub-slice of an over-allocation; use an arena.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Starting position: basic_fen now emits full castling/ep/clock fields.
    pos.set_fen(types.DEFAULT_FEN[0..]);
    {
        const out = pos.basic_fen(arena.allocator());
        // Board portion (first space-separated token) must match the canonical board.
        var it = std.mem.tokenizeScalar(u8, out, ' ');
        const board = it.next().?;
        try expect(std.mem.eql(u8, board, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"));
        // Side-to-move field is preserved.
        try expect(std.mem.eql(u8, it.next().?, "w"));
        try expect(std.mem.eql(u8, it.next().?, "KQkq"));
        try expect(std.mem.eql(u8, it.next().?, "-"));
    }

    // A black-to-move middlegame position; board portion must round-trip exactly,
    // and the side field must read "b".
    pos.set_fen("r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R b KQkq -"[0..]);
    {
        const out = pos.basic_fen(arena.allocator());
        var it = std.mem.tokenizeScalar(u8, out, ' ');
        const board = it.next().?;
        try expect(std.mem.eql(u8, board, "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R"));
        try expect(std.mem.eql(u8, it.next().?, "b"));
    }
}

// Static exchange evaluation (SEE)

// Helper: build a heap Position with the given FEN, after global init.
fn see_make_pos(fen: []const u8) *position.Position {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
    const pos = std.testing.allocator.create(position.Position) catch unreachable;
    pos.* = position.Position.new();
    pos.set_fen(fen);
    return pos;
}

test "see: free hanging knight capture is winning" {
    // White rook on e1 captures an undefended black knight on e5.
    const pos = see_make_pos("4k3/8/8/4n3/8/8/8/4R1K1 w - -");
    defer std.testing.allocator.destroy(pos);

    const mv = types.Move.new_from_string(pos, "e1e5"[0..]);
    try expect(mv.is_capture()); // confirm it is generated as a capture

    // Winning capture: positive score, exactly the knight value (308).
    try expect(see.see_score(pos, mv) > 0);
    try expect(see.see_score(pos, mv) == 308);

    // Passes generous positive thresholds (gain is a full knight, no recapture).
    try expect(see.see_threshold(pos, mv, 0));
    try expect(see.see_threshold(pos, mv, 200));
    // But the gain is not as large as a rook.
    try expect(!see.see_threshold(pos, mv, 500));
}

test "see: queen captures pawn defended by pawn fails threshold 0" {
    // White queen e1 takes black pawn e5, defended by black pawn on d6.
    const pos = see_make_pos("4k3/8/3p4/4p3/8/8/8/4Q1K1 w - -");
    defer std.testing.allocator.destroy(pos);

    const mv = types.Move.new_from_string(pos, "e1e5"[0..]);
    try expect(mv.is_capture());

    // Losing exchange: win a pawn, lose a queen.
    try expect(see.see_score(pos, mv) < 0);
    try expect(see.see_score(pos, mv) == -808); // +93 (pawn) - 901... net -808

    try expect(!see.see_threshold(pos, mv, 0));
    try expect(!see.see_threshold(pos, mv, -100));
}

test "see: equal rook trade" {
    // White rook e1 takes black rook e5, which is defended by black rook e8.
    const pos = see_make_pos("4r2k/8/8/4r3/8/8/8/4R1K1 w - -");
    defer std.testing.allocator.destroy(pos);

    const mv = types.Move.new_from_string(pos, "e1e5"[0..]);
    try expect(mv.is_capture());

    // see_threshold treats an even trade as "passing" at threshold 0 but not at 1.
    try expect(see.see_threshold(pos, mv, 0));
    try expect(!see.see_threshold(pos, mv, 1));
    // see_score for this even-trade position evaluates to the rook value.
    try expect(see.see_score(pos, mv) == 521);
}

test "see: rook captures undefended queen is strongly winning" {
    // White rook e1 takes an undefended black queen on e5.
    const pos = see_make_pos("4k3/8/8/4q3/8/8/8/4R1K1 w - -");
    defer std.testing.allocator.destroy(pos);

    const mv = types.Move.new_from_string(pos, "e1e5"[0..]);
    try expect(mv.is_capture());

    try expect(see.see_score(pos, mv) > 0);
    try expect(see.see_score(pos, mv) == 994); // full queen value, no recapture
    try expect(see.see_threshold(pos, mv, 500));
    try expect(!see.see_threshold(pos, mv, 1000));
}

test "see: bishop captures pawn defended by pawn is losing" {
    // White bishop c3 takes black pawn e5, defended by black pawn d6.
    const pos = see_make_pos("4k3/8/3p4/4p3/8/2B5/8/6K1 w - -");
    defer std.testing.allocator.destroy(pos);

    const mv = types.Move.new_from_string(pos, "c3e5"[0..]);
    try expect(mv.is_capture());

    // Win a pawn (93), lose a bishop (346) but the defender pawn recaptured:
    // confirmed score is -160.
    try expect(see.see_score(pos, mv) < 0);
    try expect(see.see_score(pos, mv) == -160);
    try expect(!see.see_threshold(pos, mv, 0));
}

test "see: pawn captures undefended pawn is winning" {
    // White pawn d4 takes an undefended black pawn on e5.
    const pos = see_make_pos("4k3/8/8/4p3/3P4/8/8/6K1 w - -");
    defer std.testing.allocator.destroy(pos);

    const mv = types.Move.new_from_string(pos, "d4e5"[0..]);
    try expect(mv.is_capture());

    try expect(see.see_score(pos, mv) > 0);
    try expect(see.see_score(pos, mv) == 93); // exactly one pawn
    try expect(see.see_threshold(pos, mv, 50));
    try expect(!see.see_threshold(pos, mv, 100));
}

test "eval: nnue weights load and dimensions" {
    weights.do_nnue();
    try expect(@sizeOf(weights.NNUEWeights) == 1607744);
    try expect(weights.HIDDEN_SIZE == 1024);
    try expect(weights.OUTPUT_SIZE == 8);
    try expect(weights.INPUT_SIZE == 768);
}

test "eval: determinism same position twice" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();

    pos.set_fen("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq -"[0..]);
    const a = hce.evaluate_comptime(pos, types.Color.White);
    const b = hce.evaluate_comptime(pos, types.Color.White);
    try expect(a == b);

    const c = hce.evaluate_nnue_comptime(pos, types.Color.White);
    const d = hce.evaluate_nnue_comptime(pos, types.Color.White);
    try expect(c == d);
}

test "eval: nnue incremental equals fresh refresh (startpos)" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);

    // set_fen forced a full_refresh; this is the reference value.
    const fresh0 = hce.evaluate_nnue_comptime(pos, types.Color.White);

    // Force another full refresh from the same board: must be identical.
    pos.evaluator.full_refresh(pos);
    const fresh1 = hce.evaluate_nnue_comptime(pos, types.Color.White);
    try expect(fresh0 == fresh1);
}

test "eval: nnue incremental equals fresh refresh after moves" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);

    const m1 = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m1);
    const m2 = types.Move.new_from_string(pos, "c7c5"[0..]);
    pos.play_move(types.Color.Black, m2);
    const m3 = types.Move.new_from_string(pos, "g1f3"[0..]);
    pos.play_move(types.Color.White, m3);
    const m4 = types.Move.new_from_string(pos, "d7d6"[0..]);
    pos.play_move(types.Color.Black, m4);

    // Incremental accumulator value (built via play_move toggles).
    const incremental_w = hce.evaluate_nnue_comptime(pos, types.Color.White);
    const incremental_b = hce.evaluate_nnue_comptime(pos, types.Color.Black);

    // Rebuild the accumulator from scratch off the current mailbox; the
    // incrementally-updated SIMD accumulator must match a fresh refresh.
    pos.evaluator.full_refresh(pos);
    const fresh_w = hce.evaluate_nnue_comptime(pos, types.Color.White);
    const fresh_b = hce.evaluate_nnue_comptime(pos, types.Color.Black);

    try expect(incremental_w == fresh_w);
    try expect(incremental_b == fresh_b);
}

test "eval: nnue incremental equals fresh after a capture" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);

    const m1 = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m1);
    const m2 = types.Move.new_from_string(pos, "d7d5"[0..]);
    pos.play_move(types.Color.Black, m2);
    const m3 = types.Move.new_from_string(pos, "e4d5"[0..]); // capture
    pos.play_move(types.Color.White, m3);

    const incremental = hce.evaluate_nnue_comptime(pos, types.Color.Black);
    pos.evaluator.full_refresh(pos);
    const fresh = hce.evaluate_nnue_comptime(pos, types.Color.Black);
    try expect(incremental == fresh);
}

test "eval: hce material draw classification" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();

    // KvK -> hard draw and drawish
    pos.set_fen("4k3/8/8/8/8/8/8/4K3 w - -"[0..]);
    try expect(hce.is_material_draw(pos));
    try expect(hce.is_material_drawish(pos));

    // KN vs K -> hard draw and drawish
    pos.set_fen("4k3/8/8/8/8/8/8/3NK3 w - -"[0..]);
    try expect(hce.is_material_draw(pos));
    try expect(hce.is_material_drawish(pos));

    // KB vs K -> hard material draw, but NOT covered by is_material_drawish
    // (drawish has no lone-bishop-vs-bare-king clause).
    pos.set_fen("4k3/8/8/8/8/8/8/3BK3 w - -"[0..]);
    try expect(hce.is_material_draw(pos));
    try expect(!hce.is_material_drawish(pos));

    // KQ vs K -> not a draw
    pos.set_fen("4k3/8/8/8/8/8/8/3QK3 w - -"[0..]);
    try expect(!hce.is_material_draw(pos));
    try expect(!hce.is_material_drawish(pos));

    // KR vs K -> not a draw
    pos.set_fen("4k3/8/8/8/8/8/8/3RK3 w - -"[0..]);
    try expect(!hce.is_material_draw(pos));
    try expect(!hce.is_material_drawish(pos));

    // KNN vs K -> not a hard material draw, but drawish.
    pos.set_fen("2NNK3/8/8/8/8/8/8/4k3 w - -"[0..]);
    try expect(!hce.is_material_draw(pos));
    try expect(hce.is_material_drawish(pos));
}

// Search: mate detection, draws, determinism

test "search: mate in 1 (white back-rank)" {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    types.GLOBAL_IO = io_threaded.io();

    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
    search.init_lmr();
    tt.GlobalTT.reset(16);
    search.NUM_THREADS = 0;
    tt.GlobalTT.clear();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen("6k1/5ppp/8/8/8/8/8/R6K w - -"[0..]);

    var s = search.Searcher.new();
    defer s.deinit();
    s.force_thinking = true;
    s.silent_output = true;
    s.stop = false;
    s.reset_heuristics(true);

    const score = s.iterative_deepening(pos, types.Color.White, 4);

    // Mate score for the side to move is positive and within MaxMate of MateScore.
    try expect(@as(i32, @intCast(@abs(score))) >= hce.MateScore - hce.MaxMate);
    try expect(score > 0);

    const mating = types.Move.new_from_string(pos, "a1a8"[0..]); // Ra8#
    try expect(s.best_move.to_u16() == mating.to_u16());
}

test "search: mate in 1 (black back-rank)" {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    types.GLOBAL_IO = io_threaded.io();

    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
    search.init_lmr();
    tt.GlobalTT.reset(16);
    search.NUM_THREADS = 0;
    tt.GlobalTT.clear();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen("r6k/8/8/8/8/8/5PPP/6K1 b - -"[0..]);

    var s = search.Searcher.new();
    defer s.deinit();
    s.force_thinking = true;
    s.silent_output = true;
    s.stop = false;
    s.reset_heuristics(true);

    const score = s.iterative_deepening(pos, types.Color.Black, 4);

    try expect(@as(i32, @intCast(@abs(score))) >= hce.MateScore - hce.MaxMate);
    try expect(score > 0);

    const mating = types.Move.new_from_string(pos, "a8a1"[0..]); // ...Ra1#
    try expect(s.best_move.to_u16() == mating.to_u16());
}

test "search: stalemate scores as draw" {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    types.GLOBAL_IO = io_threaded.io();

    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
    search.init_lmr();
    tt.GlobalTT.reset(16);
    search.NUM_THREADS = 0;
    tt.GlobalTT.clear();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    // Black to move: Kh8 has no legal move and is not in check -> stalemate.
    pos.set_fen("7k/5Q2/6K1/8/8/8/8/8 b - -"[0..]);

    var s = search.Searcher.new();
    defer s.deinit();
    s.force_thinking = true;
    s.silent_output = true;
    s.stop = false;
    s.reset_heuristics(true);

    const score = s.iterative_deepening(pos, types.Color.Black, 4);
    try expect(score == 0);
}

test "search: deterministic node counts and score" {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    types.GLOBAL_IO = io_threaded.io();

    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
    search.init_lmr();
    tt.GlobalTT.reset(16);
    search.NUM_THREADS = 0; // single-threaded: no helper search threads -> deterministic

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);

    // Run 1
    pos.* = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);
    tt.GlobalTT.clear();
    var s1 = search.Searcher.new();
    defer s1.deinit();
    s1.force_thinking = true;
    s1.silent_output = true;
    s1.stop = false;
    s1.reset_heuristics(true);
    const score1 = s1.iterative_deepening(pos, types.Color.White, 7);
    const nodes1 = s1.nodes;

    // Run 2: fresh searcher, cleared TT + heuristics, identical starting position
    pos.* = position.Position.new();
    pos.set_fen(types.DEFAULT_FEN[0..]);
    tt.GlobalTT.clear();
    var s2 = search.Searcher.new();
    defer s2.deinit();
    s2.force_thinking = true;
    s2.silent_output = true;
    s2.stop = false;
    s2.reset_heuristics(true);
    const score2 = s2.iterative_deepening(pos, types.Color.White, 7);
    const nodes2 = s2.nodes;

    try expect(score1 == score2);
    try expect(nodes1 == nodes2);
    try expect(nodes1 > 0);
}

test "zobrist: castling rights are part of the position key" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);

    pos.* = position.Position.new();
    pos.set_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    const with_rights = pos.hash;

    pos.set_fen("r3k2r/8/8/8/8/8/8/R3K2R w - - 0 1");
    try expect(pos.hash != with_rights);
}

test "fen: halfmove clock is preserved" {
    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen("7k/8/8/8/8/8/8/KR6 w - - 99 1");
    try expect(pos.history[pos.game_ply].fifty == 99);
}

test "see: absolutely pinned pawn cannot recapture" {
    const pos = see_make_pos("4k3/4p3/3p4/8/8/8/7Q/4R1K1 w - -");
    defer std.testing.allocator.destroy(pos);

    const mv = types.Move.new_from_string(pos, "h2d6");
    try expect(mv.is_capture());
    try expect(see.see_threshold(pos, mv, 0));
}

test "search: maximum-mobility position exceeds 128 quiet moves safely" {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    types.GLOBAL_IO = io_threaded.io();

    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
    search.init_lmr();
    tt.GlobalTT.reset(16);
    tt.GlobalTT.clear();
    search.NUM_THREADS = 0;

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen("R6R/3Q4/1Q4Q1/4Q3/2Q4Q/Q4Q2/pp1Q4/kBNN1KB1 w - - 0 1");

    var moves = std.array_list.Managed(types.Move).initCapacity(std.testing.allocator, 256) catch unreachable;
    defer moves.deinit();
    pos.generate_legal_moves(types.Color.White, &moves);
    var quiets: usize = 0;
    for (moves.items) |move| {
        if (!move.is_capture()) quiets += 1;
    }
    try expect(quiets > 128);

    var s = search.Searcher.new();
    defer s.deinit();
    s.force_thinking = true;
    s.silent_output = true;
    s.hash_history.append(pos.hash) catch unreachable;
    _ = s.iterative_deepening(pos, types.Color.White, 1);
}

test "qsearch: checkmate takes precedence over fifty-move draw" {
    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();
    types.GLOBAL_IO = io_threaded.io();

    tables.init_all();
    zobrist.init_zobrist();
    weights.do_nnue();
    search.init_lmr();
    tt.GlobalTT.reset(16);
    tt.GlobalTT.clear();
    search.NUM_THREADS = 0;

    const pos = try std.testing.allocator.create(position.Position);
    defer std.testing.allocator.destroy(pos);
    pos.* = position.Position.new();
    pos.set_fen("7k/6Q1/6K1/8/8/8/8/8 b - - 100 1");

    var s = search.Searcher.new();
    defer s.deinit();
    s.force_thinking = true;
    s.silent_output = true;
    s.hash_history.append(pos.hash) catch unreachable;
    const score = s.quiescence_search(pos, types.Color.Black, -hce.MateScore, hce.MateScore);
    try expect(score <= -hce.MateScore + hce.MaxMate);
}
