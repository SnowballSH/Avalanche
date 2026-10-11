# v5.0.0

- Match Results

STC vs Avalanche 4.0.0:
```
Elo   | 100.18 +- 3.87 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 10000 W: 4048 L: 1242 D: 4710
Penta | [13, 355, 1794, 2489, 349]
```

LTC vs Avalanche 4.0.0:
```
Elo   | 102.22 +- 8.18 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 2000 W: 789 L: 217 D: 994
Penta | [2, 65, 338, 549, 46]
```

VLTC vs Avalanche 4.0.0:
```
Elo   | 92.46 +- 31.19 (95%)
Conf  | 120.0+1.00s Threads=1 Hash=64MB
Games | N: 100 W: 36 L: 10 D: 54
Penta | [0, 2, 20, 28, 0]
```

SMP vs Avalanche 4.0.0 (4 Threads):
```
Elo   | 111.37 +- 14.47 (95%)
Conf  | 40.0+0.40s Threads=4 Hash=64MB
Games | N: 500 W: 193 L: 38 D: 269
Penta | [0, 8, 86, 149, 7]
```

STC Double Fischer Random vs the first build with `UCI_Chess960` (b6ac754):
```
Elo   | 257.94 +- 14.20 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 2006 W: 1346 L: 81 D: 579
Penta | [2, 17, 141, 400, 443]
```

LTC vs Stockfish 13:
```
Elo   | -38.02 +- 11.60 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 204 L: 313 D: 483
Penta | [12, 170, 234, 83, 1]
```

LTC vs Stockfish 12:
```
Elo   | 15.99 +- 11.35 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 258 L: 212 D: 530
Penta | [6, 98, 241, 154, 1]
```

LTC vs Igel 3.7.0:
```
Elo   | -76.61 +- 11.26 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 147 L: 364 D: 489
Penta | [14, 236, 203, 47, 0]
```

LTC vs RubiChess 20240817:
```
Elo   | -71.52 +- 11.37 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 154 L: 357 D: 489
Penta | [7, 246, 192, 53, 2]
```

LTC vs Seer 2.8.0:
```
Elo   | 11.12 +- 11.54 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 256 L: 224 D: 520
Penta | [7, 102, 248, 138, 5]
```

LTC vs Arasan 26.0:
```
Elo   | 48.61 +- 10.95 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 327 L: 188 D: 485
Penta | [1, 67, 227, 202, 3]
```

LTC vs Koivisto 9.0:
```
Elo   | 46.84 +- 11.32 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 300 L: 166 D: 534
Penta | [4, 69, 218, 207, 2]
```

LTC Chess960 vs Igel 3.7.0:
```
Elo   | -28.55 +- 10.30 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 78 L: 160 D: 762
Penta | [16, 111, 313, 59, 1]
```

LTC Chess960 vs Halogen 16:
```
Elo   | -19.13 +- 13.71 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 157 L: 212 D: 631
Penta | [24, 136, 234, 83, 23]
```

LTC Chess960 vs Stockfish 13:
```
Elo   | 46.13 +- 13.86 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 1000 W: 255 L: 123 D: 622
Penta | [7, 86, 217, 148, 42]
```

The matches against other engines are between AVX2 builds: each opponent from its release source, Avalanche from the release candidate, which has the search of this release. The clock is scaled to the machine and a game is resigned only when both engines agree.

- Pre-release review: fixes and cleanup that leave the search unchanged

STC (8+0.08):
```
Elo   | 0.35 +- 5.56 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 4010 W: 936 L: 932 D: 2142
Penta | [13, 477, 1026, 471, 18]
```

STC SMP (8+0.08, 8 Threads):
```
Elo   | 4.52 +- 10.64 (95%)
Conf  | 8.0+0.08s Threads=8 Hash=64MB
Games | N: 1000 W: 215 L: 202 D: 583
Penta | [1, 112, 260, 127, 0]
```

- LTC SPSA tune of the 29 search parameters that depend on the evaluation

LTC (40+0.40):
```
Elo   | 4.19 +- 2.58 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 17070 W: 3808 L: 3602 D: 9660
Penta | [13, 1934, 4442, 2126, 20]
```

- New net: Dianguang-5

STC (8+0.08) vs Dianguang-4:
```
Elo   | 3.28 +- 2.26 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 25082 W: 5892 L: 5655 D: 13535
Penta | [113, 2892, 6308, 3101, 127]
```

LTC (40+0.40) vs Dianguang-4:
```
Elo   | 2.53 +- 1.86 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [0.00, 3.00]
Games | N: 32978 W: 7235 L: 6995 D: 18748
Penta | [36, 3761, 8673, 3965, 54]
```

- New net: Dianguang-4

STC (8+0.08) vs Dianguang-3:
```
Elo   | 8.79 +- 4.13 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.98 (-2.94, 2.94) [0.00, 3.00]
Games | N: 8422 W: 2168 L: 1955 D: 4299
Penta | [70, 920, 2016, 1137, 68]
```

LTC (40+0.40) vs Dianguang-3:
```
Elo   | 17.28 +- 5.70 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 3702 W: 949 L: 765 D: 1988
Penta | [9, 356, 938, 538, 10]
```

- Speed: an evaluation cache, accumulators computed only when a position needs them, a move picker that evaluates exchanges on demand, king attackers and occupancy kept up to date, huge pages for the continuation history and the evaluator storage, per-searcher node counts

