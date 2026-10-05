# Board code

Notes on the position, the move generators, the exchange evaluation and draw detection: what the
hot paths rely on, and why they are written the way they are. None of this changes a search
result; `bench` and the tests in `src/tests/board.zig` hold each piece of it to the code it
replaced.

## Undo stack

`Position.history[game_ply]` is an `UndoInfo`: the fifty-move counter, castling rights and
en-passant square of the current position, the piece captured by the move that led to it, the
enemy pieces attacking the king of the side to move, and the keys (`hash`, `pawn_hash`,
`nonpawn_hash`) of the position that move was played from.

- `play_move` builds the entry in a local and stores it once. The side-to-move, en-passant and
  castling keys are collected into one value that is XORed into `hash` at the end.
- `undo_move` copies the saved keys back instead of recomputing them, so it does no Zobrist
  lookup and no pawn/non-pawn selection. Its board edits are `place`, `lift` and `relocate` with
  `keyed = false`; `play_move` makes the same edits keyed, except that it plays a plain capture
  in one step (`move_piece`) where `undo_move` takes it back as a `relocate` and a `place`.
- The quiet move and the plain capture are tested first; the other flags go through a switch.
  A jump table over all sixteen flags was mispredicted on undo.
- An entry is 48 bytes and the stack `HISTORY_CAPACITY` (2176) entries, 102 KiB where the packed
  entries took 17 KiB. A search touches the entries of the plies it is at; the rest is the game
  played so far.

## Occupancy

`occupancy[color]` is updated by the board edits, so `all_pieces` is a load. It was the OR of six
bitboards, repeated by `in_check`, both move generators, every exchange evaluation and the
upcoming-repetition test.

The occupancy has no slot for "no piece", so two edits now have a precondition: `place` must be
given a piece, and the square `relocate` moves from must hold one. Both are `std.debug.assert`s:
Debug and ReleaseSafe builds stop there, and in ReleaseFast the condition is handed to the
optimiser as a fact, so breaking it is undefined behaviour. Before, moving from an empty square
was tolerated: it wrote "no piece" to the destination and touched only the spare bitboard and a
zero key. No caller does it; `move_piece` and `move_piece_quiet` are private to `Position`.

## King attackers

`history[game_ply].king_attackers` holds the enemy pieces attacking the king of the side to move,
so `in_check` of the side to move is a load. The search asks at the entry of every node, and
before that the parent asks the same question about the same position for late-move reductions.

`set_fen`, `play_move` and `play_null_move` find them with the general attack query, and
`copy_game_state` copies them. `add_piece` and `remove_piece` stay public for `set_fen` and the
tests and do not update the entry: code that edits the board through them and then needs
`in_check` has to go through one of the four. Debug builds assert in `in_check` that the stored
answer is the one the board gives.

The move generators still work out the checkers together with the pins and keep both in
`Position.checkers` and `Position.pinned`, which are their working values and mean nothing
between calls.

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
  the two slider lookups from the king square gave, without the lookups. The pieces in between
  are counted as the lookups counted their blockers: the pieces of the position that are still in
  the exchange occupancy. The destination square is therefore the victim's piece on a capture,
  and no piece at all on a quiet move or an en-passant capture, where the position has it empty
  and only the occupancy has its bit.
- A side without an attacker of the square has no pins to look for.
- When the side to recapture has no attacker at all, the move passes before the loop is set up.
  The compiler prepares the loop's twenty or so combined bitboards up front, which was paid for
  by the many calls that never took a second step.

`src/tests/board.zig` keeps the previous implementation and compares the two on every legal move
of random games, over fixed and random thresholds, and on positions built for a pin along the
capture line, a pin that appears during the exchange, en passant and king recaptures.

## Draw detection

- A position is a material draw when it has no pawn, rook or queen and at most one minor piece.
  That is two tests on ten bitboards; it was five cases over twelve, each with its own count.
- `draw_score` is inlined at the node entry; the mate-or-draw decision of a drawn position in
  check is a cold function of its own.
- `Searcher.hash_history` is a `KeyHistory`, a stack in a buffer of `HISTORY_CAPACITY` keys: every
  key belongs to a position that has an undo entry (a null move takes an entry and no key). Its
  `append` is at most a compare and two stores; the `std` list called through two functions per
  move. A full history refuses the append. The search pairs each append with a pop, and a
  refused append would make the pop take a key of the game, so there the refusal is
  `unreachable`, and a compile-time check in `search.zig` holds `HISTORY_CAPACITY` to the longest
  game plus `MAX_PLY`. It is `unreachable` as well where a history starts over: the `position`
  command (which stops reading moves at `MAX_HISTORY_PLY`), `bench`, a new datagen game and a
  helper adopting the root all append to a history they have just cleared. Only datagen's random
  opening ignores a refusal, because its length is an option that nothing bounds.
