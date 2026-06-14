# NNUE Training Pipeline for Avalanche

This documents the complete pipeline for training Avalanche's NNUE network, from data generation through to installing the trained net in the engine.

## Architecture

Avalanche uses a `(768 → 512)x2 → 1x8` perspective network:
- **Input**: Chess768 (2 × 6 × 64 = 768 features, dual perspective)
- **Hidden layer**: 512 neurons with Squared Clipped ReLU (SCReLU)
- **Output**: 8 buckets via `MaterialCount<8>` (bucket = `(piece_count - 2) / 4`)
- **Quantization**: QA=255 (L0 weights/bias), QB=64 (L1 weights), QA×QB=16320 (L1 bias)
- **Eval scale**: 400 (sigmoid(cp/400) maps centipawns to win probability)

## Prerequisites

```bash
# Build the engine
zig build --release=fast

# Build the trainer (training/ uses bullet as a git dependency, fetched automatically)
cd training && cargo build --release && cd ..

# Clone bullet for bullet-utils (data shuffling/validation tool, not tracked in git)
git clone https://github.com/jw1912/bullet
cd bullet && cargo build --release -p bullet-utils && cd ..
```

## Step 1: Data Generation

The engine generates binary bulletformat data directly (32 bytes/position, no conversion needed).

```bash
# Generate data (uses N-1 cores by default, runs until Ctrl+C)
./scripts/datagen.sh

# Specify threads and duration
./scripts/datagen.sh 8 60       # 8 threads for 60 minutes
./scripts/datagen.sh 4 0        # 4 threads, run indefinitely

# Use an EPD opening book for better position diversity (recommended)
./scripts/datagen.sh 8 0 books/UHO_4060_v4.epd
./scripts/datagen.sh 8 120 books/noob_4moves.epd
```

**Opening book mode** (recommended): When an EPD file is provided, each game starts from a random book position and applies 2-4 random plies for minor diversification. This produces much higher position diversity than starting from startpos every game.

**Without a book**: The engine starts from the standard starting position and applies 9-12 random plies for opening diversity. This still works but produces less varied data.

Output goes to `data/data_<timestamp>.bin`. Each position is 32 bytes containing:
- Occupancy bitboard (STM-relative)
- Packed piece data (nibble-packed, ordered by occupancy LSB)
- Score (STM-relative centipawns)
- Result (0=loss, 1=draw, 2=win, STM-relative)
- King squares

**Recommended data volume**: 50-200 million positions for a good net. At typical speeds (~500 pos/s/thread), 8 threads generates ~50M positions in ~3.5 hours.

### Multi-run datagen

Run the datagen multiple times (or on multiple machines) to accumulate data files:

```bash
# Run 1
timeout 2h ./zig-out/bin/Avalanche datagen 8
# Run 2
timeout 2h ./zig-out/bin/Avalanche datagen 8
# ... each run creates a new data_<timestamp>.bin in the current directory
```

Move all `.bin` files into the `data/` directory before preparing.

## Step 2: Prepare Training Data

Shuffle and interleave the data files for optimal training:

```bash
./scripts/prepare_data.sh
```

This:
1. Shuffles each `.bin` file independently (randomizes position order within each file)
2. Interleaves all shuffled files into `data/training.bin`
3. Validates the merged file
4. Splits off 5% as `data/training_test.bin` (if enough data)

## Step 3: Train

```bash
./scripts/train.sh
# Or with explicit data paths:
./scripts/train.sh data/training.bin
./scripts/train.sh data/run1.bin data/run2.bin
```

The trainer uses bullet's `DirectSequentialDataLoader` which reads the binary format directly. Training parameters (in `training/src/main.rs`):

