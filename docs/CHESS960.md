# Chess960 and Double Fischer Random

Avalanche plays standard chess, Chess960 (FRC) and Double Fischer Random
(DFRC, independent back ranks per side) with one move generator. There is no
separate "960 mode" in search or movegen; only move notation depends on the
`UCI_Chess960` option.

## Castling model

`src/chess/castling.zig` describes castling per game rather than with
hard-coded e1/h1 masks:

- `castling.Rule` holds one castling move's king/rook origin and destination
  squares plus two precomputed masks:
  - `must_be_empty`: every square the king or rook passes through or lands on,
    excluding the king and the castling rook themselves;
  - `must_be_safe`: the king's path including its destination.
- `castling.Setup` (a field of `Position`) stores the four rules and a
  per-square `revoked_by` table: the rights lost when a piece leaves or lands on
  that square. It is built once by `set_fen`.
- Rights are a 4-bit field in `UndoInfo` (bit layout: white O-O, white O-O-O,
  black O-O, black O-O-O), which is also the Zobrist `CastlingHash` index, so
  standard-chess hashes are unchanged.

`play_move` updates rights with a single lookup:
`rights &= ~(revoked_by[from] | revoked_by[to])`, skipped entirely once no
rights remain. Castling legality in movegen is two mask tests against the
occupancy and the enemy attack map that legal movegen already computes.

The only Chess960-specific check: when the castling rook is not on an edge
file, removing it can uncover a rank attack on the king's destination (e.g.
white king b1, rook c1, enemy queen a1 castling queenside). `Rule.rook_may_shield`
flags those rules so standard chess never pays for the extra rook-attack lookup.

## Move encoding

Castling moves are stored king-captures-rook (`from` = king, `to` = rook) with
the `OO`/`OOO` flag. This is unambiguous even when the king does not move (king
already on g1) or when king and rook swap squares, which the old
king-destination encoding could not express. `Move.castle_king_destination`
recovers the standard notation.

Make/unmake move the king and rook with `move_piece_quiet` when their squares
do not overlap (always the case in standard chess, keeping NNUE updates to two
feature moves). When they overlap (king f1/rook g1, etc.) the rook is removed
and re-added around the king move.

## Notation and FEN

- Output: king-captures-rook when `UCI_Chess960` is set or the position's setup
  is not the standard one (to stay unambiguous), else `e1g1`-style.
- Input: `Move.new_from_string` accepts king-captures-rook always, and
  king-destination unless Chess960 notation is active.
- FEN input accepts `KQkq` (X-FEN: outermost rook on that wing) and Shredder
  file letters (`HAha`, `HFhf`, ...). Rights that do not name an actual rook on
  the back rank are dropped.
- FEN output (`basic_fen`) writes X-FEN: `K`/`Q` when the castling rook is the
  outermost rook on its wing, otherwise the rook's file letter.

## Start positions

`src/chess/frc.zig` generates Chess960 back ranks in Scharnagl numbering
(518 = standard) and builds FRC/DFRC FENs. `genfens N seed S book None frc|dfrc`
produces randomized openings from them for OpenBench.

## Tests

`src/tests/frc.zig` checks perft for 12 FRC positions, 8 castling edge cases
and 5 DFRC starts (references computed independently with python-chess), that
incremental hash/rights/NNUE match a fresh `set_fen` after every legal move,
FEN round-trips, and notation.
