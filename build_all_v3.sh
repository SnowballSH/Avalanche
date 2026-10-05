#!/usr/bin/env bash
# Builds the release binaries of docs/BUILD.md ("Release matrix") into artifacts/ and verifies each.
#   bash build_all_v3.sh              every binary, the wasm module and artifacts/build.zip
#   bash build_all_v3.sh <name>...    only the named binaries (e.g. x86_64-linux-v2), no packaging
# VERSION=4.1.0 makes a release; without it the binaries report their build time.
# VERIFY_INSTRUCTIONS=0 skips the disassembly on a machine without llvm-objdump 15 or later.
# REQUIRE_RUN=1 fails when this machine cannot execute one of the binaries it built.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="${VERSION:-dev}"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || VERSION=dev
VERSION_FLAG=()
if [ "$VERSION" != "dev" ]; then
    VERSION_FLAG=(-Dversion="$VERSION")
fi
OUT="artifacts"
MIN_OBJDUMP_VERSION=15

# tier | -Dcpu | NNUE paths | instructions it contains | instructions it lacks | /proc/cpuinfo flags that run it
TIERS='
x86_64-v1|x86_64|128-bit vectors, pairwise portable, L1 portable, L2 pairs|pmaddwd|pmaddubsw %ymm|
x86_64-v2|x86_64_v2|128-bit vectors, pairwise mulhrs, L1 maddubs, L2 pairs|pmulhrsw pmaddubsw popcnt[lq]|%ymm|ssse3 sse4_2 popcnt
x86_64-v3|x86_64_v3|256-bit vectors, pairwise mulhrs, L1 maddubs, L2 pairs|vpmulhrsw vpmaddubsw %ymm|vpdpbusd %zmm %k|avx2 bmi2 fma
x86_64-avxvnni|x86_64_v3+avxvnni|256-bit vectors, pairwise mulhrs, L1 dpbusd, L2 pairs|vpmulhrsw vpdpbusd %ymm|%zmm %k|avx2 bmi2 fma avx_vnni
x86_64-avx512|x86_64_v4+avx512vnni+avx512vbmi+avx512vbmi2+avx512bitalg+avx512vpopcntdq-prefer_256_bit|512-bit vectors, pairwise mulhrs, L1 dpbusd, L2 pairs|vpmulhrsw vpdpbusd vpcompressb %zmm||avx512bw avx512vl avx512_vnni avx512vbmi avx512_vbmi2 avx512_bitalg avx512_vpopcntdq
aarch64-v8|generic|128-bit vectors, pairwise umull, L1 extadd, L2 wide|sqxtun sadalp|sdot|
aarch64-dotprod|generic+v8_2a+dotprod|128-bit vectors, pairwise umull, L1 sdot, L2 wide|sqxtun sdot ldseta?l?||asimddp atomics
aarch64-apple|apple_m1|128-bit vectors, pairwise umull, L1 sdot, L2 wide|sqxtun sdot ldseta?l?||
'

# binary name | zig target | tier
BINARIES='
x86_64-windows-v1|x86_64-windows|x86_64-v1
x86_64-windows-v2|x86_64-windows|x86_64-v2
x86_64-windows-v3|x86_64-windows|x86_64-v3
x86_64-windows-avxvnni|x86_64-windows|x86_64-avxvnni
x86_64-windows-avx512|x86_64-windows|x86_64-avx512
aarch64-windows|aarch64-windows|aarch64-v8
aarch64-windows-dotprod|aarch64-windows|aarch64-dotprod
x86_64-linux-v1|x86_64-linux-musl|x86_64-v1
x86_64-linux-v2|x86_64-linux-musl|x86_64-v2
x86_64-linux-v3|x86_64-linux-musl|x86_64-v3
x86_64-linux-avxvnni|x86_64-linux-musl|x86_64-avxvnni
x86_64-linux-avx512|x86_64-linux-musl|x86_64-avx512
aarch64-linux|aarch64-linux-musl|aarch64-v8
aarch64-linux-dotprod|aarch64-linux-musl|aarch64-dotprod
x86_64-macos-v3|x86_64-macos|x86_64-v3
aarch64-macos|aarch64-macos|aarch64-apple
'

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Prints the row of a table whose first field is the key.
lookup() {
    local table="$1" key="$2" row
    while IFS= read -r row; do
        if [ "${row%%|*}" = "$key" ]; then
            printf '%s\n' "$row"
            return 0
        fi
    done <<< "$table"
    return 1
}

