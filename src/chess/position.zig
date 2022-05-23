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

    pub fn new() UndoInfo {
        return UndoInfo{
            .entry = 0,
            .captured = types.Piece.NO_PIECE,
            .ep_sq = types.Square.NO_SQUARE,
        };
    }

    pub fn from(old: UndoInfo) UndoInfo {
        return UndoInfo{
            .entry = old.entry,
            .captured = types.Piece.NO_PIECE,
            .ep_sq = types.Square.NO_SQUARE,
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

        std.debug.print("{s} to move\n", .{if (self.turn == types.Color.White) "White" else "Black"});
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
        // NO_SQUARE or NO_PIECE should have hash of 0, so XOR doesn't affect hash
        self.hash ^= zobrist.ZobristTable[self.mailbox[from.index()].index()][from.index()];
        self.hash ^= zobrist.ZobristTable[self.mailbox[to.index()].index()][to.index()];
        self.hash ^= zobrist.ZobristTable[self.mailbox[from.index()].index()][to.index()];

        const mask = types.SquareIndexBB[from.index()] | types.SquareIndexBB[to.index()];
        self.piece_bitboards[self.mailbox[from.index()].index()] ^= mask;
        self.piece_bitboards[self.mailbox[to.index()].index()] &= ~mask;
        self.mailbox[to.index()] = self.mailbox[from.index()];
        self.mailbox[from.index()] = types.Piece.NO_PIECE;
    }

    // DO NOT CALL IF DESTINATION IS NOT EMPTY
    pub inline fn move_piece_quiet(self: *Position, from: types.Square, to: types.Square) void {
        self.hash ^= zobrist.ZobristTable[self.mailbox[from.index()].index()][from.index()];
        self.hash ^= zobrist.ZobristTable[self.mailbox[from.index()].index()][to.index()];

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

    // Moving pieces

    pub fn play_move(self: *Position, comptime color: types.Color, move: types.Move) void {
        self.turn = self.turn.invert();
        self.game_ply += 1;
        self.history[self.game_ply] = UndoInfo.from(self.history[self.game_ply - 1]);

        var flags = move.get_flags();
        self.history[self.game_ply].entry |= types.SquareIndexBB[move.to] | types.SquareIndexBB[move.from];

        switch (flags) {
            types.MoveFlags.QUIET => {
                self.move_piece_quiet(move.get_from(), move.get_to());
            },
            types.MoveFlags.DOUBLE_PUSH => {
                self.move_piece_quiet(move.get_from(), move.get_to());

                self.history[self.game_ply].ep_sq = move.get_from().add(types.Direction.North.relative_dir(color));
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
                            self.history[self.game_ply].captured = self.mailbox[move.to];
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

        self.turn = opp;
        self.game_ply -= 1;
    }
};
