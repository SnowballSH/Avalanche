declare -a targets=("x86_64-windows" "x86_64-linux" "x86_64-macos" "aarch64-macos")
mkdir -p "artifacts/"
for target in "${targets[@]}"; do
    mkdir -p artifacts/$target
    echo "Building target ${target}..."
    zig build -Dtarget=${target} -Drelease-fast --prefix artifacts/${target}/ -Dtarget-name="Avalanche-${target}-1.1.0"
    
    if [[ "${target}" != "aarch64-macos" ]]; then
        zig build -Dtarget=${target} -Drelease-fast -Dcpu=haswell --prefix artifacts/${target}/ -Dtarget-name="Avalanche-${target}-haswell-1.1.0"
    else
        zig build -Dtarget=${target} -Drelease-fast -Dcpu=apple_m1 --prefix artifacts/${target}/ -Dtarget-name="Avalanche-${target}-m1-1.1.0"
    fi
    cat README.md > artifacts/${target}/README.md
    cp LICENSE artifacts/${target}/
    cd artifacts/${target}/
    zip -9 -r ${target}.zip *.md bin/* LICENSE
    mv ${target}.zip ../
    cd ../..
done