import os

if os.name == 'nt':
    os.system("cp ./zig-out/bin/Avalanche.exe ./old_binaries/Avalanche.exe")
else:
    os.system("cp ./zig-out/bin/Avalanche ./old_binaries/Avalanche")

print("Success!")
