#!/usr/bin/env bash
# build_net_engine.sh — build an Avalanche binary embedding a specific .nnue,
# without disturbing the working tree (uses build.zig's -Dnet option).
#
# Usage: scripts/build_net_engine.sh <net_file.nnue> <out_name> [hidden] [buckets]
#   net_file : path to a .nnue (relative to repo root or absolute)
#   out_name : output binary name -> engines_built/Avalanche-<out_name>
#   hidden   : optional hidden size (1024 default; patches weights.zig + tests if different)
#   buckets  : optional king input buckets (1=Chess768, 16=ChessBucketsMirrored; default 16)
#
# Output: engines_built/Avalanche-<out_name>
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

NET="${1:?usage: build_net_engine.sh <net_file> <out_name> [hidden] [buckets]}"
NAME="${2:?usage: build_net_engine.sh <net_file> <out_name> [hidden] [buckets]}"
HIDDEN="${3:-1024}"
BUCKETS="${4:-16}"
case "$BUCKETS" in
  1|16) ;;
  *) echo "error: buckets must be 1 or 16 (got $BUCKETS)" >&2; exit 1 ;;
esac
OUT="$REPO/engines_built/Avalanche-$NAME"
mkdir -p "$REPO/engines_built"

# net path relative to repo root for -Dnet (b.path is repo-relative)
case "$NET" in
  /*) NET_REL="$(realpath --relative-to="$REPO" "$NET")" ;;
  *)  NET_REL="$NET" ;;
esac
[ -f "$REPO/$NET_REL" ] || { echo "error: net not found: $NET_REL" >&2; exit 1; }

restore_hidden() { :; }
CURRENT_HIDDEN=$(grep -oP 'HIDDEN_SIZE: usize = \K[0-9]+' src/engine/weights.zig)
if [ "$HIDDEN" != "$CURRENT_HIDDEN" ]; then
  cp src/engine/weights.zig /tmp/weights.zig.bak
  cp src/tests.zig /tmp/tests.zig.bak
  sed -i "s/pub const HIDDEN_SIZE: usize = $CURRENT_HIDDEN;/pub const HIDDEN_SIZE: usize = $HIDDEN;/" src/engine/weights.zig
  sed -i "s/weights.HIDDEN_SIZE == $CURRENT_HIDDEN/weights.HIDDEN_SIZE == $HIDDEN/" src/tests.zig
  restore_hidden() { mv /tmp/weights.zig.bak src/engine/weights.zig; mv /tmp/tests.zig.bak src/tests.zig; }
  trap restore_hidden EXIT
fi

echo ":: Building Avalanche-$NAME  (net=$NET_REL hidden=$HIDDEN buckets=$BUCKETS)" >&2
TMPPREFIX="$(mktemp -d)"
zig build --release=fast \
  -Dnet="$NET_REL" \
  -Dbuckets="$BUCKETS" \
  -Dtarget-name="Avalanche-$NAME" \
  --prefix "$TMPPREFIX" >&2
cp "$TMPPREFIX/bin/Avalanche-$NAME" "$OUT"
rm -rf "$TMPPREFIX"
restore_hidden
trap - EXIT

echo ":: built $OUT" >&2
echo ":: bench: $("$OUT" bench 2>&1 | sed -n '1p')" >&2
echo "$OUT"
