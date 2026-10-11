# UCI support

## Commands

| Command | Notes |
| --- | --- |
| `uci`, `isready`, `ucinewgame`, `quit` | standard |
| `setoption name <name> [value <value>]` | names are case-insensitive and may contain spaces; `value` with nothing after it sets an empty value |
| `position startpos\|fen <fen> [moves ...]` | FEN accepts X-FEN and Shredder castling fields |
| `go ...` | `wtime btime winc binc movestogo depth nodes movetime mate infinite ponder searchmoves`, in any combination |
| `stop`, `ponderhit` | accepted while searching, as are `isready` and `quit`; any other line that arrives during a search is answered with `info string ignored while searching` |
| `eval` | names the network, then prints the static evaluation of the current position from White's point of view: the network output, and the final score the search uses, after endgame handling and scaling |
| `d`, `perft N`, `perftdiv N`, `spsa`, `spsa++` | engine-specific |
| `genfens N seed S book <None\|path> [frc\|dfrc]` | prints `N` opening positions for OpenBench data generation, then exits |

Otherwise a line whose first word is not one of these commands is ignored.

## Command line

Without arguments the engine speaks UCI on standard input. A first argument that names a tool runs
that tool: `bench`; `datagen`, `tbfilter` and `netscale` ([DATAGEN.md](DATAGEN.md)); `nnue-parity`,
`nnue-random` and `nnue-speed` ([NNUE.md](NNUE.md)).

Any other arguments are UCI command lines, one per argument. They are run in order before standard
input is read, exactly as if they had been typed first; OpenBench relies on this
(`Avalanche "genfens 100 seed 1 book None" "quit"`). An argument whose first word is not a UCI
command is an error: nothing is run, a usage message goes to standard error and the exit status is
2, so a mistyped tool name cannot be mistaken for a successful run.

