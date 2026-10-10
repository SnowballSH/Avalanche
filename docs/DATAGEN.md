# Self-play data generation

## Command line

```
Avalanche datagen <threads> [book.epd | book=path] [key=value ...]
  nodes=N       soft node limit per move (default 10000)
  hardmult=N    hard limit = nodes * N (default 8)
  plies=A-B     random plies without a book (default 8-10)
  bookplies=A-B random plies after a book line (default 0-2)
  randsee=N     SEE threshold for random moves (default -200)
  ttmb=N        TT MiB per side per thread (default 4)
  positions=N   stop after at least N positions, at a game boundary (default: unbounded)
  seed=N        deterministic seed (default: random)
  raweval=BOOL  true labels with the unscaled network output (default false)
  out=PATH      output file, must not exist (default data_<seed>.viribin, data_<seed>.bin with format=bullet)
  format=viri|bullet (default viri)
```

The thread count is required. Every value has a range, and a value outside it is an error like any other malformed
value:

| Option | Range |
|--------|-------|
| threads | 1 to 4096 |
| `nodes`, `hardmult` | 1 to 4294967295 each, so their product always fits the 64-bit node counter |
| `plies`, `bookplies` | `A` or `A-B` with 0 ≤ A ≤ B ≤ 500 |
| `randsee` | -10000 to 10000 |
| `ttmb` | 1 to 1048576, the maximum of the UCI `Hash` option |
| `positions` | 1 to 2^64 - 1 |
| `seed` | 0 to 2^64 - 1, decimal or with a `0x`, `0o` or `0b` prefix |
| `raweval` | exactly `true` or `false` |

Malformed, unknown or repeated options (a key given twice, or two books), an unreadable or empty book, a book line
that is not a legal position (datagen names the line and the reason), and an existing output file are errors: datagen
prints the reason and exits with status 2. A worker thread that fails stops the whole run, names the worker and the
error, and exits with status 1. Besides I/O errors a worker fails for two reasons that lie in the options:

