#!/usr/bin/env bash
set -euo pipefail

# Release builds pass e.g. VERSION=4.1.0; everything else is a dev build.
VERSION="${VERSION:-dev}"
VERSION="${VERSION#v}"
# Dev builds keep the build-timestamp version string; releases report VERSION.
VERSION_FLAG=()
if [ "$VERSION" != "dev" ]; then
    VERSION_FLAG=(-Dversion="$VERSION")
fi
OUT="artifacts"
mkdir -p "$OUT"

# build <target-triple> <cpu-name|""> <suffix>
# Pass "" for cpu to use the Zig default (baseline for the target).
build() {
    local triple="$1" cpu="$2" suffix="$3"
    local name="Avalanche-${VERSION}-${suffix}"
    echo "==> $name  (target=$triple cpu=${cpu:-baseline})"
    if [ -n "$cpu" ]; then
        zig build --release=fast -Dtarget="$triple" -Dcpu="$cpu" --prefix "$OUT" -Dtarget-name="$name" ${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}
    else
        zig build --release=fast -Dtarget="$triple" --prefix "$OUT" -Dtarget-name="$name" ${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}
    fi
}

# One build per meaningful instruction-set level: v1 runs anywhere, v3 (AVX2)
# and v4 (AVX-512) are the fast paths; v2 adds nothing NNUE inference uses.

# Windows
build x86_64-windows  x86_64    x86_64-windows-v1
build x86_64-windows  x86_64_v3 x86_64-windows-v3
build x86_64-windows  x86_64_v4 x86_64-windows-v4
build aarch64-windows ""        aarch64-windows

# Linux
build x86_64-linux-musl  x86_64    x86_64-linux-v1
build x86_64-linux-musl  x86_64_v3 x86_64-linux-v3
build x86_64-linux-musl  x86_64_v4 x86_64-linux-v4
build aarch64-linux-musl ""        aarch64-linux

# macOS: Intel, and Apple Silicon (Zig's aarch64-macos baseline is already M1)
build x86_64-macos  x86_64    x86_64-macos-v1
build x86_64-macos  x86_64_v3 x86_64-macos-v3
build aarch64-macos ""        aarch64-macos

# WebAssembly (browsers, Node, Bun; see docs/WASM.md)
echo "==> Avalanche-${VERSION}-wasm"
zig build wasm --release=fast --prefix "$OUT" ${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}
cp "$OUT/web/avalanche.wasm" "$OUT/bin/Avalanche-${VERSION}-wasm.wasm"

cp README.md "$OUT/bin/"
cp LICENSE   "$OUT/bin/"
cd "$OUT/bin"
zip -9 -r build.zip ./*
mv build.zip ../
