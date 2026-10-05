# Board code

Notes on the position, the move generators, the exchange evaluation and draw detection: what the
hot paths rely on, and why they are written the way they are. None of this changes a search
result; `bench` and the tests in `src/tests/board.zig` hold each piece of it to the code it
replaced.

## Undo stack

`Position.history[game_ply]` is an `UndoInfo`: the fifty-move counter, castling rights and
en-passant square of the current position, the piece captured by the move that led to it, the
pieces giving check to the side to move, and the keys (`hash`, `pawn_hash`, `nonpawn_hash`) of the
position that move was played from.

- `play_move` builds the entry in a local and stores it once. The side-to-move, en-passant and
  castling keys are collected into one value that is XORed into `hash` at the end.
- `undo_move` copies the saved keys back instead of recomputing them. Its board edits are the
  same three as in `play_move` (`place`, `lift`, `relocate`), called with `keyed = false`, so an
  undo does no Zobrist lookup and no pawn/non-pawn selection.
- The quiet move and the plain capture are tested first; the other flags go through a switch.
  A jump table over all sixteen flags was mispredicted on undo.
- An entry is 48 bytes and the stack 2176 entries, 102 KiB where the packed entries took 17 KiB.
  A search touches the entries of the plies it is at; the rest is the game played so far.

## Occupancy

`occupancy[color]` is updated by the board edits, so `all_pieces` is a load. It was the OR of six
bitboards, repeated by `in_check`, both move generators, every exchange evaluation and the
upcoming-repetition test. `place` and `relocate` need a piece on the square they are given; this
is asserted in Debug builds.

## Checkers

`history[game_ply].checkers` holds the pieces giving check to the side to move, so `in_check` of
the side to move is a load. The search asks at the entry of every node, and before that the parent
asks the same question about the same position for late-move reductions.

`set_fen`, `play_move` and `play_null_move` find them with the general attack query.

The entry is maintained by `set_fen`, `play_move`, `play_null_move` and `copy_game_state`. Code
that edits the board through `add_piece` or `remove_piece` and then needs `in_check` has to go
through one of them.

## King captures in the capture generator

`generate_legal_moves` builds the map of squares the other side attacks, for king moves and
castling. `generate_q_moves` only needs it for king captures, and most positions have no enemy
piece next to the king. It now asks, for each such piece, whether its square is attacked once the
king has left its own. A square is in the attack map exactly when it has an attacker, and both
iterate the squares in the same order, so the moves and their order are the same.

## Exchange evaluation

`see_threshold` removes pinned pieces from the attackers of each side before choosing the least
valuable one, with the occupancy of the exchange so far.

- The pinners are found from the lines of the king: the enemy sliders on its rank, file and
  diagonals with exactly one piece in between, that piece being the side's own. This is the set
  the two slider lookups from the king square gave, without the lookups. The pieces counted in
  between are those of the position, not the occupancy bit of the destination square, which
  stands for the moving piece and belongs to neither side there.
- A side without an attacker of the square has no pins to look for.
- When the side to recapture has no attacker at all, the move passes before the loop is set up.
  The compiler prepares the loop's twenty or so combined bitboards up front, which was paid for
  by the many calls that never took a second step.

`src/tests/board.zig` keeps the previous implementation and compares the two on every legal move
of random games, over fixed and random thresholds.

## Draw detection

- A position is a material draw when it has no pawn, rook or queen and at most one minor piece.
  That is two tests on ten bitboards; it was five cases over twelve, each with its own count.
- `draw_score` is inlined at the node entry; the mate-or-draw decision of a drawn position in
  check is a cold function of its own.
- `Searcher.hash_history` is a `KeyHistory`, a stack in a buffer sized for the undo stack. Its
  `append` is a compare and two stores; the `std` list called through two functions per move.
- The repetition scan compares the keys two, four, ... plies back, as far as `fifty + 3`. It is
  not narrowed to `4 ..= fifty`, although no real game repeats outside that window: a null move
  adds to the fifty-move counter without adding a key, so a key two entries back can be a real
  repetition (the side passed twice while the other moved a piece out and back), and callers
  that build key histories by hand rely on the window as it is.

## Measurements

Apple M4, `--release=fast`, `bench`: 15472869 nodes at every commit, and the standard perft
counts and eight `go depth 13` searches (every info line) equal before and after. The machine was
running other builds and benchmarks at load average 15 to 20 while these were taken, so nps says
nothing about the changes. The table gives what `/usr/bin/time -l` reports as the instructions
retired by the process, one run per build, back to back.

| Change | Instructions | Against the row above |
|---|---|---|
| before | 113.23 G | |
| exchange evaluation: pins from the king's lines | 112.99 G | -0.2% |
| draw detection | 112.27 G | -0.6% |
| king captures in the capture generator | 111.77 G | -0.4% |
| undo stack: saved keys, one store per move | 110.67 G | -1.0% |
| key history | 110.37 G | -0.3% |
| occupancy | 109.81 G | -0.5% |
| exchange evaluation: nobody recaptures | 109.70 G | -0.1% |
| checkers kept in the undo entry | 109.60 G | -0.1% |

That is 3.2% fewer instructions in all, 7320 to 7080 per node. Repeated runs of one build differed
by 0.1% to 0.4%, and by 1.3% when one was preempted heavily (such a run retires more), so the rows
of 0.1% and 0.2% are not resolved one by one. Elapsed cycles of the least disturbed runs were
45.9 G before and 46.8 G after, with runs of one build ranging from 44 G to 66 G: they do not
resolve the change, and the time on an idle machine is still to be measured.

Two Time Profiler recordings of `bench`, before and after, show `undo_move` going from 1.3% to
0.7% of the samples, `is_draw` and `draw_score` (1.7% together) disappearing into the node entry,
and `play_move` rising from 2.4% to 3.6%: it now finds the checkers that the node entry used to
find. The recordings were taken under different load and their other shares are not comparable.

## Looked at and left as they are

- **PEXT slider lookups.** BMI2 alone does not say that `pext` is fast (Zen 1 and Zen 2 run it in
  microcode), and the x86-64-v3 release build has to serve those CPUs. Every CPU with AVX-512 has
  a fast one, so the v4 build could select it soundly at compile time. It was not written: the
  magic lookups are 1.4% of `bench` on the M4, `pext` stands in for an and, a multiply and a shift
  and saves two small loads per lookup, and nothing here can time x86.
- **Narrowing the repetition scan**, see above.
- **Testing for an aligned enemy slider before the slider lookups of `in_check`.** The lookups
  do not hold anything up, since the result feeds a branch that is predicted not-in-check; a data
  dependent branch in front of them would. The checkers entry removes the lookups instead.
- **One record per square for the magic mask, multiplier and shift.** They are three arrays of
  64 entries read at every lookup and stay in the first-level cache as they are.
- **Testing king destinations one by one in `generate_legal_moves`.** The attack map costs one
  slider lookup per enemy slider; a square test costs two. With the two or three free squares of a
  castled king the square tests are cheaper, with an active king in an endgame the map is, and
  castling needs the map for its path. Two fifths of what the generator costs is the appends.
- **The order of the fields of `Position`.** Not measured. The hot fields (bitboards, occupancy,
  keys, mailbox, the top undo entries) are a few cache lines that stay in the first-level cache
  through a search, no profile line pointed at them, and the layout of a plain Zig struct is the
  compiler's to choose.
- **`evaluate_mode`** counts the knights, bishops, rooks and queens twice, for the phase and for
  the material scale. The whole function is 0.7% of `bench`, most of it the call into the network.
