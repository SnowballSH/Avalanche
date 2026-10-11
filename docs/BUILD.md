# Build

Avalanche builds with Zig 0.17.0 and nothing else: `build.zig` compiles the engine, the Syzygy
probing code in `src/pyrrhic` (C, through the bundled Clang) and its bindings (the `translate_c`
package and its C front end `aro`, vendored under `deps/` and named by path in `build.zig.zon`).

The two packages are the official Zig Software Foundation ones at translate-c 875969d and aro
d0c8c4d. They are vendored rather than fetched
because their host, Codeberg, rate-limits and sometimes refuses the fetch from build machines and
cloud workers, and a fetch that returns the wrong content fails the build with a hash mismatch.
`deps/translate-c/build.zig.zon` is the upstream file with its `aro` dependency pointed at
`../aro`; nothing else in `deps/` is modified. To upgrade, `zig fetch` the new commits of
`git+https://codeberg.org/ziglang/translate-c` and `git+https://codeberg.org/ziglang/arocc`, extract
the resulting `~/.cache/zig/p/<name>-<hash>.tar.gz` files over the two directories (translate-c's
archive nests its tree one directory deeper) and re-apply that one edit.

```sh
zig build --release=fast      # zig-out/bin/Avalanche, for the CPU of this machine
zig build                     # Debug
zig build test                # unit tests, Debug
zig build test -Doptimize=fast
zig build test-exe            # zig-out/bin/avalanche-tests, the unit tests as a binary
zig build wasm --release=fast # zig-out/web/avalanche.wasm (docs/WASM.md)
make EXE=name [EVALFILE=net]  # what OpenBench runs, see below
```

`test-exe` is for a machine other than the one that builds: with `-Dtarget=aarch64-linux-gnu`, say,
the binary is copied there and run.

| Option | Meaning |
|---|---|
| `-Dtarget=`, `-Dcpu=` | Target triple and CPU. Without `-Dtarget` the build is for this machine and its exact CPU; with `-Dtarget` and no `-Dcpu` it is for the target's baseline CPU (see "CPU baselines") |
| `-Dnet=<path>` | Network to embed (default `nets/dianguang-5.nnue`), relative to the repository root or absolute |
| `-Dhead=<head>` | The layers after the feature transformer: `single`, `multi`, or `auto` (the default), which reads them off the `-Dnet` file (docs/NNUE.md) |
| `-Dbuckets=<n>` | King input buckets of the feature transformer: 16 (the default), mirrored king buckets, as in every network under `nets/`, or 1, no king buckets. A `-Dnet` file of the other kind is a compile error |
| `-Dversion=<x.y.z>` | Version reported by `uci`. Without it a build reports its build time, which is why the configuration is never cached (`b.graph.poisonCache()`) |
| `-Dstrip=true` | No debug information in the binary. The release script passes it |
| `-Dtarget-name=<name>` | File name of the binary |
| `-Dtest-filter=<text>` | Only the unit tests whose name contains the text |

The default network is named in one place, the `default_net` line of `build.zig`.
`scripts/install_net.sh <checkpoint directory>` copies the checkpoint's `quantised.bin` to
`nets/<checkpoint name>.nnue`, rewrites that line and runs `scripts/update_bench.sh`;
`scripts/openbench_build_check.sh` reads it.

## What a release build is compiled with

`--release=fast` selects `ReleaseFast` and leaves every other code generation option to the
compiler. All Zig code is one LLVM module, so calls between files are inlined without LTO; the C
code is a second object (`-O3 -std=gnu11`) that the search never enters outside a tablebase probe.
What the compiler resolves, read off the binaries, and what changing it does:

