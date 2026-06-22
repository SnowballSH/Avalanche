#!/usr/bin/env bash
set -euo pipefail

VERSION="3.0.0-dev"
OUT="artifacts"
mkdir -p "$OUT"

# build <target-triple> <cpu-name|""> <suffix>
# Pass "" for cpu to use the Zig default (baseline for the target).
build() {
    local triple="$1" cpu="$2" suffix="$3"
    local name="Avalanche-${VERSION}-${suffix}"
    echo "==> $name  (target=$triple cpu=${cpu:-baseline})"
    if [ -n "$cpu" ]; then
        zig build --release=fast -Dtarget="$triple" -Dcpu="$cpu" --prefix "$OUT" -Dtarget-name="$name"
    else
        zig build --release=fast -Dtarget="$triple" --prefix "$OUT" -Dtarget-name="$name"
    fi
}

# Windows
build x86_64-windows  x86_64    x86_64-windows-v1
build x86_64-windows  x86_64_v2 x86_64-windows-v2
build x86_64-windows  x86_64_v3 x86_64-windows-v3
build x86_64-windows  x86_64_v4 x86_64-windows-v4  # AVX-512 (Skylake-X / Ice Lake+)
build aarch64-windows ""        aarch64-windows      # Surface Pro X, Snapdragon X Elite, etc.

# Linux
build x86_64-linux-musl  x86_64    x86_64-linux-v1
build x86_64-linux-musl  x86_64_v2 x86_64-linux-v2
build x86_64-linux-musl  x86_64_v3 x86_64-linux-v3
build x86_64-linux-musl  x86_64_v4 x86_64-linux-v4  # AVX-512 (server / enthusiast desktops)
build aarch64-linux-musl ""        aarch64-linux      # Raspberry Pi 4+, AWS Graviton, etc.

# MacOS Intel
build x86_64-macos x86_64    x86_64-macos-v1
build x86_64-macos x86_64_v2 x86_64-macos-v2
build x86_64-macos x86_64_v3 x86_64-macos-v3

# MacOS (Apple Silicon)
build aarch64-macos ""        aarch64-macos       # baseline — safe for any M chip
build aarch64-macos apple_m1  aarch64-macos-m1   # M1 / M1 Pro / Max / Ultra (2020–21)
build aarch64-macos apple_m2  aarch64-macos-m2   # M2 / M2 Pro / Max / Ultra (2022–23)
build aarch64-macos apple_m3  aarch64-macos-m3   # M3 / M3 Pro / Max (2023–24)
build aarch64-macos apple_m4  aarch64-macos-m4   # M4 / M4 Pro / Max (2024+)

cp README.md "$OUT/bin/"
cp LICENSE   "$OUT/bin/"
cd "$OUT/bin"
zip -9 -r build.zip ./*
mv build.zip ../
