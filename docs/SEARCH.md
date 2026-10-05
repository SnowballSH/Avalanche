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
  added to the ordering score of captures: `MVV-LVA * 32 + history`. One step
  of victim value is 3200 and the history spans ±`HistoryGravityMax` (15649),
  so the victim term leads but a saturated history can lift a capture past
  one of a more valuable piece. An en passant capture counts as a pawn.
- On a beta cutoff every capture searched at the node is updated with the same
  bonus and gravity rule as the quiet history: the cutoff move up, the other
  captures down. Captures are updated whether a capture or a quiet move cut.
- The table is halved between searches and cleared on a new game, like the
  other histories.

## Quiet move pruning depth

- The futility margin and the SEE threshold of quiet moves scale with
  `lmr_depth = max(depth - 1 - QuietLMR[depth][index], 0)`, the depth the move
  would be searched to after its base reduction. The depth limits of both
  prunings, late move pruning, history pruning and the SEE threshold of
  captures still use `depth`. `FPBase`, `FPMargin` and `SEEQuietMargin` were
  tuned for `depth` and have not been retuned.

## Move picking

`movepick.zig` hands the moves of a node to the search one at a time. The
order is part of the search's behaviour, ties included, so every speed-up
here reproduces the same sequence of moves; `bench` and the per-position node
counts do not move.

### The list

- Move generation fills a `MoveList`: 256 moves inline and a length, no
  allocator. A legal position has at most 218 moves, but a set-up position
  can have more (`knQQQQQQ/pp5Q/Q6Q/Q6Q/Q6Q/Q6Q/Q6Q/KQQQQQQQ w - - 0 1` has
  259), so `append` drops what does not fit. The search lists used to stop at
  218 the same way; such a position is now searched on its first 256 moves.

### The order

- Every move gets a score when the node's list is built:
  - the hash move 6,000,000;
  - a capture `MVV-LVA * 32 + capture history`, plus 1,000,000 if its
    exchange passes SEE at `-MovepickSEEMargin`; an en passant capture always
    gets the 1,000,000 and is never put through SEE;
  - the killers 900,000 and 800,000, the counter move 600,000;
  - any other quiet move its history plus the weighted continuation
    histories.

  A queen promotion adds 1,000,000 and a knight promotion 650,000 to
  whichever of these applies. Quiet scores and the capture history term are
  read before the first move is searched, because the search of earlier moves
  changes those tables.
- Pick `i` scans slots `i + 1 .. n` carrying a move and its score, starting
  with the move in slot `i`. Whenever the carried score is strictly less than
  the score in a slot, the two are exchanged. The carried move at the end goes
  to slot `i` and is the pick. This picks the first maximum, and moves each
  earlier running maximum to the slot of the next one. It is not a stable
  sort: which of several equal moves comes first later depends on these
  exchanges. Most quiet moves tie, so "find the maximum and swap it in" or
  any stable sort searches a different tree.
- The search uses the 0-based pick number for the reduction tables and its
  `index > 0` and `index > 1` tests, and asks whether the pick is a winning
  capture: a score of at least 1,000,000 - 32768. That is a test on the
  score, so a queen-promotion capture counts as winning even when its
  exchange loses.

### What is exact and why

- Exchanges on demand. SEE depends on the position only, and the node's
  position is the same before each of its moves, so the exchange of a capture
  can be evaluated any time before that capture is played. A capture is
  scored as if its exchange won and marked pending. A stored score is then
  never below the true one, so "carried >= stored" already proves that the
  scan would not exchange, whatever SEE says. Only when a pending score
  exceeds the carried score is the exchange evaluated (the score drops by
  1,000,000 if it loses) and the comparison repeated with the true value. The
  carried move is settled before its scan starts, so the carried score is
  always true. The last remaining move needs no comparison and stays pending
  until the search asks whether it is a winning capture, which is why the
  search asks before playing the move.
- Hash move first, scan later. The hash move scores at least 6,000,000 and
  every other move less, so pick 0 is the hash move whatever the scan does.
  It is returned without scanning or evaluating anything. Pick 0's scan runs
  when a second move is requested, or when the search asks for the unpicked
  moves, and leaves the list as the eager scan would have; no table it reads
  has changed, because all scores were taken when the list was built.
- Scan without branches. Once no exchange is pending, a slot becomes
  `min(carried, slot)` and the carried score `max(carried, slot)`, and the
  two moves are exchanged through a mask of the comparison. That is the same
  result as the conditional exchange.
- Scan by blocks. While exchanges are pending the scan compares a block of
  scores against the carried score and visits only the slots that exceed it,
  in order, recomputing the mask after each exchange. The block is
  `std.simd.suggestVectorLength(i32)` scores, at most 16. The score array is
  padded with the minimum integer so that a full block past the end is
  readable and never exceeds the carried score.
