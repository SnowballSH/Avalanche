# Avalanche

<br/>

<p align="center">
<img width="800" height="400" alt="Avalanche_3_0_0_1200x600" src="https://github.com/user-attachments/assets/9f698fd4-c191-4884-96e4-7f1aab867f16" />
</p>

<br/>

Avalanche is a strong UCI chess engine written in [Zig](https://ziglang.org/).

October 2026 update: **Avalanche now builds with Zig 0.17.0.**

## Strength

**Official [40/15 CCRL ELO (v4.0.0)](https://computerchess.org.uk/4040/cgi/engine_details.cgi?match_length=30&each_game=0&print=Details&each_game=0&eng=Avalanche%204.0.0%2064-bit#Avalanche_4_0_0_64-bit): 3492**

**Official [Blitz CCRL ELO (v4.0.0)](https://computerchess.org.uk/404/cgi/engine_details.cgi?print=Details&each_game=1&eng=Avalanche%204.0.0%2064-bit#Avalanche_4_0_0_64-bit): 3597**

Version 4.0.0 placed 6/11 in the TCEC Season 30 Category 2 Playoff.

Version 2.1.0 participated in TCEC Swiss 6.

## About

Avalanche is the **first chess engine** written in the [Zig programming language](https://ziglang.org/), proving Zig's ability to succeed in real-world, competitive applications.

Avalanche was one of the earliest adopters of the **NNUE** (Efficiently Updatable Neural Network) technology for its evaluation.

This project isn't possible without the help of the Zig community, since this is the first Zig code I've ever written. Thank you!

## License

GPL-3.0. See [`LICENSE`](LICENSE).

## Compile

`zig build --release=fast`

Avalanche builds with **Zig 0.17.0** and nothing else: the official
[translate-c](https://codeberg.org/ziglang/translate-c) package, which generates the bindings for the Syzygy probing
code, is vendored under `deps/`, so a build never downloads anything.

```sh
zig build --release=fast      # optimized build -> zig-out/bin/Avalanche
zig build                     # debug build
zig build test                # unit tests
python3 scripts/uci_protocol_test.py  # end-to-end UCI checks (needs the release build)
python3 scripts/uci_protocol_test.py node web/src/node/cli.ts zig-out/web/avalanche.wasm  # same checks on wasm
./zig-out/bin/Avalanche bench # fixed-position benchmark
zig build wasm --release=fast # WebAssembly build -> zig-out/web/avalanche.wasm (see docs/WASM.md)
```

A build targets the CPU it is compiled on. For another machine, pass its CPU: `-Dcpu=x86_64_v3`, or with a target,
`-Dtarget=aarch64-linux-musl -Dcpu=generic+v8_2a+dotprod`. `./zig-out/bin/Avalanche nnue-speed` prints the SIMD paths
a binary was compiled with. [docs/BUILD.md](docs/BUILD.md) has the build options, what a release build is compiled
with, and the measurements behind both.

Development builds report their build time as the version (`Avalanche Compiled at ...`). Release binaries are built
with `VERSION=4.1.0 bash build_all_v3.sh` (one binary per supported CPU level plus the wasm module, in `artifacts/`),
which passes `-Dversion`; CI does the same for pushed `v*` tags.

Pick the last binary in this list whose CPU features your CPU has. A binary for features the CPU lacks stops with an
illegal instruction. On Linux, `/proc/cpuinfo` lists them under `flags` (x86) or `Features` (ARM), with the names
given here.

| Binary | Needs | Typical CPUs |
|---|---|---|
| `x86_64-*-v1` | nothing | any 64-bit x86 CPU |
| `x86_64-*-v2` | `ssse3`, `sse4_2`, `popcnt` | Intel Nehalem (2008) and later, AMD Bulldozer and later, Atom-class CPUs since Silvermont |
| `x86_64-*-v3` | `avx2`, `bmi2`, `fma` | Intel Core since Haswell (2013; Pentium and Celeron models only much later), AMD Zen 1 to Zen 3 |
| `x86_64-*-avxvnni` | those of `v3` and `avx_vnni` | Intel Alder Lake (12th generation) and later without AVX-512 |
| `x86_64-*-avx512` | `avx512_vnni`, `avx512_vbmi2` and the rest of the Ice Lake set (`avx512bw`, `avx512vl`, `avx512vbmi`, `avx512_bitalg`, `avx512_vpopcntdq`) | AMD Zen 4 and later; Intel Ice Lake, Tiger Lake, Rocket Lake, Sapphire Rapids and later. It uses 512-bit vectors, which has been timed on AMD only: on an Intel CPU compare its `bench` speed with `v3` |
| `aarch64-linux`, `aarch64-windows` | nothing | any 64-bit ARM CPU: Raspberry Pi 3 and 4, Snapdragon 845 and 850, Jetson Xavier |
| `aarch64-*-dotprod` | `asimddp`, `atomics` | Cortex-A76 and later (Raspberry Pi 5), Neoverse N1 and later, Snapdragon 855 / 8cx and later, Apple Silicon under Linux |
| `aarch64-macos` | nothing | every Apple Silicon Mac |

Older Zig 0.10.x is no longer required.

Avalanche also has a lichess account (though not often played): https://lichess.org/@/IceBurnEngine

## Usage

Avalanche follows the UCI protocol and is not a full chess application. You should use Avalanche with a UCI-compatible GUI interface. If you need to use the CLI, make sure to send \n at the end of your input (^\n on windows command prompt).

Supported features include Chess960 and Double Fischer Random Chess, pondering, MultiPV, `searchmoves`, `go mate`, Syzygy tablebases, `EvalFile`, a persistent NUMA-aware thread pool, live `currmove`/bound reporting, and strength limiting via `Skill Level` or `UCI_LimitStrength`/`UCI_Elo`. See [docs/UCI.md](docs/UCI.md), [docs/CHESS960.md](docs/CHESS960.md), [docs/THREADS.md](docs/THREADS.md) and [docs/STRENGTH.md](docs/STRENGTH.md). Training-data generation is described in [docs/DATAGEN.md](docs/DATAGEN.md), the network architectures and file formats in [docs/NNUE.md](docs/NNUE.md), the board code in [docs/BOARD.md](docs/BOARD.md), the search in [docs/SEARCH.md](docs/SEARCH.md), and where the engine's large data lives in [docs/MEMORY.md](docs/MEMORY.md).

## Past Versions

<img src="https://docs.google.com/spreadsheets/d/e/2PACX-1vSeuY7fgGH72R5n7v8dtT5XoKxMMgnLkT3ew9pk8Mn8BYKp8A9wPpZ4f9EPmmVs-x0_uFiZn0_nmcm6/pubchart?oid=1884376007&format=image" width=719/>

## Credits

- [Dan Ellis Echavarria](https://github.com/Deecellar) for writing the github action CI and helping me with Zig questions
- [Ciekce](https://github.com/Ciekce) for guiding me with migrating to the new Marlinflow and answering my stupid questions related to NNUE
- Many other developers in the computer chess community for guiding me through new things like SPRT testing.

- https://www.chessprogramming.org/ for explanation on everything I need, including search, tt, pruning, reductions... everything.
- https://github.com/nkarve/surge for movegen inspiration.
- Maksim Korzh, https://www.youtube.com/channel/UCB9-prLkPwgvlKKqDgXhsMQ for getting me started on chess programming.
- https://github.com/dsekercioglu/blackmarlin for NNUE structure and trainer skeleton (1.5.0 and older)
- https://github.com/Disservin/Smallbrain and https://github.com/cosmobobak/viridithas for search ideas
- https://openai.com/dall-e-2/ for generating the beautiful logo image

## Originality Status

- General
  - This is the first released chess engine written in the **Zig Programming Language**. Although there are Zig libraries for chess, Avalanche is completely stand-alone and does not use any external libraries.
- Move Generator
  - Algorithm is inspired by Surge, but code is 100% hand-written in Zig.
- Search
  - Avalanche has a simple Search written 100% by myself, but is probably a subset of many other engines. Some ideas are borrowed from other chess engines as in comments. However many ideas and parameters are tuned manually and automatically using my own scripts.
- Evaluation
  - The Hand-Crafted Evaluation is based on https://www.chessprogramming.org/PeSTO%27s_Evaluation_Function with adaptation to endgames. The HCE is only activated at late endgames when finding checkmate against a lone king is needed.
  - NNUE since 2.0.0 is trained with https://github.com/jw1912/bullet
  - The NNUE data since 2.0.0 is purely generated from self-play games.
- UCI Interface/Communication code
  - 100% original

## Neural Networks

All Neural Networks used by Avalanche are trained through self-play. There have been several generations of reinforcement learning, listed below by codenames:

- Dianguang-4 电光
  - `768x16 -> 1024 -> pairwise -> 16x2 -> 32 -> 1x8`
  - Dianguang-3's recipe on 4 billion new positions labelled by Dianguang-3 at 8,000 nodes
- Dianguang-3 电光
  - `768x16 -> 1024 -> pairwise -> 16x2 -> 32 -> 1x8`
  - Same data and recipe as Dianguang-2, trained twice as long
- Dianguang-2 电光
  - `768x16 -> 1024 -> pairwise -> 16x2 -> 32 -> 1x8`
  - First net with a multi-layer head
  - Trained from scratch on the same 4 billion self-play positions generated by Nezha as Dianguang-1
- Dianguang-1 电光
  - `768x16 -> 1024 -> 8`
  - Trained from scratch on 4 billion self-play positions generated by Nezha
- Nezha 哪吒
  - `768x16 -> 1024 -> 8`
  - Fine-tuned Zidingxiang v2 on 1.6 billion filtered self-play positions
- Zidingxiang 紫丁香
  - `768x16 -> 1024 -> 8`
  - Fine-tuned Huangpujiang on self-play positions
  - Refined through a second continuation wave
- Huangpujiang 黄浦江
  - `768x16 -> 1024 -> 8`
  - Dual-perspective, mirrored input buckets basedon king position
  - First net with input buckets
  - Trained from scratch on the same 2 billion positions from Qinyuanchun
- Molihua 茉莉花
  - `768 -> 1024x2 -> 8`
  - Final iteration of "flat" net
  - Fine-tuned Qinyuanchun on 2 billion positions from Qinyuanchun
- Qinyuanchun 沁园春
  - `768 -> 1024x2 -> 8`
  - Trained from scratch on 2 billion positions from Shuang
- Shuang 霜
  - `768 -> 768x2 -> 8`
  - Trained from scratch on 1.3 billion positions from Jihan
- Jihan 极寒
  - `768 -> 512x2 -> 8`
  - Trained from scratch on 1 billion positions from Bingshan
- Bingshan 冰山
  - `768 -> 512x2 -> 8`
  - First net with output buckets
  - Trained from scratch on Xuebeng data
- Xuebeng 雪崩
  - `768 -> 512x2 -> 1`
  - Trained on 512 million positions from earlier nets
- net008b, net007b
  - Basic attempts of RL on base net
- base
  - `768 -> 128x2 -> 1`
  - Trained on HCE labeling of a few thousands of TCEC games

## Alternative Square Logos

<img src="https://github.com/SnowballSH/Avalanche/assets/66022611/cf099f87-91ad-4fd9-a2c3-177b790cd59e" alt="Logo 2" width=400 height=400/>
<img src="https://github.com/SnowballSH/Avalanche/assets/66022611/6ece76d4-ce7c-43e7-8321-27e368b12760" alt="Logo 3" width=400 height=400/>
<img src="https://github.com/SnowballSH/Avalanche/assets/66022611/ef77edf1-9f8d-45dc-867f-533a4c84d22f" alt="Logo 4" width=400 height=400/>
