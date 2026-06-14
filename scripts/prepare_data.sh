#!/bin/bash
# prepare_data.sh — Shuffle and interleave datagen output for training
#
# Usage: ./scripts/prepare_data.sh [output_name]
#   output_name: Name for the merged output file (default: training)
#
# This script:
# 1. Shuffles each individual .bin file
# 2. Interleaves all shuffled files into one training file
# 3. Optionally splits off a test set (5% of data)
#
# Prerequisites: bullet-utils must be built (cargo build --release -p bullet-utils)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BULLET_UTILS="$ROOT_DIR/bullet/target/release/bullet-utils"
DATA_DIR="$ROOT_DIR/data"
OUTPUT_NAME="${1:-training}"

if [ ! -f "$BULLET_UTILS" ]; then
    echo "bullet-utils not found. Building..."
    (cd "$ROOT_DIR/bullet" && cargo build --release -p bullet-utils)
fi

if [ ! -d "$DATA_DIR" ] || [ -z "$(find "$DATA_DIR" -name 'data_*.bin' 2>/dev/null)" ]; then
    echo "Error: No data files found in $DATA_DIR/"
    echo "Run scripts/datagen.sh first."
    exit 1
fi

cd "$DATA_DIR"

echo "=== Data Preparation ==="

# Step 1: Shuffle each file individually
echo "Step 1: Shuffling individual files..."
SHUFFLED_DIR="shuffled"
mkdir -p "$SHUFFLED_DIR"

for f in data_*.bin; do
    out="$SHUFFLED_DIR/${f%.bin}_shuffled.bin"
    if [ -f "$out" ]; then
        echo "  Skipping $f (already shuffled)"
        continue
    fi
    echo "  Shuffling $f..."
    "$BULLET_UTILS" shuffle -i "$f" -o "$out" -m 2048
done

# Step 2: Interleave all shuffled files
echo "Step 2: Interleaving..."
SHUFFLED_FILES=("$SHUFFLED_DIR"/*_shuffled.bin)
if [ ${#SHUFFLED_FILES[@]} -eq 1 ]; then
    cp "${SHUFFLED_FILES[0]}" "${OUTPUT_NAME}.bin"
else
    "$BULLET_UTILS" interleave "${SHUFFLED_FILES[@]}" -o "${OUTPUT_NAME}.bin"
fi

# Step 3: Validate
echo "Step 3: Validating..."
"$BULLET_UTILS" validate -i "${OUTPUT_NAME}.bin"

# Step 4: Optional test set split (last 5%)
TOTAL_SIZE=$(stat --format=%s "${OUTPUT_NAME}.bin")
TOTAL_POSITIONS=$(( TOTAL_SIZE / 32 ))
TEST_POSITIONS=$(( TOTAL_POSITIONS / 20 ))  # 5%
TRAIN_POSITIONS=$(( TOTAL_POSITIONS - TEST_POSITIONS ))

if [ "$TEST_POSITIONS" -gt 10000 ]; then
    echo "Step 4: Splitting test set (${TEST_POSITIONS} positions)..."
    TRAIN_BYTES=$(( TRAIN_POSITIONS * 32 ))
    TEST_BYTES=$(( TEST_POSITIONS * 32 ))
    head -c "$TRAIN_BYTES" "${OUTPUT_NAME}.bin" > "${OUTPUT_NAME}_train.bin"
    tail -c "$TEST_BYTES" "${OUTPUT_NAME}.bin" > "${OUTPUT_NAME}_test.bin"
    echo "  Train: ${TRAIN_POSITIONS} positions ($(( TRAIN_BYTES / 1048576 )) MB)"
    echo "  Test:  ${TEST_POSITIONS} positions ($(( TEST_BYTES / 1048576 )) MB)"
else
    echo "Step 4: Skipped test split (not enough data, need >200k positions)"
fi

echo ""
echo "=== Done ==="
echo "Training data: $DATA_DIR/${OUTPUT_NAME}.bin (${TOTAL_POSITIONS} positions)"