# Older versions do not decode every AArch64 extension, so an absent `sdot` would prove nothing.
find_objdump() {
    local candidate path version
    local -a candidates=(llvm-objdump)
    for version in {22..15}; do
        candidates+=("llvm-objdump-$version")
    done
    for candidate in "${candidates[@]}"; do
        path="$(command -v "$candidate" || true)"
        if [ -z "$path" ] && [ "$candidate" = llvm-objdump ] && command -v xcrun > /dev/null; then
            path="$(xcrun -f llvm-objdump 2> /dev/null || true)"
        fi
        [ -n "$path" ] || continue
        version="$("$path" --version | grep -o -E 'LLVM version [0-9]+' | grep -o -E '[0-9]+$' || true)"
        version="${version%%$'\n'*}"
        if [ -n "$version" ] && [ "$version" -ge "$MIN_OBJDUMP_VERSION" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

OBJDUMP=""
if [ "${VERIFY_INSTRUCTIONS:-1}" != "0" ]; then
    OBJDUMP="$(find_objdump)" || fail "no llvm-objdump $MIN_OBJDUMP_VERSION or later found; install LLVM or set VERIFY_INSTRUCTIONS=0"
fi

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# A token is a mnemonic (a regular expression for the whole word; Mach-O listings append the
# arrangement, as in sdot.4s) or, with a leading %, a register class. Succeeds when the listing
# has it, returns 1 when it has not; a grep that cannot answer ends the script.
contains_instruction() {
    local listing="$1" token="$2" pattern status=0
    case "$token" in
        %*) pattern="${token}[0-9]" ;;
        *) pattern="[[:space:]](${token})([[:space:].]|\$)" ;;
    esac
    grep -q -E -- "$pattern" "$listing" || status=$?
    [ "$status" -le 1 ] || fail "grep could not search $listing for '$pattern'"
    return "$status"
}

verify_instructions() {
    local bin="$1" token
    local -a required excluded
    read -r -a required <<< "$2"
    read -r -a excluded <<< "$3"
    local listing="$WORK/listing.txt"
    "$OBJDUMP" -d --no-show-raw-insn "$bin" > "$listing"
    [ -s "$listing" ] || fail "$OBJDUMP printed no disassembly of $bin"
    for token in ${required[@]+"${required[@]}"}; do
        contains_instruction "$listing" "$token" || fail "$bin has no '$token' instruction"
    done
    for token in ${excluded[@]+"${excluded[@]}"}; do
        if contains_instruction "$listing" "$token"; then
            fail "$bin contains '$token' instructions"
        fi
    done
}

# Why this machine cannot execute a binary of the target with the tier's CPU flags; nothing when it can.
cannot_run() {
    local target="$1" flag missing=""
    local -a flags
    read -r -a flags <<< "$2"
    case "$(uname -s)/$(uname -m)/$target" in
        Linux/x86_64/x86_64-linux-* | Linux/aarch64/aarch64-linux-*)
            for flag in ${flags[@]+"${flags[@]}"}; do
                grep -q -w -- "$flag" /proc/cpuinfo || missing="$missing $flag"
            done
            [ -z "$missing" ] || echo "host CPU lacks$missing"
            ;;
        Darwin/arm64/aarch64-macos) ;;
        *) echo "host is $(uname -s) $(uname -m)" ;;
    esac
}

RAN=()
NOT_RUN=()

build() {
    local suffix="$1" target="$2" tier="$3"
    local row cpu paths required excluded flags reason result
    row="$(lookup "$TIERS" "$tier")" || fail "unknown tier '$tier'"
    IFS='|' read -r _ cpu paths required excluded flags <<< "$row"
    local name="Avalanche-${VERSION}-${suffix}"
    echo "==> $name  (target=$target cpu=$cpu)"
    zig build --release=fast -Dtarget="$target" -Dcpu="$cpu" -Dstrip=true --prefix "$OUT" -Dtarget-name="$name" ${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}

    local bin="$OUT/bin/$name"
    [ -f "$bin" ] || bin="$bin.exe"
    [ -f "$bin" ] || fail "$name was not installed in $OUT/bin"
    LC_ALL=C grep -q -a -F -- "$paths" "$bin" || fail "$bin was not compiled with '$paths'"
    echo "    paths: $paths"
    if [ -n "$OBJDUMP" ]; then
        verify_instructions "$bin" "$required" "$excluded"
        echo "    instructions: has ${required:-nothing required}; lacks ${excluded:-nothing excluded}"
    fi
    reason="$(cannot_run "$target" "$flags")"
    if [ -z "$reason" ]; then
        result="$(bash scripts/verify_binary.sh "$bin" "$paths")"
        echo "    $result"
        RAN+=("$suffix")
    else
        echo "    not run: $reason"
        NOT_RUN+=("$suffix")
    fi
}

SELECTED=("$@")
if [ "$#" -eq 0 ]; then
    rm -rf -- "$OUT"
    while IFS='|' read -r suffix _; do
        [ -z "$suffix" ] || SELECTED+=("$suffix")
    done <<< "$BINARIES"
fi
mkdir -p "$OUT"
for suffix in "${SELECTED[@]}"; do
    row="$(lookup "$BINARIES" "$suffix")" || fail "unknown binary '$suffix'"
    IFS='|' read -r _ target tier <<< "$row"
    build "$suffix" "$target" "$tier"
done
echo "ran on this machine: ${RAN[*]:-none}"
echo "built and inspected, not run: ${NOT_RUN[*]:-none}"
if [ "${REQUIRE_RUN:-0}" = "1" ] && [ "${#NOT_RUN[@]}" -gt 0 ]; then
    fail "REQUIRE_RUN=1, but this machine could not run: ${NOT_RUN[*]}"
fi
[ "$#" -eq 0 ] || exit 0

# WebAssembly (browsers, Node, Bun; see docs/WASM.md)
echo "==> Avalanche-${VERSION}-wasm"
zig build wasm --release=fast --prefix "$OUT" ${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}
cp "$OUT/web/avalanche.wasm" "$OUT/bin/Avalanche-${VERSION}-wasm.wasm"

cp README.md "$OUT/bin/"
cp LICENSE   "$OUT/bin/"
cd "$OUT/bin"
zip -9 -r build.zip ./*
mv build.zip ../
