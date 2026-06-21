#!/bin/bash
# prepare_data.sh — Convert viriformat datagen output to shuffled bulletformat for training.
#
# Pipeline: splat (viri→bullet with filter) → interleave → shuffle → good_data/
#
# Usage:
#   scripts/prepare_data.sh [output_name]
#
#   output_name: Name for the final training file (default: training.bin)
#
# Expects:
#   - Raw .viribin files in data/ (from datagen)
#   - bullet-utils built
#
# Produces:
#   - data/good_data/<output_name>  (final shuffled+interleaved bulletformat)
#   - Moves raw .viribin and intermediate files to data/old_data/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$ROOT_DIR/data"
GOOD_DATA_DIR="$DATA_DIR/good_data"
OLD_DATA_DIR="$DATA_DIR/old_data"
FILTER_CFG="$ROOT_DIR/training/filter.toml"

# Try multiple possible paths for bullet-utils
BULLET_UTILS=""
for candidate in \
    "$ROOT_DIR/bullet/target/release/bullet-utils" \
    "$(which bullet-utils 2>/dev/null)"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        BULLET_UTILS="$candidate"
        break
    fi
done

OUTPUT_NAME="${1:-training.bin}"
# Ensure .bin extension
[[ "$OUTPUT_NAME" == *.bin ]] || OUTPUT_NAME="${OUTPUT_NAME}.bin"

# Memory for shuffle (MB)
MEM_MB="${SHUFFLE_MEM_MB:-16384}"

# ============================================================================

mkdir -p "$GOOD_DATA_DIR" "$OLD_DATA_DIR"

if [ -z "$BULLET_UTILS" ]; then
    echo "Error: bullet-utils not found."
    echo "Build it (cargo build --release in the bullet repo's crates/utils) and put it"
    echo "on PATH, or at $ROOT_DIR/bullet/target/release/bullet-utils."
    exit 1
fi

if [ ! -f "$FILTER_CFG" ]; then
    echo "Error: Filter config not found at $FILTER_CFG"
    exit 1
fi

# Find all .viribin files in data/
shopt -s nullglob
VIRI_FILES=( "$DATA_DIR"/*.viribin )
shopt -u nullglob

if [ ${#VIRI_FILES[@]} -eq 0 ]; then
    echo "Error: No .viribin files found in $DATA_DIR/"
    echo "Run datagen first: ./zig-out/bin/Avalanche datagen 96 books/UHO_4060_v4.epd nodes=5000"
    exit 1
fi

echo "=== Avalanche Data Preparation ==="
echo "Input:      ${#VIRI_FILES[@]} viribin file(s)"
echo "Filter:     $FILTER_CFG"
echo "Output:     $GOOD_DATA_DIR/$OUTPUT_NAME"
echo "Shuffle MB: $MEM_MB"
echo "==================================="
echo ""

# Step 1: Splat each viribin file to bulletformat (with filtering)
echo "[1/3] Converting viriformat → bulletformat (with filter)..."
SPLATTED_FILES=()
for f in "${VIRI_FILES[@]}"; do
    base=$(basename "$f" .viribin)
    out="$DATA_DIR/${base}_splatted.bin"
    echo "  $(basename "$f") → $(basename "$out")"
    "$BULLET_UTILS" viribinpack splat "$f" "$out" "$FILTER_CFG"
    SPLATTED_FILES+=( "$out" )
done
echo ""

# Step 2: Interleave all splatted files into one
echo "[2/3] Interleaving ${#SPLATTED_FILES[@]} file(s)..."
INTERLEAVED="$DATA_DIR/_interleaved_tmp.bin"
if [ ${#SPLATTED_FILES[@]} -eq 1 ]; then
    mv "${SPLATTED_FILES[0]}" "$INTERLEAVED"
else
    "$BULLET_UTILS" interleave "${SPLATTED_FILES[@]}" --output "$INTERLEAVED"
    rm -f "${SPLATTED_FILES[@]}"
fi

INTER_SIZE=$(stat -c '%s' "$INTERLEAVED")
echo "  Interleaved: $((INTER_SIZE / 32)) positions ($(numfmt --to=iec "$INTER_SIZE" 2>/dev/null || echo "$((INTER_SIZE/1048576))MB"))"
echo ""

# Step 3: Shuffle
echo "[3/3] Shuffling..."
"$BULLET_UTILS" shuffle --input "$INTERLEAVED" --output "$GOOD_DATA_DIR/$OUTPUT_NAME" --mem-used-mb "$MEM_MB"
rm -f "$INTERLEAVED"
echo ""

# Move raw viribin files to old_data/
echo "Archiving raw .viribin files to old_data/..."
for f in "${VIRI_FILES[@]}"; do
    mv "$f" "$OLD_DATA_DIR/"
done
# Clean any remaining splatted intermediates
rm -f "$DATA_DIR"/*_splatted.bin

# Summary
FINAL_SIZE=$(stat -c '%s' "$GOOD_DATA_DIR/$OUTPUT_NAME")
POSITIONS=$((FINAL_SIZE / 32))
echo ""
echo "=== Done ==="
echo "Output:    $GOOD_DATA_DIR/$OUTPUT_NAME"
echo "Positions: $POSITIONS ($(numfmt --to=iec "$FINAL_SIZE" 2>/dev/null || echo "$((FINAL_SIZE/1048576))MB"))"
echo "Raw data:  $OLD_DATA_DIR/"
