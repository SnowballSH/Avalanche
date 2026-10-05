#!/usr/bin/env bash
# Runs an engine binary built from this tree with the default network and checks what no target
# may change: the bench node count (bench.nodes) and the nnue-speed checksum (nnue-speed.checksum).
# With a second argument, nnue-speed must also report those SIMD paths.
#   scripts/verify_binary.sh <binary> ["128-bit vectors, pairwise umull, L1 sdot, L2 wide"]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$1"
PATHS="${2:-}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

EXPECTED_NODES="$(tr -d '[:space:]' < "$ROOT/bench.nodes")"
EXPECTED_CHECKSUM="$(tr -d '[:space:]' < "$ROOT/nnue-speed.checksum")"

BENCH="$("$BIN" bench)"
[[ "$BENCH" == "$EXPECTED_NODES nodes "* ]] || fail "$BIN bench printed '$BENCH', expected $EXPECTED_NODES nodes"

SPEED="$("$BIN" nnue-speed)"
CHECKSUM="$(sed -n 's/.*(checksum \([0-9]*\)).*/\1/p' <<< "$SPEED")"
[ "$CHECKSUM" = "$EXPECTED_CHECKSUM" ] || fail "$BIN nnue-speed checksum '$CHECKSUM' is not $EXPECTED_CHECKSUM: $SPEED"
if [ -n "$PATHS" ]; then
    grep -q -F -- "$PATHS" <<< "$SPEED" || fail "$BIN nnue-speed does not report '$PATHS': $SPEED"
fi

echo "ran: $BENCH; checksum $CHECKSUM"
