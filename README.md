# Avalanche

[WIP] Bitboard Chess Engine written in Zig

Currently plays at around 1900 ELO -- mainly due to tactical reasons.

## Changelog

- ### v0.1: NNUE  (+275-375 ELO)
    - Efficiently Updatable Neural Network trained on top-level engine tournaments
        - Current model: 728 -> dense -> 128 -> clipped_relu -> 128 -> dense -> 5 + PSQT
        - Next model: 728 -> dense -> 256 -> clipped_relu -> 256 -> dense -> 3 + PSQT
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
