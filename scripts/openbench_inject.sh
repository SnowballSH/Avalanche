#!/usr/bin/env bash
# openbench_inject.sh — build candidate net engines, seed them into the local
# OpenBench worker cache, and create STC + LTC SPRT jobs (each candidate vs a base
# net) in the running OpenBench instance.
#
# Avalanche embeds its NNUE at compile time (the Makefile ignores EVALFILE), so a
# net can't be chosen through OpenBench's network upload. Instead, for each net:
#   1. build the engine (scripts/build_net_engine.sh, via -Dnet),
#   2. copy the binary into the workers' shared Engines/ cache under the name
#      OpenBench expects, "<Engine>-<SHA8>", so the worker uses it instead of
#      downloading source,
#   3. create an Engine row with that placeholder sha and the binary's real bench
#      (the worker verifies the bench, so it must match).
# Networks stay empty (the net is in the binary); scale_nps is set to the reference
# nps so the effective time control matches the nominal one.
#
# Usage:
#   scripts/openbench_inject.sh codename:net.nnue [codename:net.nnue ...]
#   scripts/openbench_inject.sh                 # uses the CANDIDATES list below
#   DRY_RUN=1 scripts/openbench_inject.sh ...   # build and seed only, no DB write
#   HIDDEN=768 scripts/openbench_inject.sh ...  # for 768-wide nets
#
# Candidate format "codename:netfile[:token]": codename is the name shown in the UI,
# netfile is the .nnue path, token is an optional 8-char id (default sha256(net)[:8];
# pass one to reuse an existing engine/binary). Re-running is idempotent: engines are
# reused by token, and a test is skipped if an active one already exists for that
# dev + time control.
#
# Requires a running OpenBench instance in $OB_DIR with its venv, workers sharing
# $OB_DIR/Client/Engines, scripts/build_net_engine.sh, and python3.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Configuration — override any value via the environment.
ENGINE="${ENGINE:-Avalanche}"                        # OpenBench engine/config name
SOURCE_REPO="${SOURCE_REPO:-https://github.com/SnowballSH/Avalanche}" # placeholder repo (not fetched on cache hit)
OB_DIR="${OB_DIR:-$REPO/OpenBench}"
OB_PY="${OB_PY:-$OB_DIR/.venv/bin/python}"
ENGINES_CACHE="${ENGINES_CACHE:-$OB_DIR/Client/Engines}"
HIDDEN="${HIDDEN:-512}"                               # hidden size for build_net_engine.sh

# Reference nps for time scaling: default = "nps" from Engines/<Engine>.json.
REF_NPS="${REF_NPS:-$(python3 -c "import json;print(json.load(open('$OB_DIR/Engines/$ENGINE.json'))['nps'])" 2>/dev/null || echo 1500000)}"

AUTHOR="${AUTHOR:-admin}"
BOOK="${BOOK:-UHO_4060_v2.epd}"
BOUNDS_LOWER="${BOUNDS_LOWER:-0.0}" ; BOUNDS_UPPER="${BOUNDS_UPPER:-5.0}"   # SPRT [elolower, eloupper]
ALPHA="${ALPHA:-0.05}" ; BETA="${BETA:-0.05}"
WIN_ADJ="${WIN_ADJ:-movecount=3 score=400}"
DRAW_ADJ="${DRAW_ADJ:-movenumber=40 movecount=8 score=10}"
SCALE_METHOD="${SCALE_METHOD:-BOTH}"                 # DEV | BASE | BOTH

# STC / LTC presets — keep in sync with Engines/<Engine>.json test_presets.
# STC is given higher priority so workers exhaust all STC before any LTC.
STC_TC="${STC_TC:-10.0+0.1}" ; STC_OPTS="${STC_OPTS:-Threads=1 Hash=8}"  ; STC_WL="${STC_WL:-32}" ; STC_PRIO="${STC_PRIO:-200}" ; STC_PGNS="${STC_PGNS:-FALSE}"
LTC_TC="${LTC_TC:-60.0+0.6}" ; LTC_OPTS="${LTC_OPTS:-Threads=1 Hash=64}" ; LTC_WL="${LTC_WL:-8}"  ; LTC_PRIO="${LTC_PRIO:-100}" ; LTC_PGNS="${LTC_PGNS:-FALSE}"

# Base (reference) net. Set BASE_TOKEN to reuse an existing engine row/binary.
BASE_NAME="${BASE_NAME:-bingshan}" ; BASE_NET="${BASE_NET:-$REPO/nets/bingshan.nnue}" ; BASE_TOKEN="${BASE_TOKEN:-}"

