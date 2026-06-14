#!/usr/bin/env bash
#
# Refresh the expected bench node count that CI asserts against.
#
# CI (.github/workflows/CI.yml) reads the expected node count from the committed
# `bench.nodes` file instead of hardcoding it. The fixed-position benchmark is
# deterministic and its node count is platform-independent, so it only changes
# when something that affects the search/eval changes (a new NNUE net, a search
# parameter, a movegen tweak, ...). When that happens on purpose, run this script
# before pushing and commit the updated `bench.nodes`.
#
# Usage:
#   scripts/update_bench.sh
#
set -euo pipefail

# Work from the repository root regardless of where this is invoked from.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

NODES_FILE="bench.nodes"

echo "==> Building release engine (zig build --release=fast)"
zig build --release=fast

BIN="zig-out/bin/Avalanche"
if [ ! -x "$BIN" ]; then
  # Windows (e.g. Git-Bash) produces an .exe.
  BIN="zig-out/bin/Avalanche.exe"
fi
if [ ! -x "$BIN" ]; then
  echo "ERROR: engine binary not found at zig-out/bin/Avalanche[.exe]" >&2
  exit 1
fi

echo "==> Running benchmark"
OUT="$("$BIN" bench)"
echo "    $OUT"

# bench prints a single line: "<nodes> nodes <nps> nps".
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
