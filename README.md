# Avalanche

UCI Chess Engine written in Zig, using Bitboards and NNUE.

**CCRL ELO (v0.2.2): 2629**

**v1.0.0 estimate: 2725**

[Avalanche's CCRL Profile for v0.2.2](https://www.computerchess.org.uk/ccrl/4040/cgi/engine_details.cgi?match_length=30&each_game=1&print=Details&each_game=1&eng=Avalanche%200.2.2%2064-bit#Avalanche_0_2_2_64-bit)

[Avalanche's CCRL Profile for v1.0.0](https://www.computerchess.org.uk/ccrl/4040/cgi/engine_details.cgi?match_length=30&each_game=1&print=Details&each_game=1&eng=Avalanche%201.0.0%2064-bit#Avalanche_1_0_0_64-bit)

## Compile

`zig build -Drelease-fast`

Avalanche also has a lichess account: https://lichess.org/@/IceBurnEngine

Feel free to challenge it!

Brilliant win against Inanis 1.0.1 (2675) in CCRL Amateur tournament Division 6: https://lichess.org/study/1UVjx7eE/vY896gMZ#0

## Credits

- [Dan Ellis Echavarria](https://github.com/Deecellar) for writing the github action CI :D

- https://www.chessprogramming.org/ for explanation on everything I need, including search, tt, pruning, reductions... everything.
- https://github.com/nkarve/surge for movegen inspiration.
- Maksim Korzh, https://www.youtube.com/channel/UCB9-prLkPwgvlKKqDgXhsMQ for getting me started on chess programming.
- https://github.com/dsekercioglu/blackmarlin for NNUE ideas (Structure is identical that any BM normal net can be used with Avalanche!)

## Changelog

- ### v1.0 ~2725 CCRL ELO
    - Faster Movegen: heavily inspired by Surge
    - Complete Core Rewrite
    - 512-neuron NNUE trained on 50 million positions on depth 4

- ### v0.2.2 (+63 ELO), 2629 CCRL ELO
    - Bug fixes
    - LMR tuning
    - New SEE algorithm
    - Aspiration Windows

- ### v0.2.1 (+145 ELO), 2566 CCRL ELO
    - Bug fixes
    - UCI options
    - Improvements on Search

- ### v0.2: Search  (+721 ELO), 2421 CCRL ELO
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
