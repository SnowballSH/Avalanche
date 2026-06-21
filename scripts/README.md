# scripts/

Utilities for testing, training, and data generation.

## Testing

### `quick-test.sh` — fast sanity check

Plays a fixed number of games between the current working tree and a previous
commit. No SPRT — just runs the games and reports the score. Use it to catch
obvious regressions before submitting to OpenBench.

```sh
scripts/quick-test.sh              # 100 games vs HEAD~1
scripts/quick-test.sh HEAD~3 200   # 200 games vs 3 commits ago
scripts/quick-test.sh master 50    # 50 games vs master
```

Builds are cached by SHA in `.sprt-cache/bin/`, so re-running against the same
ref is instant.

**Requirements:** `zig`, `git`, `fastchess/fastchess`, `books/UHO_4060_v4.epd`.

### `sprt.py` — full SPRT testing

Runs proper Sequential Probability Ratio Test matches until a statistical bound
is reached. Wraps fastchess with configurable time controls, SPRT bounds, and
adjudication. Supports testing against a git ref or any external UCI engine.

```sh
scripts/sprt.py vs-commit HEAD~1                  # STC, gain bounds
scripts/sprt.py --tc ltc vs-commit v2.1.0         # long time control
scripts/sprt.py --bounds regression vs-commit master
scripts/sprt.py vs-engine /path/to/other-engine
scripts/sprt.py build HEAD~5                       # just build a ref
```

Run `scripts/sprt.py --help` for full option reference.

## Training & Data

| Script | Purpose |
|--------|---------|
| `train.sh` | Launch NNUE training (external `bullet` trainer) |
| `datagen.sh` | Run self-play data generation |
| `prepare_data.sh` | Preprocess raw self-play data for training |
| `install_net.sh` | Install a trained `.nnue` file into `nets/` |
| `update_bench.sh` | Rebuild and update `bench.nodes` after a search change |

## Legacy

`legacy/` contains older scripts kept for reference (e.g. `score_games.py`).
