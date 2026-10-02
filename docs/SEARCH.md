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
- Entries are in 1/256 cp and bounded by ±8192 (32 cp). The corrected eval,
  `raw + (8 * pawn + 6 * (nonpawn_white + nonpawn_black)) / (256 * 8)` clamped
  below the TB/mate bands, is the `static_eval` used by pruning, reductions and
  qsearch stand-pat. The pawn term keeps full weight; each non-pawn term gets
  3/4, as in Stockfish where the terms are of similar weight. The TT stores the
  raw eval.
- Update at the end of `negamax`, the same bonus to all three entries:
  `bonus = clamp((best - eval) * depth, ±2048)`,
  `entry += bonus - entry * |bonus| / 8192`. Skipped in check, in singular
  verification, at a restricted root, when a capture or promotion raised alpha,
  and when the result is bounded on the wrong side of the eval. qsearch only
  reads.
- The bonus uses the corrected eval: the gravity rule accumulates, so a
  raw-based bonus would drive any consistent error to the limit, while the
  residual stops once the corrected eval agrees with the search.

## Late move reductions

- The history term that shortens or lengthens a reduction is, for quiet moves,
  the main history plus the one-ply and two-ply continuation histories of the
  move, divided by `LMRHistoryDivisor`. Captures use the main history alone.
- The three tables share one bonus and gravity rule, so their sum spans about
  three times the range of one; the divisor was widened from 5164 to 8192 with
  the change and has not been tuned since.

## Pruning eval

- Reverse futility pruning, null move pruning (its condition and its reduction
  term) and razoring compare against the TT score instead of the corrected
  static eval when the entry bounds the score on the useful side: an exact
  entry, a lower bound above the eval, or an upper bound below it. Mate and
  tablebase scores are never used this way.
- The improving flag, the eval history, move-loop futility pruning and the
  ProbCut threshold keep the static eval, so they stay comparable from ply to
  ply.

## Capture history

- A table indexed by moving piece, target square and captured piece type is
  added to the ordering score of captures: `MVV-LVA * 32 + history`. The scale
  keeps the victim term dominant, so the history only orders captures of
  similar material value. An en passant capture counts as a pawn.
- On a beta cutoff every capture searched at the node is updated with the same
  bonus and gravity rule as the quiet history: the cutoff move up, the other
  captures down. Captures are updated whether a capture or a quiet move cut.
- The table is halved between searches and cleared on a new game, like the
  other histories.