## Options

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| Hash | spin | 16 | MB, up to 1048576; up to 2047 on wasm, see [WASM.md](WASM.md) |
| Threads | spin | 1 | persistent helper pool, see [THREADS.md](THREADS.md); max 1 on wasm |
| NumaPolicy | combo | auto | `auto` binds search threads to NUMA nodes on multi-node Linux machines once there are too many for one node (docs/THREADS.md), `none` leaves placement to the OS; not offered by builds without threads (wasm) |
| Move Overhead | spin | 25 | ms; the former name `MoveOverhead` is still accepted |
| MultiPV | spin | 1 | up to 256 |
| Ponder | check | false | tells GUIs pondering is supported; setting it changes nothing, pondering itself is driven by `go ponder` |
| Clear Hash | button | | |
| UCI_Chess960 | check | false | king-captures-rook castling notation |
| UCI_LimitStrength | check | false | uses `UCI_Elo` instead of `Skill Level` |
| UCI_Elo | spin | 3000 | 1320–3000, see [STRENGTH.md](STRENGTH.md) |
| Skill Level | spin | 20 | 0–20 |
| SyzygyPath, SyzygyProbeDepth, SyzygyProbeLimit, Syzygy50MoveRule | | | tablebases; an empty `SyzygyPath` (or `<empty>`) unloads them; unavailable on wasm |
| EvalFile | string | `<embedded>` | load a network file at runtime (same architecture as the embedded net); `<embedded>` or an empty value restores the built-in net; unavailable on wasm |
| EvalScale | spin | 1000 | 500–2000, permille multiplier on the network output, see [DATAGEN.md](DATAGEN.md#network-eval-scale); changing it clears the hash |
| UCI_ShowWDL | check | false | |
| Contempt | spin | 0 | |

Tunable search parameters are also exposed as spin options for SPSA; their names are matched like the
others, without regard to case.

An option the build target cannot honour is neither advertised by `uci` nor accepted by `setoption`.
A failed `setoption` is reported as `info string setoption failed (<reason>): <the rest of the line>`:
`UnknownOption` when no option or tunable has that name, `InvalidValue` when the name is known and the
value does not fit its type. Spin values outside the advertised range are clamped to it.

`MultiPV`, `UCI_LimitStrength`, `UCI_Elo` and `Skill Level` are kept in `options.Settings` and read
when a `go` starts; every other option changes engine-wide state as soon as it is set.

## Search integration

- **Root position**: the engine starts at the starting position, and `ucinewgame` returns to it. In
  both cases the key of that position is already in the search history, as it is after `position`,
  so a `go` that is not preceded by `position` searches the same tree as `position startpos`
  followed by the same `go`.
- **Time**: `src/engine/uci/go.zig` turns a `go` command into a `TimeBudget`.
  Clock and `movetime` limits combine (the tighter wins); `depth`, `nodes` and
  `mate` are independent stop conditions. Without a clock or `movetime` the
  search ignores time. Out of the remaining clock time the budget keeps back
  `Move Overhead` plus 5 ms for each helper thread, 25 ms at most.
- **Unusual `go` values**: a `depth`, `nodes`, `movetime` or `mate` value that is not a number or
  is not positive becomes 1, the smallest limit, and never an unlimited search; a limit keyword
  that ends the line without a value is ignored. A clock at or below zero, which a GUI can send
  under lag, counts as 1 ms. `movestogo 0` means no `movestogo`. The budget arithmetic saturates,
  and a budget is never larger than that of a search without a clock, so clocks and increments up
  to the integer limits are safe. `searchmoves` takes the words after it for as long as they are
  legal moves, so other limits may follow the list.
- **Pondering**: `go ponder` sets `Searcher.shared.pondering`. While it is set, time
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
  A filter that would leave no move is ignored.
- **Live feedback**: once a search has run for 3 s, the main thread also
  reports `info depth D currmove M currmovenumber N` as it starts each root
  move, and `lowerbound`/`upperbound` lines when an aspiration window fails
  high/low. `D` is the depth of the iteration, also while an aspiration
  re-search runs at a lower depth. Bounds are reported only with a single PV
  line, as in Stockfish, because only then does the bounded score refer
  unambiguously to the line a GUI displays; a search with limited strength
  keeps several candidate lines and reports none. Shorter searches print
  only one line per completed iteration (and MultiPV line).
- **Network name**: every `go` (and `eval`) starts with
  `info string NNUE evaluation using <name> (<architecture>, <size> MiB)`,
  where `<name>` is the stem of the `-Dnet` file the binary embeds (e.g.
  `dianguang-5`) or the file name of the network loaded with `EvalFile`. As in
  Stockfish, this lets a log or a GUI show which network produced an analysis.
- **EvalFile**: a file is validated (architecture, exact size, weight ranges)
  into a temporary buffer before it replaces the active network, so a bad file
  never leaves the engine without a network; cached accumulators are then
  refreshed and the hash is cleared, because its entries hold static evaluations
  of the previous network. A position that already existed, such as a helper
  thread's copy of the root, follows the new network once its evaluation is
  rebuilt, which a helper does when it takes over the root of the next search.
  A network of the other head (single-layer or multi-layer, see
  [NNUE.md](NNUE.md)) is refused with `WrongArchitecture`. A single-layer file
  carries no architecture header, so a same-size network trained for a
  different input-bucket layout cannot be detected and would be accepted; only
  load networks trained for this build's architecture.
- Output lines use CRLF on Windows and the Stockfish field order
  (`depth seldepth multipv score [wdl] [lowerbound|upperbound] nodes nps hashfull tbhits time pv`),
  which some GUIs require to record PVs.
- `score cp` is normalized: `cp 100` is the internal score at which the side to move wins half of its
  games at ply 64 under the engine's win-rate model (139 internal centipawns), as in Stockfish, so
  evaluations stay comparable across networks. A tablebase win or loss is reported as `50000 - plies` to
  the conversion, with the sign of the result. `UCI_ShowWDL` permille, the `eval` command and the data
  written by `datagen` use the internal score. The permille are those of the side to move; a mate or
  tablebase score is shown as a certain win or loss and does not go through the model.

## Win-rate model

The model (`src/engine/wdl.zig`) is a logistic in the score whose midpoint `a` and width `b` are cubics
in `min(ply, 240) / 64`. The shipped coefficients were fitted on 13,000 games of the engine at 40+0.4,
their scores unscaled with the pawn value of the build that played them.

To refit it for a new network, run `python3 scripts/fit_wdl.py --data '<its training data>/*.viribin'`
on held-out self-play chunks, or `--format pgn --score-scale <PAWN_VALUE of the build that played the
games / 100>` on match games, whose scores are in UCI units. The script needs numpy, which
`uv run scripts/fit_wdl.py ...` supplies. It prints the two coefficient arrays and the calibration by
score bucket.

- **PGN input.** Every move comment has to start with the mover's score in pawns, as in
  `{+0.35/18 1.2s}`; a zero score may come without a sign. `{book}` moves are skipped, and a mate score
  counts as the score limit of 2000. The script prints how many comments had no score, so a format it
  does not read shows.
- **The fit** minimises the mean log-loss over a histogram of (ply, score) cells. It starts with Adam,
  which is cheap and tolerates the crude starting point, and finishes with damped Newton steps on a
  finite-difference Hessian of the analytic gradient.
- **bulletformat input** (`--format bullet`) is read as contiguous blocks of 65536 records at random
  offsets. That is an unbiased sample only of a file that is already shuffled, and far cheaper to read
  than scattered records. A record stores no ply, so this fit is against the piece count and is not
  the model `wdl.zig` uses.
