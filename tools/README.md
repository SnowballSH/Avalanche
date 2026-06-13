# Avalanche testing tools

## `tools/test` — SPRT match runner

A friendly wrapper around [fastchess](../fastchess) for running SPRT matches of the
**current working tree** against either a **previous git commit** (built automatically) or a
**foreign UCI engine**. It runs on [pypy3](https://pypy.org/) via [uv](https://docs.astral.sh/uv/);
`tools/test` is a thin shell wrapper, the logic lives in `tools/sprt.py` (standard library only).

### Prerequisites

- `uv` (it will fetch a pypy3 toolchain on first run),
- `zig` 0.16.0 (to build the engines),
- the bundled `fastchess/fastchess` binary,
- an opening book at `books/noob_4moves.epd` (see [books/README.md](../books/README.md)),
  or pass `--book <path>`.

### Time-control presets

| preset | time control | threads | parallelism |
| --- | --- | --- | --- |
| `stc` | 10s + 0.1s  | 1 | games run in parallel (cores − 2) |
| `ltc` | 60s + 0.6s  | 1 | games run in parallel (cores − 2) |
| `smp` | 30s + 0.3s  | 4 | one game at a time |

Override any piece with `--tc-string`, `--threads`, `--hash`, `--concurrency`.

### SPRT bounds presets

| preset | bounds | meaning |
| --- | --- | --- |
| `gain` (default) | `[0, 5]` | is the new version stronger? |
| `regression`     | `[-5, 0]` | did we avoid a regression? |

`alpha`/`beta` default to `0.05`. Override with `--elo0/--elo1/--alpha/--beta`.

### Usage

```sh
# Current working tree vs the previous commit, STC, "is it a gain?" SPRT:
tools/test vs-commit HEAD~1

# Long time control, non-regression bounds, vs a tag:
tools/test --tc ltc --bounds regression vs-commit v2.1.0

# 4-thread SMP test vs a branch:
tools/test --tc smp vs-commit some-branch

# Current vs a foreign engine:
tools/test vs-engine /path/to/stockfish --name stockfish

# Just build a ref and print its binary path (current tree if no ref):
tools/test build HEAD~5
tools/test build
```

The SPRT runs until it crosses a bound (or `--max-rounds` is hit) and streams fastchess's
rolling Elo/LLR live. Add `--pgn games.pgn` to save the games, or `--extra "..."` to append
raw fastchess arguments.

### How "vs a commit" works

`vs-commit <ref>` resolves the ref to a commit, builds it in a throwaway `git worktree`, and
caches the resulting binary under `.sprt-cache/bin/Avalanche-<sha>` (so re-tests are instant).
The current side is always rebuilt from the working tree, so it includes uncommitted changes.
A ref only works if it builds with the current Zig toolchain (so comparing against the
pre-migration 0.10.x history will not build).

> Tip: when a change legitimately alters the bench node count, run `scripts/update_bench.sh`
> and commit `bench.nodes` so CI keeps asserting the right value.
