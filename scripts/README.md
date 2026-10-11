# scripts/

Utilities for testing, building, training and data generation.

## Testing

### `quick-test.sh`: fast sanity check

Plays a fixed number of games between the current working tree and a previous
commit. No SPRT: it runs the games and reports the score. Use it to catch
obvious regressions before submitting to OpenBench.

```sh
scripts/quick-test.sh              # 100 games vs HEAD~1
scripts/quick-test.sh HEAD~3 200   # 200 games vs 3 commits ago
scripts/quick-test.sh master 50 4  # 50 games vs master, 4 games at a time
```

The third argument is the number of concurrent games; without it the script
uses the CPU count minus 2. The build of a ref is cached by commit in
`.sprt-cache/bin/`, so a second run against the same ref only builds the
working tree.

**Requirements:** `zig`, `git`, a fastchess binary at `fastchess/fastchess`,
`books/UHO_4060_v4.epd` (see [books/README.md](../books/README.md)).

### `match.sh`: fixed-length match between two binaries

```sh
scripts/match.sh <candidate binary> <reference binary> [games] [concurrency] [time control] [tag]
```

Plays a fixed number of games between two binaries and reports Elo without
SPRT. It is for screening candidates; `sprt.py` decides. The defaults are 500
games, 10 concurrent games, `10+0.1` and, as the tag, the candidate's file
name without a leading `Avalanche-`. The fastchess output is printed and saved
as `tmp/matches/<tag>.log`, the games as `tmp/matches/<tag>.pgn`. It needs the
same fastchess binary and book as `quick-test.sh`.

### `sprt.py`: full SPRT testing

Runs Sequential Probability Ratio Test matches until a statistical bound
is reached. Wraps fastchess with configurable time controls, SPRT bounds, and
adjudication. Supports testing against a git ref or any external UCI engine.

```sh
scripts/sprt.py vs-commit HEAD~1                  # STC, gain bounds
scripts/sprt.py --tc ltc vs-commit v2.1.0         # long time control
scripts/sprt.py --bounds regression vs-commit master
scripts/sprt.py vs-engine /path/to/other-engine
scripts/sprt.py build HEAD~5                       # just build a ref
```

Run `scripts/sprt.py --help` for the full option reference. A relative
`--book` or `--pgn` path is resolved from the directory the script is called
from.

### `uci_protocol_test.py`: end-to-end UCI checks

```sh
python3 scripts/uci_protocol_test.py                                                  # zig-out/bin/Avalanche
python3 scripts/uci_protocol_test.py node web/src/node/cli.ts zig-out/web/avalanche.wasm  # the wasm build
```

Drives one engine process, given as the command to start it, through options,
search, pondering, MultiPV, Chess960 and strength limiting, with the standard
library's `unittest`. Tests for options a build does not advertise are
skipped. Every test ends by stopping the search and restoring the options it
changed; an engine that exits fails that test, and the next one starts a new
process.

### Checks of a build, and their reference data

| Script | Purpose |
|--------|---------|
| `verify_binary.sh` | Run a built binary and check its `bench` node count against `bench.nodes` and its `nnue-speed` checksum against `nnue-speed.checksum` (and, optionally, the SIMD paths it reports) |
| `update_bench.sh` | Rebuild and rewrite `bench.nodes` and `nnue-speed.checksum` after a search or network change |
| `openbench_build_check.sh` | Build as OpenBench does (`make EXE= EVALFILE=`) and parse `bench` with its regular expressions; see "OpenBench" in [docs/BUILD.md](../docs/BUILD.md) |
| `make_datatool_fixtures.sh` | Regenerate the `tools/datatool` test fixtures |

## Building

| Script | Purpose |
|--------|---------|
| `build_release.sh` | Build, check and package the release binaries; see "Release matrix" in [docs/BUILD.md](../docs/BUILD.md) |
| `install_net.sh` | Copy a checkpoint's `quantised.bin` into `nets/`, make it the default network and refresh `bench.nodes` and `nnue-speed.checksum` |

## Training & Data

| Script | Purpose |
|--------|---------|
| `train.sh` | Build and run the NNUE trainer in `training/`; see "Training" in [docs/NNUE.md](../docs/NNUE.md) |
| `datagen.sh` | Run self-play data generation |
| `datagen_a_lot.sh` | Launch a bulk datagen schedule from `datagen_a_lot.json` |
| `datagen_throughput.sh` | Measure datagen positions per second and per thread at 6000 nodes |
| `prepare_data.sh` | Convert, filter and shuffle raw self-play data into one training file |
| `fit_wdl.py` | Refit the UCI win-rate model (`src/engine/wdl.zig`) on self-play data; see [docs/UCI.md](../docs/UCI.md) |

The usage of `datagen.sh`, `datagen_a_lot.sh`, `datagen_throughput.sh` and
`prepare_data.sh` is in the "Scripts" section of
[docs/DATAGEN.md](../docs/DATAGEN.md), next to the datagen command line, the
output contract and validation. A `datagen.sh` run with a duration ends by
SIGTERM; check its files with `tools/datatool validate` before
`prepare_data.sh` uses them.

Tune the book composition of a bulk run by editing
`scripts/datagen_a_lot.json`. Each job's `count` is the number of workers to
launch for that book; missing `threads`, `duration`, and `engine_args` values
inherit from `defaults`.

Useful datagen engine args include `plies=8-10` for no-book opening plies,
`bookplies=0-2` for extra plies after book positions, `randsee=-200` for the
opening move SEE filter, and `ttmb=4` for per-side TT memory per worker.

## Python scripts

```sh
ruff check scripts
ruff format --check scripts
python3 -m unittest discover -s scripts
```

The third command runs the tests of the fit in `test_fit_wdl.py` and needs
numpy 2 or later. `fit_wdl.py` declares numpy in inline script metadata, so
`uv run scripts/fit_wdl.py ...` works without installing it.

`ruff.toml` selects every rule and ignores six families:

| Rule | Why it is off |
|------|---------------|
| `D` | docstrings are kept to non-trivial logic |
| `T20` | command-line tools print |
| `PT` | the tests use the standard library's `unittest`, not pytest |
| `S603` | the scripts start the engine, zig, git and fastchess by design |
| `INP001` | `scripts/` is not a package |
| `COM812` | the formatter owns trailing commas |

It excludes `deps` (vendored) and `tcec/version.py` (a token TCEC reads, not
Python).
