const std = @import("std");
const types = @import("chess/types.zig");
const tables = @import("chess/tables.zig");
const position = @import("chess/position.zig");
const castling = @import("chess/castling.zig");
const hce = @import("engine/hce.zig");
const weights = @import("engine/weights.zig");
const nnue = @import("engine/nnue.zig");
const perft = @import("chess/perft.zig");
const search = @import("engine/search.zig");
const tt = @import("engine/tt.zig");
const interface = @import("engine/interface.zig");
const support = @import("tests/support.zig");
const expect = std.testing.expect;

// The C tablebase code links against callbacks syzygy.zig exports. Reference
// it here so that they exist whichever tests -Dtest-filter keeps.
comptime {
    _ = @import("engine/syzygy.zig");
}

test {
    _ = @import("platform.zig");
    _ = @import("engine/search.zig");
    _ = @import("engine/wdl.zig");
    _ = @import("tests/frc.zig");
    _ = @import("tests/board.zig");
    _ = @import("tests/search_features.zig");
    _ = @import("tests/correction_history.zig");
    _ = @import("engine/strength.zig");
    _ = @import("engine/uci/go.zig");
    _ = @import("tests/uci_options.zig");
    _ = @import("engine/numa.zig");
    _ = @import("platform/large_memory.zig");
    _ = @import("engine/tt.zig");
    _ = @import("tests/thread_pool.zig");
    _ = @import("tests/smp_root.zig");
    _ = @import("tests/tt_concurrency.zig");
    _ = @import("engine/datagen/options.zig");
    _ = @import("engine/datagen/adjudicator.zig");
    _ = @import("tests/datagen.zig");
    _ = @import("chess/cuckoo.zig");
    _ = @import("chess/key_history.zig");
    _ = @import("chess/fen.zig");
    _ = @import("tests/viriformat.zig");
    _ = @import("tests/tbfilter_viri.zig");
    _ = @import("engine/netscale.zig");
    _ = @import("tests/netscale.zig");
    _ = @import("tests/nnue_multi.zig");
    _ = @import("tests/nnue_lazy.zig");
    _ = @import("engine/nnue/eval_cache.zig");
    _ = @import("tests/movepick.zig");
}

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
    const sq: types.Square = types.Square.e4;

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
    try expect(@backingInt(types.pop_lsb(&b)) == 3);
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
    }
}

test "Bitboard operations" {
    try expect(tables.reverse_bitboard(0x24180000000000) == 0x182400);
    try expect(tables.reverse_bitboard(0x40040000200200) == 0x40040000200200);
}

test "Magic Bitboard Sliding Pieces" {
    tables.init_rook_attacks();
    tables.init_bishop_attacks();

    try expect(tables.get_rook_attacks(types.Square.a1, 0x80124622004420) == 0x10101010101013e);
    try expect(tables.get_rook_attacks(types.Square.e4, 0x80124622004420) == 0x10102e101010);

    try expect(tables.get_bishop_attacks(types.Square.e4, 0x80124622004420) == 0x182442800284400);
    try expect(tables.get_bishop_attacks(types.Square.a1, 0x80124622004420) == 0x8040201008040200);
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
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

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

    pos.set_fen("rnbqkbnr/1ppp1pp1/p6p/4p3/8/1P3N2/PBPPPPPP/RN1QKB1R w KQkq -"[0..]);
    try expect(pos.attackers_from(types.Color.White, types.Square.e5, 0) == 0x200200);
    try expect(!pos.in_check(types.Color.White));

    pos.set_fen("rnb1kbnr/pppp1ppp/8/4p3/4PP1q/8/PPPP2PP/RNBQKBNR w KQkq -"[0..]);
    try expect(pos.attackers_from(types.Color.Black, types.Square.e1, 0) == 0x80000000);
    try expect(pos.in_check(types.Color.White));
    try expect(!pos.in_check(types.Color.Black));

    pos.set_fen("rnb1kbnr/pppp1ppp/8/4p3/4PP1q/6P1/PPPP3P/RNBQKBNR b KQkq -"[0..]);
    try expect(!pos.in_check(types.Color.White));

    pos.set_fen(types.DEFAULT_FEN[0..]);
    const output = support.network_output(pos);

    const m1 = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m1);
    const m2 = types.Move.new_from_string(pos, "d7d5"[0..]);
    pos.play_move(types.Color.Black, m2);
    const m3 = types.Move.new_from_string(pos, "e4d5"[0..]);
    pos.play_move(types.Color.White, m3);

    pos.undo_move(types.Color.White, m3);
    pos.undo_move(types.Color.Black, m2);
    pos.undo_move(types.Color.White, m1);

    try expect(output == support.network_output(pos));
}

