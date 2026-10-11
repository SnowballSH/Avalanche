#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

FAKE_ZIG="$WORK/fake-zig"
cat > "$FAKE_ZIG" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > zig-arguments
mkdir -p bin
: > bin/Avalanche
SH
chmod +x "$FAKE_ZIG"

check_makefile_installs_as() {
    local name="$1" dir="$WORK/install/$1"
    local net="$dir/a network.nnue"
    mkdir -p "$dir"
    (cd "$dir" && make -s -f "$ROOT/Makefile" ZIG="$FAKE_ZIG" EXE="$name" EVALFILE="$net")
    [ -f "$dir/$name" ] || fail "make EXE=$name did not install ./$name"
    grep -q -x -F -- "-Dnet=$net" "$dir/zig-arguments" || fail "EVALFILE=$net did not reach the build as one argument"
}

for name in Avalanche bin/Avalanche Avalanche-0a1b2c3d; do
    check_makefile_installs_as "$name"
done

DEFAULT_NET="$(sed -n 's/^const DEFAULT_NET = "\(.*\)";$/\1/p' "$ROOT/build.zig")"
[[ -n "$DEFAULT_NET" && -f "$ROOT/$DEFAULT_NET" ]] || fail "build.zig does not name the default network"
cp "$ROOT/$DEFAULT_NET" "$WORK/candidate.nnue"
(cd "$ROOT" && make -j EXE="$WORK/Avalanche-ob" CC=zig EVALFILE="$WORK/candidate.nnue")
test -x "$WORK/Avalanche-ob"
printf 'position startpos\ngo depth 1\nquit\n' | "$WORK/Avalanche-ob" > "$WORK/uci.txt"
grep -q "NNUE evaluation using candidate " "$WORK/uci.txt" || fail "EVALFILE network was not embedded"
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
nodes_per_second = int(re.search(r'\d+', nps).group())
expected = int(open(sys.argv[2]).read().split()[0])
assert nodes == expected, f"bench {nodes} != bench.nodes {expected}"
print(f"ok: bench {nodes}, nps {nodes_per_second}")
PY
