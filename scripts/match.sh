#!/usr/bin/env bash
# match.sh — run a fixed N-game match between a candidate engine and a reference
# engine and report Elo. No SPRT (use this to screen candidates; sprt.py for SPRT).
#
# Usage: scripts/match.sh <cand_bin> <ref_bin> [games] [concurrency] [tc] [tag]
#   cand_bin    : candidate engine binary
#   ref_bin     : reference engine binary
#   games       : total games (default 500, must be even)
#   concurrency : parallel games (default 10)
#   tc          : time control (default 10+0.1)
#   tag         : label for logs (default: candidate binary basename)
#
# Result line (Elo +/- ...) is printed to stdout and saved under tmp/matches/.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FASTCHESS="$REPO/fastchess/fastchess"
BOOK="$REPO/books/UHO_4060_v4.epd"

CAND="${1:?usage: match.sh <cand_bin> <ref_bin> [games] [conc] [tc] [tag]}"
REF="${2:?need ref_bin}"
GAMES="${3:-500}"
CONC="${4:-10}"
TC="${5:-10+0.1}"
# Display names: strip a leading "Avalanche-" from the binary basename for readability.
CAND_NAME="$(basename "$CAND" | sed 's/^Avalanche-//')"
REF_NAME="$(basename "$REF" | sed 's/^Avalanche-//')"
TAG="${6:-$CAND_NAME}"

[ -x "$FASTCHESS" ] || { echo "fastchess missing: $FASTCHESS" >&2; exit 1; }
[ -x "$CAND" ] || { echo "candidate missing: $CAND" >&2; exit 1; }
[ -x "$REF" ] || { echo "reference missing: $REF" >&2; exit 1; }
[ -f "$BOOK" ] || { echo "book missing: $BOOK" >&2; exit 1; }
[ $((GAMES % 2)) -eq 0 ] || { echo "games must be even" >&2; exit 1; }

ROUNDS=$((GAMES / 2))
mkdir -p "$REPO/tmp/matches"
LOG="$REPO/tmp/matches/$TAG.log"
PGN="$REPO/tmp/matches/$TAG.pgn"

echo ":: match $TAG  ($GAMES games @ $TC, conc=$CONC)  $CAND_NAME vs $REF_NAME" >&2
echo ":: log -> $LOG" >&2

"$FASTCHESS" \
    -engine "cmd=$CAND" "name=$CAND_NAME" \
    -engine "cmd=$REF" "name=$REF_NAME" \
    -each "tc=$TC" "option.Hash=16" "option.Threads=1" proto=uci \
    -openings "file=$BOOK" format=epd order=random \
    -games 2 -rounds "$ROUNDS" -repeat \
    -concurrency "$CONC" \
    -ratinginterval 50 \
    -recover \
    -draw movenumber=34 movecount=8 score=8 \
    -resign movecount=3 score=400 \
    -pgnout "file=$PGN" 2>&1 | tee "$LOG"

echo ""
echo "=== RESULT [$TAG] (trust only the block with Games:$GAMES + 'Finished match') ==="
grep -E "Elo:|Score of|Games:|Ptnml" "$LOG" | tail -8