| Parameter | Default | Notes |
|-----------|---------|-------|
| Hidden size | 512 | Must match engine's `HIDDEN_SIZE` |
| Output buckets | 8 | Must match engine's `OUTPUT_SIZE` |
| Batch size | 16,384 | Larger = more stable gradients |
| Superbatches | 400 | ~40B position-visits total |
| Initial LR | 0.001 | Standard AdamW starting rate |
| Final LR | ~7.3e-6 | Cosine decay over all superbatches |
| WDL proportion | 0.75 | Blend: 75% game result, 25% search score |
| Save rate | 20 | Checkpoint every 20 superbatches |

Checkpoints are saved to `training/checkpoints/avalanche-<N>/`. Each contains:
- `quantised.bin` — the ready-to-use NNUE file (803,904 bytes with padding)
- `raw.bin` — f32 weights for resuming training
- `optimiser_state/` — AdamW state for resuming

### GPU Training (recommended)

For NVIDIA GPUs with CUDA, add the feature to `training/Cargo.toml`:
```toml
bullet = { git = "https://github.com/jw1912/bullet", package = "bullet_lib", features = ["cuda"] }
```
Then rebuild with `CUDA_PATH` set:
```bash
cd training
CUDA_PATH=/usr/local/cuda cargo build --release
```

CPU training works but is ~10-50x slower depending on GPU.

## Step 4: Install the Network

```bash
./scripts/install_net.sh training/checkpoints/avalanche-400
```

This copies `quantised.bin` as the engine's NNUE file, updates `build.zig`, rebuilds, and runs bench to establish the new node count.

### Manual installation

```bash
cp training/checkpoints/avalanche-400/quantised.bin nets/new_net.nnue
# Edit build.zig: change the nets/ path in addAnonymousImport to "nets/new_net.nnue"
zig build --release=fast
./zig-out/bin/Avalanche bench
# Update bench.nodes with the new count
```

## Step 5: Verify with SPRT

Test the new net against the baseline:

```bash
# Build both versions
# ... (current engine is "new", checkout previous commit for "old")

# Run SPRT with fastchess
./fastchess/build/fastchess \
    -engine cmd=./new_engine name=New \
    -engine cmd=./old_engine name=Old \
    -each tc=5+0.05 \
    -rounds 2000 \
    -openings file=books/UHO_4060_v4.epd format=epd order=random \
    -sprt elo0=-5 elo1=5 alpha=0.05 beta=0.05
```

## Weight Layout Reference

The quantised.bin file has this exact memory layout (little-endian, x86):

| Offset | Size | Field | Shape | Quant |
|--------|------|-------|-------|-------|
| 0 | 786,432 | L0 weights | [768][512] i16 | ×255 |
| 786,432 | 1,024 | L0 bias | [512] i16 | ×255 |
| 787,456 | 16,384 | L1 weights | [8][1024] i16 | ×64 |
| 803,840 | 16 | L1 bias | [8] i16 | ×16320 |
| 803,856 | 48 | Padding | zeros | — |
| **Total** | **803,904** | | | |

The L0 weights are column-major (input-feature-indexed): `weights[feature_index * 512 .. (feature_index + 1) * 512]` gives all 512 hidden neuron connections for one input feature. This layout enables O(HIDDEN_SIZE) incremental accumulator updates.

The L1 weights are row-major (bucket-indexed) via `.transpose()`: `weights[bucket * 1024 .. (bucket + 1) * 1024]` gives all 1024 input weights for one output bucket.

## Troubleshooting

**"Incompatible sizes" panic at startup**: The `.nnue` file size doesn't match `@sizeOf(NNUEWeights)`. Check that HIDDEN_SIZE/OUTPUT_SIZE in both the trainer and `weights.zig` agree.

**Training loss not decreasing**: Check data quality. Run `bullet-utils validate` on your data. Ensure scores are centipawns (not pawns) and results are correct (1.0/0.5/0.0 for win/draw/loss, white-relative in text format).

**Bench changes after installing net**: Expected — the new network evaluates positions differently, so search explores different nodes. Update `bench.nodes`.
