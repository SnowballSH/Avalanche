# Avalanche

<br/>

<p align="center">
<img src="https://github.com/SnowballSH/Avalanche/assets/66022611/2026b61e-7558-4fb9-8549-da2f8492174f" alt="Logo" width=700 height=400/>
</p>

<br/>

### Avalanche is the first and strongest UCI Chess Engine written in [Zig](https://ziglang.org/)

## Strength

**Official [40/15 CCRL ELO (v2.0.0)](https://computerchess.org.uk/ccrl/4040/cgi/engine_details.cgi?match_length=30&each_game=0&print=Details&each_game=0&eng=Avalanche%202.0.0%2064-bit#Avalanche_2_0_0_64-bit): 3247**

**Official [Blitz CCRL ELO (v2.0.0)](https://computerchess.org.uk/ccrl/404/cgi/engine_details.cgi?match_length=30&each_game=0&print=Details&each_game=0&eng=Avalanche%202.0.0%2064-bit#Avalanche_2_0_0_64-bit): 3332**

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

## Usage

Avalanche follows the UCI protocol and is not a full chess application. You should use Avalanche with a UCI-compatible GUI interface. If you need to use the CLI, make sure to send \n at the end of your input (^\n on windows command prompt).

## Past Versions

| Version      | CCRL 40/15 | CCRL Blitz |
|--------------|------------|------------|
| v2.0.0       | 3247       | 3332       |
| v1.5.0 4CPU  | 3246       | N/A        |
| v1.5.0       | 3187       | 3249       |
| v1.4.0       | 3146       | 3216       |
| v1.3.1       | 3080       | N/A        |
| v1.3.0       | 3038       | 3096       |
| v1.2.0       | 3044       | 3035       |
| v1.1.0       | 2834       | 2929       |
| v1.0.0       | 2739       | N/A        |
| v0.2.2       | 2626       | 2589       |
| v0.2.1       | 2562       | N/A        |
| v0.2.0       | 2424       | 2490       |

<img src="https://docs.google.com/spreadsheets/d/e/2PACX-1vSeuY7fgGH72R5n7v8dtT5XoKxMMgnLkT3ew9pk8Mn8BYKp8A9wPpZ4f9EPmmVs-x0_uFiZn0_nmcm6/pubchart?oid=1884376007&amp;format=image" width=600/>

## Credits

- [Dan Ellis Echavarria](https://github.com/Deecellar) for writing the github action CI and helping me with Zig questions
- [Ciekce](https://github.com/Ciekce) for guiding me with migrating to the new Marlinflow and answering my stupid questions related to NNUE
- Many other developers in the computer chess community for guiding me through new things like SPRT testing.

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
  - The Hand-Crafted Evaluation is based on https://www.chessprogramming.org/PeSTO%27s_Evaluation_Function with adaptation to endgames. The HCE is only activated at late endgames when finding checkmate against a lone king is needed.
  - NNUE since 2.0.0 is trained with https://github.com/jw1912/bullet
  - The NNUE data since 2.0.0 is purely generated from self-play games. Currently, the latest dev network is trained on 600 million self-play positions at depth 8.
- UCI Interface/Communication code
  - 100% original

## Alternative Square Logos
<img src="https://github.com/SnowballSH/Avalanche/assets/66022611/cf099f87-91ad-4fd9-a2c3-177b790cd59e" alt="Logo 2" width=400 height=400/>
<img src="https://github.com/SnowballSH/Avalanche/assets/66022611/6ece76d4-ce7c-43e7-8321-27e368b12760" alt="Logo 3" width=400 height=400/>
<img src="https://github.com/SnowballSH/Avalanche/assets/66022611/ef77edf1-9f8d-45dc-867f-533a4c84d22f" alt="Logo 4" width=400 height=400/>