| Setting | What `--release=fast` gives | Changed to | Effect |
|---|---|---|---|
| Frame pointers | kept: 543 of 673 functions set up `x29` on AArch64 macOS, 1000 in a static AArch64 Linux binary, 1100 `mov %rsp, %rbp` on x86-64 | `omit_frame_pointer = true` | 0.43% fewer instructions in `bench` on the M4 (three pairs: 0.40 to 0.47%); 1.1 KB less text. Not applied: see below |
| Unwind tables | `async` (`.eh_frame`: 39.5 KB on macOS, 66 KB on Linux) | `unwind_tables = .none` | 33 KB smaller on macOS, 13 KB on Linux; instructions within the spread between runs (-0.4% to +0.1%) |
| Stack protector, stack probes, error return traces, C undefined-behaviour checks, Valgrind requests | all off | each set off explicitly | the identical binary: these are the defaults |
| Debug information | kept. ELF: 8.2 MB of DWARF in a 35.0 MB file. Mach-O: the symbol table, 0.26 MB. Windows: a separate `.pdb` | `-Dstrip=true` | 26.8 MB on Linux. The code that would read the debug information for a crash report goes too (134 KB of text on macOS), nothing the search runs: instructions within the spread. The release script strips; a development build keeps its symbols for profilers |
| Position-independent executable | macOS: always. Linux, static: no. Windows: relocatable (ASLR) | `pie = true` on Linux | static-pie, 28 KB larger. Not timed (the Linux machine at hand is a virtual machine without cycle counters) |
| Link-time optimisation | none; it needs LLD, so it does not exist for Mach-O | `lto = .full` on Linux | 322 KB smaller: unused parts of libc and compiler-rt go. Not timed, for the same reason; the Zig code is one module already, and the C code is not on the search's path |
| Function and data sections, section garbage collection | the linker's default | all three on | 32 KB smaller on Linux, same size on macOS; instructions within the spread (-0.5% to +0.3%) |
| libc | linked: the allocator and Pyrrhic's file I/O use it. Dynamic on macOS, static musl in the Linux release binaries | | |
| Code model, red zone | target defaults (small model; red zone where the ABI has one) | not tried | nothing in a 1 MB text segment needs another model |

Instruction counts are from `/usr/bin/time -l` on an Apple M4 that was running other work, where
wall time and cycles were useless (the same binary varied by more than 20% in cycles) and the retired
instructions of one binary varied by 0.3 to 0.5% between runs. The binaries were built from commit
870eeab with only the build changes this document describes: the function counts and sizes in the
table are not those of a build that also has the later changes.
Nothing here is a measured gain in time, so `build.zig` sets none of it. Frame pointers are the one
worth timing on a quiet x86-64 machine: there the prologue is three instructions and `rbp` becomes
a general register, and a profiler that walks frames is the price.

One thing the build does choose: the `translate_c` tool is always compiled in Debug mode
(`.optimize` in its `b.dependency` call). It runs once, on one header.
Compiled in the mode of the engine, it would cost a `--release=fast` build 3.2 times the CPU of
the Debug tool (89.8 s against 27.7 s of user time on the loaded machine, from an empty cache)
before the engine's own compilation starts, and release builds and test builds would each
compile a tool of their own. The engine binary is the same either way, instruction for
instruction.

## CPU baselines

`-Dcpu=baseline`, and a cross build without `-Dcpu`, mean:

| Target | Baseline | NNUE paths | Notes |
|---|---|---|---|
| `x86_64-linux`, `x86_64-windows` | `x86_64`: SSE2 | portable pairwise and L1, `pairs` L2 | no POPCNT |
| `x86_64-macos` | `core2`: SSSE3 | `mulhrs`, `maddubs`, `pairs` at 128 bits | no POPCNT |
| `aarch64-linux`, `aarch64-windows` | `generic`: ARMv8.0 with NEON | `umull`, `extadd` L1, `wide` L2 | no LSE: an atomic operation is a load-exclusive loop |
| `aarch64-macos` | `apple_m1` | `umull`, `sdot`, `wide` | LSE |
| `wasm32` | fixed by `build.zig`: `generic` and `simd128` | `mulhrs`, `extadd`, `pairs` | see "WebAssembly features" |

The transposition table takes its entry lock with one atomic OR per store. With LSE (ARMv8.1) that
is one `ldseta`; without, `ldaxr`, `orr`, `stlxr` and a branch back.

Two things in the path selection (`src/engine/nnue/head_multi.zig`) are specific to a target and
easy to get wrong:

- **SVE.** `std.simd.suggestVectorLength` answers 256 bits for every AArch64 CPU with SVE
  (Neoverse V1, N2 and V2, every ARMv9 core). The head's AArch64 instructions are NEON, 128 bits,
  so the head caps the width there. Before that cap, such a build (`-Dcpu=neoverse_v1`, or a native
  build on one of those machines) compiled 256-bit vectors with the portable pairwise product and
  L1.
