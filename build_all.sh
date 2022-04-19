zig build -Drelease-fast=true -Dtarget=x86_64-windows
mv ./zig-out/bin/Avalanche.exe ./binaries/Avalanche_x86_64_windows.exe
zig build -Drelease-fast=true -Dtarget=x86_64-linux
mv ./zig-out/bin/Avalanche ./binaries/Avalanche_x86_64_linux
zig build -Drelease-fast=true -Dtarget=aarch64-macos
mv ./zig-out/bin/Avalanche ./binaries/Avalanche_aarch64_macos