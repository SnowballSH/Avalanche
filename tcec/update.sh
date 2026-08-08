#!/bin/bash

if [ ! -d "Avalanche" ]; then
    git clone -b tcec --depth 1 "https://github.com/SnowballSH/Avalanche"
fi
cd Avalanche
git fetch --depth 1 origin tcec
git reset --hard FETCH_HEAD
if [ ! -d "zig-x86_64-linux-0.16.0" ]; then
    wget https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
    tar -xf zig-x86_64-linux-0.16.0.tar.xz
fi
zig-x86_64-linux-0.16.0/zig build --release=fast -Dtarget-name="Avalanche"
EXE=$PWD/zig-out/bin/Avalanche