test "movegen: startpos perft 1-5" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 20);
    try expect(perft.perft(types.Color.White, pos, 2) == 400);
    try expect(perft.perft(types.Color.White, pos, 3) == 8902);
    try expect(perft.perft(types.Color.White, pos, 4) == 197281);
    try expect(perft.perft(types.Color.White, pos, 5) == 4865609);
}

test "movegen: kiwipete perft 1-4" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -"[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 48);
    try expect(perft.perft(types.Color.White, pos, 2) == 2039);
    try expect(perft.perft(types.Color.White, pos, 3) == 97862);
    try expect(perft.perft(types.Color.White, pos, 4) == 4085603);
}

test "movegen: endgame perft suite position 3" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -"[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 14);
    try expect(perft.perft(types.Color.White, pos, 2) == 191);
    try expect(perft.perft(types.Color.White, pos, 3) == 2812);
    try expect(perft.perft(types.Color.White, pos, 4) == 43238);
    try expect(perft.perft(types.Color.White, pos, 5) == 674624);
}

test "movegen: en-passant position perft 1-4" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("rnbqkbnr/pp1ppppp/8/2pP4/8/8/PPP1PPPP/RNBQKBNR w KQkq c6"[0..]);

    try expect(perft.perft(types.Color.White, pos, 1) == 30);
    try expect(perft.perft(types.Color.White, pos, 2) == 631);
    try expect(perft.perft(types.Color.White, pos, 3) == 18825);
    try expect(perft.perft(types.Color.White, pos, 4) == 437149);
}

test "zobrist: make/unmake restores hash and board state" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    const fens = [_][]const u8{
        types.DEFAULT_FEN[0..],
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -"[0..],
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -"[0..],
        "rnbqkbnr/pp1ppppp/8/2pP4/8/8/PPP1PPPP/RNBQKBNR w KQkq c6"[0..],
    };

    for (fens) |fen| {
        pos.set_fen(fen);

        const orig_hash = pos.hash;
        const orig_bitboards = pos.piece_bitboards;
        const orig_mailbox = pos.mailbox;

        var list: types.MoveList = .{};
        pos.generate_legal_moves(types.Color.White, &list);

        for (list.items()) |move| {
            pos.play_move(types.Color.White, move);
            pos.undo_move(types.Color.White, move);

            try expect(pos.hash == orig_hash);

            for (0..types.N_PIECES) |p| try expect(pos.piece_bitboards[p] == orig_bitboards[p]);
            for (0..types.N_SQUARES) |s| try expect(pos.mailbox[s] == orig_mailbox[s]);
        }
    }
}

test "zobrist: hash differs after a real move" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN[0..]);

    const orig_hash = pos.hash;
    const m = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m);
    try expect(pos.hash != orig_hash);
    pos.undo_move(types.Color.White, m);
    try expect(pos.hash == orig_hash);
}

test "zobrist: null-move hash symmetry" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    const without_en_passant_square = types.DEFAULT_FEN;
    const with_en_passant_square = "rnbqkbnr/pp1ppppp/8/2pP4/8/8/PPP1PPPP/RNBQKBNR w KQkq c6";

    for ([_][]const u8{ without_en_passant_square, with_en_passant_square }) |fen| {
        pos.set_fen(fen);

        const orig_hash = pos.hash;
        pos.play_null_move();
        try expect(pos.hash != orig_hash);
        pos.undo_null_move();
        try expect(pos.hash == orig_hash);
    }
}

fn packed_move_bits(flags: types.MoveFlags, from: types.Square, to: types.Square) u16 {
    return @as(u16, @backingInt(flags)) | (@as(u16, @intCast(from.index())) << 4) | (@as(u16, @intCast(to.index())) << 10);
}

