# UCI support

## Commands

| Command | Notes |
| --- | --- |
| `uci`, `isready`, `ucinewgame`, `quit` | standard |
| `setoption name <name> [value <value>]` | names are case-insensitive and may contain spaces |
| `position startpos\|fen <fen> [moves ...]` | FEN accepts X-FEN and Shredder castling fields |
| `go ...` | `wtime btime winc binc movestogo depth nodes movetime mate infinite ponder searchmoves`, in any combination |
| `stop`, `ponderhit` | accepted while searching |
| `eval` | names the network, then prints the static evaluation of the current position (network output and final score, White's view) |
| `d`, `perft N`, `perftdiv N`, `spsa`, `spsa++`, `genfens ...` | engine-specific |

## Options

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| Hash | spin | 16 | MB |
| Threads | spin | 1 | persistent helper pool, see [THREADS.md](THREADS.md); max 1 on wasm |
| NumaPolicy | combo | auto | `auto` binds threads to NUMA nodes on multi-node Linux machines, `none` leaves placement to the OS |
| Move Overhead | spin | 25 | ms; the former name `MoveOverhead` is still accepted |
| MultiPV | spin | 1 | up to 256 |
| Ponder | check | false | tells GUIs pondering is supported; pondering itself is driven by `go ponder` |
| Clear Hash | button | | |
| UCI_Chess960 | check | false | king-captures-rook castling notation |
| UCI_LimitStrength | check | false | uses `UCI_Elo` instead of `Skill Level` |
| UCI_Elo | spin | 3000 | 1320–3000, see [STRENGTH.md](STRENGTH.md) |
| Skill Level | spin | 20 | 0–20 |
| SyzygyPath, SyzygyProbeDepth, SyzygyProbeLimit, Syzygy50MoveRule | | | tablebases |
| EvalFile | string | `<embedded>` | load a network file at runtime (same architecture as the embedded net); `<embedded>` restores the built-in net; unavailable on wasm |
| EvalScale | spin | 1000 | 500–2000, permille multiplier on the network output, see [DATAGEN.md](DATAGEN.md#network-eval-scale); changing it clears the hash |
| UCI_ShowWDL | check | false | |
| Contempt | spin | 0 | |

Tunable search parameters are also exposed as spin options for SPSA.

## Search integration

- **Time**: `src/engine/uci/go.zig` turns a `go` command into a `TimeBudget`.
  Clock and `movetime` limits combine (the tighter wins); `depth`, `nodes` and
  `mate` are independent stop conditions. Without a clock or `movetime` the
  search ignores time.
- **Pondering**: `go ponder` sets `Searcher.pondering`. While it is set, time
  limits are ignored; `ponderhit` clears it and the budget, measured from the
  original `go`, applies again, so a long ponder can end the search at once.
  `bestmove` is never printed during `go ponder` or `go infinite` until
  `ponderhit`/`stop`, even if the search finishes early.
- **bestmove ... ponder**: the second move of the chosen PV, or, when the PV
  is one move long, the transposition-table move of the resulting position if
  it is legal.
- **MultiPV**: each iteration searches line `k` at the root with the first
  moves of lines `0..k-1` excluded (`Searcher.root_excluded`), each with its
  own aspiration window; lines are then sorted by score. Root TT stores are
  skipped for `k > 0` because those scores describe a restricted move set.
  With MultiPV 1 the search path is unchanged.
- **Root candidates**: `searchmoves` and the Syzygy DTZ filter narrow
  `Searcher.root_moves`; helpers receive the same candidates and exclusions.
- **Live feedback**: once a search has run for 3 s, the main thread also
  reports `info depth D currmove M currmovenumber N` as it starts each root
  move, and, with a single PV line, `lowerbound`/`upperbound` lines when an
  aspiration window fails high/low. Shorter searches print only one line per
  completed iteration (and MultiPV line).
- **Network name**: every `go` (and `eval`) starts with
  `info string NNUE evaluation using <name> (<architecture>, <size> MiB)`,
  where `<name>` is the stem of the `-Dnet` file the binary embeds (e.g.
  `dianguang-4`) or the file name of the network loaded with `EvalFile`.
- **EvalFile**: a file is validated (architecture, exact size, weight ranges)
  into a temporary buffer before it replaces the active network, so a bad file
  never leaves the engine without a network; cached accumulators are then
  refreshed. A network of the other head (single-layer or multi-layer, see
  [NNUE.md](NNUE.md)) is refused with `WrongArchitecture`. A single-layer file
  carries no architecture header, so a same-size network trained for a
  different input-bucket layout cannot be detected and would be accepted; only
  load networks trained for this build's architecture.
- Output lines use CRLF on Windows and the Stockfish field order
  (`depth seldepth multipv score [wdl] nodes nps hashfull tbhits time pv`),
  which some GUIs require to record PVs.
- `score cp` is normalized: `cp 100` is the internal score at which the side to move wins half of its
  games at ply 64 under the engine's win-rate model (`src/engine/wdl.zig`; 151 internal centipawns), as in
  Stockfish, so evaluations stay comparable across networks. `UCI_ShowWDL` permille, the `eval` command
  and the data written by `datagen` use the internal score. The model is a logistic in the score whose
  midpoint `a` and width `b` are cubics in `min(ply, 240) / 64`. To refit it for a new network, run
  `scripts/fit_wdl.py --data '<its training data>/*.viribin'` on held-out self-play chunks; it prints the
  two coefficient arrays and the calibration by score bucket.
