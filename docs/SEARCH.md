# Search notes

## Score ranges

- A mate found at ply `p` scores `MateScore - p`, and every score within
  `MaxMate` of `MateScore` is a mate score.
- A tablebase win found at ply `p` scores `TB_WIN_SCORE - p` and a loss the
  negation, so the shallower win is preferred. `TB_WIN_SCORE` is
  `MateScore - MaxMate - MAX_PLY`: the band lies just below the mate band, so
  a tablebase result is a large centipawn score, is never reported as a mate
  and is never taken for one by the search.
- Scores above `SCORE_PLY_ADJ` (`TB_WIN_SCORE - MAX_PLY`) in magnitude, which
  covers both bands, are stored in the transposition table relative to the
  node: the ply is added to the magnitude on a store and subtracted on a
  probe. A score stored at one ply and probed at another can therefore come
  back up to `2 * MAX_PLY` smaller in magnitude. `MaxMate` is at least
  `2 * MAX_PLY` for that reason, which a compile-time check enforces, so a
  mate score always stays a mate score.
- For the search the tablebase band is only `MAX_PLY` wide. A tablebase score
  that has lost more than that is an ordinary evaluation to the search from
  then on, but the UCI output treats every score down to
  `TB_WIN_SCORE - 2 * MAX_PLY` as a tablebase result: it is printed in the
  fixed band of docs/UCI.md and as a decided game under `UCI_ShowWDL`.
- The corrected static evaluation is clamped below `SCORE_PLY_ADJ`.

## Contempt and the transposition table

- A draw is worth `-Contempt` to the side to move at the root and `+Contempt`
  to its opponent, so `contempt_score` depends on whether the ply is even or
  odd. A transposition-table entry can be probed at a ply of the other
  parity, where a stored draw value would have the wrong sign.
- A tablebase draw is therefore stored as an exact 0, and an exact 0 read
  from the table becomes the draw value of the probing node.
- With a non-zero contempt every other store skips the two scores this makes
  ambiguous: one equal to the node's draw value, which may be a draw and
  would be wrong at the other parity, and an exact 0, which a probe would
  turn into a draw.

## Tablebases

- Syzygy probing goes through the vendored Pyrrhic library (`src/pyrrhic`, docs/BUILD.md). The
  bit and attack primitives Pyrrhic asks its host for are callbacks exported from
  `src/engine/syzygy.zig` and served by the engine's own attack tables, so no move generation
  is duplicated. `src/pyrrhic/tbconfig.h` declares them; it inverts the color of the pawn
  attacks, because Pyrrhic numbers White 1 and the engine 0.
- Nothing probes until `SyzygyPath` has loaded tables: `syzygy.init` has to succeed, and every
  probe in the search tests `syzygy.active()` before anything else. `bench` loads none, so
  its node count is that of a search without tablebases.
- An interior node probes the WDL tables when the fifty-move counter is zero, no side may
  castle, at most `syzygy.max_pieces()` pieces are left (what the loaded tables cover, capped
  by `SyzygyProbeLimit`) and the depth is at least `SyzygyProbeDepth`. Nodes that follow a
  null move, singular verifications and nodes with an excluded move do not probe. A win is a
  lower bound and a loss an upper bound in the band of "Score ranges", a draw is exact. A
  result that decides the node is stored in the transposition table and returned; otherwise
  it narrows the window. With `Syzygy50MoveRule` (the default) a cursed win and a blessed
  loss are draws, without it the win and the loss they are.
- The root probes the DTZ tables, or the WDL tables when Pyrrhic has no DTZ result, under the
  same conditions on castling rights and piece count, and keeps the root moves that share
  the best rank ("Root candidates" in docs/UCI.md).

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
  move, divided by `LMRHistoryDivisor`. Captures use the main history alone,
  and so does every move of a node that follows a null move or is a singular
  verification (see "Continuation history").
- The three tables share one bonus and gravity rule, so the sum that the
  divisor applies to spans about three times the range of one.

## Continuation history

- `ContinuationHistory` is indexed by the piece and target square of an earlier
  move, then by the from and to squares of the quiet move it scores.
- The earlier moves are those one, two and four plies back
  (`CONTINUATION_PLIES_AGO`, counted from the previous move). Move ordering
  adds all three with the weights `ContHistWeight1`, `ContHistWeight2` and
  `ContHistWeight4`, late move reductions use the first two, and a beta cutoff
  by a quiet move updates all three for every quiet move searched, with the
  bonus and gravity rule of the main history. An earlier null move has no
  entry.
- A node that follows a null move or is a singular verification
  (`is_null_or_singular`) neither reads nor updates the table, and does not set
  a counter move.

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
  captures still use `depth`.

## Move picking

`movepick.zig` hands the moves of a node to the search one at a time. The
order is part of the search's behaviour, ties included, so every speed-up
here reproduces the same sequence of moves; `bench` and the per-position node
counts do not move.

