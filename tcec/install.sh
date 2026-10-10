#!/bin/bash

install_avalanche() {
    local zig_version zig_dir release commit release_tag version

    [ -d Avalanche ] || git clone --depth 1 https://github.com/SnowballSH/Avalanche || return
    cd Avalanche || return
    git fetch --depth 1 origin master || return
    git reset --hard FETCH_HEAD || return

    zig_version=$(sed -n 's/^ *\.minimum_zig_version = "\(.*\)",$/\1/p' build.zig.zon)
    zig_dir=zig-$(uname -m)-linux-$zig_version
    if [ ! -x "$zig_dir/zig" ]; then
        rm -rf "$zig_dir" "$zig_dir.partial"
        mkdir "$zig_dir.partial" || return
        wget -nv -O - "https://ziglang.org/download/$zig_version/$zig_dir.tar.xz" |
            tar -xJ -C "$zig_dir.partial" --strip-components=1 || return
        mv "$zig_dir.partial" "$zig_dir" || return
    fi

    release=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
    commit=$(git rev-parse HEAD)
    release_tag=$(git ls-remote origin "refs/tags/v$release" "refs/tags/v$release^{}") || return
    if [ "$(printf '%s\n' "$release_tag" | tail -n 1 | cut -f 1)" = "$commit" ]; then
        version=$release
    else
        version=$release-dev-$(git rev-parse --short=8 HEAD)
    fi

    "$zig_dir/zig" build --release=fast -Dversion="$version" || return
    bash scripts/verify_binary.sh zig-out/bin/Avalanche || return
    # shellcheck disable=SC2034 # read by TCEC's updater once update.sh returns
    EXE=$PWD/zig-out/bin/Avalanche
}

install_avalanche
