#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FASTCHESS="$REPO/fastchess/fastchess"
CACHE="$REPO/.sprt-cache"
BIN_CACHE="$CACHE/bin"
BOOK="$REPO/books/UHO_4060_v4.epd"

REF="${1:-HEAD~1}"
GAMES="${2:-100}"
CONCURRENCY_ARG="${3:-}"

bold() { printf '\033[1m%s\033[0m' "$1"; }
info() { printf '\033[36m::\033[0m %s\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v zig >/dev/null 2>&1 || die "zig not found on PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH"
[ -x "$FASTCHESS" ] || die "fastchess not found at $FASTCHESS"
[ -f "$BOOK" ] || die "opening book not found at $BOOK"
[ $((GAMES % 2)) -eq 0 ] || die "GAMES must be even (for color-balanced pairs), got $GAMES"

build_current() {
    local out="$CACHE/current"
    info "Building current working tree" >&2
    zig build --release=fast -Dtarget-name=Avalanche-current --prefix "$out" >&2 2>&1
    local bin="$out/bin/Avalanche-current"
    [ -x "$bin" ] || die "build did not produce $bin"
    echo "$bin"
}

build_ref() {
    local ref="$1"
    local sha
    sha="$(git -C "$REPO" rev-parse --short "$ref")" || die "cannot resolve ref '$ref'"

    mkdir -p "$BIN_CACHE"
    local cached="$BIN_CACHE/Avalanche-$sha"
    if [ -x "$cached" ]; then
        info "Reusing cached build for $(bold "$ref") ($sha)" >&2
        echo "$cached"
        return
    fi

    local wt="$CACHE/wt-$sha"
    [ -d "$wt" ] && git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
    info "Building ref $(bold "$ref") ($sha) in a temporary worktree" >&2
    git -C "$REPO" worktree add --detach --force "$wt" "$sha" >&2 2>&1

    (
        cd "$wt"
        zig build --release=fast -Dtarget-name=Avalanche --prefix "$wt/out" >&2 2>&1
    )
    local built="$wt/out/bin/Avalanche"
    [ -x "$built" ] || die "ref build did not produce $built"
    cp "$built" "$cached"
    git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
    echo "$cached"
}

SHA="$(git -C "$REPO" rev-parse --short "$REF")"
ROUNDS=$((GAMES / 2))

info "Quick test: current vs $(bold "$REF") ($SHA), $GAMES games"
echo

NEW_BIN="$(build_current)"
OPP_BIN="$(build_ref "$REF")"

if [ -n "$CONCURRENCY_ARG" ]; then
    CONCURRENCY="$CONCURRENCY_ARG"
else
    CONCURRENCY="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    CONCURRENCY=$((CONCURRENCY > 2 ? CONCURRENCY - 2 : 1))
fi

echo
printf '  \033[1mAvalanche Quick Test\033[0m\n'
printf '    current  vs  ref-%s\n' "$SHA"
printf '    tc=5+0.05  threads=1  hash=16MB  concurrency=%d\n' "$CONCURRENCY"
printf '    games=%d  book=%s\n' "$GAMES" "$(basename "$BOOK")"
echo

exec "$FASTCHESS" \
    -engine "cmd=$NEW_BIN" "name=current" \
    -engine "cmd=$OPP_BIN" "name=ref-$SHA" \
    -each "tc=5+0.05" "option.Hash=16" "option.Threads=1" proto=uci \
    -openings "file=$BOOK" format=epd order=random \
    -games 2 \
    -rounds "$ROUNDS" \
    -repeat \
    -concurrency "$CONCURRENCY" \
    -ratinginterval 10 \
    -recover \
    -draw movenumber=34 movecount=8 score=8 \
    -resign movecount=3 score=400