test "types-move: packed layout and to_u16 bit ordering" {
    const quiet_queen_promotion: types.MoveFlags = @fromBackingInt(types.PR_QUEEN);
    const capturing_queen_promotion: types.MoveFlags = @fromBackingInt(types.PC_QUEEN);
    {
        const m = types.Move.new_from_to_flag(types.Square.e2, types.Square.e4, types.MoveFlags.DOUBLE_PUSH);
        try expect(m.get_from() == types.Square.e2);
        try expect(m.get_to() == types.Square.e4);
        try expect(m.get_flags() == types.MoveFlags.DOUBLE_PUSH);
        try expect(m.from == 12);
        try expect(m.to == 28);
        try expect(m.flags == 1);
        try expect(m.to_u16() == packed_move_bits(.DOUBLE_PUSH, .e2, .e4));
        const bits: u16 = m.to_u16();
        try expect(@as(u4, @truncate(bits)) == m.flags);
        try expect(@as(u6, @truncate(bits >> 4)) == m.from);
        try expect(@as(u6, @truncate(bits >> 10)) == m.to);
        try expect(!m.is_capture());
        try expect(!m.is_promotion());
    }
    {
        const m = types.Move.new_from_to(types.Square.g1, types.Square.f3);
        try expect(m.get_flags() == types.MoveFlags.QUIET);
        try expect(m.to_u16() == packed_move_bits(.QUIET, .g1, .f3));
        try expect(!m.is_capture());
    }
    {
        const m = types.Move.new_from_to_flag(types.Square.e4, types.Square.d5, types.MoveFlags.CAPTURE);
        try expect(m.is_capture());
        try expect(!m.is_promotion());
        try expect(m.to_u16() == packed_move_bits(.CAPTURE, .e4, .d5));
    }
    {
        const m = types.Move.new_from_to_flag(types.Square.h7, types.Square.h8, quiet_queen_promotion);
        try expect(m.is_promotion());
        try expect(!m.is_capture());
        try expect(m.flags == types.PR_QUEEN);
        try expect(m.to_u16() == packed_move_bits(quiet_queen_promotion, .h7, .h8));
    }
    {
        const m = types.Move.new_from_to_flag(types.Square.h7, types.Square.h8, capturing_queen_promotion);
        try expect(m.is_promotion());
        try expect(m.is_capture());
        try expect(m.flags == types.PC_QUEEN);
    }
    {
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
    try expect(types.Direction.NorthEast.relative_dir(types.Color.White) == types.Direction.NorthEast);
    try expect(types.Direction.SouthSouth.relative_dir(types.Color.White) == types.Direction.SouthSouth);
}

test "types-square: add/sub/new arithmetic" {
    try expect(types.Square.e4.add(types.Direction.NorthEast) == types.Square.f5);
    try expect(types.Square.e4.sub(types.Direction.NorthEast) == types.Square.d3);
    try expect(types.Square.c5.add(types.Direction.SouthSouth) == types.Square.c3);
    try expect(types.Square.b2.sub(types.Direction.West) == types.Square.c2);

    try expect(types.Square.new(types.File.HFILE, types.Rank.RANK8) == types.Square.h8);
    try expect(types.Square.h8.rank() == types.Rank.RANK8);
    try expect(types.Square.h8.file() == types.File.HFILE);
    try expect(types.Square.a1.index() == 0);
    try expect(types.Square.h8.index() == 63);
}

test "types-rank: relative_rank edge cases" {
    try expect(types.Rank.RANK1.relative_rank(types.Color.Black) == types.Rank.RANK8);
    try expect(types.Rank.RANK4.relative_rank(types.Color.Black) == types.Rank.RANK5);
    try expect(types.Rank.RANK6.relative_rank(types.Color.White) == types.Rank.RANK6);
}

test "fen: starting position parse" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen(types.DEFAULT_FEN[0..]);

    try expect(pos.turn == types.Color.White);
    try expect(pos.game_ply == 0);

    try expect(pos.mailbox[types.Square.e1.index()] == types.Piece.WHITE_KING);
    try expect(pos.mailbox[types.Square.d1.index()] == types.Piece.WHITE_QUEEN);
    try expect(pos.mailbox[types.Square.a1.index()] == types.Piece.WHITE_ROOK);
    try expect(pos.mailbox[types.Square.e8.index()] == types.Piece.BLACK_KING);
    try expect(pos.mailbox[types.Square.b8.index()] == types.Piece.BLACK_KNIGHT);
    try expect(pos.mailbox[types.Square.e4.index()] == types.Piece.NO_PIECE);

    try expect(pos.piece_bitboards[types.Piece.WHITE_PAWN.index()] == 0xff00);
    try expect(pos.piece_bitboards[types.Piece.BLACK_PAWN.index()] == 0xff000000000000);
    try expect(pos.piece_bitboards[types.Piece.WHITE_KING.index()] == 0x10);
    try expect(pos.piece_bitboards[types.Piece.BLACK_KING.index()] == 0x1000000000000000);
    try expect(pos.piece_bitboards[types.Piece.WHITE_ROOK.index()] == 0x81);

    try expect(pos.castling_rights() == 0b1111);
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.NO_SQUARE);
}

test "fen: black-to-move and partial castling rights" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b k -"[0..]);
    try expect(pos.turn == types.Color.Black);
    try expect(pos.castling_rights() == castling.right(.Black, .King));
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.NO_SQUARE);

    pos.set_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - -"[0..]);
    try expect(pos.turn == types.Color.White);
    try expect(pos.castling_rights() == castling.NO_RIGHTS);
}

