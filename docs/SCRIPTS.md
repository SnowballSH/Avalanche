# Scripts Reference

All scripts assume they're run from the repository root unless noted otherwise.

---

## Training Pipeline (recommended workflow)

These scripts form the end-to-end NNUE training pipeline. Run them in order:

### `scripts/datagen.sh`

**Goal**: Generate self-play training data in binary bulletformat.

The engine plays games against itself, recording quiet positions with search evaluations and game outcomes. Output is native bulletformat (32 bytes/position) — no conversion step needed.

**Usage**:
```bash
./scripts/datagen.sh                              # Use (nproc - 1) threads, run indefinitely
./scripts/datagen.sh 8                            # 8 threads, run indefinitely
./scripts/datagen.sh 8 120                        # 8 threads, stop after 120 minutes
./scripts/datagen.sh 8 0 books/UHO_4060_v4.epd   # 8 threads, use EPD opening book
./scripts/datagen.sh 8 60 books/noob_4moves.epd  # 8 threads, 60 min, with book
```

**Output**: `data/data_<timestamp>.bin`

**Notes**:
- Each thread has an independent PRNG (no data race).
- Ctrl+C to stop gracefully.
- ~500 pos/s/thread typical throughput.
- 50–200M positions recommended for a good network.
- **EPD book mode** (recommended): starts each game from a random book position with 2-4 random plies. Produces higher diversity data than startpos-only mode.

---

### `scripts/prepare_data.sh`

**Goal**: Shuffle and merge datagen output into a single training-ready file.

Shuffling is essential for good training — consecutive positions from the same game are highly correlated.

**Usage**:
```bash
./scripts/prepare_data.sh           # Merge all data/*.bin → data/training.bin
./scripts/prepare_data.sh myrun     # Merge all data/*.bin → data/myrun.bin
```

**Steps performed**:
1. Shuffles each `data_*.bin` individually (randomizes position order)
2. Interleaves all shuffled files into one merged file
3. Validates the output with `bullet-utils validate`
4. Splits off 5% as a test set (if >200k positions)

**Requires**: `bullet-utils` (auto-built if missing from `bullet/target/release/`)

---

### `scripts/train.sh`

**Goal**: Train an NNUE network from prepared data using the bullet framework.

**Usage**:
```bash
./scripts/train.sh                          # Train on data/training.bin (default)
./scripts/train.sh data/training.bin        # Explicit data path
./scripts/train.sh data/run1.bin data/run2.bin  # Multiple data files
```

**Output**: `training/checkpoints/avalanche-<N>/` directories containing:
- `quantised.bin` — ready-to-use NNUE file (803,904 bytes)
- `raw.bin` — f32 weights (for resuming training)
- `optimiser_state/` — AdamW state

**Configuration**: Edit `training/src/main.rs` to adjust hyperparameters (learning rate, superbatches, WDL proportion, etc.).

**GPU acceleration**: For NVIDIA GPUs, edit `training/Cargo.toml` to add `features = ["cuda"]` and set `CUDA_PATH`.

---

### `scripts/install_net.sh`

**Goal**: Install a trained network into the engine, rebuild, and verify with bench.

**Usage**:
```bash
./scripts/install_net.sh training/checkpoints/avalanche-400
```

**Steps performed**:
1. Copies `quantised.bin` to `nets/<name>.nnue`
2. Updates `build.zig` to embed the new net
3. Rebuilds the engine (`zig build --release=fast`)
4. Runs bench and updates `bench.nodes`

---

## Utility Scripts

### `scripts/update_bench.sh`

**Goal**: Rebuild the engine and refresh `bench.nodes` with the current node count.

Run this after any change that affects search behavior (new net, parameter tuning, movegen fix, etc.). CI asserts against this file.

**Usage**:
```bash
./scripts/update_bench.sh
```

---

### `build_all_v2.sh`

**Goal**: Cross-compile release binaries for all supported platforms and microarchitecture levels.

Produces x86_64 (v1–v4) for Windows/Linux/macOS plus aarch64-macos (Apple Silicon). Outputs go to `artifacts/bin/` and are zipped.

**Usage**:
```bash
VERSION="2.3.0" bash build_all_v2.sh
```

**Note**: Edit the `VERSION` variable at the top of the script before running.

---

---

## Legacy Scripts

These scripts have been superseded and are kept in `scripts/legacy/` for reference only.

| Script | Replaced by |
|--------|------------|
| `scripts/legacy/sprt.py` | `tools/test` — local SPRT runner (see [tools/README.md](../tools/README.md)); OpenBench for distributed testing |
| `scripts/legacy/score_games.py` | Datagen now writes binary bulletformat directly; no PGN scoring step needed |

