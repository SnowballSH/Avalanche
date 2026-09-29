#!/usr/bin/env bash
# Usage: scripts/datagen_throughput.sh <threads> <positions> [extra datagen args...]
# Prints positions/second/thread for the current build with all threads loaded.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THREADS="${1:?threads}"
POSITIONS="${2:?positions}"
shift 2
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
"$ROOT/zig-out/bin/Avalanche" datagen "$THREADS" nodes=6000 hardmult=8 positions="$POSITIONS" seed=1 \
    out="$WORK/throughput.viribin" "$@" > "$WORK/summary.json" 2> "$WORK/datagen.log" \
    || { cat "$WORK/datagen.log" >&2; exit 1; }
python3 - "$WORK/summary.json" "$THREADS" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
threads = int(sys.argv[2])
rate = summary["positions"] / summary["seconds"]
print(json.dumps({
    "threads": threads,
    "positions": summary["positions"],
    "seconds": round(summary["seconds"], 1),
    "pos_per_s": round(rate, 1),
    "pos_per_s_per_thread": round(rate / threads, 1),
}))
PY
