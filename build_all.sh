zig build -Drelease-fast=true -Dtarget=x86_64-windows
mv ./zig-out/bin/Avalanche.exe ./binaries/Avalanche_x86_64_windows_0.3dev.exe
zig build -Drelease-fast=true -Dtarget=x86_64-windows -Dcpu=haswell
mv ./zig-out/bin/Avalanche.exe ./binaries/Avalanche_x86_64_windows_haswell_0.3dev.exe
zig build -Drelease-fast=true -Dtarget=x86_64-linux
mv ./zig-out/bin/Avalanche ./binaries/Avalanche_x86_64_linux_0.3dev
zig build -Drelease-fast=true -Dtarget=aarch64-macos
cp ./zig-out/bin/Avalanche ./binaries/Avalanche_aarch64_macos_0.3dev