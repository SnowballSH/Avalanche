VERSION="1.6.0"

# Windows
zig build -Dtarget=x86_64-windows -Drelease-fast -Dcpu=x86_64 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-win-v1"
zig build -Dtarget=x86_64-windows -Drelease-fast -Dcpu=x86_64_v2 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-win-v2"
zig build -Dtarget=x86_64-windows -Drelease-fast -Dcpu=x86_64_v3 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-win-v3"
zig build -Dtarget=x86_64-windows -Drelease-fast -Dcpu=x86_64_v4 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-win-v4"

# Linux
zig build -Dtarget=x86_64-linux -Drelease-fast -Dcpu=x86_64 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-linux-v1"
zig build -Dtarget=x86_64-linux -Drelease-fast -Dcpu=x86_64_v2 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-linux-v2"
zig build -Dtarget=x86_64-linux -Drelease-fast -Dcpu=x86_64_v3 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-linux-v3"
zig build -Dtarget=x86_64-linux -Drelease-fast -Dcpu=x86_64_v4 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-linux-v4"

# macOS
zig build -Dtarget=x86_64-macos -Drelease-fast -Dcpu=x86_64 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-macos-v1"
zig build -Dtarget=x86_64-macos -Drelease-fast -Dcpu=x86_64_v2 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-macos-v2"
zig build -Dtarget=x86_64-macos -Drelease-fast -Dcpu=x86_64_v3 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-macos-v3"
zig build -Dtarget=x86_64-macos -Drelease-fast -Dcpu=x86_64_v4 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-x86_64-macos-v4"

# apple chip
zig build -Dtarget=aarch64-macos -Drelease-fast -Dcpu=apple_m1 --prefix artifacts/ -Dtarget-name="Avalanche-${VERSION}-aarch64-macos-m1"

cp README.md artifacts/bin/
cp LICENSE artifacts/bin/
cd artifacts/bin/
zip -9 -r build.zip *
mv build.zip ../