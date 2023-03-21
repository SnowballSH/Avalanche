# Avalanche

<br/>

<p align="center">
<img src="https://user-images.githubusercontent.com/66022611/226020771-aaaf3345-3834-4485-8f6e-29371a497a9e.png" alt="Logo" width = "400" height = "400"/>
</p>

<br/>

### Avalanche is the first and strongest UCI Chess Engine written in [Zig](https://ziglang.org/)

## Strength

**Official [CCRL ELO (v1.3.1)](http://ccrl.chessdom.com/ccrl/4040/cgi/engine_details.cgi?print=Details&each_game=0&eng=Avalanche%201.3.1%2064-bit#Avalanche_1_3_1_64-bit): 3081**

## About

Avalanche is the **first and strongest chess engine** written in the [Zig programming language](https://ziglang.org/), proving Zig's ability to succeed in real-world, competitive applications.

This is my second attempt at computer chess, after dropping development of my MiniShogi (五将棋) engine.

Avalanche v1.2.0 was the **sole winner** of the 96th CCRL Amateur Series Tournament (Division 5), having a score of **27.0/44**. See [Tournament Page](http://kirill-kryukov.com/chess/discussion-board/viewtopic.php?f=7&t=14568&sid=a66f54aae9c1aa4cd03a6ed5f95035af).

Avalanche uses the new **NNUE** (Efficiently Updatable Neural Network) technology for its evaluation.

This project isn't possible without the help of the Zig community, since this is the first and only Zig code I've ever written. Thank you!

## License

Good Old MIT License. In short, feel free to use this program anywhere, but please credit this repository somewhere in your project :)

## Compile

`zig build -Drelease-fast`

Avalanche is only guaranteed to compile using Zig v0.10.x. Newer versions will not work as Avalanche still uses Stage1.

Avalanche also has a lichess account (though not often played): https://lichess.org/@/IceBurnEngine

## Tuning

Parameter Tuning is done by my [Storming Tune](https://github.com/SnowballSH/storming_tune) script.

## Credits

- [Dan Ellis Echavarria](https://github.com/Deecellar) for writing the github action CI and helping me with Zig questions

- https://www.chessprogramming.org/ for explanation on everything I need, including search, tt, pruning, reductions... everything.
- https://github.com/nkarve/surge for movegen inspiration.
- Maksim Korzh, https://www.youtube.com/channel/UCB9-prLkPwgvlKKqDgXhsMQ for getting me started on chess programming.
- https://github.com/dsekercioglu/blackmarlin for NNUE structure and trainer skeleton
- https://github.com/Disservin/Smallbrain for search ideas
- https://github.com/SzilBalazs/BlackCore for time management ideas
- https://openai.com/dall-e-2/ for generating the beautiful logo image

## Originality Status

- General
  - This is the first released chess engine written in the **Zig Programming Language**. Although there are Zig libraries for chess, Avalanche is completely stand-alone and does not use any external libraries.
- Move Generator
  - Algorithm is inspired by Surge, but code is 100% hand-written in Zig.
- Search
  - Avalanche has a simple Search written 100% by myself, but is probably a subset of many other engines. Some ideas are borrowed from other chess engines as in comments. However many ideas and parameters are tuned manually and automatically using my own scripts.
- Evaluation
  - The Hand-Crafted Evaluation is based on https://www.chessprogramming.org/PeSTO%27s_Evaluation_Function, **however it is no longer Avalanche's main evaluation**.
  - NNUE is trained with a private, significantly modified fork of https://github.com/dsekercioglu/marlinflow. The data is generated through self-play games and the default net is trained over the BM 4.0 net. The secondary net in the nets/ folder is smaller, faster, and trained purely on Avalanche 1.3.1 self-play games.
- UCI Interface/Communication code
  - 100% original

## Changelog

- ### v1.4.0 (+~50 ELO) ~3131 ELO

  - Search Improvements
  - Manual Tuning
  - NNUE Optimizations
  - Time Management

- ### v1.3.1 (+49 ELO) 3081 ELO

  - Search Improvements
  - Countermove heuristic fix
  - Tuning

- ### v1.3.0 (-16 ELO) 3032 ELO

  - Stronger Neural Network trained on 2GB of data
  - Countermove Heuristics
  - Higher bounds for History Heuristics
  - Improved Aspiration Window

- ### v1.2.0 (+210 ELO) 3048 CCRL ELO

  - Movegen Bug fixes
  - Tuned Search parameters
  - Search Rewrite
  - Better SEE
  - Stronger Neural Network (depth 8, 500 epoch) featuring 8 buckets

- ### v1.1.0 (+95 ELO) 2838 CCRL ELO

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

- ### v0.2: Search (+721 ELO), 2421 CCRL ELO

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

- ### v0.1: NNUE (+275-375 ELO), ~1700 ELO

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
