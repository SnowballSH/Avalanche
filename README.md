# Avalanche

[WIP] Bitboard Chess Engine written in Zig

Currently plays at around 2000 ELO.

## Compile

`zig build -Drelease-fast=true -- nnue` to make weights.zig as well (add NNUE)
If the weights.zig for current net already exists (rebuild), `zig build -Drelease-fast=true`

## Changelog

- ### v0.2: [DEV] Search  (+200 ELO)
    - History heuristics, killer heuristics
    - Better LMR
    - Reversed Futility Pruning
    - Null Move Pruning
    - Razoring
    - Stronger NNUE network
        - Trained on human games on https://database.lichess.org/ and engine games.
        - 728 -> dense -> 256 -> clipped_relu -> 256 -> dense -> 1 + PSQT

- ### v0.1: NNUE  (+275-375 ELO)
    - Efficiently Updatable Neural Network trained on top-level engine tournaments
        - Current model: 728 -> dense -> 128 -> clipped_relu -> 128 -> dense -> 5 + PSQT
    - Forward Pass
    - Tuned LMR
    - Bishop pair, doubled pawns, etc.

- ### v0.0: Base
    - Bitboard board representation
    - Magic bitboards
    - Negamax Search with Alpha-Beta pruning
    - Quiescence Search with stand-pat pruning
    - MVV_LVA
    - LMR
    - HCE PSQT Evaluation
