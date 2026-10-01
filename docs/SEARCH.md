# Search notes

## Correction history

- `Position.pawn_hash` is the Zobrist XOR of the pawns, and
  `Position.nonpawn_hash[c]` that of color `c`'s knights, bishops, rooks, queens
  and king. Both are maintained in the piece operations; Debug builds check them
  against `compute_pawn_hash()` and `compute_nonpawn_hash(c)` after every
  `play_move`.
- Each `Searcher` has `pawn_correction: [2][16384]i16` and
  `nonpawn_correction: [2][2][16384]i16`, indexed by side to move, then (for
  non-pawn) the key's color, then the low 14 bits of the key. All are cleared on
  `ucinewgame`.
- Each `Searcher` also owns a heap-allocated
  `cont_correction: *[12 * 64 * 12 * 64]i16` (1.125 MiB per thread), indexed by
  the (piece, to) of the move two plies ago and then of the previous move, taken
  from `moved_piece_history` and `move_history` like the continuation history.
  The term is skipped (reads as 0, no update) when `ply < 2` or either of those
  plies was a null move, so never at the root, at ply 1, in a null-move node or
  in its children. Cleared on `ucinewgame`; helper threads keep their own table
  and nothing is copied per search.
- Entries are in 1/256 cp and bounded by ±8192 (32 cp). The corrected eval,
  `raw + (8 * pawn + 6 * (nonpawn_white + nonpawn_black) + 6 * cont) / (256 * 8)`
  clamped below the TB/mate bands, is the `static_eval` used by pruning,
  reductions and qsearch stand-pat. The pawn term keeps full weight; each
  non-pawn term and the continuation term get 3/4, as in Stockfish where the
  terms are of similar weight. The TT stores the raw eval.
- Update at the end of `negamax`, the same bonus to every applicable entry:
  `bonus = clamp((best - eval) * depth, ±2048)`,
  `entry += bonus - entry * |bonus| / 8192`. Skipped in check, in singular
  verification, at a restricted root, when a capture or promotion raised alpha,
  and when the result is bounded on the wrong side of the eval. qsearch only
  reads.
- The bonus uses the corrected eval: the gravity rule accumulates, so a
  raw-based bonus would drive any consistent error to the limit, while the
  residual stops once the corrected eval agrees with the search.