- **`prefer_256_bit`.** LLVM marks `x86_64_v4` and every Intel AVX-512 model, from Skylake-X to
  Diamond Rapids, as preferring 256-bit vectors (AMD's `znver4` and `znver5` are not marked), and
  `suggestVectorLength` follows it. The head then uses the 256-bit forms of its instructions.
  `-Dcpu=<model>-prefer_256_bit` gives 512 bits.

## Release matrix

`scripts/build_release.sh` builds one binary per row into `artifacts/bin`, named
`Avalanche-<version>-<binary>`, and the wasm module. Linux binaries are static (musl).

```sh
scripts/build_release.sh                  # every binary, the wasm module and artifacts/build.zip
scripts/build_release.sh x86_64-linux-v2  # only the binaries named, no wasm module and no packaging
```

| Variable | Effect |
|---|---|
| `VERSION=<x.y.z>` | The version the binaries report and carry in their names. Without it they are named `dev` and report their build time |
| `VERIFY_INSTRUCTIONS=0` | No disassembly, for a machine without `llvm-objdump` 15 or later |
| `REQUIRE_RUN=1` | A binary that this machine cannot execute is a failure |

A full run adds `README.md`, `LICENSE` and `LICENSE-pyrrhic` to `artifacts/bin` and zips the
directory. `LICENSE-pyrrhic` is `src/pyrrhic/LICENSE`: every native binary contains the Syzygy
probing code, whose licence asks for its text in every copy.

| Binary | `-Dcpu` | NNUE paths | For |
|---|---|---|---|
| `x86_64-{linux,windows}-v1` | `x86_64` | 128 bits, portable pairwise and L1, `pairs` L2 | any 64-bit x86 CPU |
| `x86_64-{linux,windows}-v2` | `x86_64_v2` | 128 bits, `mulhrs`, `maddubs`, `pairs` | SSSE3, SSE4.2, POPCNT: Nehalem to Ivy Bridge, Bulldozer to Excavator, Atom cores from Silvermont to Tremont |
| `x86_64-{linux,windows,macos}-v3` | `x86_64_v3` | 256 bits, `mulhrs`, `maddubs`, `pairs` | AVX2, BMI2: Haswell and later, Zen 1 to Zen 3, and AVX-512 CPUs before Ice Lake |
| `x86_64-{linux,windows}-avxvnni` | `x86_64_v3+avxvnni` | 256 bits, `mulhrs`, `dpbusd` (VEX), `pairs` | Alder Lake and later without AVX-512 |
| `x86_64-{linux,windows}-avx512` | `x86_64_v4+avx512vnni+avx512vbmi+avx512vbmi2+avx512bitalg+avx512vpopcntdq-prefer_256_bit` | 512 bits, `mulhrs`, `dpbusd`, `pairs`, `vpcompressb` search | Zen 4 and later, Ice Lake, Tiger Lake, Rocket Lake, Sapphire Rapids and later |
| `aarch64-{linux,windows}` | `generic` | 128 bits, `umull`, `extadd`, `wide` | every CPU without the dot product: Cortex-A53, A57, A72, A73 (Raspberry Pi 3 and 4), and the first ARMv8.2 cores, Cortex-A55 r0 and A75 (Snapdragon 845 and 850), Carmel (Jetson Xavier) |
| `aarch64-{linux,windows}-dotprod` | `generic+v8_2a+dotprod` | 128 bits, `umull`, `sdot`, `wide`; LSE | `asimddp` and `atomics` in `/proc/cpuinfo`: Cortex-A76 and later (Raspberry Pi 5), Neoverse N1 and later, Snapdragon 855 / 8cx and later, Apple Silicon under Linux |
| `aarch64-macos` | `apple_m1` | 128 bits, `umull`, `sdot`, `wide`; LSE | every Apple Silicon Mac |

Why these rows:

- **`v2` exists.** The earlier matrix went from `v1` to `v3` on the grounds that `v2` adds nothing
  the network uses. It does: SSSE3 is what the `mulhrs` pairwise product and the `maddubs` L1 need,
  and without POPCNT every population count in move generation and evaluation is a bit-twiddling
  sequence. `v2` covers the x86 CPUs of 2008 to 2013 and the Atom line up to Tremont, none of which
  have AVX2.
- **`avx512` replaces `v4`.** `x86_64_v4` has neither VNNI nor VBMI2 and prefers 256-bit vectors,
  so the `v4` binary was the `v3` paths in another encoding: `maddubs` L1 and the table search for
  non-zero blocks. The CPUs where AVX-512 pays have both extensions (Ice Lake and later, Zen 4 and
  later), so the row asks for that level, which gives `vpdpbusd` and the `vpcompressb` search.
  Skylake-X and Cascade Lake, which have AVX-512 without VBMI2 and lower their clock for 512-bit
  work, use `v3`.
- **512 bits in `avx512`.** With `prefer_256_bit` removed the head uses 512-bit vectors. On a Zen 5
  server CPU that is 5% faster in `bench` than the 256-bit form of the same instructions, and
  within 0.3% of a build for the exact CPU ("Measurements" below); on a Zen 4 server CPU the
  512-bit native build is 6.7% faster than the AVX2 build (docs/NNUE.md, "Performance"). On Intel
  nothing has been timed, and 512 bits is the opposite of what LLVM prefers for every Intel
  model: the README tells Intel users to compare the binary with `v3`. The width is one token of
  the `-Dcpu` string in `scripts/build_release.sh`.
- **`avxvnni`.** Intel's CPUs since Alder Lake have no AVX-512 but have the VEX-encoded
  `vpdpbusd`. No development machine has the instruction; the binary was first run on a Zen 5
  server CPU, which has it next to AVX-512, with the node count and checksum of every other
  path. There it is 0.8% faster than `v3`. On the Intel CPUs it is meant for it has not been
  timed.
- **Two AArch64 levels.** Zig's baseline for Linux and Windows is ARMv8.0, which a Raspberry Pi 4
  needs, and which has neither the dot product nor LSE. The dot product is optional in ARMv8.2
  and only mandatory from ARMv8.4: the first ARMv8.2 cores (Cortex-A55 r0, Cortex-A75, Nvidia
  Carmel) have LSE and no `sdot`, so the architecture version does not decide and the level is
  named for the feature, which a user can look up (`asimddp` in `/proc/cpuinfo`). The Cortex-A76
  and everything after it, every Neoverse core and every Apple M-series chip have it. Whoever is unsure
  takes the plain binary, which runs everywhere. macOS needs no second level: its baseline is
  the M1.
- **macOS on x86** has `v3` only. Zig 0.17 builds for macOS 15 and later, and no Mac without AVX2
  runs that.

The script fails when a binary is not what its row says. It checks three things, the first two
for every binary.

The description `nnue-speed` would print is the row's. It is a string in the binary, derived from
the same constants that select the code.

The instructions of the row are in the disassembly, and those of the next level are not:

| Level | Contains | Does not contain |
|---|---|---|
| `v1` | `pmaddwd` | `pmaddubsw`, `%ymm` registers |
| `v2` | `pmulhrsw`, `pmaddubsw`, `popcnt` | `%ymm` |
| `v3` | `vpmulhrsw`, `vpmaddubsw`, `%ymm` | `vpdpbusd`, `%zmm`, the mask registers `%k` |
| `avxvnni` | `vpmulhrsw`, `vpdpbusd`, `%ymm` | `%zmm`, `%k`: so its `vpdpbusd` is the VEX one |
| `avx512` | `vpmulhrsw`, `vpdpbusd`, `vpcompressb`, `%zmm` | |
| ARMv8.0 | `sqxtun`, `sadalp` | `sdot` |
| `dotprod`, macOS | `sqxtun`, `sdot`, `ldseta` | |

Each of these is emitted by the intended path alone: `sqxtun` is the narrowing of the `umull`
pairwise product (a build that fell back to the portable one has none), `sadalp` the `extadd` L1,
`ldseta` the transposition table's lock with LSE. Mnemonics that also have a scalar form
(`umull`, `smull`) or sit in every libc (`ldaxr`) would show nothing and are not used. The
disassembler is `llvm-objdump` 15 or later: older ones do not decode every AArch64 extension,
and an instruction that is not decoded cannot be found missing. The script takes the newest
`llvm-objdump*` command on `PATH`, since some distributions install only versioned names
(`llvm-objdump-19`), and failing that the one of Xcode.

A binary this machine can execute (same OS and architecture, and `/proc/cpuinfo` lists the row's
flags) goes through `scripts/verify_binary.sh`: `bench` must print the node count in
`bench.nodes` and `nnue-speed` the checksum in `nnue-speed.checksum`, so binaries verified on
different machines are held to one value. Both values change only with the network or the search;
a change that means to alter them runs `scripts/update_bench.sh`, which rebuilds and rewrites the
two files, and commits them. Built with a `VERSION`, the binary must also answer `uci` with
`id name Avalanche <version>`. For every other binary the script prints why it did not run
(`not run: host CPU lacks avx_vnni`), and it ends with the list of what ran and what was only
inspected. `REQUIRE_RUN=1` makes a binary that could not run a failure.

## CI

The job `build` puts its native binary through `scripts/verify_binary.sh` on Linux, macOS and
Windows. On Linux it also compiles the engine in Debug mode: the unit tests do not include the UCI
frontend, so no other step would compile that without optimisation.

The same job runs the unit tests in Debug and with `-Doptimize=fast` on every runner, and with
`-Doptimize=safe` on Linux and macOS. The safe run is the one that executes the intrinsic SIMD
paths with bounds and overflow checks: Debug does not compile them and a fast build has no such
checks (docs/NNUE.md, "What has been executed"). Linux executes the x86 paths of its runner and
macOS the NEON ones; Windows would be x86 a second time. On Linux the job also checks the
formatting, `zig fmt --check src build.zig build.zig.zon`, and runs the tests once more with
`-Dnet=nets/nezha.nnue`, a single-layer network: the tests that evaluate positions reach only the
head of the embedded network, which by default is the multi-layer one (docs/NNUE.md, "Tests").

The job `tiers` runs the release script on every pull request, with `VERSION=ci`: a fixed version
lets unchanged sources be cache hits, and the binaries a runner executes must report it.

| Runner | Built per pull request | Run there |
|---|---|---|
| x86-64 | `x86_64-linux-v2` | always (`REQUIRE_RUN=1`): the 128-bit SSSE3 paths, which no runner compiles natively |
| | `x86_64-linux-avx512` | when the runner has AVX-512 with VNNI and VBMI2; otherwise compiled and inspected |
| AArch64 | `aarch64-linux`, `aarch64-linux-dotprod` | always (`REQUIRE_RUN=1`) |
| | a native build | when the runner has SVE: the only execution of an SVE-enabled build, since no development machine has SVE; the job says so when the runner has none |

`v1`, `v3`, `avxvnni` and the Windows and macOS binaries are built by the `artifacts` job only,
for version tags and manual runs, which builds the whole matrix. A path that stops compiling or
stops being selected therefore fails in a pull request when it is one of the four above, and at
the next tag otherwise. `artifacts` runs for nothing else because it is the slowest job and because
a pull request from a fork must not be able to start a build of downloadable binaries. The
binaries take their version from the tag alone, so for a tag the job first requires the tag,
`version` in `build.zig.zon` and `version` in `web/package.json` to be one version. It uploads
`artifacts/bin` without the `.pdb` files of the Windows builds as a workflow artifact, kept for
30 days; it creates no GitHub release.

The job `wasm` runs the checks of the `web/` package (type check, lint and tests) and then
`scripts/uci_protocol_test.py` on the wasm module. `web/package.json` requires Node 26 or later,
the version its type definitions describe.

The job `scripts` runs shellcheck over every tracked shell script, then `ruff check`,
`ruff format --check` and the unit tests of `scripts/`. ruff is installed at the version
`RUFF_VERSION` names: `ruff.toml` selects every rule, so a newer ruff can report rules the scripts
were never checked against. `artifacts` waits for this job as well, because two of the scripts it
lints, `build_release.sh` and `verify_binary.sh`, are the ones that build and check the release
binaries.

The jobs `datatool` and `trainer` format, lint and test the two Rust crates with their committed
lock files. `trainer` does so without the `cuda` feature, which needs no GPU toolkit (docs/NNUE.md,
"Training"), and also lints the default configuration, the one with CUDA: bullet's build script
asks only that the directory `CUDA_PATH` names exists, and clippy does not link, so the runner's
temporary directory is enough.

The actions that are not GitHub's own, `mlugg/setup-zig` (it installs the compiler that builds the
release binaries) and `dtolnay/rust-toolchain`, are referenced by commit, with the tag the commit
was taken from in a trailing comment: a tag can be moved to other code, a commit cannot.

