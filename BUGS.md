# Bug audit (logic bugs in the engine)

Findings from an adversarial, per-component audit of the engine logic (not just the
0.16 migration). Every claim below was re-verified against the current source; the
genuine bugs have now been **fixed and verified** (unit tests pass; the affected
repros were confirmed empirically).

**Bench impact.** The crash/robustness fixes do not change the fixed benchmark. The
four correctness fixes (move generation, en-passant hashing, SEE x-ray, TT mate
scores) legitimately change the deterministic search output, so the bench node count
moved from **`33745282`** to **`35183719`**. `bench.nodes` has been updated to match;
`zig build test` passes (43 tests).

## Fixed: crash / robustness (no change to bench)

These were already present in the source before this pass and do not affect normal
single-threaded play:

| file | bug |
| --- | --- |
| `engine/search.zig` | `stop_helpers` reused its loop counter, so the join loop never ran → the final helper-thread batch was never joined (leak + node-aggregation race). Reset `i = 0` between the loops. |
| `engine/search.zig` | Dead `bound == MAX_PLY - 1` branch (initializer is `MAX_PLY - 2`) disabled early-stop-on-forced-mate in `go infinite`. Fixed to `max_depth == null and bound == MAX_PLY - 2`. |
| `engine/search.zig` | Per-ply arrays (`pv`/`pv_size`/`killer`) were sized exactly `MAX_PLY` but indexed at `ply+1` at extreme ply → out-of-bounds in ReleaseFast. Sized to `MAX_PLY + 1`. |
| `engine/search.zig` | `const extra = NUM_THREADS - helper_searchers.items.len` underflows (usize) if `Threads` is reduced between searches. Guarded. |
| `engine/see.zig` | `see_score`: `max_depth` stays 0 → `max_depth - 1` underflows if a capture chain fills all 15 slots. Guarded. |
| `engine/tt.zig` | `reset()` did not zero the (re-used arena) backing store → garbage TT entries after a second `reset` (e.g. `setoption Hash`). Added `@memset(.., 0)`. |
| `engine/tt.zig` | `setoption Hash value 0` → size 0 → `index()` into an empty list → OOB crash. Clamped size to `@max(1, ..)`. |
| `engine/interface.zig` | `setoption Threads value 0` → `NUM_THREADS = value - 1` underflows → crash. Clamped to `@max(value, 1) - 1`. |
| `engine/datagen.zig` | datagen used a positional `file.writer()` (each game overwrote the previous one). Fixed to `writerStreaming`. |

## Fixed: correctness (changes bench → `35183719`)

Each of these is a genuine correctness bug whose fix changes search/eval output. They
were previously deferred for SPRT; they have now been applied. (Strength was **not**
re-tested with games per request — only bench + unit tests.)

### 1. Move generator omitted queen/rook/bishop promotion-captures for a pinned pawn — FIXED

A diagonally-pinned pawn capturing its pinner on the promotion rank generated **only the
knight** promotion-capture, because the pinned path used a single
`make_all(MoveFlags.PROMOTION_CAPTURES, ..)` and `PROMOTION_CAPTURES` (`0b1100`) aliases
`PC_KNIGHT`. Both pinned call sites — `generate_legal_moves` and `generate_q_moves` in
`chess/position.zig` — now emit all four (Q/R/B/N) via `new_from_to_flag`, matching the
non-pinned and in-check pinner paths.

Verified: `position fen 2b5/1P6/K7/8/8/8/8/7k w - -` → `perftdiv 1` now reports
`Total: 8` (`bxc8=Q/R/B/N` + 4 king moves), was `5`.

### 2. Zobrist en-passant hash leak — FIXED (with a correction to the originally-proposed patch)

The EP key XOR'd in on a double push was never XOR'd out by the next move, so positions
after any double push carried a stale EP component → wrong keys → degraded TT hits and
repetition detection. `play_null_move`/`undo_null_move` cleared EP correctly; real moves
did not.