STC (8+0.08):
```
Elo   | 25.17 +- 6.99 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.98 (-2.94, 2.94) [0.00, 3.00]
Games | N: 2558 W: 682 L: 497 D: 1379
Penta | [1, 241, 625, 396, 16]
```

LTC (40+0.40):
```
Elo   | 17.56 +- 5.66 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 3506 W: 848 L: 671 D: 1987
Penta | [4, 324, 921, 499, 5]
```

- Zig 0.17.0

STC (8+0.08), the same search built with Zig 0.16.0:
```
Elo   | 3.73 +- 5.44 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 4008 W: 912 L: 869 D: 2227
Penta | [11, 443, 1057, 478, 15]
```

STC SMP (8+0.08, 8 Threads):
```
Elo   | 6.25 +- 10.79 (95%)
Conf  | 8.0+0.08s Threads=8 Hash=64MB
Games | N: 1000 W: 220 L: 202 D: 578
Penta | [2, 107, 265, 123, 3]
```

- New net: Dianguang-3

STC (8+0.08) vs Dianguang-2:
```
Elo   | 4.65 +- 3.69 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 10006 W: 2467 L: 2333 D: 5206
Penta | [67, 1133, 2473, 1259, 71]
```

LTC (40+0.40) vs Dianguang-2:
```
Elo   | 9.86 +- 4.26 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [0.00, 3.00]
Games | N: 6730 W: 1605 L: 1414 D: 3711
Penta | [12, 733, 1698, 896, 26]
```

- LMR-reduced depth in the quiet futility and SEE pruning margins

STC (8+0.08):
```
Elo   | 2.73 +- 2.00 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.97 (-2.94, 2.94) [0.00, 3.00]
Games | N: 32712 W: 7568 L: 7311 D: 17833
Penta | [147, 3848, 8146, 4031, 184]
```

LTC (40+0.40), stopped undecided:
```
Elo   | 0.83 +- 2.54 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 0.08 (-2.94, 2.94) [0.00, 3.00]
Games | N: 17502 W: 3768 L: 3726 D: 10008
Penta | [29, 1998, 4650, 2050, 24]
```

- New net: Dianguang-2 (multi-layer head)

STC (8+0.08) vs Dianguang-1:
```
Elo   | 10.14 +- 3.85 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 10006 W: 2572 L: 2280 D: 5154
Penta | [85, 1115, 2314, 1401, 88]
```

LTC (40+0.40) vs Dianguang-1:
```
Elo   | 16.11 +- 5.49 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.97 (-2.94, 2.94) [0.00, 3.00]
Games | N: 4014 W: 1027 L: 841 D: 2146
Penta | [11, 389, 1023, 571, 13]
```

- New net: Dianguang-1

STC (8+0.08) vs Nezha:
```
Elo   | 16.02 +- 3.81 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 10006 W: 2687 L: 2226 D: 5093
Penta | [54, 1073, 2351, 1408, 117]
```

LTC (40+0.40) vs Nezha:
```
Elo   | 16.33 +- 4.91 (95%)
Conf  | 40.0+0.40s Threads=1 Hash=64MB
Games | N: 5002 W: 1264 L: 1029 D: 2709
Penta | [9, 483, 1302, 678, 29]
```

STC Double Fischer Random vs Nezha:
```
Elo   | 162.65 +- 11.67 (95%)
Conf  | 8.0+0.08s Threads=1 Hash=16MB
Games | N: 2006 W: 1044 L: 168 D: 794
Penta | [7, 50, 254, 444, 248]
```

- Capture history for capture ordering

STC (8+0.08):
```
Elo   | 2.81 +- 2.03 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.97 (-2.94, 2.94) [0.00, 3.00]
Games | N: 31324 W: 7163 L: 6910 D: 17251
Penta | [132, 3668, 7863, 3813, 186]
```

LTC (40+0.40), stopped undecided:
```
Elo   | 2.62 +- 4.00 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 0.68 (-2.94, 2.94) [0.00, 3.00]
Games | N: 7282 W: 1590 L: 1535 D: 4157
Penta | [15, 829, 1895, 890, 12]
```

- Transposition table score as the pruning evaluation when its bound allows

STC (8+0.08):
```
Elo   | 2.87 +- 2.06 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 3.01 (-2.94, 2.94) [0.00, 3.00]
Games | N: 30946 W: 7131 L: 6875 D: 16940
Penta | [152, 3604, 7735, 3800, 182]
```

LTC (40+0.40), stopped undecided:
```
Elo   | 0.33 +- 3.90 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | -0.15 (-2.94, 2.94) [0.00, 3.00]
Games | N: 7290 W: 1578 L: 1571 D: 4141
Penta | [8, 837, 1948, 844, 8]
```

- Continuation history in the late-move reduction adjustment

STC (8+0.08):
```
Elo   | 2.11 +- 1.65 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 48228 W: 11083 L: 10790 D: 26355
Penta | [261, 5651, 11987, 5964, 251]
```

LTC (40+0.40):
```
Elo   | 10.53 +- 4.36 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 6038 W: 1365 L: 1182 D: 3491
Penta | [3, 636, 1569, 797, 14]
```

- Non-pawn correction history

STC (8+0.08):
```
Elo   | 12.85 +- 5.00 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 5220 W: 1274 L: 1081 D: 2865
Penta | [17, 550, 1308, 693, 42]
```

