# Strength limiting

`Skill Level` (0–20) and `UCI_LimitStrength` + `UCI_Elo` weaken play. Level 20
(the default) is full strength and takes exactly the normal search path. With
`UCI_LimitStrength` enabled, `UCI_Elo` overrides `Skill Level`.

## Model (`src/engine/strength.zig`)

A limited engine at (possibly fractional) level `L`:

1. searches at most `1 + floor(L)` plies deep;
2. searches `max(MultiPV, 2 + floor((20 - L) / 3))` MultiPV lines, so weaker
   levels consider more candidates (`MIN_CANDIDATES` and
   `LEVELS_PER_EXTRA_CANDIDATE`). The extra candidate lines are searched but
   not reported: `info` lines show only the lines `MultiPV` asks for;
3. after the search, samples one candidate line with probability proportional
   to `exp(-(best - score) / T)` where `T = 2 + 0.6 * (20 - L)^2` centipawns
   (`BASE_TEMPERATURE` and `TEMPERATURE_PER_HANDICAP_SQUARED`; scores clamped
   to ±2000, `DECISIVE_CLAMP`, so mates stay comparable). `T` is the score gap
   at which a candidate becomes e times less likely. The quadratic keeps
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
fixed time control and fitting the level→Elo curve; the named constants at the
top of `strength.zig` (the ones above, `MIN_ELO` and `MAX_ELO`) are the knobs
to adjust.
