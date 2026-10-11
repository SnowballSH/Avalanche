#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPOINTS="$ROOT/training/checkpoints"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if [ "$#" -ne 1 ]; then
    echo "usage: install_net.sh <checkpoint directory>" >&2
    if [ -d "$CHECKPOINTS" ]; then
        echo "checkpoints with a quantised.bin:" >&2
        find "$CHECKPOINTS" -name quantised.bin -exec dirname {} \; >&2
    fi
    exit 1
fi

CHECKPOINT="${1%/}"
QUANTISED="$CHECKPOINT/quantised.bin"
[ -f "$QUANTISED" ] || fail "$QUANTISED not found"

NAME="$(basename "$CHECKPOINT")"
case "$NAME" in
    *[!A-Za-z0-9._-]*) fail "'$NAME' cannot name a network: only letters, digits, '.', '_' and '-' are allowed" ;;
esac
NET="nets/$NAME.nnue"
cp "$QUANTISED" "$ROOT/$NET"

DEFAULT_NET_LINE="const DEFAULT_NET = \"$NET\";"
sed -i.previous "s|^const DEFAULT_NET = \".*\";\$|$DEFAULT_NET_LINE|" "$ROOT/build.zig"
rm "$ROOT/build.zig.previous"
grep -q -x -F -- "$DEFAULT_NET_LINE" "$ROOT/build.zig" || fail "build.zig has no DEFAULT_NET line to rewrite"
echo "==> $NET is the default network"

"$ROOT/scripts/update_bench.sh"