LTC (40+0.40):
```
Elo   | 23.91 +- 6.66 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 2576 W: 642 L: 465 D: 1469
Penta | [1, 228, 658, 395, 6]
```

- Pawn correction history

STC (8+0.08):
```
Elo   | 15.37 +- 5.45 (95%)
SPRT  | 8.0+0.08s Threads=1 Hash=16MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 4252 W: 1027 L: 839 D: 2386
Penta | [12, 425, 1080, 581, 28]
```

LTC (40+0.40):
```
Elo   | 23.43 +- 6.57 (95%)
SPRT  | 40.0+0.40s Threads=1 Hash=64MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 2614 W: 657 L: 481 D: 1476
Penta | [1, 230, 673, 398, 5]
```

- Chess960 and Double Fischer Random Chess: `UCI_Chess960`, X-FEN and Shredder-FEN, king-takes-rook notation
- MultiPV, pondering, `searchmoves` and `go mate`; `currmove` and bound lines while searching
- Strength limiting with `Skill Level` or `UCI_LimitStrength` and `UCI_Elo`
- Persistent thread pool; helpers take over the root once per search
- `NumaPolicy`: on a multi-node Linux machine search threads are bound to NUMA nodes once there are too many of them for one node, and spread over the nodes in proportion to their CPU counts
- `score cp` is normalized so that 100 is a 50% win chance at move 32, with the win-rate model fitted on the engine's own games at 40+0.4
- Tablebase scores are reported in a fixed band below the mate scores
- `EvalFile` loads a network at run time, `EvalScale` rescales its output, `Clear Hash` empties the hash table; `MoveOverhead` is now `Move Overhead` and the old name is still accepted
- Command-line arguments are run as UCI commands before standard input is read
- `eval` prints the static evaluation of the current position, and every `go` names the network in an `info string`
- Multi-layer network head (`768x16 -> 1024 -> pairwise -> 16x2 -> 32 -> 1x8`), network file format v2, and faster inference of it on AVX-512, AVX2, NEON and wasm
- WebAssembly build and a TypeScript package around it
- Builds with Zig 0.17.0 and downloads nothing: the `translate-c` and `aro` packages are vendored
- A release binary per CPU level, each checked for the instruction set of its level and, where the build machine can run it, against the bench node count and the NNUE checksum. The files are named `v1`, `v2`, `v3`, `avxvnni` and `avx512` on x86-64 (`v3` only on macOS) and plain or `dotprod` on AArch64; the `v4`, `general`, per-chip macOS and x86-64 macOS `v1` and `v2` files of 4.0.0 are gone (README, "Compile")
- Datagen: batch mode, strict opening book validation, `raweval`, the `datatool` validator and a tablebase filter for viriformat data
- Trainer: dataset directories, resumable runs, held-out validation, learning rate warmup and a selectable multi-layer head
- A fixed TCEC update script that follows `master` (docs/TCEC.md)
- Relicensed from MIT to GPL-3.0-only
- Fixes an issue where some GUIs did not record the PV: the `info` fields are in Stockfish's order and output lines end with CRLF on Windows
- Fixes an issue where `go` without a preceding `position` searched with an empty repetition history
- Fixes an issue where an en passant square was accepted from a FEN without a pawn that could be captured
- Fixes an issue where a FEN's fullmove number could overflow the ply counter
- Fixes an issue where datagen ran forever on a book with no usable opening, or recorded a mate score when its node budget could not finish depth 1

# v4.0.0

- Match Results

STC vs Avalanche 3.0.0:
```
Elo   | 249.83 +- 10.16 (95%)
Conf  | 10.0+0.10s Threads=1 Hash=8MB
Games | N: 3000 W: 1985 L: 136 D: 879
Penta | [2, 14, 183, 735, 566]
```

LTC vs Avalanche 3.0.0:
```
Elo   | 239.09 +- 9.26 (95%)
Conf  | 60.0+0.60s Threads=1 Hash=256MB
Games | N: 2500 W: 1559 L: 67 D: 874
Penta | [0, 6, 116, 758, 370]
```

LTC vs Stockfish 11:
```
Elo   | 88.29 +- 8.36 (95%)
Conf  | 60.0+0.60s Threads=1 Hash=256MB
Games | N: 2500 W: 1092 L: 470 D: 938
Penta | [10, 120, 460, 558, 102]
```

LTC vs Igel 3.6.0:
```
Elo   | -16.27 +- 7.54 (95%)
Conf  | 60.0+0.60s Threads=1 Hash=256MB
Games | N: 2500 W: 598 L: 715 D: 1187
Penta | [21, 370, 575, 273, 11]
```

LTC vs Black Marlin 9.0:
```
Elo   | 19.62 +- 7.59 (95%)
Conf  | 60.0+0.60s Threads=1 Hash=256MB
Games | N: 2500 W: 681 L: 540 D: 1279
Penta | [16, 244, 602, 359, 29]
```

LTC vs Bread 4.0.0:
```
Elo   | 9.17 +- 7.39 (95%)
Conf  | 60.0+0.60s Threads=1 Hash=256MB
Games | N: 2500 W: 646 L: 580 D: 1274
Penta | [17, 272, 601, 348, 12]
```

LTC vs Koivisto 9.0:
```
Elo   | -41.89 +- 7.50 (95%)
Conf  | 60.0+0.60s Threads=1 Hash=256MB
Games | N: 2500 W: 460 L: 760 D: 1280
Penta | [38, 434, 572, 202, 4]
```

