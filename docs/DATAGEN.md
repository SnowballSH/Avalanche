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
  out=PATH      output file, must not exist (default data_<seed>.viribin)
  format=viri|bullet (default viri)
```

The thread count is required (the old implicit default of 7 is gone). Malformed or unknown options, an unreadable
or empty book, a book line that is not a legal position (datagen names the line and the reason), and an existing
output file are errors: datagen prints the reason and exits with status 2. A worker thread that fails (for example on
a write error) stops the whole run, which then exits non-zero.

## Output

The default format is viriformat: per game a 32-byte packed start position (with the white-relative result), one
4-byte `(move, score)` pair per searched position, and a 4-byte zero terminator. `format=bullet` writes filtered
32-byte bulletformat records instead.

Games are written whole under a lock, so a run that ends through `positions=` contains only complete games. A run
killed by a signal may end inside a game; such files must be discarded (the batch pipeline only keeps runs that
exited with status 0). The output file is created exclusively and is never overwritten.

On success the only stdout output is one JSON line:

```json
{"positions":2154,"games":19,"white_wins":8,"draws":5,"black_wins":6,"seconds":1.44,"seed":1}
```

The banner and per-thread progress go to stderr. `positions` counts `(move, score)` pairs, i.e. positions before
training filters.

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
