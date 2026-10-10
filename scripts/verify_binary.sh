#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:?usage: verify_binary.sh <binary> [SIMD paths that nnue-speed must report]}"
PATHS="${2:-}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

EXPECTED_NODES="$(tr -d '[:space:]' < "$ROOT/bench.nodes")"
EXPECTED_CHECKSUM="$(tr -d '[:space:]' < "$ROOT/nnue-speed.checksum")"
[ -n "$EXPECTED_NODES" ] || fail "bench.nodes is empty"
[ -n "$EXPECTED_CHECKSUM" ] || fail "nnue-speed.checksum is empty"

BENCH="$("$BIN" bench)"
[[ "$BENCH" == "$EXPECTED_NODES nodes "* ]] || fail "$BIN bench printed '$BENCH', expected $EXPECTED_NODES nodes"

SPEED="$("$BIN" nnue-speed)"
CHECKSUM="$(sed -n 's/.*(checksum \([0-9]*\)).*/\1/p' <<< "$SPEED")"
[ "$CHECKSUM" = "$EXPECTED_CHECKSUM" ] || fail "$BIN nnue-speed checksum '$CHECKSUM' is not $EXPECTED_CHECKSUM: $SPEED"
if [ -n "$PATHS" ]; then
    grep -q -F -- "$PATHS" <<< "$SPEED" || fail "$BIN nnue-speed does not report '$PATHS': $SPEED"
fi

echo "ran: $BENCH; checksum $CHECKSUM"
