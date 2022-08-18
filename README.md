# Avalanche

The first UCI Chess Engine written in Zig, using Bitboards and NNUE.

**Estimated Development ELO (v2.0.0): ~2930**

**CCRL ELO (v1.1.0): 2852**

[Avalanche's CCRL Profile for v1.1.0](https://www.computerchess.org.uk/ccrl/4040/cgi/engine_details.cgi?match_length=30&each_game=1&print=Details&each_game=1&eng=Avalanche%201.1.0%2064-bit#Avalanche_1_1_0_64-bit)

## About

Avalanche is the **first chess engine** written in the [Zig programming language](https://ziglang.org/), marking a milestone of Zig's growth and proves that Zig's ability to succeed in real-world applications.

This is my second attempt at computer chess, after dropping development of my MiniShogi engine. Avalanche experienced a major v1.0.0 rewrite, which made full use of Zig's optimizations and features, and became a lot faster.

Avalanche v1.1.0 is the **sole winner** of the 95th CCRL Amateur Series Tournament (Division 6), having a score of **30.0/44**, **4.5 points higher** than the second place. See [Tournament Page](http://kirill-kryukov.com/chess/discussion-board/viewtopic.php?f=7&t=14438&sid=f5417da1d80faac3b3d6f1530a3b41cc).

Avalanche uses the new **NNUE** (Efficiently Updatable Neural Network) technology for its evaluation.
The current architecture is 768x512x1, proven to be strong enough by BlackMarlin 5.0.
Without NNUE (pure PeSTO's PSQT eval), Avalanche only plays at around 2300 ELO.

My goal for Avalanche reaching 3000 elo on CCRL and getting into the top 100 list. Currently it is ranked #120. After that, I will put more time on Competitive Programming and Neural Networks.

This project isn't possible without the help of the Zig community, since this is the first and only Zig code I've ever written. Thank you!

## License
Good Old MIT License. In short, feel free to use this program anywhere, but please put a link to this repository somewhere in your project :)

## Compile

`zig build -Drelease-fast`

Avalanche also has a lichess account: https://lichess.org/@/IceBurnEngine

Feel free to challenge it!

Brilliant win against Weiawaga 5.0.0 (2848) in 95th CCRL Amateur Tournament Division 6: https://lichess.org/study/1UVjx7eE/ariuxOkQ#0

## Credits

- [Dan Ellis Echavarria](https://github.com/Deecellar) for writing the github action CI :D

- https://www.chessprogramming.org/ for explanation on everything I need, including search, tt, pruning, reductions... everything.
- https://github.com/nkarve/surge for movegen inspiration.
- Maksim Korzh, https://www.youtube.com/channel/UCB9-prLkPwgvlKKqDgXhsMQ for getting me started on chess programming.
- https://github.com/dsekercioglu/blackmarlin for NNUE structure, data generation ideas, and trainer

## Originality Status

- General
    - This is the first released chess engine written in the **Zig Programming Language**. Although there are Zig libraries for chess, Avalanche is completely stand-alone and does not use any external libraries.
- Move Generator
    - Algorithm is inspired by Surge, but code is 100% hand-written in Zig.
- Search
    - Avalanche has a fairy simple Search written 100% by myself, but is probably a subset of many other engines. However many ideas and parameters are tuned manually. I hope to add more sophisticated prunings and extensions in the future.
- Evaluation
    - The Hand-Crafted Evaluation is based on https://www.chessprogramming.org/PeSTO%27s_Evaluation_Function, **however it is no longer Avalanche's main evaluation**.
    - NNUE is trained with a private, significantly modified fork of https://github.com/dsekercioglu/marlinflow and the data is generated through self-play games. I hope to make it public in the future.
- UCI Interface/Communication code
    - 100% original
- Testing
    - SPRT Testing of new features is ran on a local instance of https://github.com/AndyGrant/OpenBench.

## Changelog

- ### v1.1.0 (+109 ELO) 2852 CCRL ELO
    - NNUE Optimizations
    - Singular Extension / MultiCut
    - More Aggressive Prunings

- ### v1.0.0 (+113 ELO) 2743 CCRL ELO
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
