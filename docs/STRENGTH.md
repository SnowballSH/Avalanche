# Strength limiting

`Skill Level` (0–20) and `UCI_LimitStrength` + `UCI_Elo` weaken play. Level 20
(the default) is full strength and takes exactly the normal search path. With
`UCI_LimitStrength` enabled, `UCI_Elo` overrides `Skill Level`.

## Model (`src/engine/strength.zig`)

A limited engine at (possibly fractional) level `L`:

1. searches at most `1 + floor(L)` plies deep;
2. searches `max(MultiPV, 2 + floor((20 - L) / 3))` MultiPV lines, so weaker
   levels consider more candidates;
3. after the search, samples one candidate line with probability proportional
   to `exp(-(best - score) / T)` where `T = 2 + 0.6 * (20 - L)^2` centipawns
   (scores clamped to ±2000 so mates stay comparable). The quadratic keeps
   near-full levels from conceding even small gaps (level 19: `T = 2.6`)
   while level 0 (`T = 242`) picks almost uniformly among its candidates.

Low levels therefore both see little and often choose clearly inferior moves;
high levels almost always play the best move of a slightly shallower search.
The `ponder` move reported with `bestmove` comes from the chosen line.

## Elo mapping

`UCI_Elo` in `[1320, 3000]` maps linearly onto levels `[0, 20]`, so the
maximum (and default) Elo is full strength even when `UCI_LimitStrength` is
on. The mapping is **not calibrated** against a rating list; treat Elo values as a monotone
strength dial. Calibrating it requires gauntlets against anchored engines at a
fixed time control and fitting the level→Elo curve; the constants above are
the knobs to adjust.