- `NoUsableOpening`: 10000 games in a row were discarded (see [Openings](#openings)), so the book or the `plies`
  setting yields nothing to record.
- `NodeBudgetBelowDepthOne`: the hard node limit ended a search before its first iteration completed. Such a search
  has no score, and the value it returns is a mate score that must not reach the data.

Each worker's transposition tables are allocated before the first game, and a table that cannot be allocated fails
the run instead of leaving a worker without one.

`datagen`, `tbfilter` and `netscale` read their `key=value` arguments through one module
(`src/engine/datagen/arguments.zig`): an argument is split at its first `=`, a key may be given once, and a value
that does not parse or lies outside its range is an error naming the key. No tool replaces a bad value by a default.

## Output

The default format is viriformat: per game a 32-byte packed start position, one 4-byte `(move, score)` pair per
searched position, and a 4-byte zero terminator. All integers are little-endian.

| Bytes | Start position field |
|-------|----------------------|
| 0-7 | occupancy, one bit per occupied square, a1 = bit 0 |
| 8-23 | one 4-bit code per occupied square, in ascending square order, low nibble first: bits 0-2 are the piece (0 pawn, 1 knight, 2 bishop, 3 rook, 4 queen, 5 king, 6 a rook that may still castle), bit 3 is set for Black |
| 24 | bit 7 is set when Black is to move; bits 0-6 are the en-passant square, 64 when there is none |
| 25 | halfmove clock, at most 255 |
| 26-27 | fullmove number, at most 65535 |
| 28-29 | White-relative score of the position, clamped to ±32000 |
| 30 | game result: 0 Black wins, 1 draw, 2 White wins |
| 31 | 0 |

A move is 16 bits: the origin square in bits 0-5, the destination in bits 6-11, the promotion piece in bits 12-13
(0 knight, 1 bishop, 2 rook, 3 queen) and the move type in bits 14-15 (0 normal, 1 en passant, 2 castling,
3 promotion). The score next to it is White-relative and clamped to ±32000.

The engine reads the format back through the code that writes it. A start position is turned into a FEN whose
castling field names the files of the rooks that may still castle (Shredder-FEN), which the position parser accepts
for standard chess and Chess960 alike. A stored move is decoded by searching the legal moves for the one that
encodes to the same 16 bits, so decoding cannot disagree with encoding, and a move that is not legal is an error. A
reader checks every start position before using it: at most 32 pieces, no unknown piece code, an en-passant code of
at most 64, a result of at most 2, and a position that would pass as a book line (see [Openings](#openings)). It
also refuses a game of more than 1920 moves, the longest a position can replay. A file that fails any of this is
reported as invalid, and the offending game is not replayed.

`format=bullet` writes 32-byte bulletformat records instead. A record holds the board from the side to move's point
of view (flipped vertically when Black is to move), and its score and result are relative to that side (0 loss,
1 draw, 2 win). Only quiet positions are recorded: after ply 16 (ply 8 with a book), not in check, with a best move
that neither captures, promotes nor gives check, and with a score inside ±2000 cp.

Games are written whole under a lock, each viriformat game with a single write, so a run that ends through
`positions=` contains only complete games. Datagen handles no signals: a killed run (Ctrl+C, `timeout`, the duration
of `scripts/datagen.sh`) stops wherever it is and prints no summary. Its file almost always still ends at a game
boundary, because a game reaches the file in one write, but nothing guarantees it, so check such a file with
`datatool validate` (see [Validation](#validation)) before using it. Discard the output of a run that datagen itself
ended with status 1 or 2. The output file is created exclusively and is never overwritten.

On success the only stdout output is one JSON line:

```json
{"positions":2154,"games":19,"white_wins":8,"draws":5,"black_wins":6,"discarded_games":2,"seconds":1.44,"seed":1,"raw_eval":false}
```

The banner and per-thread progress go to stderr. `positions` counts `(move, score)` pairs, i.e. positions before
training filters. `games` counts written games and `discarded_games` the ones that were played but left nothing in
the file. `raw_eval` is always present and repeats the `raweval` option.

## Openings

A game starts from a random line of the book, or from the start position without one, and plays a random number of
random moves in the `bookplies` (or `plies`) range. A random move is drawn from the legal moves whose static
exchange value is at least `randsee`; castling, en passant and promotions always qualify, and when no move qualifies
any legal move may be drawn.

The first search after the random moves does two jobs. It screens the opening: when its score is beyond ±600 cp the
game is discarded. Otherwise it also supplies the first recorded move and score, so no search is spent on screening
alone. A game is discarded as well when it is over before a position is recorded, because the book line or the random
moves ran into mate, stalemate or a rule draw (or, in bulletformat, because no position passed the recording
filters). A worker that discards 10000 games in a row stops with `NoUsableOpening`: a book of decided or finished
positions would otherwise keep the run busy forever without writing anything.

Every book line is validated before datagen starts: eight ranks of eight squares, known pieces, one king per side,
no pawns on the back ranks, a side to move, well-formed castling and en-passant fields, the side not to move not in
check, and no more than a game record can hold, which is 32 pieces and a fullmove number of 65535. The fullmove
field is read by the number parser the position code uses, so the two agree on what a number is (`65_536` is one,
and is refused). EPD opcodes after the FEN fields are ignored. The whole book is refused at its first bad line,
because the position code trusts its input: a bad line would be played as a broken board or read out of bounds.
`netscale` and `genfens` load their position files through the same loader (`src/engine/datagen/book.zig`).

## Raw evaluation

The engine post-processes the network output before the search sees it: a division by 8 for drawish material, a
scaling by `(700 + phase_material / 32 - 5 * fifty) / 1024`, and contempt. With the default `raweval=false` the
recorded scores carry those transformations, so a network trained on them learns the scaled values and the engine
then scales its output a second time at inference. `raweval=true` generates labels on the network's own scale: the
datagen searches use the network output as is, and contempt is forced to 0. Positions the network is not used for
(no pawns and at most a rook or two minor pieces in total) keep the hand-crafted evaluation with its usual
corrections in both modes.

Nothing is rescaled to compensate: the adjudication thresholds, the opening rejection threshold (600 cp), the
bulletformat recording window and the stored scores all operate on raw-scale scores, which are larger in magnitude
than scaled ones (by about 1024/900 with full material and more as material comes off or the fifty-move counter
grows). Datasets generated with and without `raweval=true` therefore label the same position differently and must
not be mixed blindly; tell them apart by the `raw_eval` field of the summary line and the `Eval:` banner line.

The search itself is not retuned, so raw-eval searches behave a little differently. Pruning margins and the
correction-history limits are fixed centipawn amounts and are therefore relatively tighter against the larger raw
scores. Without the fifty-move decay the scores of shuffling positions do not drift towards zero, so draw
adjudication fires less often, and win adjudication at 2500 cp is reached earlier. Positions without pawns and with
phase below 3 keep their scaled hand-crafted labels inside a raw dataset; filtering them out of raw datasets is
recommended.

Each worker owns two transposition tables, one per side, shared with no other worker. They are aged, not cleared,
between games, so entries (including static evaluations) outlive a game. This is safe because the evaluation mode is
fixed for the whole run; if the mode ever becomes switchable per game, the tables must be cleared on a switch.

## Determinism

`seed` derives one generator seed per thread with splitmix64, so every seed (including 0) gives distinct streams.
Each thread's game stream is deterministic; files are byte-identical across runs only with one thread, because
threads interleave whole games in arrival order.

## Adjudication

Games end by checkmate or stalemate (decided first, so a mate on the fiftieth move still counts), repetition,
the fifty-move rule, insufficient material, 500 plies, or score adjudication:
a win after 4 consecutive searches beyond ±2500 cp, a draw after 12 consecutive searches below 5 cp in absolute
value once ply 50 is reached. Datagen never probes tablebases: endgames are played out so low-material positions keep
search evals, and labels are cleaned afterwards with `Avalanche tbfilter` (see
[Tablebase cleaning](#tablebase-cleaning)).

## Chess960

Books may contain Chess960 and Double Fischer Random positions in Shredder-FEN or X-FEN. Castling moves are stored
king-to-rook-square with the castle type, and castling rooks are marked as rooks that may still castle in the packed
start position, as viriformat specifies.

## Validation

`tools/datatool` (Rust, `viriformat` crate) checks data independently of the engine:

```sh
cargo run --release --manifest-path tools/datatool/Cargo.toml -- validate chunk.viribin --expect-positions 2000000 --filter training/filter.toml
cargo run --release --manifest-path tools/datatool/Cargo.toml -- dupes chunk-*.viribin --sample-per-mille 10
```

`validate` replays every move with the crate's Chess960-aware move generator and reports counts, results, game
lengths, an absolute-eval histogram and, with `--filter`, how many positions pass the training filter. It exits
non-zero for truncated or illegal data, or when fewer than `--expect-positions` positions are present. `dupes`
estimates the duplicate-position rate from a hash-selected sample.

## Scripts

`scripts/datagen.sh [threads] [duration_minutes] [book.epd] [datagen option ...]` runs `datagen` in `data/`, building
the engine first when `zig-out/bin/Avalanche` is missing. `threads` defaults to one less than the CPU count. The book
is optional and may be given relative to the repository root; every further argument (`plies=8-10`, `ttmb=4`,
`format=bullet`, ...) is passed to datagen, which names the output `data/data_<seed>.viribin` (`.bin` for
bulletformat). The engine has no time limit of its own, so a duration ends the run with SIGTERM, and with the default
duration of 0 the run lasts until `positions=` is reached or it is interrupted. Files from runs that were killed
either way fall under the rule in [Output](#output): validate them before use. The script exits with the engine's
status and counts only the expiry of the duration as success, so a rejected option or a failed worker fails the
script.

`scripts/datagen_a_lot.sh` starts many `datagen.sh` workers from the schedule in `scripts/datagen_a_lot.json`; its
`--help` describes the file and the command-line overrides. It exits non-zero when any worker did.

`scripts/datagen_throughput.sh <threads> <positions> [datagen option ...]` prints one JSON line with the positions
per second and per thread of the current build, at 6000 nodes with all threads loaded. The extra options must not
repeat `nodes`, `hardmult`, `positions`, `seed` or `out`, since datagen rejects repeated keys.

`scripts/prepare_data.sh [output_name]` turns every `data/*.viribin` into one shuffled bulletformat file,
`data/good_data/<output_name>` (default `training.bin`), with `bullet-utils` (on `PATH` or at
`bullet/target/release/bullet-utils`): each file is converted through `training/filter.toml`, the results are
interleaved and then shuffled within `SHUFFLE_MEM_MB` (default 16384). The raw files are moved to `data/old_data/`.
It takes the files as they are and does not validate them.

## OpenBench build

OpenBench runs `make -j EXE=<path> CC=<compiler> EVALFILE=<absolute .nnue path>`. The Makefile passes `EVALFILE` to
`zig build -Dnet=...` (absolute and relative paths both work), ignores `CC`, and moves the binary to `EXE`.
`scripts/openbench_build_check.sh` reproduces this build and OpenBench's bench parsing.

## Opening generation for OpenBench

For its datagen workloads OpenBench asks the engine for openings with the command
`genfens N seed S book <None|path>` and reads `N` lines of the form `info string genfens <fen>`. In Avalanche
`genfens` is one of the commands of the UCI loop listed in [UCI.md](UCI.md): it prints the openings and then ends the
engine without waiting for a `quit`. `frc` or `dfrc` is accepted as a further word.

Each opening is a random book line followed by 1 to 3 random legal moves or, without a book, the start position
(with `frc` a random Chess960 start, with `dfrc` an independent random start for each side) followed by 9 to 12
random legal moves. Positions in check or without a legal move are skipped. The same seed gives the same openings.

A count or seed that is not a number, an unknown word, a missing value and a book that does not load (see
[Openings](#openings)) are errors: `genfens` names the fault on stderr and prints no opening, where a silent
fallback would hand OpenBench openings from the wrong source. It also stops with an error after 10000 consecutive
skipped positions, which only a book of finished positions produces.

## Tablebase cleaning

```
Avalanche tbfilter <input | in=PATH> <output | out=PATH> tb=<dir[:dir]> [format=bullet|viri] [men=N]
                   [rule50=keep|on|off] [threads=N] [max=N]
```

`tbfilter` probes the Syzygy WDL tables for every position of at most `men` pieces (2 to 7, default 5, and never
more than the loaded tables cover) and removes from the training data the positions whose tablebase result
contradicts the game result. Cursed wins and blessed losses contradict nothing under the default `rule50=keep`; `on`
treats both as draws and `off` as the win or loss they are without the fifty-move rule. A failed probe or missing
table keeps the position.

An argument with `=` in it is an option, so a path that contains `=` cannot be given bare: name it, as `in=PATH` or
`out=PATH`. A bare argument is the input, or the output once the input is given.

The two data formats need different treatment, so the format must be known. It is taken from the input's extension,
`.bin` for bulletformat and `.viribin` for viriformat, the extensions datagen gives its files, and `format=`
overrides the extension. When neither decides, `tbfilter` stops with an error instead of guessing: the bulletformat
code run over a viriformat file would treat every 32-byte window as a record, drop some of them and still report
success. The output is written in the format of the input, and an output whose extension names the other format is
refused, because the next run would take that file for what its name says. As a second line of defence a
bulletformat input must be a whole number of 32-byte records, and a viriformat input must replay from its first game
to its last. Unknown options, repeated options and malformed values are errors, as are a third path and equal input
and output paths. Every error exits with status 1.

### Viriformat

`tbfilter` replays every game and probes each position without castling rights. When the table's result for the
side to move contradicts the game's result from that side's view, the position's stored eval is replaced by 32767.
Datagen never writes that value (evals are clamped to ±32000) and the trainer's filter drops every position whose
|eval| reaches its `max_eval`, so contradicted positions are excluded from training while the game, its moves and
every other position stay unchanged. The command prints one JSON line of counts (`games`, `positions`, `over_men`,
`castling`, `failed`, `ambiguous`, `agree`, `masked`) and refuses to overwrite an existing output file. `threads=`
and `max=` do not apply and are errors.

WDL tables assume a zero fifty-move counter. A tablebase win recorded in a drawn game is masked even when the game's
counter was already high, although such a win may not be convertible before the fifty-move rule; telling the two
apart needs DTZ tables. On an endgame-book sample (400k positions), about 6% of positions were masked, 98% of them
with a non-zero counter; an independent check with python-chess's Syzygy prober agreed on every probed position.

### Bulletformat

Records are independent, so a contradicted record is dropped from the output and the work is split over `threads`
workers, each filtering a contiguous share of the input into a part file (`<output>.part<N>.tmp`); the parts are
concatenated in order and removed. `threads` (1 to 256) defaults to the CPU count but at most 32, because the work
is bound by disk I/O, which a few dozen streams saturate. `max=N` filters only the first `N` records, and the output
then holds nothing from the rest.

A record stores neither castling rights nor an en-passant square. It is probed as a position without castling
rights, and a record in which an en-passant capture is possible on the board (a pawn of the side to move on its
fifth rank next to an enemy pawn) is kept unprobed, since the capture may or may not be legal and can change the
result. Records that cannot be a position (an unknown piece code, not exactly one king per side, a result above 2)
are counted as anomalies and kept.

The report goes to stderr: the counts per category, the probed and dropped records per piece count, and a matrix of
recorded against tablebase results. A failed worker, a short read or an output whose size does not match the count of
kept records fails the run and removes what was written. Unlike the viriformat mode, this mode replaces an existing
output file.

## Network eval scale

Search margins are tuned to the production network's eval scale, and every newly trained network comes out slightly
louder or quieter, which mis-measures it in an SPRT. Measure the candidate against the production network:

```
Avalanche netscale net=<candidate.nnue> ref=<reference.nnue> positions=<file.epd> [limit=<n>]
```

then give the candidate `EvalScale=<eval_scale>` in the SPRT (the reference keeps the default 1000).

Both networks are evaluated by the build that runs the tool, so both must have its architecture (`-Dhead`, see
[NNUE.md](NNUE.md)): the default build compares multi-layer networks, and to compare two single-layer networks,
build with one of them as `-Dnet`. A file of the other architecture is refused with the message `EvalFile` gives for
it.

For both networks the tool takes the mean absolute raw network output (centipawns for the side to move, before
`EvalScale`, the eval post-scaling, the drawish division and correction history) over the positions the engine would
evaluate with the network. Positions in check are skipped, and so are positions with no pawns and a phase below 3,
which the engine scores with its classical endgame evaluation instead. `limit` uses only the first `n` positions
that remain. An invalid position line is an error naming the line. Use a representative set of quiet positions
(for example a sample of the positions the network was trained on, or a large opening book), not a handful of lines:
the factor is an average and depends on the mix of material and game phase.

It prints one JSON line: `positions`, `ref_mean_abs`, `candidate_mean_abs`, `factor` (`ref_mean_abs /
candidate_mean_abs`) and `eval_scale` (`factor` in permille, rounded). When `eval_scale` falls outside the option's
500–2000 range the line is still printed, with a warning and exit code 1. Exit code 2 means bad options.

`EvalScale` multiplies the network output as it enters the static evaluation (`raw * EvalScale / 1000`, truncated),
so the post-scaling, correction history and the hash table all see the scaled value; the default is an exact
identity. The network file is never rewritten: the output weights of a single-layer network are small integers (at
most 127 in magnitude), so re-rounding them adds eval noise of about 10 cp RMS per position that a mean cannot show,
and a network whose weights already sit at the 127 clip, as Nezha's do, could not be scaled up at all. Datagen and
`netscale` run at the default scale and record the unscaled output.