test "fen: an en-passant square that a pawn can capture on is stored" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("rnbqkbnr/pppp1ppp/8/8/3pP3/8/PPPP1PPP/RNBQKBNR b KQkq e3"[0..]);
    try expect(pos.turn == types.Color.Black);
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.e3);
    try expect(pos.mailbox[types.Square.e4.index()] == types.Piece.WHITE_PAWN);
    try expect(pos.mailbox[types.Square.e2.index()] == types.Piece.NO_PIECE);
}

test "fen: an en-passant square that no pawn can capture on is dropped and the board is kept" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3"[0..]);
    try expect(pos.turn == types.Color.Black);
    try expect(pos.history[pos.game_ply].ep_sq == types.Square.NO_SQUARE);
    try expect(pos.mailbox[types.Square.e4.index()] == types.Piece.WHITE_PAWN);
    try expect(pos.mailbox[types.Square.e2.index()] == types.Piece.NO_PIECE);
    try expect(pos.piece_bitboards[types.Piece.WHITE_PAWN.index()] == 0x1000ef00);
}

test "fen: basic_fen board round-trips" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    pos.set_fen(types.DEFAULT_FEN[0..]);
    {
        const out = pos.basic_fen(arena.allocator());
        var it = std.mem.tokenizeScalar(u8, out, ' ');
        const board = it.next().?;
        try expect(std.mem.eql(u8, board, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"));
        try expect(std.mem.eql(u8, it.next().?, "w"));
        try expect(std.mem.eql(u8, it.next().?, "KQkq"));
        try expect(std.mem.eql(u8, it.next().?, "-"));
    }

    pos.set_fen("r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R b KQkq -"[0..]);
    {
        const out = pos.basic_fen(arena.allocator());
        var it = std.mem.tokenizeScalar(u8, out, ' ');
        const board = it.next().?;
        try expect(std.mem.eql(u8, board, "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R"));
        try expect(std.mem.eql(u8, it.next().?, "b"));
    }
}

test "eval: nnue weights load and dimensions" {
    weights.use_embedded();
    try expect(weights.HIDDEN_SIZE == 1024);
    try expect(weights.OUTPUT_SIZE == 8);
    try expect(weights.INPUT_SIZE == 768 * weights.NUM_INPUT_BUCKETS);
    try weights.validate(std.mem.asBytes(weights.MODEL));
    const single = weights.Network(.single);
    const multi = weights.Network(.multi);
    try expect(@sizeOf(weights.NNUEWeights) == @sizeOf(weights.Network(weights.HEAD)));
    if (weights.NUM_INPUT_BUCKETS == 1) {
        try expect(@sizeOf(single) == 1607744);
    } else {
        try expect(weights.NUM_INPUT_BUCKETS == 16);
        try expect(@sizeOf(single) == 25200704);
        try expect(@sizeOf(multi) == 25334400);
    }
    try expect(@offsetOf(single, "layer_1") == 0);
    try expect(@offsetOf(single, "layer_1_bias") == weights.INPUT_SIZE * weights.HIDDEN_SIZE * 2);
    try expect(@offsetOf(single, "head") == @offsetOf(single, "layer_1_bias") + 2048);
    try expect(@offsetOf(weights.head_single.Weights, "layer_2_bias") == 32768);
    try expect(@offsetOf(multi, "layer_1") == 64);
    try expect(@offsetOf(multi, "head") == 64 + weights.INPUT_SIZE * weights.HIDDEN_SIZE * 2 + 2048);
    const head = weights.head_multi.Weights;
    try expect(@offsetOf(head, "l1_weights") == 0);
    try expect(@offsetOf(head, "l1_bias") == 131072);
    try expect(@offsetOf(head, "l2_weights") == 131584);
    try expect(@offsetOf(head, "l2_bias") == 164352);
    try expect(@offsetOf(head, "l3_weights") == 165376);
    try expect(@offsetOf(head, "l3_bias") == 166400);
    try expect(@sizeOf(head) == 166464);
}

fn evaluate_nnue_scalar(pos: *position.Position, comptime turn: types.Color) i32 {
    const accumulator = pos.evaluator.nnue_evaluator.accumulator(pos);
    const pieces = types.popcount_usize(pos.all_all_pieces());
    const bucket = @min((pieces -| 2) / 4, weights.OUTPUT_SIZE - 1);
    const own = if (turn == types.Color.White) &accumulator.white else &accumulator.black;
    const opp = if (turn == types.Color.White) &accumulator.black else &accumulator.white;
    if (weights.HEAD == .multi) return weights.head_multi.evaluate_scalar(&weights.MODEL.head, weights.l1_shift(&weights.MODEL.header), own, opp, bucket);
    const output_weights = &weights.MODEL.head.layer_2[bucket];

    var result: i32 = 0;
    for (0..weights.HIDDEN_SIZE) |i| {
        const own_activation = std.math.clamp(@as(i32, own[i]), 0, 255);
        const opp_activation = std.math.clamp(@as(i32, opp[i]), 0, 255);
        result += own_activation * own_activation * @as(i32, output_weights[i]);
        result += opp_activation * opp_activation * @as(i32, output_weights[weights.HIDDEN_SIZE + i]);
    }

    return @divTrunc((@divTrunc(result, 255) + @as(i32, weights.MODEL.head.layer_2_bias[bucket])) * 400, 255 * 64);
}

test "eval: SIMD inference matches the scalar head" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    const fens = [_][]const u8{
        types.DEFAULT_FEN,
        "r1bq1rk1/ppp2ppp/2np1n2/2b1p3/4P3/2NP1N2/PPP2PPP/R1BQ1RK1 w - - 0 8",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "4k3/8/8/8/3pP3/8/8/3K4 b - - 0 1",
    };

    for (fens) |fen| {
        pos.set_fen(fen);
        try expect(hce.evaluate_nnue_comptime(pos, types.Color.White) == evaluate_nnue_scalar(pos, types.Color.White));
        try expect(hce.evaluate_nnue_comptime(pos, types.Color.Black) == evaluate_nnue_scalar(pos, types.Color.Black));
    }
}