### The list

- Move generation fills a `MoveList`: 256 moves inline and a length, no
  allocator. A legal position has at most 218 moves, but a set-up position
  can have more (`knQQQQQQ/pp5Q/Q6Q/Q6Q/Q6Q/Q6Q/Q6Q/KQQQQQQQ w - - 0 1` has
  259), so `append` drops what does not fit: such a position is searched on
  its first 256 moves.

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
  That the hash move outscores every other move is checked when the engine
  is built: `movepick.zig` derives the largest score any other move can get
  from the score constants, the MVV-LVA table, the range of a
  capture-history and of a continuation-history entry and the upper limits
  of `HistoryGravityMax` and of the continuation weights, and does not
  compile unless the hash move's score is above it. The main history is
  bounded by its gravity rule, not by its type, which is why the upper
  limit of the tunable stands in for it. The same check covers the
  winning-capture test: a capture whose exchange wins cannot score below
  the floor, and one whose exchange loses stays below it unless it promotes
  to a queen.
- Scan without branches. Once no exchange is pending, a slot becomes
  `min(carried, slot)` and the carried score `max(carried, slot)`, and the
  two moves are exchanged through a mask of the comparison. That is the same
  result as the conditional exchange.
- Scan by blocks. While exchanges are pending the scan compares a block of
  scores against the carried score and visits only the slots that exceed it,
  in order, recomputing the mask after each exchange. The block is
  `std.simd.suggestVectorLength(i32)` scores, at most 16: four with NEON and
  SSE, eight with AVX2 and on AArch64 CPUs with SVE (256 bits are suggested
  there, docs/BUILD.md, and compile to two NEON halves), sixteen with AVX-512
  at 512 bits. The scan is correct at every length, and the tests run 4, 8
  and 16 on any host; the SVE case has not been timed. The score array is
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

The figures in this section were taken with an earlier network and search
tune, for which `bench` searched 15,472,869 nodes; the count of the current
tree is in `bench.nodes`.

On an idle Zen 4 server CPU, one thread, alternating runs, identical node
counts, the picker with the early exits against the allocator-backed lists
and the eager selection sort: `bench` +10.1% nodes per second and 3-second
searches +10.65%. The fixed-capacity list alone is +2.4% and +2.8% of that.
Those runs predate the scoring change below.

Counts over `bench` (6,246,026 nodes build a list, 13.8 moves each):

| | eager, full loops | now |
|---|---:|---:|
| picks | 34,128,161 | 19,272,936 |
| SEE calls for ordering | 12,931,875 | 9,128,152 |
| slots compared by the scans | 487,702,175 | 324,458,264 |
| first picks served with no scan | 0 | 1,470,992 (876,362 never scanned) |

The early exits fire 1,745,395 times and remove 14,855,225 picks. A scan
finds 4.8 slots above the carried score per pick. With blocks of four (NEON
without SVE, SSE) that is about one per block, so skipping whole blocks saves
little there; the time went into mispredicted exchanges, which the
branch-free scan removes.

Retired instructions for `bench` on an Apple M4. The builds are commit
870eeab with these changes alone, row by row: the absolute counts are not
those of a build that also has the later changes.

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
  a score leaves the searcher untouched. `SearchContext.at` reads them once
  per node: 3.2% fewer instructions, and 2.4% fewer cycles as the median of
  five alternating pairs (-5.4% to +0.6%).

Tried and left out:

- A picker whose scan was an out-of-line function with a `std.StaticBitSet`
  for the pending marks retired 6% more instructions than the plain scalar
  scan: most lists are short quiescence lists, where the call and the
  by-value bit set copy cost more than the scan. The scan is inlined into the
  move loop; only the SEE call and the replay of the deferred hash step are
  out of line.
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
pruning). Whether the node follows a null move or is a singular verification
(`is_null_or_singular`) and whether it is an expected cut node (`cutnode`) are run-time values:
they only feed conditions, and as compile-time parameters they doubled the function twice over
for the non-PV nodes, 24 copies of about 8 KiB each instead of 12. The move picker takes the first
of them as `without_continuation_history`, which is all it uses it for.

Single thread, nine alternating rounds, node counts identical: a Zen 4 server CPU `bench` +1.2%,
3 s searches +1.0%; a Zen 5 server CPU +1.1% and +0.5%. Making the node type a run-time value as
well (four copies) lost 0.8% on the Zen 5 server CPU and was left out.

## Sources

- Internal iterative reduction follows the discussion at
  http://talkchess.com/forum3/viewtopic.php?f=7&t=74769.
- The exchange evaluation against a threshold (`see_threshold`), with its treatment of pinned
  attackers, follows Weiss (https://github.com/TerjeKir/weiss).
- Scaling the final evaluation by the remaining material and the fifty-move counter is an idea
  from Clover.
- The `bench` positions come from Stormphrax, which took them from Alexandria, which took them
  from Bit-Genie.