# Candidates to test. Pass them as CLI args, or list them here. Format as above, e.g.
#   CANDIDATES=( "mynet:$REPO/nets/mynet.nnue" )
CANDIDATES=()
[ $# -gt 0 ] && CANDIDATES=("$@")

bold() { printf '\033[1m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidates: pass codename:net.nnue args, or fill in CANDIDATES"
[ -x "$OB_PY" ] || die "OpenBench venv python not found at $OB_PY (set OB_PY=)"
[ -d "$ENGINES_CACHE" ] || die "worker Engines cache not found at $ENGINES_CACHE (set ENGINES_CACHE=)"
[ -x "$REPO/scripts/build_net_engine.sh" ] || die "scripts/build_net_engine.sh missing"

# token = explicit (upper, ≤8) or sha256(netfile)[:8] upper
derive_token() { # netfile explicit
  local net="$1" explicit="${2:-}"
  if [ -n "$explicit" ]; then printf '%s' "$explicit" | tr '[:lower:]' '[:upper:]' | cut -c1-8; return; fi
  { sha256sum "$net" 2>/dev/null || shasum -a 256 "$net" 2>/dev/null \
    || python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$net"; } \
    | awk '{print toupper(substr($1,1,8))}'
}

# Build (if needed), seed the cache binary, and return "name|token|bench".
prepare_engine() { # name net explicit_token
  local name="$1" net="$2" explicit="${3:-}" token cache_bin built bench
  [ -f "$net" ] || die "net file not found: $net"
  token="$(derive_token "$net" "$explicit")"
  cache_bin="$ENGINES_CACHE/$ENGINE-$token"
  if [ ! -x "$cache_bin" ]; then
    built="$REPO/engines_built/$ENGINE-$name"
    [ -x "$built" ] || "$REPO/scripts/build_net_engine.sh" "$net" "$name" "$HIDDEN" >&2
    cp -f "$built" "$cache_bin"; chmod +x "$cache_bin"
    bold ":: seeded $ENGINE-$token  <- $name ($net)"
  else
    bold ":: reusing cached $ENGINE-$token"
  fi
  bench="$("$cache_bin" bench 2>&1 | grep -oE '^[0-9]+' | head -1)"
  [ -n "$bench" ] || die "could not parse bench for $name ($cache_bin)"
  printf '%s|%s|%s\n' "$name" "$token" "$bench"
}

bold "== OpenBench injector =="
bold "   engine=$ENGINE  ref_nps=$REF_NPS  bounds=[$BOUNDS_LOWER,$BOUNDS_UPPER]  STC prio=$STC_PRIO  LTC prio=$LTC_PRIO"

BASE_TRIPLE="$(prepare_engine "$BASE_NAME" "$BASE_NET" "$BASE_TOKEN")"
CAND_TRIPLES=()
for entry in "${CANDIDATES[@]}"; do
  IFS=':' read -r cname cnet ctoken <<< "$entry"
  CAND_TRIPLES+=("$(prepare_engine "$cname" "$cnet" "${ctoken:-}")")
done

# Serialize the whole plan to JSON for the Django step (env avoids quoting pain).
export ENGINE SOURCE_REPO REF_NPS AUTHOR BOOK BOUNDS_LOWER BOUNDS_UPPER ALPHA BETA \
       WIN_ADJ DRAW_ADJ SCALE_METHOD STC_TC STC_OPTS STC_WL STC_PRIO STC_PGNS \
       LTC_TC LTC_OPTS LTC_WL LTC_PRIO LTC_PGNS
export BASE_TRIPLE
export CAND_TRIPLES_STR="$(printf '%s\n' "${CAND_TRIPLES[@]}")"
OB_INJECT_CONFIG="$(python3 - <<'PYJSON'
import os, json
def trip(s):
    n, t, b = s.split('|'); return {"name": n, "token": t.upper()[:8], "bench": int(b)}
leg = lambda p: {"tc": os.environ[p+"_TC"], "opts": os.environ[p+"_OPTS"],
                 "wl": int(os.environ[p+"_WL"]), "prio": int(os.environ[p+"_PRIO"]),
                 "pgns": os.environ[p+"_PGNS"]}
cfg = {
  "engine": os.environ["ENGINE"], "repo": os.environ["SOURCE_REPO"],
  "ref_nps": int(os.environ["REF_NPS"]), "author": os.environ["AUTHOR"], "book": os.environ["BOOK"],
  "elolower": float(os.environ["BOUNDS_LOWER"]), "eloupper": float(os.environ["BOUNDS_UPPER"]),
  "alpha": float(os.environ["ALPHA"]), "beta": float(os.environ["BETA"]),
  "win_adj": os.environ["WIN_ADJ"], "draw_adj": os.environ["DRAW_ADJ"],
  "scale_method": os.environ["SCALE_METHOD"], "stc": leg("STC"), "ltc": leg("LTC"),
  "base": trip(os.environ["BASE_TRIPLE"]),
  "candidates": [trip(x) for x in os.environ["CAND_TRIPLES_STR"].splitlines() if x.strip()],
}
print(json.dumps(cfg))
PYJSON
)"
export OB_INJECT_CONFIG

if [ "${DRY_RUN:-0}" = "1" ]; then
  bold ":: DRY_RUN — binaries seeded; not writing to DB. Plan:"
  printf '%s\n' "$OB_INJECT_CONFIG" | python3 -m json.tool >&2
  exit 0
fi

# Back up the DB before any write.
cp -a "$OB_DIR/db.sqlite3" "$OB_DIR/db.sqlite3.bak-$(date +%s)" 2>/dev/null \
  && bold ":: backed up db.sqlite3"

# Django step: upsert engines + create STC/LTC tests (idempotent).
INJECT_PY="$(mktemp --suffix=.py)"; trap 'rm -f "$INJECT_PY"' EXIT
cat > "$INJECT_PY" <<'PYEOF'
import os, json, math
from OpenBench.models import Engine, Test
from django.db import transaction

cfg   = json.loads(os.environ["OB_INJECT_CONFIG"])
alpha = cfg["alpha"]; beta = cfg["beta"]
lowerllr = math.log(beta / (1.0 - alpha))
upperllr = math.log((1.0 - beta) / alpha)

def upsert_engine(spec):
    e = Engine.objects.filter(sha=spec["token"]).first() or Engine()
    e.name = spec["name"]; e.sha = spec["token"]; e.bench = spec["bench"]
    e.source = "%s/archive/%s.zip" % (cfg["repo"], spec["token"])
    e.save()
    return e

base = upsert_engine(cfg["base"])

def make_test(dev, leg, kind):
    if Test.objects.filter(dev=dev, dev_time_control=leg["tc"],
                           finished=False, deleted=False).exists():
        print("  skip (active test exists): %s %s" % (kind, dev.name)); return None
    t = Test()
    t.author = cfg["author"]; t.upload_pgns = leg["pgns"]
    t.book_name = cfg["book"]; t.book_index = 1
    t.dev = dev;   t.dev_repo = cfg["repo"];  t.dev_engine = cfg["engine"]
    t.dev_options = leg["opts"]; t.dev_network = ""; t.dev_netname = ""; t.dev_time_control = leg["tc"]
    t.base = base; t.base_repo = cfg["repo"]; t.base_engine = cfg["engine"]
    t.base_options = leg["opts"]; t.base_network = ""; t.base_netname = ""; t.base_time_control = leg["tc"]
    t.workload_size = leg["wl"]; t.priority = leg["prio"]; t.throughput = 100
    t.scale_method = cfg["scale_method"]; t.scale_nps = cfg["ref_nps"]
    t.syzygy_wdl = "OPTIONAL"; t.syzygy_adj = "OPTIONAL"
    t.win_adj = cfg["win_adj"]; t.draw_adj = cfg["draw_adj"]
    t.test_mode = "SPRT"
    t.elolower = cfg["elolower"]; t.eloupper = cfg["eloupper"]; t.alpha = alpha; t.beta = beta
    t.lowerllr = lowerllr; t.upperllr = upperllr; t.currentllr = 0.0
    t.max_games = 0; t.genfens_args = ""; t.play_reverses = 0
    t.use_tri = False; t.use_penta = True
    t.approved = True; t.awaiting = False; t.finished = False
    t.deleted = False; t.passed = False; t.failed = False; t.error = False
    t.info = "%s: %s vs %s SPRT [%g,%g]" % (kind, dev.name, base.name, cfg["elolower"], cfg["eloupper"])
    t.save()
    return t

with transaction.atomic():
    for spec in cfg["candidates"]:
        dev = upsert_engine(spec)
        stc = make_test(dev, cfg["stc"], "STC")
        ltc = make_test(dev, cfg["ltc"], "LTC")
        msg = "%-12s bench=%-9d" % (spec["name"], spec["bench"])
        if stc: msg += "  STC id=%d(prio %d)" % (stc.id, stc.priority)
        if ltc: msg += "  LTC id=%d(prio %d)" % (ltc.id, ltc.priority)
        print(msg)

active = Test.objects.filter(approved=True, finished=False, deleted=False, awaiting=False)
print("\nACTIVE jobs now: %d" % active.count())
for t in active.order_by("-priority", "id"):
    print("  id=%-3d prio=%-3d %-42s dev_bench=%-9d base_bench=%-9d TC=%-9s %-18s scale_nps=%d bounds=[%g,%g]"
          % (t.id, t.priority, t.info, t.dev.bench, t.base.bench, t.dev_time_control,
             t.dev_options, t.scale_nps, t.elolower, t.eloupper))
PYEOF

bold ":: injecting via Django ORM ($OB_DIR)"
( cd "$OB_DIR" && "$OB_PY" manage.py shell -c "exec(open('$INJECT_PY').read())" )

bold ":: done — watch progress on the OpenBench web UI"