test "eval: king bucket layout is 16-way mirrored half-board" {
    const layout = nnue.INPUT_BUCKET_LAYOUT;
    try expect(layout[types.Square.a1.index()] == 0);
    try expect(layout[types.Square.d1.index()] == 3);
    try expect(layout[types.Square.e1.index()] == layout[types.Square.d1.index()]);
    try expect(layout[types.Square.h1.index()] == layout[types.Square.a1.index()]);
    try expect(layout[types.Square.a2.index()] == 4);
    try expect(layout[types.Square.a5.index()] == 12);
    try expect(layout[types.Square.e8.index()] == 15);
    var max_b: usize = 0;
    for (layout) |b| max_b = @max(max_b, b);
    try expect(max_b == 15);
}

test "eval: determinism same position twice" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq -"[0..]);
    const recomputed = support.network_output(pos);
    try expect(recomputed == support.network_output(pos));

    const stored = hce.evaluate_nnue_comptime(pos, types.Color.White);
    const cached = hce.evaluate_nnue_comptime(pos, types.Color.White);
    try expect(stored == cached);
    try expect(cached == pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.White, pos));
}

test "eval: nnue incremental equals fresh refresh (startpos)" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN[0..]);

    const after_set_fen = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.White, pos);

    pos.evaluator.full_refresh(pos);
    const after_full_refresh = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.White, pos);
    try expect(after_set_fen == after_full_refresh);
}

test "eval: nnue incremental equals fresh refresh after moves" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN[0..]);

    const m1 = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m1);
    const m2 = types.Move.new_from_string(pos, "c7c5"[0..]);
    pos.play_move(types.Color.Black, m2);
    const m3 = types.Move.new_from_string(pos, "g1f3"[0..]);
    pos.play_move(types.Color.White, m3);
    const m4 = types.Move.new_from_string(pos, "d7d6"[0..]);
    pos.play_move(types.Color.Black, m4);

    const incremental_w = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.White, pos);
    const incremental_b = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.Black, pos);

    pos.evaluator.full_refresh(pos);
    const fresh_w = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.White, pos);
    const fresh_b = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.Black, pos);

    try expect(incremental_w == fresh_w);
    try expect(incremental_b == fresh_b);
}

test "eval: nnue king mirror crossing matches fresh (white e1d1)" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("4k3/8/8/8/8/8/8/4K3 w - -"[0..]);

    const mv = types.Move.new_from_string(pos, "e1d1"[0..]);
    pos.play_move(types.Color.White, mv);
    try support.expect_nnue_matches_fresh(pos);

    pos.undo_move(types.Color.White, mv);
    try support.expect_nnue_matches_fresh(pos);
}

test "eval: nnue king mirror crossing matches fresh (black e8d8)" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("4k3/8/8/8/8/8/8/4K3 b - -"[0..]);

    const mv = types.Move.new_from_string(pos, "e8d8"[0..]);
    pos.play_move(types.Color.Black, mv);
    try support.expect_nnue_matches_fresh(pos);

    pos.undo_move(types.Color.Black, mv);
    try support.expect_nnue_matches_fresh(pos);
}

