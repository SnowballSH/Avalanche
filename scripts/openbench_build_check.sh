#!/usr/bin/env bash
# Builds exactly as an OpenBench worker does and parses bench the way OpenBench does.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
cp "$ROOT/nets/nezha.nnue" "$WORK/candidate.nnue"
(cd "$ROOT" && make -j EXE="$WORK/Avalanche-ob" CC=zig EVALFILE="$WORK/candidate.nnue")
test -x "$WORK/Avalanche-ob"
printf 'position startpos\ngo depth 1\nquit\n' | "$WORK/Avalanche-ob" > "$WORK/uci.txt"
grep -q "NNUE evaluation using candidate " "$WORK/uci.txt" || { echo "EVALFILE network was not embedded" >&2; exit 1; }
"$WORK/Avalanche-ob" bench > "$WORK/bench.txt" 2>&1
python3 - "$WORK/bench.txt" "$ROOT/bench.nodes" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
bench = nps = None
for line in text.splitlines():
    b = re.search(r'(\d+\s+nodes)|(nodes\s+\d+)|(nodes searched\s+\d+)', line, re.IGNORECASE)
    n = re.search(r'(\d+\s+nps)|(nps\s+\d+)|(nodes second\s+\d+)', line, re.IGNORECASE)
    bench = bench or (b and b.group())
    nps = nps or (n and n.group())
assert bench and nps, f"OpenBench regexes did not match:\n{text}"
nodes = int(re.search(r'\d+', bench).group())
expected = int(open(sys.argv[2]).read().split()[0])
assert nodes == expected, f"bench {nodes} != bench.nodes {expected}"
print(f"ok: bench {nodes}, nps {re.search(r'\d+', nps).group()}")
PY
