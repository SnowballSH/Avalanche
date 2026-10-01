# Search notes

## Pawn correction history

- `Position.pawn_hash` is the Zobrist XOR of the pawns, maintained in the piece
  operations; Debug builds check it against `compute_pawn_hash()` after every
  `play_move`.
- Each `Searcher` has `pawn_correction: [2][16384]i16`, indexed by side to move
  and the low 14 bits of the pawn key, cleared on `ucinewgame`.
- Entries are in 1/256 cp and bounded by ±8192 (32 cp). The corrected eval,
  `raw + entry / 256` clamped below the TB/mate bands, is the `static_eval` used
  by pruning, reductions and qsearch stand-pat. The TT stores the raw eval.
- Update at the end of `negamax`: `bonus = clamp((best - eval) * depth, ±2048)`,
  `entry += bonus - entry * |bonus| / 8192`. Skipped in check, in singular
  verification, at a restricted root, when a capture or promotion raised alpha,
  and when the result is bounded on the wrong side of the eval. qsearch only
  reads.
- qsearch probes the TT before evaluating: a cutoff costs no evaluation, and a
  stored raw eval replaces the evaluator call, corrected on read as in `negamax`.
  The upper-bound cutoff therefore compares against the incoming alpha, not the
  one raised by stand-pat.
- The bonus uses the corrected eval: the gravity rule accumulates, so a
  raw-based bonus would drive any consistent error to the limit, while the
  residual stops once the corrected eval agrees with the search.
