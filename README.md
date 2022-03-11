# Avalanche

[WIP] Bitboard and NNUE Chess Engine written in Zig

Currently plays at around 2200 ELO.

## Compile

`zig build -Drelease-fast=true -- nnue` to make weights.zig as well (add NNUE)
If the weights.zig for current net already exists (rebuild), `zig build -Drelease-fast=true`

## Credits

- https://www.chessprogramming.org/ for explanation on everything I need, including search, tt, pruning, reductions... everything.
- Maksim Korzh, https://www.youtube.com/channel/UCB9-prLkPwgvlKKqDgXhsMQ for getting me started on chess programming. Hope the war in Ukraine doesn't impact him and he stays safe!
- https://github.com/amanjpro/zahak for Search ideas
- https://github.com/dsekercioglu/blackmarlin for NNUE ideas
- https://github.com/Tearth/Cosette for Movegen ideas

## Changelog

- ### v0.2: [DEV] Search  (+450-600 ELO), ~2200 ELO
    - History heuristics, killer heuristics
    - Better LMR
    - Reversed Futility Pruning
    - Null Move Pruning
    - Razoring
    - Time management
    - Stronger NNUE network: Flake 2
        - Trained on human games on https://database.lichess.org/ and more engine games.
        - Trained on one million endgame positions
        - 728 -> dense -> 512 -> clipped_relu -> 512 -> dense -> 1 + PSQT

- ### v0.1: NNUE  (+275-375 ELO), ~1700 ELO
    - Efficiently Updatable Neural Network trained on top-level engine tournaments
        - Current model: 728 -> dense -> 128 -> clipped_relu -> 128 -> dense -> 5 + PSQT
    - Forward Pass
    - Tuned LMR
    - Bishop pair, doubled pawns, etc.

- ### v0.0: Base, ~1400 ELO
    - Bitboard board representation
    - Magic bitboards
    - Negamax Search with Alpha-Beta pruning
    - Quiescence Search with stand-pat pruning
    - MVV_LVA
    - LMR
    - HCE PSQT Evaluation
