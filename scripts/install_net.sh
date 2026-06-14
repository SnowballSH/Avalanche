#!/bin/bash
# install_net.sh — Install a trained NNUE network into the engine
#
# Usage: ./scripts/install_net.sh <checkpoint_path>
#   checkpoint_path: Path to a bullet checkpoint directory (contains quantised.bin)
#
# This script:
# 1. Copies quantised.bin as the new .nnue file
# 2. Updates build.zig to embed the new net
# 3. Rebuilds and runs bench to verify

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECKPOINT="${1:-}"
if [ -z "$CHECKPOINT" ]; then
    echo "Usage: $0 <checkpoint_path>"
    echo ""
    echo "Available checkpoints:"
    find "$ROOT_DIR/training/checkpoints" "$ROOT_DIR/bullet/checkpoints" -name "quantised.bin" -printf "  %h\n" 2>/dev/null || echo "  (none found)"
    exit 1
fi

QUANTISED="$CHECKPOINT/quantised.bin"
if [ ! -f "$QUANTISED" ]; then
    echo "Error: $QUANTISED not found"
    exit 1
fi

# Verify file size matches expected (803904 bytes = 768*512*2 + 512*2 + 8*1024*2 + 8*2 + 48 padding)
EXPECTED_SIZE=803904
ACTUAL_SIZE=$(stat --format=%s "$QUANTISED")
if [ "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]; then
    echo "Warning: File size mismatch!"
    echo "  Expected: $EXPECTED_SIZE bytes (768x512x8 architecture)"
    echo "  Got:      $ACTUAL_SIZE bytes"
    echo "  The architecture may not match. Proceeding anyway..."
fi

# Install the net
NET_NAME="$(basename "$CHECKPOINT").nnue"
cp "$QUANTISED" "$ROOT_DIR/nets/$NET_NAME"
echo "Installed: nets/$NET_NAME"

# Update build.zig to use the new net
CURRENT_NET=$(grep -oP 'nets/\K[^"]+' "$ROOT_DIR/build.zig" | head -1)
if [ -n "$CURRENT_NET" ] && [ "$CURRENT_NET" != "$NET_NAME" ]; then
    sed -i "s|nets/$CURRENT_NET|nets/$NET_NAME|g" "$ROOT_DIR/build.zig"
    echo "Updated build.zig: $CURRENT_NET -> $NET_NAME"
fi

# Rebuild
echo "Rebuilding engine..."
export PATH="/home/coder/.vscode-server/data/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-0.16.0:$PATH"
(cd "$ROOT_DIR" && zig build --release=fast)

# Run bench
echo "Running bench..."
BENCH_OUTPUT=$("$ROOT_DIR/zig-out/bin/Avalanche" bench 2>&1)
echo "Bench: $BENCH_OUTPUT"

# Update bench.nodes
NODES=$(echo "$BENCH_OUTPUT" | grep -oP '^\d+')
echo "$NODES" > "$ROOT_DIR/bench.nodes"
echo "Updated bench.nodes: $NODES"

echo ""
echo "=== Network Installed Successfully ==="
echo "Net:   nets/$NET_NAME"
echo "Bench: $NODES nodes"
