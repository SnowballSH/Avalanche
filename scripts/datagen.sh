#!/bin/bash
# datagen.sh — Generate self-play training data for Avalanche NNUE
#
# Usage: ./scripts/datagen.sh [threads] [duration_minutes] [epd_file] [engine_arg ...]
#   threads:          Number of search threads (default: nproc - 1)
#   duration_minutes: How long to run, 0 = infinite (default: 0)
#   epd_file:         Opening book in EPD/FEN format, one position per line (optional)
#   engine_arg:        Extra Avalanche datagen option, e.g. plies=8-10 or ttmb=4
#
# Output: data/ directory with .viribin files by default, or .bin files when
# passing format=bullet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE="$ROOT_DIR/zig-out/bin/Avalanche"
DATA_DIR="$ROOT_DIR/data"

THREADS="${1:-$(( $(nproc) - 1 ))}"
DURATION="${2:-0}"
EPD_FILE="${3:-}"
EXTRA_ENGINE_ARGS=()

if [ "$#" -ge 3 ]; then
    if [[ "$EPD_FILE" == *=* ]]; then
        EXTRA_ENGINE_ARGS=("${@:3}")
        EPD_FILE=""
    else
        EXTRA_ENGINE_ARGS=("${@:4}")
    fi
fi

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
echo "Options:  $([ "${#EXTRA_ENGINE_ARGS[@]}" -gt 0 ] && printf '%q ' "${EXTRA_ENGINE_ARGS[@]}" || echo "(defaults)")"
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

ENGINE_ARGS+=("${EXTRA_ENGINE_ARGS[@]}")

if [ "$DURATION" = "0" ]; then
    "$ENGINE" "${ENGINE_ARGS[@]}"
else
    timeout --foreground "${DURATION}m" "$ENGINE" "${ENGINE_ARGS[@]}" || true
fi

# Report results
echo ""
echo "=== Data Generation Complete ==="
TOTAL_BYTES=$(find . \( -name "data_*.bin" -o -name "data_*.viribin" \) -newer "$ENGINE" -exec stat --format=%s {} + 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
BULLET_BYTES=$(find . -name "data_*.bin" -newer "$ENGINE" -exec stat --format=%s {} + 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
echo "Generated: $(( TOTAL_BYTES / 1048576 )) MB"
if [ "$BULLET_BYTES" != "0" ]; then
    echo "Bullet positions: $(( BULLET_BYTES / 32 ))"
fi
echo "Files:"
ls -lh data_*.bin data_*.viribin 2>/dev/null | tail -5 || true
