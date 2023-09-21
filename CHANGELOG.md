# v1.6.0

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
