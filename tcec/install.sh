#!/bin/bash

unset EXE

[ -d Avalanche ] || git clone --depth 1 https://github.com/SnowballSH/Avalanche || return
cd Avalanche || return
git fetch --depth 1 origin master || return
git reset --hard FETCH_HEAD || return

zig_version=$(sed -n 's/^ *\.minimum_zig_version = "\(.*\)",$/\1/p' build.zig.zon)
zig_dir=zig-$(uname -m)-linux-$zig_version
if [ ! -x "$zig_dir/zig" ]; then
    wget -q -O - "https://ziglang.org/download/$zig_version/$zig_dir.tar.xz" | tar -xJ || return
fi

release=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
commit=$(git rev-parse HEAD)
if [ "$(git ls-remote --tags origin "v$release" | tail -n 1 | cut -f 1)" = "$commit" ]; then
    version=$release
else
    version=$release-dev-${commit:0:8}
fi

"$zig_dir/zig" build --release=fast -Dversion="$version" || return
bash scripts/verify_binary.sh zig-out/bin/Avalanche || return
# shellcheck disable=SC2034 # read by TCEC's updater once update.sh returns
EXE=$PWD/zig-out/bin/Avalanche
