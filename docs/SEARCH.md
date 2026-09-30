# Search notes

## Static evaluation correction history

The search corrects the static evaluation with what earlier searches of similar
positions returned. Only the pawn-structure table exists so far.

### Key and table

- `Position.pawn_hash` is the Zobrist XOR of the pawns alone (the same
  `ZobristTable` entries the full hash uses). It is updated in `add_piece`,
  `remove_piece`, `move_piece` and `move_piece_quiet`, so pushes, pawn captures,
  en passant and promotions (the promoted pawn leaves the key) all follow from
  the existing piece operations. `set_fen` starts from zero and rebuilds it
  through `add_piece`. Debug builds assert after every `play_move` that it
  equals `compute_pawn_hash()`.
- Each `Searcher` owns `pawn_correction: [2][16384]i16`, indexed by side to
  move and `pawn_hash % 16384` (the low 14 bits). Zobrist keys are uniform in
  every bit and the pawn key is not used by any other table, so the low bits
  are as good as the high ones and cost a single mask. The table is zeroed by
  `reset_heuristics(true)` (`ucinewgame`, a new searcher, bench positions) and
  kept across `go` commands.

### Units and constants

Entries are in 1/256 cp (`CORRHIST_GRAIN = 256`) and bounded by
`CORRHIST_LIMIT = 32 * 256`, so a correction is at most 32 cp. An update is

```
bonus = clamp((best_score - static_eval) * depth, -LIMIT / 4, LIMIT / 4)
entry += bonus - entry * |bonus| / LIMIT
```

which is Stockfish's first correction history (`diff * depth / 8` clamped to
±256, gravity limit 1024, applied as `entry / 32`) scaled by 8 for a finer
grain. The gravity step never leaves `[-LIMIT, LIMIT]`, far inside `i16`.

### Where it applies

- `corrected = clamp(raw + entry / 256, -SCORE_PLY_ADJ + 1, SCORE_PLY_ADJ - 1)`,
  where `raw` is the full `hce.evaluate_comptime` result (including the
  drawish-material and fifty-move scaling). The clamp keeps a corrected eval out
  of the TB and mate bands.
- `negamax` uses the corrected value as `static_eval` for everything: RFP, NMP
  and its reduction, razoring, ProbCut's SEE threshold, futility pruning,
  `improving` and the history bonus depth. `qsearch` stands pat on it. Evals
  in check are not corrected.
- The TT stores the raw eval; the correction is applied again on every read.
  `raw_eval_history` keeps the raw eval per ply so null-move children and
  singular verification searches reuse the raw value, not a doubly corrected
  one.

### Update rule

At the end of `negamax`, the entry for the node is updated when the node is not
in check, is not a singular verification search or a MultiPV root with excluded
moves, the best move is quiet (or there is none), and the result is not bounded
on the wrong side of the static eval (`best >= beta` with `best <= eval`, or
`best <= alpha` with `best >= eval`). `qsearch` only reads the table.

The bonus measures `best_score - corrected static_eval`, not the raw eval. The
gravity rule accumulates bonuses rather than averaging a target, so a raw-based
bonus would keep pushing an entry whose raw error is a steady 5 cp until it hit
the 32 cp limit. With the residual, updates stop once the corrected eval agrees
with the search, and the entry converges on the actual error (this is what
Stockfish does; the tests check both properties).
