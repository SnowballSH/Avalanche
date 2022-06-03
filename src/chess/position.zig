const std = @import("std");
const types = @import("./types.zig");
const tables = @import("./tables.zig");
const zobrist = @import("./zobrist.zig");
const utils = @import("./utils.zig");

// Stores information for undoing a move.
pub const UndoInfo = packed struct {
    // Bitboard of changed pieces
    entry: types.Bitboard,

    // piece that was captured
    captured: types.Piece,

    // EP square
    ep_sq: types.Square,

    // Fifty-move rule counter
    fifty: u16,

    pub fn new() UndoInfo {
        return UndoInfo{
            .entry = 0,
            .captured = types.Piece.NO_PIECE,
            .ep_sq = types.Square.NO_SQUARE,
            .fifty = 0,
        };
    }

    pub fn from(old: UndoInfo) UndoInfo {
        return UndoInfo{
            .entry = old.entry,
            .captured = types.Piece.NO_PIECE,
            .ep_sq = types.Square.NO_SQUARE,
            .fifty = old.fifty + 1,
        };
    }
};

// A chess position
pub const Position = struct {
    // Bitboards of each piece
    piece_bitboards: [types.N_PIECES]types.Bitboard,
    // Mailbox representation of the board
    mailbox: [types.N_SQUARES]types.Piece,
    // Current player
    turn: types.Color,
    // Ply since game started
    game_ply: u32,
    // Zobrist Hash
    hash: u64,

    // History of Undo information
    history: [256]UndoInfo,

    // Stores the enemy pieces that are attacking the king
    checkers: types.Bitboard,

    // Stores the pieces that are pinned to the king
    pinned: types.Bitboard,

    pub fn new() Position {
        var pos = std.mem.zeroes(Position);

        std.mem.set(types.Piece, pos.mailbox[0..types.N_SQUARES], types.Piece.NO_PIECE);
        pos.history[0] = UndoInfo.new();

        return pos;
    }

    pub fn debug_print(self: Position) void {
        const line = "   +---+---+---+---+---+---+---+---+\n";
        const letters = "     A   B   C   D   E   F   G   H\n";
        std.debug.print("{s}", .{letters});
        var i: i32 = 56;
        while (i >= 0) : (i -= 8) {
            std.debug.print("{s} {} ", .{ line, @divFloor(i, 8) + 1 });
            var j: i32 = 0;
            while (j < 8) : (j += 1) {
                std.debug.print("| {c} ", .{types.PieceString[self.mailbox[@intCast(usize, i + j)].index()]});
            }
            std.debug.print("| {}\n", .{@divFloor(i, 8) + 1});
        }
        std.debug.print("{s}", .{line});
        std.debug.print("{s}\n", .{letters});

        var s = if (self.turn == types.Color.White) "White" else "Black";

        std.debug.print("{s} to move\n", .{s});
        std.debug.print("Hash: 0x{x}\n", .{self.hash});
    }

    pub fn set_fen(self: *Position, fen: []const u8) void {
        self.* = Position.new();
        var sq: i32 = @intCast(i32, @enumToInt(types.Square.a8));
        var tokens = std.mem.tokenize(u8, fen, " ");
        var bd = tokens.next().?;
        for (bd) |ch| {
            if (std.ascii.isDigit(ch)) {
                sq += @intCast(i32, ch - '0') * @enumToInt(types.Direction.East);
            } else if (ch == '/') {
                sq += @enumToInt(types.Direction.South) * 2;
            } else {
                self.add_piece(@intToEnum(types.Piece, utils.first_index(u8, types.PieceString[0..], ch).?), @intToEnum(types.Square, sq));
                sq += 1;
            }
        }

        var turn = tokens.next().?;
        if (std.mem.eql(u8, turn, "w")) {
            self.turn = types.Color.White;
        } else {
            self.turn = types.Color.Black;
            self.hash ^= zobrist.TurnHash;
        }

        self.history[self.game_ply].entry = types.AllCastlingMask;
        var castle = tokens.next().?;
        for (castle) |ch| {
            switch (ch) {
                'K' => {
                    self.history[self.game_ply].entry &= ~types.WhiteOOMask;
                },
                'Q' => {
                    self.history[self.game_ply].entry &= ~types.WhiteOOOMask;
                },
                'k' => {
                    self.history[self.game_ply].entry &= ~types.BlackOOMask;
                },
                'q' => {
                    self.history[self.game_ply].entry &= ~types.BlackOOOMask;
                },
                else => {},
            }
        }
    }

    pub inline fn phase(self: *Position) usize {
        var val: usize = 0;
        val += @intCast(usize, types.popcount(self.piece_bitboards[types.Piece.WHITE_KNIGHT.index()] | self.piece_bitboards[types.Piece.WHITE_BISHOP.index()] | self.piece_bitboards[types.Piece.BLACK_KNIGHT.index()] | self.piece_bitboards[types.Piece.BLACK_BISHOP.index()]));
        val += @intCast(usize, types.popcount(self.piece_bitboards[types.Piece.WHITE_ROOK.index()] | self.piece_bitboards[types.Piece.BLACK_ROOK.index()]) * 2);
        val += @intCast(usize, types.popcount(self.piece_bitboards[types.Piece.WHITE_QUEEN.index()] | self.piece_bitboards[types.Piece.BLACK_QUEEN.index()]) * 4);
        return val;
    }

    pub inline fn add_piece(self: *Position, pc: types.Piece, sq: types.Square) void {
        self.mailbox[sq.index()] = pc;
        self.piece_bitboards[pc.index()] |= types.SquareIndexBB[sq.index()];
        self.hash ^= zobrist.ZobristTable[pc.index()][sq.index()];
    }

    pub inline fn remove_piece(self: *Position, sq: types.Square) void {
        const pc = self.mailbox[sq.index()].index();
        self.hash ^= zobrist.ZobristTable[pc][sq.index()];
        self.piece_bitboards[pc] &= ~types.SquareIndexBB[sq.index()];
        self.mailbox[sq.index()] = types.Piece.NO_PIECE;
    }

    pub fn move_piece(self: *Position, from: types.Square, to: types.Square) void {
        self.remove_piece(to);
        self.move_piece_quiet(from, to);
    }

    // DO NOT CALL IF DESTINATION IS NOT EMPTY
    pub inline fn move_piece_quiet(self: *Position, from: types.Square, to: types.Square) void {
        self.hash ^= zobrist.ZobristTable[self.mailbox[from.index()].index()][from.index()] ^ zobrist.ZobristTable[self.mailbox[from.index()].index()][to.index()];

        self.piece_bitboards[self.mailbox[from.index()].index()] ^= types.SquareIndexBB[from.index()] | types.SquareIndexBB[to.index()];
        self.mailbox[to.index()] = self.mailbox[from.index()];
        self.mailbox[from.index()] = types.Piece.NO_PIECE;
    }

    pub inline fn diagonal_sliders(self: Position, comptime color: types.Color) types.Bitboard {
        return if (color == types.Color.White)
            self.piece_bitboards[types.Piece.WHITE_BISHOP.index()] | self.piece_bitboards[types.Piece.WHITE_QUEEN.index()]
        else
            self.piece_bitboards[types.Piece.BLACK_BISHOP.index()] | self.piece_bitboards[types.Piece.BLACK_QUEEN.index()];
    }

    pub inline fn orthogonal_sliders(self: Position, comptime color: types.Color) types.Bitboard {
        return if (color == types.Color.White)
            self.piece_bitboards[types.Piece.WHITE_ROOK.index()] | self.piece_bitboards[types.Piece.WHITE_QUEEN.index()]
        else
            self.piece_bitboards[types.Piece.BLACK_ROOK.index()] | self.piece_bitboards[types.Piece.BLACK_QUEEN.index()];
    }

    pub inline fn all_pieces(self: Position, comptime color: types.Color) types.Bitboard {
        return if (color == types.Color.White)
            self.piece_bitboards[types.Piece.WHITE_PAWN.index()] | self.piece_bitboards[types.Piece.WHITE_KNIGHT.index()] | self.piece_bitboards[types.Piece.WHITE_BISHOP.index()] | self.piece_bitboards[types.Piece.WHITE_ROOK.index()] | self.piece_bitboards[types.Piece.WHITE_QUEEN.index()] | self.piece_bitboards[types.Piece.WHITE_KING.index()]
        else
            self.piece_bitboards[types.Piece.BLACK_PAWN.index()] | self.piece_bitboards[types.Piece.BLACK_KNIGHT.index()] | self.piece_bitboards[types.Piece.BLACK_BISHOP.index()] | self.piece_bitboards[types.Piece.BLACK_ROOK.index()] | self.piece_bitboards[types.Piece.BLACK_QUEEN.index()] | self.piece_bitboards[types.Piece.BLACK_KING.index()];
    }

    pub inline fn attackers_from(self: Position, comptime color: types.Color, sq: types.Square, occ: types.Bitboard) types.Bitboard {
        if (color == types.Color.White) {
            const p = (tables.BlackPawnAttacks[sq.index()] & self.piece_bitboards[types.Piece.WHITE_PAWN.index()]);
            const n = (tables.get_attacks(types.PieceType.Knight, sq, occ) & self.piece_bitboards[types.Piece.WHITE_KNIGHT.index()]);
            const b = (tables.get_attacks(types.PieceType.Bishop, sq, occ) & self.diagonal_sliders(color));
            const r = (tables.get_attacks(types.PieceType.Rook, sq, occ) & self.orthogonal_sliders(color));
            return p | n | b | r;
        } else {
            const p = (tables.WhitePawnAttacks[sq.index()] & self.piece_bitboards[types.Piece.BLACK_PAWN.index()]);
            const n = (tables.get_attacks(types.PieceType.Knight, sq, occ) & self.piece_bitboards[types.Piece.BLACK_KNIGHT.index()]);
            const b = (tables.get_attacks(types.PieceType.Bishop, sq, occ) & self.diagonal_sliders(color));
            const r = (tables.get_attacks(types.PieceType.Rook, sq, occ) & self.orthogonal_sliders(color));
            return p | n | b | r;
        }
    }

    pub inline fn in_check(self: Position, comptime color: types.Color) bool {
        comptime var king: types.Piece = types.Piece.new_comptime(color, types.PieceType.King);
        comptime var opp = if (color == types.Color.White) types.Color.Black else types.Color.White;
        return self.attackers_from(opp, @intToEnum(types.Square, types.lsb(self.piece_bitboards[king.index()])), self.all_pieces(types.Color.White) | self.all_pieces(types.Color.Black)) != 0;
    }

    pub inline fn has_non_pawns(self: Position) bool {
        return self.piece_bitboards[types.Piece.WHITE_PAWN.index()] | self.piece_bitboards[types.Piece.BLACK_PAWN.index()] | self.piece_bitboards[types.Piece.WHITE_KING.index()] | self.piece_bitboards[types.Piece.BLACK_KING.index()] != self.all_pieces(types.Color.White) | self.all_pieces(types.Color.Black);
    }

    // Moving pieces

    pub fn play_move(self: *Position, comptime color: types.Color, move: types.Move) void {
        self.turn = self.turn.invert();
        self.hash ^= zobrist.TurnHash;
        self.game_ply += 1;
        self.history[self.game_ply] = UndoInfo.from(self.history[self.game_ply - 1]);

        var flags = move.get_flags();
        self.history[self.game_ply].entry |= types.SquareIndexBB[move.to] | types.SquareIndexBB[move.from];

        var pt = self.mailbox[move.from].piece_type();
        if (pt == types.PieceType.Pawn or move.is_capture()) {
            self.history[self.game_ply].fifty = 0;
        }

        switch (flags) {
            types.MoveFlags.QUIET => {
                self.move_piece_quiet(move.get_from(), move.get_to());
            },
            types.MoveFlags.DOUBLE_PUSH => {
                self.move_piece_quiet(move.get_from(), move.get_to());

                self.history[self.game_ply].ep_sq = move.get_from().add(types.Direction.North.relative_dir(color));
                self.hash ^= zobrist.EnPassantHash[self.history[self.game_ply].ep_sq.file().index()];
            },
            types.MoveFlags.OO => {
                if (color == types.Color.White) {
                    self.move_piece_quiet(types.Square.e1, types.Square.g1);
                    self.move_piece_quiet(types.Square.h1, types.Square.f1);
                } else {
                    self.move_piece_quiet(types.Square.e8, types.Square.g8);
                    self.move_piece_quiet(types.Square.h8, types.Square.f8);
                }
            },
            types.MoveFlags.OOO => {
                if (color == types.Color.White) {
                    self.move_piece_quiet(types.Square.e1, types.Square.c1);
                    self.move_piece_quiet(types.Square.a1, types.Square.d1);
                } else {
                    self.move_piece_quiet(types.Square.e8, types.Square.c8);
                    self.move_piece_quiet(types.Square.a8, types.Square.d8);
                }
            },
            types.MoveFlags.EN_PASSANT => {
                self.move_piece_quiet(move.get_from(), move.get_to());
                self.remove_piece(move.get_to().add(types.Direction.South.relative_dir(color)));
            },
            else => {
                var index = @enumToInt(flags);
                switch (index) {
                    types.PR_KNIGHT => {
                        self.remove_piece(move.get_from());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Knight), move.get_to());
                    },
                    types.PR_BISHOP => {
                        self.remove_piece(move.get_from());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Bishop), move.get_to());
                    },
                    types.PR_ROOK => {
                        self.remove_piece(move.get_from());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Rook), move.get_to());
                    },
                    types.PR_QUEEN => {
                        self.remove_piece(move.get_from());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Queen), move.get_to());
                    },
                    types.PC_KNIGHT => {
                        self.remove_piece(move.get_from());
                        self.history[self.game_ply].captured = self.mailbox[move.to];
                        self.remove_piece(move.get_to());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Knight), move.get_to());
                    },
                    types.PC_BISHOP => {
                        self.remove_piece(move.get_from());
                        self.history[self.game_ply].captured = self.mailbox[move.to];
                        self.remove_piece(move.get_to());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Bishop), move.get_to());
                    },
                    types.PC_ROOK => {
                        self.remove_piece(move.get_from());
                        self.history[self.game_ply].captured = self.mailbox[move.to];
                        self.remove_piece(move.get_to());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Rook), move.get_to());
                    },
                    types.PC_QUEEN => {
                        self.remove_piece(move.get_from());
                        self.history[self.game_ply].captured = self.mailbox[move.to];
                        self.remove_piece(move.get_to());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Queen), move.get_to());
                    },
                    else => {
                        if (flags == types.MoveFlags.CAPTURE) {
                            var c = self.mailbox[move.to];
                            self.history[self.game_ply].captured = c;
                            self.move_piece(move.get_from(), move.get_to());
                        }
                    },
                }
            },
        }
    }

    pub fn undo_move(self: *Position, comptime color: types.Color, move: types.Move) void {
        var flags = move.get_flags();
        comptime var opp = if (color == types.Color.White) types.Color.Black else types.Color.White;

        switch (flags) {
            types.MoveFlags.QUIET => {
                self.move_piece_quiet(move.get_to(), move.get_from());
            },
            types.MoveFlags.DOUBLE_PUSH => {
                self.move_piece_quiet(move.get_to(), move.get_from());
                self.hash ^= zobrist.EnPassantHash[self.history[self.game_ply].ep_sq.file().index()];
            },
            types.MoveFlags.OO => {
                if (color == types.Color.White) {
                    self.move_piece_quiet(types.Square.g1, types.Square.e1);
                    self.move_piece_quiet(types.Square.f1, types.Square.h1);
                } else {
                    self.move_piece_quiet(types.Square.g8, types.Square.e8);
                    self.move_piece_quiet(types.Square.f8, types.Square.h8);
                }
            },
            types.MoveFlags.OOO => {
                if (color == types.Color.White) {
                    self.move_piece_quiet(types.Square.c1, types.Square.e1);
                    self.move_piece_quiet(types.Square.d1, types.Square.a1);
                } else {
                    self.move_piece_quiet(types.Square.c8, types.Square.e8);
                    self.move_piece_quiet(types.Square.d8, types.Square.a8);
                }
            },
            types.MoveFlags.EN_PASSANT => {
                self.move_piece_quiet(move.get_to(), move.get_from());
                self.add_piece(types.Piece.new_comptime(opp, types.PieceType.Pawn), move.get_to().add(types.Direction.South.relative_dir(color)));
            },
            else => {
                var index = @enumToInt(flags);
                switch (index) {
                    types.PR_KNIGHT, types.PR_BISHOP, types.PR_ROOK, types.PR_QUEEN => {
                        self.remove_piece(move.get_to());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Pawn), move.get_from());
                    },
                    types.PC_KNIGHT, types.PC_BISHOP, types.PC_ROOK, types.PC_QUEEN => {
                        self.remove_piece(move.get_to());
                        self.add_piece(types.Piece.new_comptime(color, types.PieceType.Pawn), move.get_from());
                        self.add_piece(self.history[self.game_ply].captured, move.get_to());
                    },
                    else => {
                        if (flags == types.MoveFlags.CAPTURE) {
                            self.move_piece(move.get_to(), move.get_from());
                            self.add_piece(self.history[self.game_ply].captured, move.get_to());
                        }
                    },
                }
            },
        }

        self.turn = self.turn.invert();
        self.hash ^= zobrist.TurnHash;
        self.game_ply -= 1;
    }

    pub inline fn play_null_move(self: *Position) void {
        self.turn = self.turn.invert();
        self.hash ^= zobrist.TurnHash;
        self.game_ply += 1;
        self.history[self.game_ply] = UndoInfo.from(self.history[self.game_ply - 1]);

        if (self.history[self.game_ply - 1].ep_sq != types.Square.NO_SQUARE) {
            self.hash ^= zobrist.EnPassantHash[self.history[self.game_ply - 1].ep_sq.file().index()];
        }
    }

    pub inline fn undo_null_move(self: *Position) void {
        self.turn = self.turn.invert();
        self.hash ^= zobrist.TurnHash;
        self.game_ply -= 1;

        if (self.history[self.game_ply].ep_sq != types.Square.NO_SQUARE) {
            self.hash ^= zobrist.EnPassantHash[self.history[self.game_ply].ep_sq.file().index()];
        }
    }

    // Generate all LEGAL moves
    pub fn generate_legal_moves(self: *Position, comptime color: types.Color, list: *std.ArrayList(types.Move)) void {
        comptime var opp = if (color == types.Color.White) types.Color.Black else types.Color.White;

        const us_bb = self.all_pieces(color);
        const them_bb = self.all_pieces(opp);
        const all_bb = us_bb | them_bb;

        const our_king = @intToEnum(types.Square, types.lsb(self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.King).index()]));
        const their_king = @intToEnum(types.Square, types.lsb(self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.King).index()]));

        const our_diag_sliders = self.diagonal_sliders(color);
        const their_diag_sliders = self.diagonal_sliders(opp);
        const our_ortho_sliders = self.orthogonal_sliders(color);
        const their_ortho_sliders = self.orthogonal_sliders(opp);

        // Bitboards just for temp storage
        var b1: types.Bitboard = 0;
        var b2: types.Bitboard = 0;
        var b3: types.Bitboard = 0;

        comptime var rel_north = if (color == types.Color.White) types.Direction.North else types.Direction.South;
        comptime var rel_south = if (color == types.Color.White) types.Direction.South else types.Direction.North;
        comptime var rel_northwest = if (color == types.Color.White) types.Direction.NorthWest else types.Direction.SouthEast;
        comptime var rel_northeast = if (color == types.Color.White) types.Direction.NorthEast else types.Direction.SouthWest;

        // Squares King cannot go to
        var danger: types.Bitboard = 0;

        const their_pawns = self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Pawn).index()];

        danger |= tables.get_pawn_attacks_bb(opp, their_pawns) | tables.get_attacks(types.PieceType.King, their_king, all_bb);

        b1 = self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Knight).index()];
        while (b1 != 0) {
            danger |= tables.get_attacks(types.PieceType.Knight, types.pop_lsb(&b1), all_bb);
        }

        b1 = their_diag_sliders;
        while (b1 != 0) {
            danger |= tables.get_attacks(types.PieceType.Bishop, types.pop_lsb(&b1), all_bb ^ types.SquareIndexBB[our_king.index()]);
        }

        b1 = their_ortho_sliders;
        while (b1 != 0) {
            danger |= tables.get_attacks(types.PieceType.Rook, types.pop_lsb(&b1), all_bb ^ types.SquareIndexBB[our_king.index()]);
        }

        // King moves
        b1 = tables.get_attacks(types.PieceType.King, our_king, all_bb) & ~(us_bb | danger);

        types.Move.make_all(types.MoveFlags.QUIET, our_king, b1 & ~them_bb, list);
        types.Move.make_all(types.MoveFlags.CAPTURE, our_king, b1 & them_bb, list);

        var capture_mask: types.Bitboard = 0;
        var quiet_mask: types.Bitboard = 0;
        var sq: types.Square = types.Square.NO_SQUARE;

        self.checkers = tables.get_attacks(types.PieceType.Knight, our_king, all_bb) & self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Knight).index()];
        self.checkers |= tables.get_pawn_attacks(color, our_king) & self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Pawn).index()];

        var candidates: types.Bitboard = tables.get_attacks(types.PieceType.Rook, our_king, them_bb) & their_ortho_sliders;
        candidates |= tables.get_attacks(types.PieceType.Bishop, our_king, them_bb) & their_diag_sliders;

        self.pinned = 0;

        while (candidates != 0) {
            sq = types.pop_lsb(&candidates);
            b1 = tables.SquaresBetween[our_king.index()][sq.index()] & us_bb;

            if (b1 == 0) {
                // No our piece between king and slider: check
                self.checkers ^= types.SquareIndexBB[sq.index()];
            } else if ((b1 & (b1 - 1)) == 0) {
                // Only one of our piece between king and slider: pinned
                self.pinned ^= b1;
            }
        }

        const not_pinned: types.Bitboard = ~self.pinned;

        switch (types.popcount(self.checkers)) {
            2 => {
                // Double check: we have to move the king
                return;
            },
            1 => {
                // Single check: Move, capture, or block

                var checker_sq = @intToEnum(types.Square, types.lsb(self.checkers));

                switch (self.mailbox[checker_sq.index()]) {
                    types.Piece.new_comptime(opp, types.PieceType.Pawn) => {
                        var ep = self.history[self.game_ply].ep_sq;
                        if (self.checkers == types.shift_bitboard(types.SquareIndexBB[ep.index()], rel_south)) {
                            b1 = tables.get_pawn_attacks(opp, ep) & self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()] & not_pinned;
                            while (b1 != 0) {
                                list.append(types.Move.new_from_to_flag(types.pop_lsb(&b1), ep, types.MoveFlags.EN_PASSANT)) catch {};
                            }
                        }

                        // If checker is a pawn, then we can only move or capture.
                        b1 = self.attackers_from(color, checker_sq, all_bb) & not_pinned;
                        while (b1 != 0) {
                            list.append(types.Move.new_from_to_flag(types.pop_lsb(&b1), checker_sq, types.MoveFlags.CAPTURE)) catch {};
                        }

                        return;
                    },

                    types.Piece.new_comptime(opp, types.PieceType.Knight) => {
                        // If checker is a knight, then we can only move or capture.
                        b1 = self.attackers_from(color, checker_sq, all_bb) & not_pinned;
                        while (b1 != 0) {
                            list.append(types.Move.new_from_to_flag(types.pop_lsb(&b1), checker_sq, types.MoveFlags.CAPTURE)) catch {};
                        }

                        return;
                    },

                    else => {
                        capture_mask = self.checkers;
                        quiet_mask = tables.SquaresBetween[our_king.index()][checker_sq.index()];
                    },
                }
            },
            else => {
                // No check: do anything

                // we can take anything
                capture_mask = them_bb;

                // or play quiet move to empty squares
                quiet_mask = ~all_bb;

                var ep = self.history[self.game_ply].ep_sq;
                if (ep != types.Square.NO_SQUARE) {
                    b2 = tables.get_pawn_attacks(opp, ep) & self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()];
                    b1 = b2 & not_pinned;

                    while (b1 != 0) {
                        sq = types.pop_lsb(&b1);

                        if ((tables.sliding_attack(our_king, all_bb ^ types.SquareIndexBB[sq.index()] ^ types.shift_bitboard(types.SquareIndexBB[ep.index()], rel_south), types.MaskRank[our_king.rank().index()]) & their_ortho_sliders) == 0) {
                            list.append(types.Move.new_from_to_flag(sq, ep, types.MoveFlags.EN_PASSANT)) catch {};
                        }
                    }

                    // Diagonal pin? OK
                    b1 = b2 & self.pinned & tables.LineOf[ep.index()][our_king.index()];
                    if (b1 != 0) {
                        list.append(types.Move.new_from_to_flag(@intToEnum(types.Square, types.lsb(b1)), ep, types.MoveFlags.EN_PASSANT)) catch {};
                    }
                }

                // Castling
                // Castle is only allowed if:
                // 1. The king and the rook have both not moved
                // 2. No piece is attacking between the the rook and the king
                // 3. The king is not in check
                var entry = self.history[self.game_ply].entry;
                if (0 == ((entry & types.get_oo_mask(color)) | ((all_bb | danger) & types.get_oo_blocker_mask(color)))) {
                    if (color == types.Color.White) {
                        list.append(types.Move.new_from_to_flag(types.Square.e1, types.Square.g1, types.MoveFlags.OO)) catch {};
                    } else {
                        list.append(types.Move.new_from_to_flag(types.Square.e8, types.Square.g8, types.MoveFlags.OO)) catch {};
                    }
                }
                if (0 == ((entry & types.get_ooo_mask(color)) | ((all_bb | (danger & ~types.ignore_ooo_danger(color))) & types.get_ooo_blocker_mask(color)))) {
                    if (color == types.Color.White) {
                        list.append(types.Move.new_from_to_flag(types.Square.e1, types.Square.c1, types.MoveFlags.OOO)) catch {};
                    } else {
                        list.append(types.Move.new_from_to_flag(types.Square.e8, types.Square.c8, types.MoveFlags.OOO)) catch {};
                    }
                }

                // pinned rook, bishop, or queen
                b1 = ~(not_pinned | self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Knight).index()]);
                while (b1 != 0) {
                    sq = types.pop_lsb(&b1);

                    // Only include moves that align with king.

                    b2 = tables.get_attacks(self.mailbox[sq.index()].piece_type(), sq, all_bb) & tables.LineOf[our_king.index()][sq.index()];
                    types.Move.make_all(types.MoveFlags.QUIET, sq, b2 & quiet_mask, list);
                    types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
                }

                b1 = ~not_pinned & self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()];
                while (b1 != 0) {
                    sq = types.pop_lsb(&b1);

                    if (sq.rank() == types.Rank.RANK7.relative_rank(color)) {
                        // Quiet promotions are not possible here
                        b2 = tables.get_pawn_attacks(color, sq) & capture_mask & tables.LineOf[our_king.index()][sq.index()];
                        types.Move.make_all(types.MoveFlags.PROMOTION_CAPTURES, sq, b2, list);
                    } else {
                        b2 = tables.get_pawn_attacks(color, sq) & them_bb & tables.LineOf[sq.index()][our_king.index()];
                        types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2, list);

                        // Single Pawn Pushes
                        b2 = types.shift_bitboard(types.SquareIndexBB[sq.index()], rel_north) & ~all_bb & tables.LineOf[our_king.index()][sq.index()];
                        // Double Pawn Pushes
                        b3 = types.shift_bitboard(b2 & types.MaskRank[types.Rank.RANK3.relative_rank(color).index()], rel_north) & ~all_bb & tables.LineOf[our_king.index()][sq.index()];

                        types.Move.make_all(types.MoveFlags.QUIET, sq, b2, list);
                        types.Move.make_all(types.MoveFlags.DOUBLE_PUSH, sq, b3, list);
                    }
                }
            },
        }

        // Non-pinned knight moves
        b1 = self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Knight).index()] & not_pinned;
        while (b1 != 0) {
            sq = types.pop_lsb(&b1);
            b2 = tables.get_attacks(types.PieceType.Knight, sq, all_bb);
            types.Move.make_all(types.MoveFlags.QUIET, sq, b2 & quiet_mask, list);
            types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
        }

        // Non-pinned diagonal moves
        b1 = our_diag_sliders & not_pinned;
        while (b1 != 0) {
            sq = types.pop_lsb(&b1);
            b2 = tables.get_attacks(types.PieceType.Bishop, sq, all_bb);
            types.Move.make_all(types.MoveFlags.QUIET, sq, b2 & quiet_mask, list);
            types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
        }

        // Non-pinned orthogonal moves
        b1 = our_ortho_sliders & not_pinned;
        while (b1 != 0) {
            sq = types.pop_lsb(&b1);
            b2 = tables.get_attacks(types.PieceType.Rook, sq, all_bb);
            types.Move.make_all(types.MoveFlags.QUIET, sq, b2 & quiet_mask, list);
            types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
        }

        b1 = self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()] & not_pinned & ~types.MaskRank[types.Rank.RANK7.relative_rank(color).index()];

        // Single pushes
        b2 = types.shift_bitboard(b1, rel_north) & ~all_bb;

        // Double pushes
        b3 = types.shift_bitboard(b2 & types.MaskRank[types.Rank.RANK3.relative_rank(color).index()], rel_north) & quiet_mask;

        b2 &= quiet_mask;

        while (b2 != 0) {
            sq = types.pop_lsb(&b2);
            list.append(types.Move.new_from_to_flag(sq.sub(rel_north), sq, types.MoveFlags.QUIET)) catch {};
        }

        while (b3 != 0) {
            sq = types.pop_lsb(&b3);
            list.append(types.Move.new_from_to_flag(sq.sub(rel_north).sub(rel_north), sq, types.MoveFlags.DOUBLE_PUSH)) catch {};
        }

        // Pawn captures
        b2 = types.shift_bitboard(b1, rel_northwest) & capture_mask;
        b3 = types.shift_bitboard(b1, rel_northeast) & capture_mask;

        while (b2 != 0) {
            sq = types.pop_lsb(&b2);
            list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, types.MoveFlags.CAPTURE)) catch {};
        }

        while (b3 != 0) {
            sq = types.pop_lsb(&b3);
            list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, types.MoveFlags.CAPTURE)) catch {};
        }

        // Promotions
        b1 = self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()] & not_pinned & types.MaskRank[types.Rank.RANK7.relative_rank(color).index()];
        if (b1 != 0) {
            // Quiet Promotions
            b2 = types.shift_bitboard(b1, rel_north) & quiet_mask;
            while (b2 != 0) {
                sq = types.pop_lsb(&b2);

                list.append(types.Move.new_from_to_flag(sq.sub(rel_north), sq, @intToEnum(types.MoveFlags, types.PR_QUEEN))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_north), sq, @intToEnum(types.MoveFlags, types.PR_ROOK))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_north), sq, @intToEnum(types.MoveFlags, types.PR_KNIGHT))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_north), sq, @intToEnum(types.MoveFlags, types.PR_BISHOP))) catch {};
            }

            // Promotion Captures
            b2 = types.shift_bitboard(b1, rel_northwest) & capture_mask;
            b3 = types.shift_bitboard(b1, rel_northeast) & capture_mask;

            while (b2 != 0) {
                sq = types.pop_lsb(&b2);

                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_QUEEN))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_ROOK))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_KNIGHT))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_BISHOP))) catch {};
            }

            while (b3 != 0) {
                sq = types.pop_lsb(&b3);

                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_QUEEN))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_ROOK))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_KNIGHT))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_BISHOP))) catch {};
            }
        }

        // Finish!
        return;
    }

    // Generate all CAPTURE moves
    pub fn generate_q_moves(self: *Position, comptime color: types.Color, list: *std.ArrayList(types.Move)) void {
        comptime var opp = if (color == types.Color.White) types.Color.Black else types.Color.White;

        const us_bb = self.all_pieces(color);
        const them_bb = self.all_pieces(opp);
        const all_bb = us_bb | them_bb;

        const our_king = @intToEnum(types.Square, types.lsb(self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.King).index()]));
        const their_king = @intToEnum(types.Square, types.lsb(self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.King).index()]));

        const our_diag_sliders = self.diagonal_sliders(color);
        const their_diag_sliders = self.diagonal_sliders(opp);
        const our_ortho_sliders = self.orthogonal_sliders(color);
        const their_ortho_sliders = self.orthogonal_sliders(opp);

        // Bitboards just for temp storage
        var b1: types.Bitboard = 0;
        var b2: types.Bitboard = 0;
        var b3: types.Bitboard = 0;

        comptime var rel_south = if (color == types.Color.White) types.Direction.South else types.Direction.North;
        comptime var rel_northwest = if (color == types.Color.White) types.Direction.NorthWest else types.Direction.SouthEast;
        comptime var rel_northeast = if (color == types.Color.White) types.Direction.NorthEast else types.Direction.SouthWest;

        // Squares King cannot go to
        var danger: types.Bitboard = 0;

        const their_pawns = self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Pawn).index()];

        danger |= tables.get_pawn_attacks_bb(opp, their_pawns) | tables.get_attacks(types.PieceType.King, their_king, all_bb);

        b1 = self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Knight).index()];
        while (b1 != 0) {
            danger |= tables.get_attacks(types.PieceType.Knight, types.pop_lsb(&b1), all_bb);
        }

        b1 = their_diag_sliders;
        while (b1 != 0) {
            danger |= tables.get_attacks(types.PieceType.Bishop, types.pop_lsb(&b1), all_bb ^ types.SquareIndexBB[our_king.index()]);
        }

        b1 = their_ortho_sliders;
        while (b1 != 0) {
            danger |= tables.get_attacks(types.PieceType.Rook, types.pop_lsb(&b1), all_bb ^ types.SquareIndexBB[our_king.index()]);
        }

        // King moves
        b1 = tables.get_attacks(types.PieceType.King, our_king, all_bb) & ~(us_bb | danger);

        types.Move.make_all(types.MoveFlags.CAPTURE, our_king, b1 & them_bb, list);

        var capture_mask: types.Bitboard = 0;
        var quiet_mask: types.Bitboard = 0;
        var sq: types.Square = types.Square.NO_SQUARE;

        self.checkers = tables.get_attacks(types.PieceType.Knight, our_king, all_bb) & self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Knight).index()];
        self.checkers |= tables.get_pawn_attacks(color, our_king) & self.piece_bitboards[types.Piece.new_comptime(opp, types.PieceType.Pawn).index()];

        var candidates: types.Bitboard = tables.get_attacks(types.PieceType.Rook, our_king, them_bb) & their_ortho_sliders;
        candidates |= tables.get_attacks(types.PieceType.Bishop, our_king, them_bb) & their_diag_sliders;

        self.pinned = 0;

        while (candidates != 0) {
            sq = types.pop_lsb(&candidates);
            b1 = tables.SquaresBetween[our_king.index()][sq.index()] & us_bb;

            if (b1 == 0) {
                // No our piece between king and slider: check
                self.checkers ^= types.SquareIndexBB[sq.index()];
            } else if ((b1 & (b1 - 1)) == 0) {
                // Only one of our piece between king and slider: pinned
                self.pinned ^= b1;
            }
        }

        const not_pinned: types.Bitboard = ~self.pinned;

        switch (types.popcount(self.checkers)) {
            2 => {
                // Double check: we have to move the king
                return;
            },
            1 => {
                // Single check: Move, capture, or block

                var checker_sq = @intToEnum(types.Square, types.lsb(self.checkers));

                switch (self.mailbox[checker_sq.index()]) {
                    types.Piece.new_comptime(opp, types.PieceType.Pawn) => {
                        var ep = self.history[self.game_ply].ep_sq;
                        if (self.checkers == types.shift_bitboard(types.SquareIndexBB[ep.index()], rel_south)) {
                            b1 = tables.get_pawn_attacks(opp, ep) & self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()] & not_pinned;
                            while (b1 != 0) {
                                list.append(types.Move.new_from_to_flag(types.pop_lsb(&b1), ep, types.MoveFlags.EN_PASSANT)) catch {};
                            }
                        }

                        // If checker is a pawn, then we can only move or capture.
                        b1 = self.attackers_from(color, checker_sq, all_bb) & not_pinned;
                        while (b1 != 0) {
                            list.append(types.Move.new_from_to_flag(types.pop_lsb(&b1), checker_sq, types.MoveFlags.CAPTURE)) catch {};
                        }

                        return;
                    },

                    types.Piece.new_comptime(opp, types.PieceType.Knight) => {
                        // If checker is a knight, then we can only move or capture.
                        b1 = self.attackers_from(color, checker_sq, all_bb) & not_pinned;
                        while (b1 != 0) {
                            list.append(types.Move.new_from_to_flag(types.pop_lsb(&b1), checker_sq, types.MoveFlags.CAPTURE)) catch {};
                        }

                        return;
                    },

                    else => {
                        capture_mask = self.checkers;
                        quiet_mask = tables.SquaresBetween[our_king.index()][checker_sq.index()];
                    },
                }
            },
            else => {
                // No check: do anything

                // we can take anything
                capture_mask = them_bb;

                // or play quiet move to empty squares
                quiet_mask = ~all_bb;

                var ep = self.history[self.game_ply].ep_sq;
                if (ep != types.Square.NO_SQUARE) {
                    b2 = tables.get_pawn_attacks(opp, ep) & self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()];
                    b1 = b2 & not_pinned;

                    while (b1 != 0) {
                        sq = types.pop_lsb(&b1);

                        if ((tables.sliding_attack(our_king, all_bb ^ types.SquareIndexBB[sq.index()] ^ types.shift_bitboard(types.SquareIndexBB[ep.index()], rel_south), types.MaskRank[our_king.rank().index()]) & their_ortho_sliders) == 0) {
                            list.append(types.Move.new_from_to_flag(sq, ep, types.MoveFlags.EN_PASSANT)) catch {};
                        }
                    }

                    // Diagonal pin? OK
                    b1 = b2 & self.pinned & tables.LineOf[ep.index()][our_king.index()];
                    if (b1 != 0) {
                        list.append(types.Move.new_from_to_flag(@intToEnum(types.Square, types.lsb(b1)), ep, types.MoveFlags.EN_PASSANT)) catch {};
                    }
                }

                // pinned rook, bishop, or queen
                b1 = ~(not_pinned | self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Knight).index()]);
                while (b1 != 0) {
                    sq = types.pop_lsb(&b1);

                    // Only include moves that align with king.

                    b2 = tables.get_attacks(self.mailbox[sq.index()].piece_type(), sq, all_bb) & tables.LineOf[our_king.index()][sq.index()];

                    types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
                }

                b1 = ~not_pinned & self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()];
                while (b1 != 0) {
                    sq = types.pop_lsb(&b1);

                    if (sq.rank() == types.Rank.RANK7.relative_rank(color)) {
                        // Quiet promotions are not possible here
                        b2 = tables.get_pawn_attacks(color, sq) & capture_mask & tables.LineOf[our_king.index()][sq.index()];
                        types.Move.make_all(types.MoveFlags.PROMOTION_CAPTURES, sq, b2, list);
                    } else {
                        b2 = tables.get_pawn_attacks(color, sq) & them_bb & tables.LineOf[sq.index()][our_king.index()];
                        types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2, list);
                    }
                }
            },
        }

        // Non-pinned knight moves
        b1 = self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Knight).index()] & not_pinned;
        while (b1 != 0) {
            sq = types.pop_lsb(&b1);
            b2 = tables.get_attacks(types.PieceType.Knight, sq, all_bb);
            types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
        }

        // Non-pinned diagonal moves
        b1 = our_diag_sliders & not_pinned;
        while (b1 != 0) {
            sq = types.pop_lsb(&b1);
            b2 = tables.get_attacks(types.PieceType.Bishop, sq, all_bb);
            types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
        }

        // Non-pinned orthogonal moves
        b1 = our_ortho_sliders & not_pinned;
        while (b1 != 0) {
            sq = types.pop_lsb(&b1);
            b2 = tables.get_attacks(types.PieceType.Rook, sq, all_bb);
            types.Move.make_all(types.MoveFlags.CAPTURE, sq, b2 & capture_mask, list);
        }

        b1 = self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()] & not_pinned & ~types.MaskRank[types.Rank.RANK7.relative_rank(color).index()];

        // Pawn captures
        b2 = types.shift_bitboard(b1, rel_northwest) & capture_mask;
        b3 = types.shift_bitboard(b1, rel_northeast) & capture_mask;

        while (b2 != 0) {
            sq = types.pop_lsb(&b2);
            list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, types.MoveFlags.CAPTURE)) catch {};
        }

        while (b3 != 0) {
            sq = types.pop_lsb(&b3);
            list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, types.MoveFlags.CAPTURE)) catch {};
        }

        // Promotions
        b1 = self.piece_bitboards[types.Piece.new_comptime(color, types.PieceType.Pawn).index()] & not_pinned & types.MaskRank[types.Rank.RANK7.relative_rank(color).index()];
        if (b1 != 0) {
            // Promotion Captures
            b2 = types.shift_bitboard(b1, rel_northwest) & capture_mask;
            b3 = types.shift_bitboard(b1, rel_northeast) & capture_mask;

            while (b2 != 0) {
                sq = types.pop_lsb(&b2);

                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_QUEEN))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_ROOK))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_KNIGHT))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northwest), sq, @intToEnum(types.MoveFlags, types.PC_BISHOP))) catch {};
            }

            while (b3 != 0) {
                sq = types.pop_lsb(&b3);

                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_QUEEN))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_ROOK))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_KNIGHT))) catch {};
                list.append(types.Move.new_from_to_flag(sq.sub(rel_northeast), sq, @intToEnum(types.MoveFlags, types.PC_BISHOP))) catch {};
            }
        }

        // Finish!
        return;
    }
};