test "eval: nnue white castling OO matches fresh (bucket change)" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq -"[0..]);

    const mv = types.Move.new_from_string(pos, "e1g1"[0..]);
    pos.play_move(types.Color.White, mv);
    try support.expect_nnue_matches_fresh(pos);

    pos.undo_move(types.Color.White, mv);
    try support.expect_nnue_matches_fresh(pos);
}

test "eval: nnue black castling OOO matches fresh" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("r3k2r/8/8/8/8/8/8/R3K2R b KQkq -"[0..]);

    const mv = types.Move.new_from_string(pos, "e8c8"[0..]);
    pos.play_move(types.Color.Black, mv);
    try support.expect_nnue_matches_fresh(pos);

    pos.undo_move(types.Color.Black, mv);
    try support.expect_nnue_matches_fresh(pos);
}

test "eval: nnue king capture into another bucket, then further moves, matches fresh" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("4k3/8/8/8/8/8/3p3P/4K3 w - -"[0..]);

    const capture = types.Move.new_from_string(pos, "e1d2"[0..]);
    pos.play_move(types.Color.White, capture);
    try support.expect_nnue_matches_fresh(pos);

    const reply = types.Move.new_from_string(pos, "e8e7"[0..]);
    pos.play_move(types.Color.Black, reply);
    try support.expect_nnue_matches_fresh(pos);

    const push = types.Move.new_from_string(pos, "h2h4"[0..]);
    pos.play_move(types.Color.White, push);
    try support.expect_nnue_matches_fresh(pos);

    pos.undo_move(types.Color.White, push);
    pos.undo_move(types.Color.Black, reply);
    try support.expect_nnue_matches_fresh(pos);
    pos.undo_move(types.Color.White, capture);
    try support.expect_nnue_matches_fresh(pos);
}

test "eval: nnue finny revisit after leaving and returning to bucket" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("4k3/8/8/8/8/8/8/4K3 w - -"[0..]);

    const m1 = types.Move.new_from_string(pos, "e1d1"[0..]);
    pos.play_move(types.Color.White, m1);
    try support.expect_nnue_matches_fresh(pos);

    const m2 = types.Move.new_from_string(pos, "e8f8"[0..]);
    pos.play_move(types.Color.Black, m2);
    try support.expect_nnue_matches_fresh(pos);

    const m3 = types.Move.new_from_string(pos, "d1e1"[0..]);
    pos.play_move(types.Color.White, m3);
    try support.expect_nnue_matches_fresh(pos);

    pos.undo_move(types.Color.White, m3);
    try support.expect_nnue_matches_fresh(pos);
    pos.undo_move(types.Color.Black, m2);
    try support.expect_nnue_matches_fresh(pos);
    pos.undo_move(types.Color.White, m1);
    try support.expect_nnue_matches_fresh(pos);
}

test "eval: nnue incremental equals fresh after a capture" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen(types.DEFAULT_FEN[0..]);

    const m1 = types.Move.new_from_string(pos, "e2e4"[0..]);
    pos.play_move(types.Color.White, m1);
    const m2 = types.Move.new_from_string(pos, "d7d5"[0..]);
    pos.play_move(types.Color.Black, m2);
    const m3 = types.Move.new_from_string(pos, "e4d5"[0..]);
    pos.play_move(types.Color.White, m3);

    const incremental = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.Black, pos);
    pos.evaluator.full_refresh(pos);
    const fresh = pos.evaluator.nnue_evaluator.evaluate_uncached(types.Color.Black, pos);
    try expect(incremental == fresh);
}

test "eval: hce material draw classification" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    const bare_kings = "4k3/8/8/8/8/8/8/4K3 w - -";
    const knight_against_king = "4k3/8/8/8/8/8/8/3NK3 w - -";
    const bishop_against_king = "4k3/8/8/8/8/8/8/3BK3 w - -";
    const queen_against_king = "4k3/8/8/8/8/8/8/3QK3 w - -";
    const rook_against_king = "4k3/8/8/8/8/8/8/3RK3 w - -";
    const two_knights_against_king = "2NNK3/8/8/8/8/8/8/4k3 w - -";

    pos.set_fen(bare_kings);
    try expect(hce.is_material_draw(pos));
    try expect(hce.is_material_drawish(pos));

    pos.set_fen(knight_against_king);
    try expect(hce.is_material_draw(pos));
    try expect(hce.is_material_drawish(pos));

    pos.set_fen(bishop_against_king);
    try expect(hce.is_material_draw(pos));
    try expect(!hce.is_material_drawish(pos));

    pos.set_fen(queen_against_king);
    try expect(!hce.is_material_draw(pos));
    try expect(!hce.is_material_drawish(pos));

    pos.set_fen(rook_against_king);
    try expect(!hce.is_material_draw(pos));
    try expect(!hce.is_material_drawish(pos));

    pos.set_fen(two_knights_against_king);
    try expect(!hce.is_material_draw(pos));
    try expect(hce.is_material_drawish(pos));
}

