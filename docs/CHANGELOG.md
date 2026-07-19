# v3.1.0

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
