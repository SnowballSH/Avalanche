#!/bin/bash
# train.sh — Train an Avalanche NNUE network using bullet
#
# Usage: ./scripts/train.sh [data_file ...]
#   data_file: Path(s) to training data in bulletformat (default: data/training.bin)
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
if [ $# -eq 0 ]; then
    DATA_FILES=("$ROOT_DIR/data/training.bin")
else
    DATA_FILES=("$@")
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
if [ ! -f "$TRAINER" ] || [ "$TRAINING_DIR/src/main.rs" -nt "$TRAINER" ]; then
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
echo "  ./scripts/install_net.sh training/checkpoints/avalanche-<N>"