## Naming

`zig fmt` settles the layout of the source and nothing checks its names, so the convention is
stated here. Functions, parameters, fields, local values, namespaces and the settings that change
at run time are snake_case (`set_fen`, `search.contempt`). Types, and functions that return a
type, are PascalCase. A constant of a file or of a type is SCREAMING_CASE (`MAX_PLY`), except two
kinds that are lower case because of how they read: a flag that selects code at compile time
(`platform.is_wasm`, `arch.intrinsics`), and a value a type declares of itself, which is written
like an enum tag wherever the type is known (`.stale` for `FrameState.stale`).

Two groups are named by something outside the engine. The search parameters of
`src/engine/parameters.zig` are spelled as their UCI options (`LMRWeight`), because
`parameters.set` finds an option's variable by the option's name, and the callbacks of
`src/engine/syzygy.zig` have the names Pyrrhic calls them by (`pawnAttacks`). Any other name that
differs, such as the PascalCase lookup tables of `src/chess/tables.zig`, is not a second
convention, and new code does not follow it.

## Measurements

Both tables were measured while Dianguang-3 was the default network. Every build in them printed
the same `bench` node count and `nnue-speed` checksum, those of that tree and not the ones
`bench.nodes` and `nnue-speed.checksum` hold now.

**ARM levels on one core.** Apple M4, native macOS builds that differ only in `-Dcpu`, so the
core is the same and the instructions it may use are not. `bench` instructions are the median of
two runs, the `nnue-speed` figures the median of three (whole program: two million evaluations
and the stage loops). The builds are commit 870eeab with only the build changes this document
describes: the absolute counts are not those of a build that also has the later changes.