SMP vs Avalanche 3.0.0 (4 Threads):
```
Elo   | 200.24 +- 22.43 (95%)
Conf  | 60.0+0.60s Threads=4 Hash=2048MB
Games | N: 300 W: 167 L: 11 D: 122
Penta | [0, 1, 18, 105, 26]
```

VLTC SMP vs Avalanche 3.0.0 (48 Threads):
```
Elo   | 195.51 +- 38.75 (95%)
Conf  | 180.0+2.0s Threads=48 Hash=32768MB
Games | N: 100 W: 54 L: 3 D: 43
Penta | [0, 0, 7, 35, 8]
```

- New net: Nezha

LTC (60+0.60):
```
Elo   | 10.57 +- 4.37 (95%)
SPRT  | 60.0+0.6s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [0.00, 3.00]
Games | N: 6084 W: 1377 L: 1192 D: 3515
Penta | [11, 626, 1586, 805, 14]
```

- Optimizations

STC (10+0.10):
```
Elo   | 42.82 +- 9.54 (95%)
SPRT  | 10.0+0.10s Threads=1 Hash=8MB
LLR   | 2.95 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 1264 W: 366 L: 211 D: 687
Penta | [2, 81, 314, 230, 5]
```

LTC (60+0.60):
```
Elo   | 56.70 +- 10.37 (95%)
SPRT  | 60.0+0.60s Threads=1 Hash=256MB
LLR   | 2.95 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 1020 W: 305 L: 140 D: 575
Penta | [0, 50, 252, 201, 7]
```

- New net: Zidingxiang 2

STC (10+0.10) vs Zidingxiang:
```
Elo   | 6.85 +- 3.57 (95%)
SPRT  | 10.0+0.1s Threads=1 Hash=8MB
LLR   | 2.97 (-2.94, 2.94) [0.00, 3.00]
Games | N: 10812 W: 2553 L: 2340 D: 5919
Penta | [62, 1229, 2637, 1390, 88]
```

- New net: Zidingxiang

STC (10+0.10) vs Huangpujiang:
```
Elo   | 35.83 +- 8.60 (95%)
SPRT  | 10.0+0.1s Threads=1 Hash=8MB
LLR   | 3.00 (-2.94, 2.94) [0.00, 3.00]
Games | N: 1946 W: 541 L: 341 D: 1064
Penta | [4, 172, 447, 320, 30]
```

- New net: Huangpujiang (king buckets)

LTC (60+0.60):
```
Elo   | 38.81 +- 8.73 (95%)
SPRT  | 60.0+0.6s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [0.00, 3.00]
Games | N: 1798 W: 520 L: 320 D: 958
Penta | [8, 137, 419, 317, 18]
```

- New net: Molihua

STC (10+0.10):
```
Elo   | 28.15 +- 7.81 (95%)
SPRT  | 10.0+0.1s Threads=1 Hash=8MB
LLR   | 2.95 (-2.94, 2.94) [0.00, 3.00]
Games | N: 2536 W: 720 L: 515 D: 1301
Penta | [15, 239, 585, 384, 45]
```

LTC (60+0.60):
```
Elo   | 25.62 +- 6.98 (95%)
SPRT  | 60.0+0.6s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [0.00, 3.00]
Games | N: 2432 W: 624 L: 445 D: 1363
Penta | [1, 213, 621, 368, 13]
```

- Fixes undefined piece_bitboards / NNUE accumulator on Position.new
- Fixes an issue where Zobrist omitted castling rights, which caused false TT hits / repetitions
- Support FEN halfmove clock
- Fixes an issue where UCI quit ignored while searching
- Fixes an issue where hard node/time limits not enforced
- Fixes an issue where terminal roots could hang and emit illegal bestmove a1a1
- Fixes an issue where Cuckoo upcoming-repetition root boundary off-by-one
- Fixes an SEE bug for EP / missing kings / pinned recaptures
- Qsearch now accepts quiet promotions, draws, and quiet stalemate
- Adjusted mate vs fifty-move draw precedence
- Fixes an issue where Syzygy non-cutting WDL bounds was discarded
- Fixes an issue where NNUE SCReLU output bias was scaled incorrectly
- Fixes quiet_moves buffer overflow

LTC (60+0.60):
```
Elo   | 34.03 +- 9.12 (95%)
SPRT  | 60.0+0.60s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 1598 W: 432 L: 276 D: 890
Penta | [2, 136, 383, 260, 18]
```

SMP (10+0.10):
```
Elo   | 34.18 +- 9.27 (95%)
SPRT  | 10.0+0.10s Threads=4 Hash=128MB
LLR   | 2.97 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 1652 W: 463 L: 301 D: 888
Penta | [4, 147, 380, 273, 22]
```

- TT static eval separation + lockless XOR verification
- Cuckoo upcoming-repetition detection
- ProbCut

STC (10+0.10):
```
Elo   | 24.87 +- 7.73 (95%)
SPRT  | 10.0+0.1s Threads=1 Hash=8MB
LLR   | 2.96 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 2670 W: 711 L: 545 D: 1414
Penta | [22, 263, 618, 391, 41]
```

LTC (60+0.60):
```
Elo   | 25.29 +- 7.42 (95%)
SPRT  | 60.0+0.6s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 2894 W: 691 L: 508 D: 1695
Penta | [2, 278, 714, 441, 12]
```