Fix applied in `chess/position.zig`:
- **`play_move`**: after `self.history[self.game_ply] = UndoInfo.from(..)`, XOR out the
  previous ply's EP key if set (mirrors `play_null_move`).
- **`undo_move`**: after `self.game_ply -= 1`, XOR the restored position's EP key back in
  if set (mirrors `undo_null_move`).

> **Correction to the original recommendation:** an earlier draft of this fix said to
> *remove* the special-case EP toggle inside `undo_move`'s `DOUBLE_PUSH` branch. That is
> wrong — that toggle removes the double-push's *own* new EP key and must be **kept**.
> The correct fix keeps it and *adds* the post-decrement re-add of the previous EP key.

Verified: `position startpos moves e2e4 a7a6` now hashes identically to the same position
parsed fresh from FEN (`0x80e44cb9c6900229`); previously they differed by the e-file EP key.

### 3. SEE dropped the rook x-ray when a queen was captured — FIXED

`see_threshold` re-added x-ray attackers with `if (pt==0|2|4) bishop; else if (pt==3|4) rook;`
(piece encoding: pawn 0, knight 1, bishop 2, rook 3, queen 4, king 5). The `else if` meant a
captured **queen** (`pt==4`) only revealed diagonal x-rays, never orthogonal ones. Changed to
two independent `if`s, matching the cited Weiss source — a queen capture now reveals both.
(`engine/see.zig`)

### 4. TT mate-score store/probe asymmetry — FIXED

The TT probe converts mate scores toward the current node (`tt_eval -= ply` / `+= ply`), but
the store wrote `best_score` raw with no inverse conversion, so mate scores were off by the
storing ply when round-tripping the TT. The store now normalizes a **local copy** of
`best_score` (positive mate `+= ply`, negative mate `-= ply`, same thresholds as the probe)
before building the `tt.Item`; the returned `best_score` stays root-relative. (`engine/search.zig`)

## Fixed: UCI robustness / thread lifecycle (no change to bench)

These live only in the async UCI path (`bench` calls `iterative_deepening` synchronously and
never touches them), so they do not affect the bench node count.

- **Illegal/garbage move in `position … moves` no longer crashes.** `types.Move.new_from_string`
  now validates the coordinate token (length + char ranges) and returns the idiomatic
  `Move.empty()` sentinel (`to_u16() == 0`) on a malformed or non-legal move instead of reading
  out of bounds / `@enumFromInt`-out-of-range / `std.debug.panic`. The two `position … moves`
  loops stop applying moves when they hit the sentinel. (`chess/types.zig`, `engine/interface.zig`)
- **Search thread is joined before teardown / re-spawn.** The detached search thread was never
  joined, so EOF mid-search raced `deinit()` (use-after-free on `hash_history`/`continuation`/TT).
  The handle is now kept (not detached) and joined — after setting `stop` — on `stop`,
  `ucinewgame`, the next `go`, and the exit path (`join_search` helper). (`engine/interface.zig`)
- **`is_searching` is set before spawning** (not only inside the worker), closing the
  double-spawn window where a second `go` arriving before the worker started could pass the
  guard and spawn a second searcher on the same state. (`engine/interface.zig`)

## Not a bug

- **History malus on LMP-skipped quiets** (`engine/search.zig`): a quiet move is appended to the
  malus list before the late-move-pruning `continue`, so LMP-skipped quiets do receive a history
  malus. Re-verified as accurate, but this is a deliberate, pre-existing history-heuristic choice
  (identical across the 0.10.x→0.16 migration), not a correctness defect — no crash, no UB, and
  the history table was SPRT-tuned against exactly this behavior. **Left unchanged**; changing it
  would alter strength and must go through SPRT, not this pass.
- **NNUE output bias scaling** (`engine/nnue.zig`): the `layer_2_bias` is added at the same
  `QA²·QB` scale as the squared-clipped-ReLU dot product and descaled once (`/QA` then `/QAB`).
  This is the deliberate bullet quantization scheme the net was trained for (depth-9 output is
  bit-identical to the reference), not an extra-`QA` bug. **Do not change.**