| `-Dcpu` | L1 | Atomics | `bench` instructions | `nnue-speed` cycles | `nnue-speed` user time |
|---|---|---|---|---|---|
| `apple_m4` (native) | `sdot` | LSE | 113.2 G | 3.50 G | 1.77 s |
| `apple_m1` (`aarch64-macos`) | `sdot` | LSE | 113.5 G | 3.50 G | 1.78 s |
| `generic+v8_2a+dotprod` (`dotprod`) | `sdot` | LSE | 114.5 G (+1.2%) | 3.72 G (+6%) | 1.85 s |
| `generic` (ARMv8.0), `extadd` L1 | `extadd` | `ldaxr` loop | 128.7 G (+13.7%) | 4.69 G (+34%) | 2.32 s |
| `generic` with the portable L1 it compiled before | portable | `ldaxr` loop | 158.8 G (+40.3%) | 8.48 G (+142%) | 4.17 s |

So the binary that `aarch64-linux` and `aarch64-windows` users were given cost every one of them
the last row, on CPUs that have `sdot`. The `dotprod` level runs 1.2% more instructions than a
build for the exact CPU and its cycles are within the noise of it; what is left of the ARMv8.0
penalty is the price of having no `sdot`. The Linux builds of these levels in a virtual machine
on that M4 (wall time, noisy, two runs): `nnue-speed` 1428 and 1125 ns per evaluation with the
portable L1, 729 and 664 with `extadd`, 531 and 643 for `dotprod`, 528 and 693 for `apple_m4`.