- The repetition scan compares the keys two, four, ... plies back, as far as `fifty + 3`. It is
  not narrowed to `4 ..= fifty`, although no real game repeats outside that window: a null move
  adds to the fifty-move counter without adding a key, so a key two entries back can be a real
  repetition (the side passed twice while the other moved a piece out and back), and callers
  that build key histories by hand rely on the window as it is.

## Measurements

`bench` searches 15472869 nodes at every commit, and the standard perft counts and eight
`go depth 13` searches (every info line) are equal before and after.

EPYC 9R14 (Zen 4), idle, one thread, seven alternating rounds: nodes per second against the code
before. The round-to-round ratios of this run spread about two points either way.

| State | `bench` | 3 s searches |
|---|---|---|
| exchange evaluation pins, draw detection, king captures | +2.4% | +2.3% |
| and the undo stack | +1.5% | +3.8% |
| and the key history, occupancy, exchange fast path, king attackers | +4.3% | +3.9% |

Apple M4, `--release=fast`. The machine was running other builds and benchmarks at load average
15 to 20, so nps says nothing; the table gives what `/usr/bin/time -l` reports as the instructions
retired by `bench`, one run per build, back to back. The builds are commit 870eeab with these
changes alone, row by row: the absolute counts are not those of a build that also has the other
changes of pull requests #104 to #111.

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
| king attackers kept in the undo entry | 109.60 G | -0.1% |

That is 3.2% fewer instructions in all, 7320 to 7080 per node. Repeated runs of one build differed
by 0.1% to 0.4%, and by 1.3% when one was preempted heavily (such a run retires more), so the rows
of 0.1% and 0.2% are not resolved one by one. Elapsed cycles ranged from 44 G to 66 G between runs
of one build and do not resolve the change on this machine.

Time Profiler recordings of `bench` before and after (the second of a build that also had the
moved-piece test described below) show `undo_move` going from 1.3% to 0.7% of the samples and
`is_draw` and `draw_score` (1.7% together) disappearing into the node entry. They were taken under
different load and their other shares are not comparable.

## Tried and dropped

- **King attackers after a move from the moved piece alone.** In a position reached by a legal
  move the king of the side that did not move was not attacked before it, so afterwards only the
  moved piece, or a slider behind the square it left, can attack it. `play_move` tested just the
  moved piece (two table loads, no slider lookup) unless the origin square was on a line with the
  king, and Debug builds checked the result against the general query on every move. It retired
  0.2% fewer instructions on the M4 (109.60 G to 109.43 G), which the counts do not resolve, and
  on the EPYC 9R14 the build with it measured +3.3% on `bench` and +3.8% on 3 s searches against
  +4.3% and +3.9% without: nothing gained. The test of the origin square is a branch that depends
  on the position, taken for an estimated third of the moves, which is the likely price of the
  lookups it saves. It also left the stored attackers wrong after a move from a position set up
  with the side not to move in check.

## Looked at and left as they are

- **PEXT slider lookups.** BMI2 alone does not say that `pext` is fast (Zen 1 and Zen 2 run it in
  microcode), and the x86-64-v3 release build has to serve those CPUs. Every CPU with AVX-512 has
  a fast one, so the `avx512` release build (docs/BUILD.md) could select it soundly at compile
  time. It was not written: the magic lookups are 1.4% of `bench` on the M4, `pext` stands in for
  an and, a multiply and a shift and saves two small loads per lookup, and nothing here can time
  x86.
- **Narrowing the repetition scan**, see above.
- **Seeding the move generators with the stored king attackers.** Not built. They would skip a
  knight and a pawn table load and one branch of the loop that finds the pins, an estimated five
  of the 7100 instructions of a node, which the counts above cannot show. In exchange the
  generators would only be right for the side to move, which they do not require today.
- **Testing for an aligned enemy slider before the slider lookups of `in_check`.** The lookups
  do not hold anything up, since the result feeds a branch that is predicted not-in-check; a data
  dependent branch in front of them would. The undo entry removes the lookups instead.
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