- New net: Qinyuanchun

LTC (60+0.60):
```
Elo   | 36.47 +- 8.68 (95%)
SPRT  | 60.0+0.6s Threads=1 Hash=64MB
LLR   | 2.96 (-2.94, 2.94) [0.00, 3.00]
Games | N: 1874 W: 522 L: 326 D: 1026
Penta | [4, 161, 433, 313, 26]
```

- Tuning

LTC (60+0.60):
```
Elo: 6.02 +/- 6.25, nElo: 11.64 +/- 12.08
LOS: 97.05 %, DrawRatio: 51.51 %, PairsRatio: 1.16
Games: 3176, Wins: 697, Losses: 642, Draws: 1837, Points: 1615.5 (50.87 %)
Ptnml(0-2): [15, 341, 818, 402, 12], WL/DD Ratio: 0.50
```

- Multithreaded TT initialization

STC SMP (10+0.1, 16t, 4096MB):
```
Elo: 12.17 +/- 17.65, nElo: 23.51 +/- 34.05
LOS: 91.20 %, DrawRatio: 53.50 %, PairsRatio: 1.32
Games: 400, Wins: 84, Losses: 70, Draws: 246, Points: 207.0 (51.75 %)
```

- Search improvements

STC (10+0.10):
```
Elo   | 39.52 +- 8.98 (95%)
SPRT  | 10.0+0.10s Threads=1 Hash=8MB
LLR   | 3.14 (-2.94, 2.94) [0.00, 3.00]
Games | N: 1960 W: 575 L: 353 D: 1032
Penta | [10, 165, 440, 323, 42]
```

LTC (60+0.60):
```
Elo   | 30.79 +- 7.75 (95%)
SPRT  | 60.0+0.6s Threads=1 Hash=64MB
LLR   | 2.98 (-2.94, 2.94) [0.00, 3.00]
Games | N: 2138 W: 547 L: 358 D: 1233
Penta | [4, 180, 528, 337, 20]
```

- New net: Shuang

STC (10+0.10):
```
Elo   | 24.38 +- 7.51 (95%)
SPRT  | 10.0+0.1s Threads=1 Hash=8MB
LLR   | 2.96 (-2.94, 2.94) [0.00, 3.00]
Games | N: 3140 W: 925 L: 705 D: 1510
Penta | [30, 325, 692, 441, 82]
```

LTC (60+0.60):
```
Elo   | 24.68 +- 7.02 (95%)
SPRT  | 60.0+0.6s Threads=1 Hash=64MB
LLR   | 3.01 (-2.94, 2.94) [0.00, 3.00]
Games | N: 2820 W: 718 L: 518 D: 1584
Penta | [15, 251, 697, 413, 34]
```

# v3.0.0

- Final match vs 2.1.0

STC (10+0.10):
```
Elo: 108.91 +/- 6.49, nElo: 172.56 +/- 9.63
LOS: 100.00 %, DrawRatio: 34.24 %, PairsRatio: 6.06
Games: 5000, Wins: 2179, Losses: 661, Draws: 2160, Points: 3259.0 (65.18 %)
Ptnml(0-2): [21, 212, 856, 1050, 361], WL/DD Ratio: 0.91
```

LTC (120+1.00):
```
Elo: 87.78 +/- 5.56, nElo: 158.58 +/- 9.63
LOS: 100.00 %, DrawRatio: 38.36 %, PairsRatio: 5.64
Games: 5000, Wins: 1857, Losses: 620, Draws: 2523, Points: 3118.5 (62.37 %)
Ptnml(0-2): [10, 222, 959, 1139, 170], WL/DD Ratio: 0.65
```

SMP (60+0.60):
```
Elo: 238.66 +/- 20.61, nElo: 475.60 +/- 30.45
LOS: 100.00 %, DrawRatio: 8.80 %, PairsRatio: 113.00
Games: 500, Wins: 309, Losses: 11, Draws: 180, Points: 399.0 (79.80 %)
Ptnml(0-2): [0, 2, 22, 152, 74], WL/DD Ratio: 0.69
```

- NNUE Speedup

STC (10+0.10):
```
Elo   | 28.17 +- 8.36 (95%)
SPRT  | 10.0+0.10s Threads=1 Hash=8MB
LLR   | 2.99 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 1990 W: 542 L: 381 D: 1067
Penta | [10, 168, 495, 295, 27]
```

- Add support for Syzygy Tablebases

STC (10+0.10, Endgames.epd):
```
Elo   | 15.42 +- 5.09 (95%)
SPRT  | 10.0+0.10s Threads=1 Hash=8MB
LLR   | 3.24 (-2.94, 2.94) [-3.00, 0.50]
Games | N: 2818 W: 600 L: 475 D: 1743
Penta | [1, 160, 961, 287, 0]
```

- LTC Tune

- New net: Jihan

Trained on 1.3B fresh self-play data from after migration.

STC (10+0.10):
```
Elo   | 21.02 +- 6.98 (95%)
SPRT  | 10.0+0.10s Threads=1 Hash=8MB
LLR   | 2.97 (-2.94, 2.94) [0.00, 3.00]
Games | N: 3774 W: 1101 L: 873 D: 1800
Penta | [53, 387, 820, 533, 94]
```