The load-exclusive loop was not timed apart from the L1: it is three more instructions on a
transposition table store, at most 0.05% of the instructions of `bench`.

**x86 levels on one core.** A Zen 5 server CPU, idle, one thread, builds that differ only in
`-Dcpu`. Speed relative to the build for the exact CPU, in `bench` (five alternating rounds) and
in searches of three seconds.

| Build | NNUE paths | `bench` | 3 s searches | `nnue-speed` |
|---|---|---|---|---|
| native (`znver5`) | 512 bits, `mulhrs`, `dpbusd`, `pairs` | 1.000 | 1.000 | |
| `avx512` | 512 bits, `mulhrs`, `dpbusd`, `pairs` | 0.998 | 1.003 | 72.0 ns |
| the features of `avx512` with `prefer_256_bit` left in | 256 bits, `mulhrs`, `dpbusd`, `pairs` | 0.951 | 0.958 | 84.0 ns |
| `x86_64_v4`, the `v4` binary of earlier releases | 256 bits, `mulhrs`, `maddubs`, `pairs` | 0.923 | 0.930 | 97.2 ns |
| `avxvnni` | 256 bits, `mulhrs`, `dpbusd` (VEX), `pairs` | 0.892 | 0.903 | 94.4 ns |
| `v3` | 256 bits, `mulhrs`, `maddubs`, `pairs` | 0.885 | 0.895 | |
| `v2` | 128 bits, `mulhrs`, `maddubs`, `pairs` | 0.713 | 0.724 | 326.5 ns |
| `v1` | 128 bits, portable pairwise and L1, `pairs` | 0.254 | 0.275 | 1406.5 ns |

