#!/bin/bash
# train.sh — Train an Avalanche NNUE network using bullet
#
# Usage: ./scripts/train.sh [data_file ...]
#   data_file: Path(s) to training data in bulletformat (default: data/training.bin)
#
# Tunables (env vars, all optional — defaults are the current best recipe):
#   TRAIN_NET_ID (net), TRAIN_INPUT (buckets16), TRAIN_HIDDEN (1024),
#   TRAIN_ARCH (single|multi; the head, see docs/NNUE.md. multi needs TRAIN_INPUT=buckets16, and the
#     engine picks the matching head from the saved file's header),
#   TRAIN_L1_SPARSITY (0 = off; TRAIN_ARCH=multi only. Adds coefficient x mean pairwise activation to the
#     training loss, for fewer non-zero inputs to the engine's sparse L1; bullet's advanced example uses
#     0.005. The printed training loss includes the penalty, the validation loss does not),
#   TRAIN_SUPERBATCHES (40),
#   TRAIN_WDL (0.25), TRAIN_WDL_END (=WDL; set != WDL for LinearWDL),
#   TRAIN_LR_SCHEDULE (cosine|cosine-legacy|constant), TRAIN_LR_INITIAL (0.001), TRAIN_LR_FINAL (1e-7),
#     cosine:        progress (sb - 1) / (superbatches - 1), so superbatch 1 runs at TRAIN_LR_INITIAL.
#     cosine-legacy: progress sb / superbatches, the curve bullet had before jw1912/bullet#553 and the one
#                    every net up to the bullet 2ea3d2d pin was trained with; set it to reproduce those.
#   TRAIN_WARMUP_SB (0 = off; scales the LR linearly, batch by batch, from near zero up to the schedule
#     over that many superbatches),
#   TRAIN_BATCH_SIZE (16384), TRAIN_BATCHES_PER_SB (12208),
#   TRAIN_SAVE_RATE (10), TRAIN_THREADS (all cores),
#   TRAIN_DATA_DIR (a directory of .viribin chunks, read with games interleaved across files),
#   TRAIN_SHUFFLE_MB (128; shuffle buffer of the .viribin loader, 16384 positions per MB),
#   TRAIN_START_SB (1; with TRAIN_RESUME_FROM, the superbatch to resume at, keeping the LR schedule),
#   TRAIN_VALIDATION_DIR (unset or empty = off; a directory of held-out .viribin files, filtered like the
#     training data. Prints "validation superbatch <n> loss <value>" after every superbatch, and once
#     before training with n = TRAIN_START_SB - 1. Only a failure of that first pass stops the run),
#   TRAIN_VALIDATION_BATCHES (64; validation batches of TRAIN_BATCH_SIZE, always the first filtered
#     positions of the held-out files in sorted file order; fewer than that many is a startup error).
#   TRAIN_PARITY_FENS (unset or empty = train. A file of FENs: instead of training, write the evaluation of each
#     by the net of TRAIN_RESUME_FROM (required), as "<fen> | <centipawns>", to TRAIN_PARITY_OUT (parity.txt), for
#     `Avalanche nnue-parity`; see docs/NNUE.md).
#   e.g. TRAIN_NET_ID=mynet TRAIN_SUPERBATCHES=40 TRAIN_WDL=0.25 ./scripts/train.sh
#   (HIDDEN is runtime here; the Zig engine's weights.zig must match at build time.)
#
# Output: training/checkpoints/ directory with saved networks
# The quantised.bin file from a checkpoint can be directly used as an .nnue file.
#
# Prerequisites:
#   - Training data in bulletformat (.bin)
#   - Rust toolchain installed
#   - For GPU training: set CUDA_PATH and pass --features cuda

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRAINING_DIR="$ROOT_DIR/training"

# Auto-detect CUDA toolkit for GPU-accelerated training
if [ -z "${CUDA_PATH:-}" ]; then
    if [ -d "/usr/local/cuda" ]; then
        export CUDA_PATH="/usr/local/cuda"
    fi
fi

# Collect data file arguments (default to data/training.bin)
# Canonicalize to absolute paths so they survive the cd into training/
if [ $# -eq 0 ]; then
    DATA_FILES=("$ROOT_DIR/data/training.bin")
else
    DATA_FILES=()
    for arg in "$@"; do
        if [[ "$arg" = /* ]]; then
            DATA_FILES+=("$arg")
        else
            DATA_FILES+=("$(pwd)/$arg")
        fi
    done
fi

# Verify data files exist
for f in "${DATA_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "Error: Training data not found at $f"
        echo "Run scripts/datagen.sh and scripts/prepare_data.sh first."
        exit 1
    fi
done

# Build trainer if needed
TRAINER="$TRAINING_DIR/target/release/avalanche-trainer"
if [ ! -f "$TRAINER" ] || [ -n "$(find "$TRAINING_DIR/src" "$TRAINING_DIR/Cargo.toml" "$TRAINING_DIR/Cargo.lock" -newer "$TRAINER" -print -quit)" ]; then
    echo "Building trainer..."
    (cd "$TRAINING_DIR" && cargo build --release)
fi

echo "=== Avalanche NNUE Training ==="
echo "Data: ${DATA_FILES[*]}"
echo "Output: $TRAINING_DIR/checkpoints/"
if [ -n "${CUDA_PATH:-}" ]; then
    echo "GPU: CUDA (${CUDA_PATH})"
else
    echo "GPU: none (CPU-only training)"
fi
echo "==============================="
echo ""

cd "$TRAINING_DIR"
"$TRAINER" "${DATA_FILES[@]}"

echo ""
echo "=== Training Complete ==="
echo "Checkpoints saved to: $TRAINING_DIR/checkpoints/"
echo ""
echo "To install a network:"
echo "  ./scripts/install_net.sh training/checkpoints/..."