LTC (60+0.60):
```
Elo   | 20.43 +- 6.32 (95%)
SPRT  | 60.0+0.60s Threads=1 Hash=64MB
LLR   | 3.05 (-2.94, 2.94) [0.00, 3.00]
Games | N: 3474 W: 914 L: 710 D: 1850
Penta | [21, 334, 829, 526, 27]
```

Endgame STC:
```
Elo   | 4.20 +- 2.97 (95%)
SPRT  | 10.0+0.10s Threads=1 Hash=8MB
LLR   | 3.03 (-2.94, 2.94) [0.00, 5.00]
Games | N: 10826 W: 2162 L: 2031 D: 6633
Penta | [29, 943, 3325, 1100, 16]
```

- Migrate to Zig 0.16.0 and fix some bugs

```
Results of current vs Avalanche-2.1.0 (50+0.5, 1t, 64MB, UHO_4060_v4.epd):
Elo: 34.05 +/- 15.43, nElo: 66.25 +/- 29.80
LOS: 100.00 %, DrawRatio: 51.72 %, PairsRatio: 2.15
Games: 522, Wins: 136, Losses: 85, Draws: 301, Points: 286.5 (54.89 %)
Ptnml(0-2): [1, 39, 135, 80, 6], WL/DD Ratio: 0.48
LLR: 2.98 (101.2%) (-2.94, 2.94) [-10.00, 0.00]
--------------------------------------------------
SPRT ([-10.00, 0.00]) completed - H1 was accepted
```

# v2.1.0

## 1/11/2024

- Regression

STC 8.0+0.08 | noob_4moves
```
Score of New vs v2.0.0: 608 - 303 - 1089  [0.576] 2000
Elo difference: 53.4 +/- 10.2, LOS: 100.0 %, DrawRatio: 54.4 %
```

LTC 40.0+0.40 | noob_4moves
```
Score of New vs v2.0.0: 249 - 68 - 683  [0.591] 1000
Elo difference: 63.6 +/- 11.9, LOS: 100.0 %, DrawRatio: 68.3 %
```

## 1/9/2024

- More LTC Tune

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 112 - 100 - 270  [0.512] 482
Elo difference: 8.7 +/- 20.6, LOS: 79.5 %, DrawRatio: 56.0 %
```

## 1/7/2024

- Regression vs v2.0.0

LTC 40.0+0.40 | 8moves_v3
```
Score of New vs v2.0.0: 201 - 57 - 542  [0.590] 800
Elo difference: 63.2 +/- 13.4, LOS: 100.0 %, DrawRatio: 67.8 %
```

SMP 30.0+0.30 | 8moves_v3
```
Score of New_4T_256 vs v2.0.0_4T_256: 80 - 7 - 113  [0.682] 200
Elo difference: 132.9 +/- 30.6, LOS: 100.0 %, DrawRatio: 56.5 %
Ordo: +134.2
```

## 1/6/2024

- Tune and limit stability in time management

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 267 - 246 - 500  [0.510] 1013
Elo difference: 7.2 +/- 15.2
```

## 1/5/2024

- Add cutnode conditions

STC 8.0+0.08 | Pohl
```
Score of New_16 vs Master_16: 345 - 318 - 680  [0.510] 1343
Elo difference: 7.0 +/- 13.0
```

## 1/2/2024

- 30+0.3 5k games tunes

Probably didn't lose elo but whatever

LMR wasn't tuned due to an initial bug

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 211 - 205 - 535  [0.503] 951
Elo difference: 2.2 +/- 14.6, LOS: 61.6 %, DrawRatio: 56.3 %
Ordo: +2.4
```

## 11/2/2023

- New bucketed net: bingshan

Positive elo gain, just trust me

## 10/30/2023

- Simplify History (formula from Stormphrax)

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 228 - 199 - 490  [0.516] 917
Elo difference: 11.0 +/- 15.3, LOS: 92.0 %, DrawRatio: 53.4 %
Ordo: +12.0
```

## 10/22/2023

- Continuation History

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 878 - 841 - 1714  [0.505] 3433
Elo difference: 3.7 +/- 8.2, LOS: 81.4 %, DrawRatio: 49.9 %
Ordo: +4.2
```

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 97 - 79 - 205  [0.524] 381
Elo difference: 16.4 +/- 23.7
```

## 10/2/2023

- Change to standard aspiration window algorithm

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 388 - 326 - 795  [0.521] 1509
Elo difference: 14.3 +/- 12.0, LOS: 99.0 %, DrawRatio: 52.7 %
Ordo: +15.8
```

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 158 - 142 - 376  [0.512] 676
Ordo: +9.6
```

# v2.0.0

## 9/23/2023

- New net: Xuebeng
    - 512 hidden neurons
    - Squared Clipped ReLU

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 616 - 497 - 1088  [0.527] 2201
Elo difference: 18.8 +/- 10.3, LOS: 100.0 %, DrawRatio: 49.4 %
SPRT: llr 2.95 (100.1%), lbound -2.94, ubound 2.94 - H1 was accepted
Ordo: +21.6
```

~+2 in STC

## 9/20/2023

- Progress Check/Regression

LTC 40.0+0.40 | Pohl
```
Score of Dev vs v1.5.0: 274 - 40 - 186  [0.734] 500
Elo difference: 176.3 +/- 25.0, LOS: 100.0 %, DrawRatio: 37.2 %
Ordo: +215.2