- Leaving the loop early. In `negamax`, once late move, history or futility
  pruning has set `skip_quiet`, a quiet move that is neither a killer nor a
  promotion (`is_prunable_quiet`) is skipped after the excluded-move test and
  the count of quiet moves, and that count is not read after the loop. If
  every unpicked move is of that kind, the remaining iterations can only
  skip; no search runs between them, so the killers they would compare
  against are the ones the check used, and the loop ends. In
  `quiescence_search` outside check, a capture scored below the
  winning-capture floor is skipped after the first pick. Picks come in
  non-increasing true score, so once one capture is below the floor every
  unpicked capture is too, and if only captures are left the loop ends.

`src/tests/movepick.zig` checks the first four against a plain implementation
of the order above, for blocks of 4, 8 and 16 on any host: random lists with
heavy ties, random pending sets and exchange results, hash moves in random
slots, picks stopped at a random point, and the winning-capture question and
the unpicked moves asked for at random. The early exits are checked by running
each loop's skip rule with and without the exit over the same random lists
and requiring the same sequence of searched picks, and the three predicates
(`is_prunable_quiet`, `only_prunable_quiets`, `only_captures`) on every kind
of move.

### Measurements

On an idle EPYC 9R14 (Zen 4), one thread, alternating runs, identical node
counts, the picker with the early exits against the allocator-backed lists
and the eager selection sort: `bench` +10.1% nodes per second and 3-second
searches +10.65%. The fixed-capacity list alone is +2.4% and +2.8% of that.
Those runs predate the scoring change below.

Counts over `bench` (15,472,869 nodes; 6,246,026 nodes build a list, 13.8
moves each):

| | eager, full loops | now |
|---|---:|---:|
| picks | 34,128,161 | 19,272,936 |
| SEE calls for ordering | 12,931,875 | 9,128,152 |
| slots compared by the scans | 487,702,175 | 324,458,264 |
| first picks served with no scan | 0 | 1,470,992 (876,362 never scanned) |

The early exits fire 1,745,395 times and remove 14,855,225 picks. A scan
finds 4.8 slots above the carried score per pick. With blocks of four (NEON,
SSE) that is about one per block, so skipping whole blocks saves little
there; the time went into mispredicted exchanges, which the branch-free scan
removes.

Retired instructions for `bench` on an Apple M4:

| | instructions |
|---|---:|
| allocator-backed lists, eager selection sort | 112.8e9 |
| fixed-capacity list | 111.0e9 |
| picker and early exits | 111.1e9 |
| node invariants of the scoring read once | 107.5e9 |

- The picker hardly changes the instruction count; its gain is in
  mispredictions. In the sampling profile the selection scan was 9.7% of the
  run before and its lines are about 1.3% after; `negamax` self time went
  from 17.5% to 12.0%, `see_threshold` from 4.8% to 4.1%, and
  `ArrayList.append` and the buffer allocator (0.6%) are gone.
- Scoring was the largest remaining cost at about 6.5% of the run. It read the
  ply, both killers, the previous moves and the base of each continuation
  table again for every move, because the compiler cannot prove that storing
  a score leaves the searcher untouched. `SearchContext.at` now reads them
  once per node: 3.2% fewer instructions, and 2.4% fewer cycles as the median
  of five alternating pairs (-5.4% to +0.6%).

Tried and left out:

- A picker whose scan was an out-of-line function with a `std.StaticBitSet`
  for the pending marks retired 6% more instructions than the plain scalar
  scan: most lists are short quiescence lists, where the call and the
  by-value bit set copy cost more than the scan. The scan is now inlined into
  the move loop; only the SEE call and the replay of the deferred hash step
  are out of line.
- Counting the unpicked captures and promotions instead of rescanning the
  unpicked moves at a skipped move. On `bench` 3,057,765 checks lead to
  1,745,395 exits, so 0.75 checks per exit stop at a move that keeps the loop
  alive. Two counters kept up to date for every scored and every picked move
  would execute more than those rescans.
- Generating moves through a local length that is stored into the list once.
  The list's length is otherwise reloaded after every move stored. 0.18%
  fewer instructions, and no difference in cycles over nine alternating
  pairs on the M4.

## Compile-time and run-time parameters of the search

`negamax` is compiled once per value of its compile-time parameters. The side to move, the
evaluation mode and the node type (root, PV, non-PV) stay compile-time: the board code is
specialised by color, and the node type removes whole blocks (root reporting, PV bookkeeping,
pruning). Whether the node follows a null move or a singular verification (`is_null`) and whether
it is an expected cut node (`cutnode`) are run-time values: they only feed conditions, and as
compile-time parameters they doubled the function twice over for the non-PV nodes, 24 copies of
about 8 KiB each instead of 12. The move picker takes the first of them as
`without_continuation_history`, which is all it uses it for.

Single thread, nine alternating rounds, node counts identical: EPYC 9R14 (Zen 4) `bench` +1.2%,
3 s searches +1.0%; EPYC 9R45 (Zen 5) +1.1% and +0.5%. Making the node type a run-time value as
well (four copies) lost 0.8% on the EPYC 9R45 and was left out.
