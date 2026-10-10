#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

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

find_objdump() {
    local candidate version
    local -a candidates=()
    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(compgen -c llvm-objdump | sort -u -V -r || true)
    if command -v xcrun > /dev/null; then
        candidate="$(xcrun -f llvm-objdump 2> /dev/null || true)"
        [ -z "$candidate" ] || candidates+=("$candidate")
    fi
    for candidate in ${candidates[@]+"${candidates[@]}"}; do
        version="$("$candidate" --version 2> /dev/null | grep -o -E 'LLVM version [0-9]+' | grep -o -E '[0-9]+$' || true)"
        version="${version%%$'\n'*}"
        if [ -n "$version" ] && [ "$version" -ge "$MIN_OBJDUMP_VERSION" ]; then
            command -v "$candidate"
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

contains_instruction() {
    local listing="$1" token="$2" pattern status=0
    local register_of_class="${token}[0-9]"
    # Mach-O listings append the arrangement to the mnemonic, as in sdot.4s.
    local whole_mnemonic="[[:space:]](${token})([[:space:].]|\$)"
    case "$token" in
        %*) pattern="$register_of_class" ;;
        *) pattern="$whole_mnemonic" ;;
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

reason_it_cannot_run() {
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

check_reported_version() {
    local bin="$1" reported
    reported="$(printf 'uci\nquit\n' | "$bin" | sed -n 's/^id name //p')" || fail "$bin did not answer uci"
    [ "$reported" = "Avalanche $VERSION" ] || fail "$bin reports '$reported', not 'Avalanche $VERSION'"
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
    reason="$(reason_it_cannot_run "$target" "$flags")"
    if [ -z "$reason" ]; then
        result="$(scripts/verify_binary.sh "$bin" "$paths")"
        echo "    $result"
        if [ "$VERSION" != "dev" ]; then
            check_reported_version "$bin"
            echo "    reports version $VERSION"
        fi
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

echo "==> Avalanche-${VERSION}-wasm"
zig build wasm --release=fast --prefix "$OUT" ${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}
cp "$OUT/web/avalanche.wasm" "$OUT/bin/Avalanche-${VERSION}-wasm.wasm"

cp README.md LICENSE "$OUT/bin/"
cp src/pyrrhic/LICENSE "$OUT/bin/LICENSE-pyrrhic"
cd "$OUT/bin"
zip -9 -r build.zip ./*
mv build.zip ../
