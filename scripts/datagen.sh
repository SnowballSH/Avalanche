#!/bin/bash
# See "Scripts" in docs/DATAGEN.md.

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

if [ ! -f "$ENGINE" ]; then
    echo "Engine not found at $ENGINE. Building..."
    (cd "$ROOT_DIR" && zig build --release=fast)
fi

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

echo "=== Avalanche Data Generation ==="
echo "Threads:  $THREADS"
echo "Duration: $([ "$DURATION" = "0" ] && echo "unbounded (ends through positions= or Ctrl+C)" || echo "${DURATION}m, then SIGTERM")"
echo "Book:     $([ -n "$EPD_FILE" ] && echo "$EPD_FILE" || echo "(none, random from startpos)")"
echo "Options:  $([ "${#EXTRA_ENGINE_ARGS[@]}" -gt 0 ] && printf '%q ' "${EXTRA_ENGINE_ARGS[@]}" || echo "(defaults)")"
echo "Output:   $DATA_DIR/"
echo "================================="
echo ""

ENGINE_ARGS=("datagen" "$THREADS")
if [ -n "$EPD_FILE" ]; then
    if [ ! -f "$EPD_FILE" ]; then
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

TIMEOUT_EXPIRED_STATUS=124
ENGINE_STATUS=0
if [ "$DURATION" = "0" ]; then
    "$ENGINE" "${ENGINE_ARGS[@]}" || ENGINE_STATUS=$?
else
    timeout --foreground "${DURATION}m" "$ENGINE" "${ENGINE_ARGS[@]}" || ENGINE_STATUS=$?
    if [ "$ENGINE_STATUS" -eq "$TIMEOUT_EXPIRED_STATUS" ]; then
        ENGINE_STATUS=0
    fi
fi

echo ""
if [ "$ENGINE_STATUS" -eq 0 ]; then
    echo "=== Data Generation Complete ==="
else
    echo "=== Data Generation Failed (engine exit status $ENGINE_STATUS) ==="
fi
TOTAL_BYTES=$(find . \( -name "data_*.bin" -o -name "data_*.viribin" \) -newer "$ENGINE" -exec stat --format=%s {} + 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
BULLET_BYTES=$(find . -name "data_*.bin" -newer "$ENGINE" -exec stat --format=%s {} + 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
echo "Generated: $(( TOTAL_BYTES / 1048576 )) MB"
if [ "$BULLET_BYTES" != "0" ]; then
    echo "Bullet positions: $(( BULLET_BYTES / 32 ))"
fi
echo "Files:"
find . -maxdepth 1 \( -name "data_*.bin" -o -name "data_*.viribin" \) -exec ls -lh {} + | tail -5 || true

exit "$ENGINE_STATUS"
