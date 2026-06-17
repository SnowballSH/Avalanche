#!/bin/bash
# datagen.sh — Generate self-play training data for Avalanche NNUE
#
# Usage: ./scripts/datagen.sh [threads] [duration_minutes] [epd_file]
#   threads:          Number of search threads (default: nproc - 1)
#   duration_minutes: How long to run, 0 = infinite (default: 0)
#   epd_file:         Opening book in EPD/FEN format, one position per line (optional)
#
# Output: data/ directory with binary bulletformat .bin files
#
# The engine generates data in native bulletformat (32 bytes/position),
# which can be directly loaded by bullet's DirectSequentialDataLoader.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE="$ROOT_DIR/zig-out/bin/Avalanche"
DATA_DIR="$ROOT_DIR/data"

THREADS="${1:-$(( $(nproc) - 1 ))}"
DURATION="${2:-0}"
EPD_FILE="${3:-}"

# Ensure engine is built
if [ ! -f "$ENGINE" ]; then
    echo "Engine not found at $ENGINE. Building..."
    (cd "$ROOT_DIR" && zig build --release=fast)
fi

# Create data directory
mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

echo "=== Avalanche Data Generation ==="
echo "Threads:  $THREADS"
echo "Duration: $([ "$DURATION" = "0" ] && echo "infinite (Ctrl+C to stop)" || echo "${DURATION}m")"
echo "Book:     $([ -n "$EPD_FILE" ] && echo "$EPD_FILE" || echo "(none, random from startpos)")"
echo "Output:   $DATA_DIR/"
echo "================================="
echo ""

# Build engine args
ENGINE_ARGS=("datagen" "$THREADS")
if [ -n "$EPD_FILE" ]; then
    if [ ! -f "$EPD_FILE" ]; then
        # Try relative to repo root
        if [ -f "$ROOT_DIR/$EPD_FILE" ]; then
            EPD_FILE="$ROOT_DIR/$EPD_FILE"
        else
            echo "Error: EPD file not found: $EPD_FILE"
            exit 1
        fi
    fi
    ENGINE_ARGS+=("$EPD_FILE")
fi

if [ "$DURATION" = "0" ]; then
    "$ENGINE" "${ENGINE_ARGS[@]}"
else
    timeout --foreground "${DURATION}m" "$ENGINE" "${ENGINE_ARGS[@]}" || true
fi

# Report results
echo ""
echo "=== Data Generation Complete ==="
TOTAL_BYTES=$(find . -name "data_*.bin" -newer "$ENGINE" -exec stat --format=%s {} + 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
TOTAL_POSITIONS=$(( TOTAL_BYTES / 32 ))
echo "Generated: $TOTAL_POSITIONS positions ($(( TOTAL_BYTES / 1048576 )) MB)"
echo "Files:"
ls -lh data_*.bin 2>/dev/null | tail -5
