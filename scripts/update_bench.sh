#!/usr/bin/env bash
set -euo pipefail
cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

NODES_FILE="bench.nodes"
CHECKSUM_FILE="nnue-speed.checksum"

echo "==> Building release engine (zig build --release=fast)"
zig build --release=fast

BIN="zig-out/bin/Avalanche"
if [ ! -x "$BIN" ]; then
  BIN="zig-out/bin/Avalanche.exe"
fi
if [ ! -x "$BIN" ]; then
  echo "ERROR: engine binary not found at zig-out/bin/Avalanche[.exe]" >&2
  exit 1
fi

echo "==> Running benchmark"
OUT="$("$BIN" bench)"
echo "    $OUT"

NODES="$(printf '%s\n' "$OUT" | grep -oE '^[0-9]+' | head -n1)"
if [ -z "${NODES:-}" ]; then
  echo "ERROR: could not parse a node count from bench output:" >&2
  echo "       $OUT" >&2
  exit 1
fi

OLD="(none)"
[ -f "$NODES_FILE" ] && OLD="$(tr -d '[:space:]' < "$NODES_FILE")"

printf '%s\n' "$NODES" > "$NODES_FILE"

if [ "$OLD" = "$NODES" ]; then
  echo "==> $NODES_FILE unchanged ($NODES nodes)."
else
  echo "==> $NODES_FILE updated: $OLD -> $NODES"
  echo ""
  echo "    Commit bench.nodes and include 'Bench: $NODES' in the commit"
  echo "    message so OpenBench can auto-detect it when creating tests:"
  echo ""
  echo "      git commit -m \"<description>\" -m \"Bench: $NODES\""
fi

CHECKSUM="$("$BIN" nnue-speed | sed -n 's/.*(checksum \([0-9]*\)).*/\1/p')"
if [ -z "${CHECKSUM:-}" ]; then
  echo "ERROR: could not parse a checksum from the nnue-speed output" >&2
  exit 1
fi
printf '%s\n' "$CHECKSUM" > "$CHECKSUM_FILE"
echo "==> $CHECKSUM_FILE: $CHECKSUM"
