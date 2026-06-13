# Bug audit (logic bugs in the engine)

Findings from an adversarial, per-component audit of the engine logic (not just the
0.16 migration). Split into **fixed** (safe, no change to playing strength — `bench`
still reports `33745282 nodes`), **recommended** (genuine correctness bugs that *do*
change playing strength, so they are SPRT-gated and left for you to apply + test), and
**rejected** (not actually bugs).

## Fixed (safe — applied; bench unchanged at 33745282)

These are crash/robustness/resource fixes that do not affect normal single-threaded play:

| file | bug |
| --- | --- |
| `engine/search.zig` | `stop_helpers` reused its loop counter, so the join loop never ran → the final helper-thread batch was never joined (leak + node-aggregation race). Reset `i = 0` between the loops. |
| `engine/search.zig` | Dead `bound == MAX_PLY - 1` branch (initializer is `MAX_PLY - 2`) disabled early-stop-on-forced-mate in `go infinite`. Fixed to `max_depth == null and bound == MAX_PLY - 2`. |
| `engine/search.zig` | Per-ply arrays (`pv`/`pv_size`/`killer`) were sized exactly `MAX_PLY` but indexed at `ply+1`/`MAX_PLY` at extreme ply → out-of-bounds in ReleaseFast. Sized to `MAX_PLY + 1`. |
| `engine/search.zig` | `const extra = NUM_THREADS - helper_searchers.items.len` underflows (usize) if `Threads` is reduced between searches. Guarded. |
| `engine/see.zig` | `see_score`: `max_depth` stays 0 → `max_depth - 1` underflows if a capture chain fills all 15 slots. Guarded. |
| `engine/tt.zig` | `reset()` did not zero the (re-used arena) backing store → garbage TT entries after a second `reset` (e.g. `setoption Hash`). Added `@memset(.., 0)`. |
| `engine/tt.zig` | `setoption Hash value 0` → size 0 → `index()` into an empty list → OOB crash. Clamped size to `@max(1, ..)`. |
| `engine/interface.zig` | `setoption Threads value 0` → `NUM_THREADS = value - 1` underflows → crash. Clamped to `@max(value, 1) - 1`. |

Also: the migration bug where datagen used a positional `file.writer()` (each game
overwrote the previous one) was fixed to `writerStreaming` (verified: 50 games now
accumulate ~3700 lines instead of one game's worth).

## Recommended (SPRT-gated — NOT applied)

Each of these is a genuine correctness bug, but fixing it changes search/eval output and
therefore playing strength. Per standard engine testing, apply each as its own commit and
SPRT it before trusting (use `tools/test`, e.g. `tools/test vs-commit <parent-commit>`).

### 1. Move generator omits queen/rook/bishop promotion-captures for a pinned pawn (verified)

A diagonally-pinned pawn capturing its pinner on the promotion rank generates **only the
knight** promotion-capture. Verified: `position fen 2b5/1P6/K7/8/8/8/8/7k w - -` →
`perftdiv 1` reports `Total: 5` (only `b7c8N`); it should be `8` (`bxc8=Q/R/B/N` plus 4
king moves). The pinned path uses one `make_all(MoveFlags.PROMOTION_CAPTURES, ..)` (a
single flag = knight) whereas the non-pinned path emits all four.

Fix — `chess/position.zig`, in `generate_legal_moves` (~line 719-720) and
`generate_q_moves` (~line 1010-1011), replace the single `make_all(.. PROMOTION_CAPTURES ..)`
with the four-fold emission used elsewhere:

```zig
while (b2 != 0) {
    const t = types.pop_lsb(&b2);
    list.append(types.Move.new_from_to_flag(sq, t, @as(types.MoveFlags, @enumFromInt(types.PC_QUEEN)))) catch {};
    list.append(types.Move.new_from_to_flag(sq, t, @as(types.MoveFlags, @enumFromInt(types.PC_ROOK)))) catch {};
    list.append(types.Move.new_from_to_flag(sq, t, @as(types.MoveFlags, @enumFromInt(types.PC_KNIGHT)))) catch {};
    list.append(types.Move.new_from_to_flag(sq, t, @as(types.MoveFlags, @enumFromInt(types.PC_BISHOP)))) catch {};
}
```

(Only adds legal moves, so it can only help; still SPRT it. Re-run `scripts/update_bench.sh`
afterwards — the node count will change.)

### 2. Zobrist en-passant hash leak (verified)

The EP hash XOR'd in on a double push is never XOR'd out by the next move, so positions
reached after any double push carry a stale EP component → wrong keys → degraded TT
transposition hits and repetition detection. Verified: `startpos moves e2e4 a7a6` hashes
to `0xd16e…` while the same position parsed fresh hashes to `0x80e4…` (differ by exactly
the e-file EP key). `play_null_move`/`undo_null_move` already clear EP correctly; real
moves do not.

Fix — `chess/position.zig`, in `play_move`, right after
`self.history[self.game_ply] = UndoInfo.from(self.history[self.game_ply - 1]);` add:

```zig
if (self.history[self.game_ply - 1].ep_sq != types.Square.NO_SQUARE)
    self.hash ^= zobrist.EnPassantHash[self.history[self.game_ply - 1].ep_sq.file().index()];
```

and symmetrically re-add it at the end of `undo_move` (after `game_ply` is decremented),
removing the now-redundant special-case toggle inside `undo_move`'s `DOUBLE_PUSH` branch.

### 3. SEE drops the rook x-ray when a queen is captured

`see_threshold` re-adds x-ray attackers with `if (pt==0|2|4) bishop; else if (pt==3|4) rook;`
— the `else if` means a captured **queen** (`pt==4`) only reveals diagonal x-rays, never
orthogonal ones (and the `pt==4` in the second clause is dead). Weiss (the cited source)
uses two independent `if`s.

Fix — `engine/see.zig` (~line 121-125): make the two re-adds independent `if`s (not `else if`).

### 4. TT mate-score store/probe asymmetry

The TT probe converts mate scores toward the current node (`tt_eval -= ply` / `+= ply`),
but the store writes `best_score` raw without the inverse conversion, so mate scores are
off by the storing ply when they pass through the TT (the root masks reported mate
distances, which is why it survived testing).

Fix — `engine/search.zig`, just before building the `tt.Item` (~line 858), make the stored
eval node-relative:

```zig
var stored_eval = best_score;
if (stored_eval > hce.MateScore - hce.MaxMate and stored_eval <= hce.MateScore)
    stored_eval += @as(i32, @intCast(self.ply))
else if (stored_eval < -hce.MateScore + hce.MaxMate and stored_eval >= -hce.MateScore)
    stored_eval -= @as(i32, @intCast(self.ply));
// ... .eval = stored_eval
```

### Lower-confidence / robustness (also not applied)

- `engine/search.zig`: history malus is applied to quiet moves that were LMP-skipped (never
  searched). Possibly intentional; SPRT if changed.
- `engine/interface.zig`: the detached search thread is never joined before `deinit()`
  (use-after-free if `quit`/EOF arrives mid-search), `is_searching` is set inside the worker
  (a double-spawn race window), and an illegal move in `position … moves` panics the whole
  engine. These need a small thread-lifecycle/input-validation refactor; left out to avoid
  introducing a UCI-loop deadlock without testing.

## Rejected (not a bug)

- **NNUE output bias scaling** (`engine/nnue.zig`): an audit flagged the `layer_2_bias`
  as being divided by an extra `QA`. This is the engine's deliberate quantization scheme —
  the net was trained/selected for exactly this arithmetic, so "fixing" it would change
  every eval and almost certainly require retraining. Not a bug; do not change.