test "search: mate in 1 (white back-rank)" {
    var f = try support.SearchFixture.init("6k1/5ppp/8/8/8/8/8/R6K w - -");
    defer f.deinit();

    const score = f.run(4);

    try expect(@as(i32, @intCast(@abs(score))) >= hce.MateScore - hce.MaxMate);
    try expect(score > 0);
    try expect(f.searcher.best_move.to_u16() == f.move("a1a8").to_u16());
}

test "search: mate in 1 (black back-rank)" {
    var f = try support.SearchFixture.init("r6k/8/8/8/8/8/5PPP/6K1 b - -");
    defer f.deinit();

    const score = f.run(4);

    try expect(@as(i32, @intCast(@abs(score))) >= hce.MateScore - hce.MaxMate);
    try expect(score > 0);
    try expect(f.searcher.best_move.to_u16() == f.move("a8a1").to_u16());
}

test "search: forced node-limited search continues after reporting mate" {
    var f = try support.SearchFixture.init("2r3k1/p4p2/3Rp2p/1p2P1pK/8/1P4P1/P3Q2P/1q6 b - - 0 1");
    defer f.deinit();
    const more_nodes_than_the_mate_in_three_takes: u64 = 30_000;
    f.searcher.max_nodes = more_nodes_than_the_mate_in_three_takes;

    const score = f.run(null);
    const mate_moves = @divTrunc(hce.MateScore - @as(i32, @intCast(@abs(score))) + 1, 2);

    try expect(f.searcher.total_nodes() >= more_nodes_than_the_mate_in_three_takes);
    try expect(score >= hce.MateScore - hce.MaxMate);
    try expect(mate_moves == 3);
}

test "search: stalemate scores as draw" {
    var f = try support.SearchFixture.init("7k/5Q2/6K1/8/8/8/8/8 b - -");
    defer f.deinit();
    try expect(f.pos.legal_moves().len == 0);
    try expect(!f.pos.in_check(types.Color.Black));

    try expect(f.run(4) == 0);
}

const SearchOutcome = struct { score: i32, nodes: u64 };

fn search_start_position_with_new_searcher(f: *support.SearchFixture) SearchOutcome {
    f.pos.set_fen(types.DEFAULT_FEN);
    f.renew_searcher();
    const score = f.run(7);
    return .{ .score = score, .nodes = f.searcher.shared.nodes };
}

test "search: deterministic node counts and score" {
    var first = try support.SearchFixture.init(types.DEFAULT_FEN);
    defer first.deinit();
    var second = try support.SearchFixture.init(types.DEFAULT_FEN);
    defer second.deinit();

    const cold = search_start_position_with_new_searcher(&first);
    const cold_again = search_start_position_with_new_searcher(&second);
    const warm = search_start_position_with_new_searcher(&first);

    try expect(cold.nodes > 0);
    try std.testing.expectEqual(cold, cold_again);
    try std.testing.expectEqual(cold, warm);
}

test "zobrist: castling rights are part of the position key" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    const with_rights = pos.hash;

    pos.set_fen("r3k2r/8/8/8/8/8/8/R3K2R w - - 0 1");
    try expect(pos.hash != with_rights);
}

test "fen: halfmove clock is preserved" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);
    pos.set_fen("7k/8/8/8/8/8/8/KR6 w - - 99 1");
    try expect(pos.history[pos.game_ply].fifty == 99);
}

test "fen: start_ply follows fullmove and side to move" {
    support.init_tables();

    const pos = try support.new_position();
    defer support.destroy_position(pos);

    pos.set_fen("8/5k2/8/8/3P4/8/5K2/8 w - - 0 1");
    try expect(pos.start_ply == 0);
    try expect(pos.absolute_ply() == 0);

    pos.set_fen("8/5k2/8/8/3P4/8/5K2/8 w - - 0 60");
    try expect(pos.start_ply == (60 - 1) * 2);
    try expect(pos.game_ply == 0);
    try expect(pos.absolute_ply() == (60 - 1) * 2);

    pos.set_fen("8/5k2/8/8/3P4/8/5K2/8 b - - 0 60");
    try expect(pos.start_ply == (60 - 1) * 2 + 1);
}