Score of Dev vs Defenchess 2.2: 222 - 139 - 139  [0.583] 500
Elo difference: 58.2 +/- 26.1, LOS: 100.0 %, DrawRatio: 27.8 %
Ordo: +67.8
```

SMP 4CPU 20.0+0.20 | Pohl
```
Score of Dev vs v1.5.0: 57 - 12 - 31  [0.725] 100
Elo difference: 168.4 +/- 60.5, LOS: 100.0 %, DrawRatio: 31.0 %
Ordo: +190.8
```

Estimate CCRL 3350 1CPU Blitz, 3350 4CPU 40/15, 3260 1CPU 40/15.

## 9/16/2023

- Consider History in LMR

STC 8.0+0.08 | Pohl
```
Score of New_16 vs Master_16: 326 - 322 - 715  [0.501] 1363
Elo difference: 1.0 +/- 12.7, LOS: 56.2 %, DrawRatio: 52.5 %
```

## 9/15/2023

- Simplify LMR logic for captures

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 1402 - 1353 - 3346  [0.504] 6101
Elo difference: 2.8 +/- 5.9, LOS: 82.5 %, DrawRatio: 54.8 %
SPRT: llr 2.96 (100.6%), lbound -2.94, ubound 2.94 - H1 was accepted
Ordo: +3.2
```

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 128 - 124 - 296  [0.504] 548
Elo difference: 2.5 +/- 19.7, LOS: 59.9 %, DrawRatio: 54.0 %
Ordo: +2.4
```

## 9/14/2023

- Flip LMR condition for pv

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 331 - 291 - 748  [0.515] 1370
Elo difference: 10.1 +/- 12.4, LOS: 94.6 %, DrawRatio: 54.6 %
Ordo: +11.0
```

## 9/5/2023

- Fix SEE bug where threshold > pawn

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 305 - 205 - 617  [0.544] 1127
Elo difference: 30.9 +/- 13.6, LOS: 100.0 %, DrawRatio: 54.7 %
SPRT: llr 2.96 (100.7%), lbound -2.94, ubound 2.94 - H1 was accepted
```

## 9/4/2023

- Scale history down ("Gravity")
    - Suggested by Engine Programming Discord server

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 730 - 696 - 1705  [0.505] 3131
Elo difference: 3.8 +/- 8.2, LOS: 81.6 %, DrawRatio: 54.5 %
Ordo: +4.2
```

## 9/2/2023

- Age History instead of clearing it after each search
    - Mostly STC gains because LTC recalculates histories

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 218 - 159 - 430  [0.537] 807
Elo difference: 25.4 +/- 16.4, LOS: 99.9 %, DrawRatio: 53.3 %
SPRT: llr 2.95 (100.1%), lbound -2.94, ubound 2.94 - H1 was accepted
Ordo: +27.8
```

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 69 - 65 - 226  [0.506] 360
Elo difference: 3.9 +/- 21.9, LOS: 63.5 %, DrawRatio: 62.8 %
Ordo: +4.2
```

## 8/30/2023

- Regression Test vs 1.5.0

STC 8.0+0.08 | Pohl
```
Score of New vs v1.5.0: 161 - 34 - 83  [0.728] 278
Elo difference: 171.4 +/- 36.4, LOS: 100.0 %, DrawRatio: 29.9 %
SPRT: llr 2.96 (100.4%), lbound -2.94, ubound 2.94 - H1 was accepted
Ordo: +188.3
```

LTC 40.0+0.40 | Pohl
```
Score of New vs v1.5.0: 162 - 43 - 115  [0.686] 320
Elo difference: 135.7 +/- 31.4, LOS: 100.0 %, DrawRatio: 35.9 %
SPRT: llr 2.95 (100.1%), lbound -2.94, ubound 2.94 - H1 was accepted
Ordo: +154.5
```

## 8/29/2023

- TT Aging

STC 8.0+0.08 | Pohl
```
Score of New vs Master: 608 - 575 - 1304  [0.507] 2487
Elo difference: 4.6 +/- 9.4, LOS: 83.1 %, DrawRatio: 52.4 %
Ordo: +5.0
```

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 42 - 34 - 82  [0.525] 158
Elo difference: 17.6 +/- 37.7, LOS: 82.1 %, DrawRatio: 51.9 %
Ordo: +21.3
```

## 8/26/2023

- Material Scaling

STC 10.0+0.10 | 8moves_v3
```
Score of New vs Master: 178 - 163 - 659  [0.507] 1000
Elo difference: 5.2 +/- 12.6, LOS: 79.2 %, DrawRatio: 65.9 %
Ordo: +5.2
```

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 161 - 143 - 361  [0.514] 665
Cutechess output lost
Ordo: +11.0
```

## 8/25/2023

- 50 move count scaling

STC 10.0+0.10 | 8moves_v3
```
Score of New vs Master: 1152 - 1072 - 4332  [0.506] 6556
Elo difference: 4.2 +/- 4.9, LOS: 95.5 %, DrawRatio: 66.1 %
SPRT: llr 1.39 (47.3%), lbound -2.94, ubound 2.94
Ordo: +4.3
```

LTC 40.0+0.40 | Pohl
```
Score of New vs Master: 339 - 325 - 885  [0.505] 1549
Elo difference: 3.1 +/- 11.3, LOS: 70.7 %, DrawRatio: 57.1 %
SPRT: llr 0.0958 (3.3%), lbound -2.94, ubound 2.94
Ordo: +3.6
```

## 8/18/2023

