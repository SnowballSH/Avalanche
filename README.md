# Avalanche

[WIP] UCI Chess Engine written in Zig, using Bitboards and NNUE.

**CCRL ELO (v0.2.2): 2629**

[Avalanche's CCRL Profile](https://www.computerchess.org.uk/ccrl/4040/cgi/engine_details.cgi?match_length=30&each_game=1&print=Details&each_game=1&eng=Avalanche%200.2.2%2064-bit#Avalanche_0_2_2_64-bit)

## Compile

`zig build -Drelease-fast=true -- nnue` to make weights.zig as well (add NNUE)
If the weights.zig for current net already exists (rebuild), `zig build -Drelease-fast=true`
Currently no CPU-specific instructions besides POPCNT and CTZ are used, so one binary should run on any modern machine.

Avalanche also has a lichess account: https://lichess.org/@/IceBurnEngine (It might not be online until I host it some time in the future... but you can still view its games!)

Brilliant win against Blunder 7.6.0 in CCRL division 7 tournament: https://lichess.org/eENdzud8/white

## Credits

- https://www.chessprogramming.org/ for explanation on everything I need, including search, tt, pruning, reductions... everything.
- Maksim Korzh, https://www.youtube.com/channel/UCB9-prLkPwgvlKKqDgXhsMQ for getting me started on chess programming. Hope the war in Ukraine doesn't impact him and he stays safe!
- https://github.com/amanjpro/zahak for Search ideas
- https://github.com/dsekercioglu/blackmarlin for NNUE ideas (Structure is identical that any BM normal net can be used with Avalanche!)
- https://github.com/Tearth/Cosette for Movegen ideas

## Changelog (ELO based on Stockfish limit_strength)

- ### v1.0 ~2600 CCRL ELO, WIP
    - Faster Movegen
    - Rewrite
    - 256-neuron NNUE trained on 30 million positions on depth 3

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
