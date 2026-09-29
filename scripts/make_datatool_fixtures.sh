#!/usr/bin/env bash
# Regenerates the datatool test fixtures from fixed seeds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tools/datatool/tests/fixtures"
ENGINE="$ROOT/zig-out/bin/Avalanche"
(cd "$ROOT" && zig build --release=fast)
rm -f "$FIX/std.viribin" "$FIX/frc.viribin"
"$ENGINE" datagen 1 nodes=300 positions=600 seed=101 out="$FIX/std.viribin" > "$FIX/std.summary.json"
"$ENGINE" datagen 1 "$FIX/frc.epd" bookplies=4-6 nodes=300 positions=600 seed=202 out="$FIX/frc.viribin" > "$FIX/frc.summary.json"