- New net: net008b

STC 15.0+0.10 | 1000 games | 8moves_v3
```
Score of New vs Master: 284 - 174 - 542  [0.555] 1000
Elo difference: 38.4 +/- 14.5, LOS: 100.0 %, DrawRatio: 54.2 %
Ordo: +39.1
```

## 8/16/2023

- Switch to new NNUE architecture
- New net: net007b

STC 20.0+0.10 | 1000 games | 8moves_v3
```
Score of New vs Master: 404 - 162 - 434  [0.621] 1000
Elo difference: 85.8 +/- 16.3, LOS: 100.0 %, DrawRatio: 43.4 %
Ordo: +86.9
```

LTC 40.0+0.40 | 300 games | Pohl
```
Score of New vs Master: 127 - 74 - 99  [0.588] 300
Elo difference: 62.0 +/- 32.5, LOS: 100.0 %, DrawRatio: 33.0 %
Ordo: +76.8
```

## 8/5/2023

- Fix NMP bug

STC 20.0+0.10 | 1000 games | 8moves_v3
```
Score of New vs Master: 170 - 127 - 703  [0.521] 1000
Elo difference: 14.9 +/- 11.7, LOS: 99.4 %, DrawRatio: 70.3 %
```

LTC 60.0+0.60 | 1000 games | 8moves_v3
```
Score of New vs Master: 134 - 144 - 722  [0.495] 1000
Elo difference: -3.5 +/- 11.3, LOS: 27.4 %, DrawRatio: 72.2 %
```

30.0+0.30 VS 1.5.0:
```
Score of Master vs 1.5.0: 328 - 258 - 1414  [0.517] 2000
Elo difference: 12.2 +/- 8.2, LOS: 99.8 %, DrawRatio: 70.7 %
```

- Do more NMP when position is improving

STC 30.0+0.20 | 1000 games | noob_4moves
```
Score of New vs Master: 140 - 121 - 739  [0.509] 1000
Elo difference: 6.6 +/- 11.0, LOS: 88.0 %, DrawRatio: 73.9 %
```

## 8/4/2023

- New RFP parameters from Viridithas

STC 15.0+0.10 | 2000 games | 8moves_v3
```
Score of New vs Master: 357 - 337 - 1306  [0.505] 2000
Elo difference: 3.5 +/- 9.0, LOS: 77.6 %, DrawRatio: 65.3 %
```

LTC 60.0+0.60 | 1000 games | 8moves_v3
```
Score of New vs Master: 143 - 127 - 730  [0.508] 1000
Elo difference: 5.6 +/- 11.2, LOS: 83.5 %, DrawRatio: 73.0 %
```

## 8/3/2023

- New LMR parameters from Viridithas

STC 14.0+0.10 | 1000 games | 8moves_v3
```
181 - 173 - 646  [0.504] 1000
Elo difference: 2.8 +/- 12.8, LOS: 66.5 %, DrawRatio: 64.6 %
```

LTC 50.0+0.50 | 1000 games | 8moves_v3
```
[0.510] 1000
Elo difference: 7.0
DrawRatio: 76.52 %
```


## v1.5.0

- Optimizations
- Search Tuning
- Stronger Neural Network
- Trained on over 25 Million depth 8 positions from lichess elite database
- Trained on 1.5 Million depth 10 endgame positions
- LazySMP Implementation

## v1.4.0

- Search Improvements
- Manual Tuning
- NNUE Optimizations
- Time Management

## v1.3.1

- Search Improvements
- Countermove heuristic fix
- Tuning

## v1.3.0

- Stronger Neural Network trained on 2GB of data
- Countermove Heuristics
- Higher bounds for History Heuristics
- Improved Aspiration Window

## v1.2.0

- Movegen Bug fixes
- Tuned Search parameters
- Search Rewrite
- Better SEE
- Stronger Neural Network (depth 8, 500 epoch) featuring 8 buckets

## v1.1.0

- NNUE Optimizations
- Singular Extension / MultiCut
- More Aggressive Prunings

## v1.0.0

- Faster Movegen: heavily inspired by Surge
- Complete Core Rewrite
- 512-neuron NNUE trained on 50 million positions on depth 4

## v0.2.2

- Bug fixes
- LMR tuning
- New SEE algorithm
- Aspiration Windows

## v0.2.1

- Bug fixes
- UCI options
- Improvements on Search

## v0.2: Search

- History heuristics, killer heuristics
- Better LMR
- Reversed Futility Pruning
- Null Move Pruning
- Razoring
- Time management
- Better Transposition Table
- Static Exchange Evaluation
- Stronger NNUE network: Flake 2
- Trained on human games on https://database.lichess.org/ and more engine games.
- Trained on one million endgame positions
- 728 -> dense -> 512 -> clipped_relu -> 512 -> dense -> 1 + PSQT

## v0.1: NNUE, ~1700 ELO

- Efficiently Updatable Neural Network trained on top-level engine tournaments
- Current model: 728 -> dense -> 128 -> clipped_relu -> 128 -> dense -> 5 + PSQT
- Forward Pass
- Tuned LMR
- Bishop pair, doubled pawns, etc.

## v0.0: Base, ~1400 ELO

- Bitboard board representation
- Magic bitboards
- Negamax Search with Alpha-Beta pruning
- Quiescence Search with stand-pat pruning
- MVV_LVA
- LMR
- HCE PSQT Evaluation
