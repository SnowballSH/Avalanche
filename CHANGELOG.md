# v1.6.0

## 8/5/2023

- Fix NMP bug

STC 20.0+0.10 | 1000 games | 8moves_v3
```
Score of New vs Master: 170 - 127 - 703  [0.521] 1000
Elo difference: 14.9 +/- 11.7, LOS: 99.4 %, DrawRatio: 70.3 %
```

LTC 60.0+0.60 | 1000 games | 8moves_v3
```
Score of New vs Master: 134 - 144 - 722  [0.495]                         
Elo difference: -3.5 +/- 11.3, LOS: 27.4 %, DrawRatio: 72.2 %
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
