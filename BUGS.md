# Bugs

All entries below are **fixed**. The reported issue (#1) was the visible symptom; the
SMP crash (#2) and the stop/quit hang (#3) were uncovered while auditing the area.
`zig build test` is green (43/43) and `bench` is deterministic at the committed
`bench.nodes` (`35032097`).

## 1. PV continued after a threefold repetition (fixed)

Symptom — the search reported a PV that walked *through* a repeated position instead of
stopping at the draw:

```
Warning; PV continues after threefold repetition - move h3h4 from current
Info; info depth 23 ... score cp 0 pv h3h4 a6a4 h4h3 a4a6 h3h4 a6a4 h4h3 a4a6 h3h4
Position; fen r1bqkbnr/pppp1p1p/2n3p1/4p3/Q1P5/2N1P3/PP1P1PPP/R1B1KBNR w KQkq - 0 5
Moves; ... g2h3 h7h5
```

**Root cause — "phantom" en-passant in the hash.** The previous commit's en-passant
hash-leak fix made the Zobrist key correctly reflect the EP square *only* for the position
right after a double push. But `set_fen` and `play_move`'s `DOUBLE_PUSH` branch recorded
and hashed the EP square on *every* double push, even when no enemy pawn could actually
capture en passant. In the position above Black's last move `h7h5` set EP `h6`, yet no
white pawn is on g5 — the EP right is illusory. The hash still mixed in `EnPassantHash[h]`,
so the root position hashed differently from the *identical* position reached four plies
later (after the EP right silently expires), and `is_draw`'s repetition scan never matched
them. (The earlier hash-leak bug had masked this by smearing the stale EP key across every
later position, making the two accidentally agree.) Per the FIDE/Zobrist definition, an EP
square that cannot be captured is not part of the position.

**Fix** — `chess/position.zig`: in `set_fen` and `play_move`'s `DOUBLE_PUSH`, record/hash
the EP square only when a pawn of the side to move can actually capture it
(`get_pawn_attacks(pusher, ep) & enemy_pawns != 0`, matching the move generator's own EP
predicate and Stockfish). `undo_move`'s `DOUBLE_PUSH` branch was guarded to remove the EP
key only when it was recorded, keeping make/unmake symmetric. Verified: the phantom-EP root
now hashes identically to the EP-expired position, legitimate EP captures still hash and
generate normally, all perft counts are unchanged, and the depth-23 PV stops exactly at the
threefold.

## 2. Lazy-SMP double-join crash (fixed)

With more than one thread (`setoption name Threads value N`, `N > 1`) the engine aborted as
soon as the search advanced from depth 2 to depth 3:

```
setoption name Threads value 2 / position startpos / go depth 6
-> thread panic: reached unreachable code  (pthread_join on a reaped handle)
```

**Root cause.** `stop_helpers()` joined every helper thread but left the reaped
`std.Thread` handle in `threads.items[i]`. At the next depth, `helpers()` sees the slot is
non-null and joins it again; a second `pthread_join` returns `ESRCH`, which Zig's
`Thread.join` maps to `unreachable` (panic in ReleaseSafe, UB in ReleaseFast). CI never
caught it because the smoke test runs the default single-threaded (`Threads=1`, zero
helpers).

**Fix** — `engine/search.zig` `stop_helpers()`: set `threads.items[i] = null` after joining
each helper. Verified: `Threads 2/4/8` now search cleanly to high depth and across repeated
`go` commands.

## 3. UCI `stop`/`quit` hang from a lost-stop race (fixed)

A `stop` (or `quit`) arriving immediately after `go` could be ignored, and because the
recent commit made `stop`/`quit`/EOF *join* the search thread, the whole engine then hung
(e.g. `go infinite` never terminated).

**Root cause.** The worker reset `self.stop = false` at the start of `iterative_deepening`,
on the worker thread. The UCI `go` handler already clears `stop` before spawning, so the
worker's reset was redundant — and racy: if a `stop` landed after the handler's reset but
before the worker ran its own, the worker clobbered it and the search ran to full
depth/`infinite`. The pre-existing race was harmless when `stop` merely detached the worker;
once `stop`/`quit` started joining it, a lost stop became a hang.

**Fix** — `engine/search.zig`: don't reset `self.stop` in `iterative_deepening` (the `go`
handler clears it on the main thread before spawn; the non-UCI callers — datagen/bench/tests
— never set it). Also added a legal-move fallback before emitting `bestmove`, so an
immediate stop (before depth 1 finishes) yields a real move instead of the null `a1a1`.
Verified: `go infinite` + `stop` and `go ... ` + `quit` now terminate promptly with a legal
bestmove, while a normal timed/depth-limited search is unchanged.
