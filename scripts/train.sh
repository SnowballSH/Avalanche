#!/bin/bash
# See "Training" in docs/NNUE.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRAINING_DIR="$ROOT_DIR/training"

DEFAULT_CUDA_PATH="/usr/local/cuda"
if [ -z "${CUDA_PATH:-}" ] && [ -d "$DEFAULT_CUDA_PATH" ]; then
    export CUDA_PATH="$DEFAULT_CUDA_PATH"
fi

# Paths are made absolute because the trainer runs from training/.
if [ $# -eq 0 ] && [ -n "${TRAIN_DATA_DIR:-}" ]; then
    DATA_FILES=()
elif [ $# -eq 0 ]; then
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

for f in ${DATA_FILES[@]+"${DATA_FILES[@]}"}; do
    if [ ! -f "$f" ]; then
        echo "Error: Training data not found at $f"
        echo "Run scripts/datagen.sh and scripts/prepare_data.sh first."
        exit 1
    fi
done

TRAINER="$TRAINING_DIR/target/release/avalanche-trainer"
if [ ! -f "$TRAINER" ] || [ -n "$(find "$TRAINING_DIR/src" "$TRAINING_DIR/Cargo.toml" "$TRAINING_DIR/Cargo.lock" -newer "$TRAINER" -print -quit)" ]; then
    if [ -z "${CUDA_PATH:-}" ]; then
        echo "Error: the trainer builds against CUDA. Set CUDA_PATH to the toolkit's directory" \
            "(there is none at $DEFAULT_CUDA_PATH)." >&2
        exit 1
    fi
    echo "Building trainer..."
    (cd "$TRAINING_DIR" && cargo build --release)
fi

echo "=== Avalanche NNUE Training ==="
echo "Data: ${TRAIN_DATA_DIR:-${DATA_FILES[*]}}"
echo "Output: $TRAINING_DIR/checkpoints/"
if [ -n "${CUDA_PATH:-}" ]; then
    echo "CUDA: $CUDA_PATH"
fi
echo "==============================="
echo ""

cd "$TRAINING_DIR"
"$TRAINER" ${DATA_FILES[@]+"${DATA_FILES[@]}"}

echo ""
echo "=== Training Complete ==="
echo "Checkpoints saved to: $TRAINING_DIR/checkpoints/"
echo ""
echo "To install a network:"
echo "  ./scripts/install_net.sh training/checkpoints/..."
