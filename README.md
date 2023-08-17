# Avalanche

<br/>

<p align="center">
<img src="https://user-images.githubusercontent.com/66022611/226020771-aaaf3345-3834-4485-8f6e-29371a497a9e.png" alt="Logo" width = "400" height = "400"/>
</p>

<br/>

### Avalanche is the first and strongest UCI Chess Engine written in [Zig](https://ziglang.org/)

## Strength

**Official [40/15 CCRL ELO (v1.4.0)](http://ccrl.chessdom.com/ccrl/4040/cgi/engine_details.cgi?match_length=30&each_game=0&print=Details&each_game=0&eng=Avalanche%201.4.0%2064-bit#Avalanche_1_4_0_64-bit): 3147**

**Official [Blitz CCRL ELO (v1.5.0)](http://ccrl.chessdom.com/ccrl/404/cgi/engine_details.cgi?match_length=30&each_game=1&print=Details&each_game=1&eng=Avalanche%201.5.0%2064-bit#Avalanche_1_5_0_64-bit): 3247**

## About

Avalanche is the **first and strongest chess engine** written in the [Zig programming language](https://ziglang.org/), proving Zig's ability to succeed in real-world, competitive applications.

This is my second attempt at computer chess, after dropping development of my MiniShogi (五将棋) engine.

Avalanche v1.4.0 was the **sole winner** of the 102nd CCRL Amateur Series Tournament (Division 5), having a score of **29.5/44**. See [Tournament Page](https://kirill-kryukov.com/chess/discussion-board/viewtopic.php?f=7&t=15613&sid=8ada67b5589f716aaf477dd1befe051b).

Avalanche uses the new **NNUE** (Efficiently Updatable Neural Network) technology for its evaluation.

This project isn't possible without the help of the Zig community, since this is the first and only Zig code I've ever written. Thank you!

## License

Good Old MIT License. In short, feel free to use this program anywhere, but please credit this repository somewhere in your project :)

## Compile

`zig build -Drelease-fast`

Avalanche is only guaranteed to compile using Zig v0.10.x. Newer versions will not work as Avalanche still uses Stage1.

Avalanche also has a lichess account (though not often played): https://lichess.org/@/IceBurnEngine

## Strength

| Version      | CCRL 40/15 | CCRL Blitz |
|--------------|------------|------------|
| v1.5.0 4CPU  | 3256?      | N/A        |
| v1.5.0       | 3174?      | 3247       |
| v1.4.0       | 3147       | 3211       |
| v1.3.1       | 3080       | N/A        |
| v1.3.0       | 3037       | 3091       |
| v1.2.0       | 3046       | 3029       |
| v1.1.0       | 2835       | 2923       |
| v1.0.0       | 2742       | N/A        |
| v0.2.2       | 2626       | 2587       |
| v0.2.1       | 2563       | N/A        |
| v0.2.0       | 2424       | 2487       |

## Tuning

Parameter Tuning is done by my [Storming Tune](https://github.com/SnowballSH/storming_tune) script.

## Credits

- [Dan Ellis Echavarria](https://github.com/Deecellar) for writing the github action CI and helping me with Zig questions
- [Ciekce](https://github.com/Ciekce) for guiding me with migrating to the new Marlinflow and answering my stupid questions related to NNUE

- https://www.chessprogramming.org/ for explanation on everything I need, including search, tt, pruning, reductions... everything.
- https://github.com/nkarve/surge for movegen inspiration.
- Maksim Korzh, https://www.youtube.com/channel/UCB9-prLkPwgvlKKqDgXhsMQ for getting me started on chess programming.
- https://github.com/dsekercioglu/blackmarlin for NNUE structure and trainer skeleton
- https://github.com/Disservin/Smallbrain and https://github.com/cosmobobak/viridithas for search ideas
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
  - NNUE after 1.5.0 is trained with Ciekce's [modified fork](https://github.com/Ciekce/marlinflow) of https://github.com/dsekercioglu/marlinflow.
  - The NNUE data after 1.5.0 is purely generated from self-play games. Currently, the latest dev network is trained on 160 million self-play positions at 5k-6k nodes.
- UCI Interface/Communication code
  - 100% original