On this CPU the `avx512` binary is as fast as a native build, 8% faster than the `v4` binary it
replaces and 13% faster than `v3`; 512-bit vectors are worth 5% over 256-bit ones with the same
instructions; `avxvnni` gains 0.8% on `v3`; `v2` is 2.8 times as fast as `v1`. No Intel CPU was
measured: `avxvnni` and the 512-bit width of `avx512` compute the right result, and how fast
they are on Intel is unknown.

## WebAssembly features

`zig build wasm` targets the `generic` wasm CPU plus `simd128`: bulk memory, sign extension,
non-trapping float-to-int conversion, multi-value, mutable globals and reference types are on.
Every one of them is supported by every browser that supports `simd128` at all, so nothing
universally available is missing. What is left out needs a decision at run time:

- **Relaxed SIMD.** `i32x4.relaxed_dot_i8x16_i7x16_add_s` is `vpdpbusd` and `sdot` for inputs of at
  most 127, which the L1 activations are, so it would replace the multiply and widening addition
  of the `extadd` L1 (four instructions per 16 products) by one. Not every browser has it, so it
  needs a second module and feature detection in the web client.
- **Threads** (`atomics`, shared memory): see "Not supported on wasm" in docs/WASM.md.

## OpenBench

OpenBench builds with `make EXE=<path> [EVALFILE=<net>] [CC=<compiler>]` in the repository root and
runs `<path> bench`. The `Makefile` is that contract and nothing else: a native `--release=fast`
build with the network embedded, installed under the requested name, whatever the name (without
`EXE` the binary stays where the build installs it, `bin/Avalanche`). `CC` is ignored, Zig brings
its compiler. `scripts/openbench_build_check.sh` holds the `Makefile` to this; CI runs it on
Linux. With a stand-in for the compiler it checks that the binary ends up at `EXE` for
`Avalanche` and `bin/Avalanche`, the name and the path of the file the build installs, and for a
name of the form OpenBench passes, and that an `EVALFILE` path with a space in it reaches the
build whole. Then it builds for real into a temporary directory with a copy of the default
network as `EVALFILE`, checks that the copy is the network embedded, and parses the `bench`
output with OpenBench's regular expressions: the count must be the one in `bench.nodes`.

A worker therefore runs the paths of its own CPU. The build must not depend on anything a worker
lacks: no option of `build.zig` is required, and nothing is downloaded, since the `translate_c`
package and its dependency `aro` are vendored.

## Tried and left out

- **One binary that selects its paths when it starts.** The vector width is a compile-time
  constant that the types of the head depend on, so every level would need its own instantiation
  of the head and of the accumulator updates, chosen through function pointers on the hottest
  calls of the engine. A file per CPU level is what users of chess engines expect, and each one
  is checked.
- **A `v4` row at 256 bits.** It would differ from `v3` only in encoding (see above).
- **SVE paths.** The head has none. An SVE CPU runs the NEON paths, which is what its 128-bit SVE
  would do as well; the 256-bit SVE of Neoverse V1 is the only wider one in a chess-capable CPU.
- **Building the release binaries with a CPU model's tuning** (`znver4`, `cortex_a76`) instead of
  a feature level. A model brings features its siblings lack and tuning only its own
  microarchitecture wants; the rows above name features and keep LLVM's generic tuning.

## Timer

`src/chess/types.zig` keeps its own monotonic timer: the standard library has had none since Zig 0.16.
