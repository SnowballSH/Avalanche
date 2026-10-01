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
  out=PATH      output file, must not exist (default data_<seed>.viribin)
  format=viri|bullet (default viri)
```

The thread count is required (the old implicit default of 7 is gone). Malformed, unknown or repeated options (a key
given twice, or two books), an unreadable or empty book, a book line that is not a legal position (datagen names the
line and the reason), and an existing output file are errors: datagen prints the reason and exits with status 2. A
worker thread that fails (for example on a write error) stops the whole run, names the worker and the error, and
exits with status 1.

## Output

The default format is viriformat: per game a 32-byte packed start position (with the white-relative result), one
4-byte `(move, score)` pair per searched position, and a 4-byte zero terminator. `format=bullet` writes filtered
32-byte bulletformat records instead.

Games are written whole under a lock, so a run that ends through `positions=` contains only complete games. A run
killed by a signal may end inside a game; such files must be discarded (the batch pipeline only keeps runs that
exited with status 0). The output file is created exclusively and is never overwritten.

On success the only stdout output is one JSON line:

```json
{"positions":2154,"games":19,"white_wins":8,"draws":5,"black_wins":6,"seconds":1.44,"seed":1,"raw_eval":false}
```

The banner and per-thread progress go to stderr. `positions` counts `(move, score)` pairs, i.e. positions before
training filters. `raw_eval` is always present and repeats the `raweval` option.

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

`seed` derives one generator seed per thread with splitmix64, so every seed (including 0) gives distinct streams. Each thread's game stream is deterministic; files
are byte-identical across runs only with one thread, because threads interleave whole games in arrival order.

## Adjudication

Games end by checkmate or stalemate (decided first, so a mate on the fiftieth move still counts), repetition,
the fifty-move rule, insufficient material, 500 plies, or score adjudication:
a win after 4 consecutive searches beyond ±2500 cp, a draw after 12 consecutive searches within ±5 cp once ply 50 is
reached. Datagen never probes tablebases: endgames are played out so low-material positions keep search evals, and
labels are cleaned afterwards with `Avalanche tbfilter` on bulletformat data.

## Chess960

Every book line is validated before datagen starts: eight ranks of eight squares, known pieces, one king per side,
no pawns on the back ranks, a side to move, well-formed castling and en-passant fields, and the side not to move not
in check. Books may contain Chess960 and Double Fischer Random positions in Shredder-FEN or X-FEN. Castling moves are stored
king-to-rook-square with the castle flag, and castling rooks are marked as "unmoved rook" pieces in the packed start
position, as viriformat specifies. EPD opcodes after the FEN fields are ignored.

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

## OpenBench build

OpenBench runs `make -j EXE=<path> CC=<compiler> EVALFILE=<absolute .nnue path>`. The Makefile passes `EVALFILE` to
`zig build -Dnet=...` (absolute and relative paths both work), ignores `CC`, and moves the binary to `EXE`.
`scripts/openbench_build_check.sh` reproduces this build and OpenBench's bench parsing.

## Tablebase cleaning

`Avalanche tbfilter <in.viribin> <out.viribin> tb=<dir[:dir]> men=6 rule50=keep format=viri` replays every game and,
for each position of at most `men` pieces without castling rights, probes the Syzygy WDL tables. When the table's
result for the side to move contradicts the game's result from that side's view, the position's stored eval is
replaced by 32767. Datagen never writes that value (evals are clamped to ±32000) and the trainer's filter drops every
position whose |eval| reaches its `max_eval`, so contradicted positions are excluded from training while the game,
its moves and every other position stay unchanged. Cursed wins and blessed losses are kept under `rule50=keep`; a
missing table keeps the position. The command prints one JSON line of counts (`games`, `positions`, `over_men`,
`castling`, `failed`, `ambiguous`, `agree`, `masked`) and refuses to overwrite an existing output file.

WDL tables assume a zero fifty-move counter. A tablebase win recorded in a drawn game is masked even when the game's
counter was already high, although such a win may not be convertible before the fifty-move rule; telling the two
apart needs DTZ tables. On an endgame-book sample (400k positions), about 6% of positions were masked, 98% of them
with a non-zero counter; an independent check with python-chess's Syzygy prober agreed on every probed position.

## Network eval scale

Search margins are tuned to the production network's eval scale, and every newly trained network comes out slightly
louder or quieter. Before an SPRT, rescale the candidate to the production network:

```
Avalanche netscale net=<candidate.nnue> ref=<reference.nnue> positions=<file.epd> out=<scaled.nnue> [limit=<n>]
```

For both networks the tool takes the mean absolute raw network output (centipawns for the side to move, before the
eval post-scaling, the drawish division and correction history) over the positions that are not in check, each
evaluated from a fresh accumulator. `out` is a copy of `net` whose output-layer weights and biases are multiplied by
`factor = ref_mean_abs / candidate_mean_abs` and rounded to nearest; every other byte is identical. `limit` uses only
the first `n` positions not in check. An invalid position line is an error naming the line.

It prints one JSON line: `positions`, `ref_mean_abs`, `candidate_mean_abs`, `factor` and `scaled_mean_abs`, the last
measured on the written network to show the rounding error. Nothing is written, and the exit code is non-zero, when
a scaled output weight would leave [-128, 127] (inference multiplies a weight by an activation of up to 255 in an
i16, and `EvalFile` rejects weights outside that range) or a scaled bias would overflow i16.