test "search: maximum-mobility position exceeds 128 quiet moves safely" {
    var f = try support.SearchFixture.init("R6R/3Q4/1Q4Q1/4Q3/2Q4Q/Q4Q2/pp1Q4/kBNN1KB1 w - - 0 1");
    defer f.deinit();

    var moves: types.MoveList = .{};
    f.pos.generate_legal_moves(types.Color.White, &moves);
    var quiets: usize = 0;
    for (moves.items()) |move| {
        if (!move.is_capture()) quiets += 1;
    }
    try expect(quiets > 128);

    _ = f.run(1);
}

test "qsearch: checkmate takes precedence over fifty-move draw" {
    const old_contempt = search.contempt;
    defer search.contempt = old_contempt;
    search.contempt = 100;

    var f = try support.SearchFixture.init("7k/6Q1/6K1/8/8/8/8/8 b - - 100 1");
    defer f.deinit();

    const score = f.quiescence(-hce.MateScore, hce.MateScore);
    try expect(score <= -hce.MateScore + hce.MaxMate);
}

test "qsearch: stalemate precedes stand-pat and TT cutoffs" {
    const old_contempt = search.contempt;
    defer search.contempt = old_contempt;
    search.contempt = 100;

    var f = try support.SearchFixture.init("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1");
    defer f.deinit();

    tt.GlobalTT.set(f.pos.hash, tt.Item{
        .score = 37,
        .static_eval = 0,
        .bestmove = types.Move.empty(),
        .flag = tt.Bound.Exact,
        .depth = 0,
        .was_pv = 0,
        .key = @as(u32, @truncate(f.pos.hash)),
        .age = tt.GlobalTT.age,
    });

    const tt_score = f.quiescence(-hce.MateScore, hce.MateScore);
    try expect(tt_score == -search.contempt);

    tt.GlobalTT.clear();
    const stand_pat_score = f.quiescence(-hce.MateScore, -hce.MateScore + 1);
    try expect(stand_pat_score == -search.contempt);
}

test "qsearch: contempt draw keeps fail-soft provenance" {
    const old_contempt = search.contempt;
    defer search.contempt = old_contempt;
    search.contempt = -100;

    var f = try support.SearchFixture.init("4k3/8/2n5/1B6/8/8/8/4K3 w - - 0 1");
    defer f.deinit();

    const draw_score = -search.contempt;
    const static_eval = hce.evaluate_comptime(f.pos, types.Color.White);
    try expect(static_eval < draw_score);
    const beta = @divTrunc(static_eval + draw_score, 2);
    const score = f.quiescence(beta - 1, beta);
    try expect(score == draw_score);
    try expect(tt.GlobalTT.get(f.pos.hash) == null);
}

fn new_uci() !*interface.UciInterface {
    support.init_engine();
    const ui = try std.testing.allocator.create(interface.UciInterface);
    ui.init();
    return ui;
}

fn destroy_uci(ui: *interface.UciInterface) void {
    ui.deinit();
    std.testing.allocator.destroy(ui);
}

test "uci: the search history holds the root key before any position command and after ucinewgame" {
    const ui = try new_uci();
    defer destroy_uci(ui);
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);

    try std.testing.expectEqualSlices(u64, &.{ui.position.hash}, ui.searcher.hash_history.items);

    try expect(try ui.handle_command("position startpos moves e2e4 e7e5\n", &out));
    try std.testing.expectEqual(@as(usize, 3), ui.searcher.hash_history.items.len);
    try std.testing.expectEqual(ui.position.hash, ui.searcher.hash_history.items[2]);

    try expect(try ui.handle_command("ucinewgame\n", &out));
    try std.testing.expectEqualSlices(u64, &.{ui.position.hash}, ui.searcher.hash_history.items);
}

test "uci: a command-line argument is accepted only when its first word is a UCI command" {
    for ([_][]const u8{ "quit", "isready", "go depth 5", "setoption name Hash value 64", "genfens 100 seed 1 book None", "spsa++" }) |argument| {
        try expect(interface.is_command(argument));
    }
    for ([_][]const u8{ "", "--version", "--help", "tbfliter", "Go depth 5", "benchmark" }) |argument| {
        try expect(!interface.is_command(argument));
    }
}

test "uci: startup commands run in order and nothing runs after quit" {
    const ui = try new_uci();
    defer destroy_uci(ui);
    var buf: [256]u8 = undefined;

    var out = std.Io.Writer.fixed(&buf);
    try expect(try ui.run_commands(&.{ "position startpos moves e2e4", "isready" }, &out));
    try std.testing.expectEqualStrings("readyok" ++ search.LINE_ENDING, out.buffered());
    try std.testing.expectEqual(@as(usize, 2), ui.searcher.hash_history.items.len);

    out = std.Io.Writer.fixed(&buf);
    try expect(!try ui.run_commands(&.{ "quit", "isready" }, &out));
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
}
