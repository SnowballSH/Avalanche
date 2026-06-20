# Avalanche NNUE Experiment Log

Architecture: 768 -> 512 -> 1x8 buckets, SCReLU, QA=255 / QB=64 / eval scale 400.
Trainer: bullet (Rust/CUDA). Reference net: bingshan.
Testing: 500 games at 10+0.1, 1 thread, 16 MB hash, UHO_4060_v4 book, against an engine built from
identical search code with only the net swapped, so each result isolates the net's strength.

## Summary

Earlier training on depth-9 (soft ~5000) self-play data plateaued at -12 to -18 Elo and was read as a
"student can't beat teacher" limit. It was a data-quality ceiling, not a fundamental one. Regenerating data
at soft_nodes=7500 with quiet-position filtering (no captures/promotions/checks, eval in [-2000, 2000];
1.344B positions in `data/training.bin`), the same recipe beats bingshan by up to +48 Elo. Eight distinct
nets beat bingshan.

## Results (512h unless noted; cosine LR 1e-3 -> 1e-7; AdamW; 500 games at 10+0.1)

200M positions per superbatch, so epochs = superbatches x 0.149 over the 1.344B-position set.

| Net | sb | epochs | WDL | Elo +/- CI | Score | LOS | Result |
|-----|----|--------|-----|------------|-------|-----|--------|
| jihan76 | 40 | 6.0 | 0.25 | +47.6 ± 20.0 | 56.80% | ~100%  | best |
| jihan83 | 40 | 6.0 | 0.25 | +38.4 ± 20.3 | 55.50% | 99.99% | reproduces jihan76 |
| jihan81 | 35 | 5.2 | 0.25 | +37.0 ± 18.8 | 55.30% | 99.99% | beats (shorter run) |
| jihan75 | 54 | 8.0 | 0.25 | +20.2 ± 19.3 | 52.90% | —      | beats |
| jihan85 | 40 | 6.0 | 0.30 | +19.5 ± 18.8 | 52.80% | 97.9%  | beats |
| jihan74 | 47 | 7.0 | 0.25 | +11.1 ± 19.8 | 51.60% | —      | beats |
| jihan82 | 40 | 6.0 | 0.20 | +10.4 ± 20.1 | 51.50% | 84.6%  | beats |
| jihan84 | 44 | 6.5 | 0.25 |  +8.3 ± 19.8 | 51.20% | 79.5%  | beats |
| jihan80 | 30 | 4.5 | 0.25 |  +4.9 ± 19.5 | 50.70% | —      | parity (underfits) |
| jihan86 | 40 | 6.0 | 0.40 |  -3.5 ± 20.1 | 49.50% | —      | loses (WDL too high) |
| jihan77 | 47 | 7.0 | 0.25 | -15.3 ± 19.7 | 47.80% | —      | loses (768h, slower) |

(jihan87, 40 sb / WDL 0.35, was trained but not tested; it is bracketed by 0.30 -> +19.5 and 0.40 -> -3.5.)

## Findings

1. Data depth is the main lever. Going from soft 5000 to 7500 nodes plus quiet filtering moved the same
   recipe from -18 to +48 Elo. Per-position eval quality was the bottleneck, not the training schedule.
2. Superbatch length has a broad peak at 35-40 (about 6 epochs), dropping sharply below 35 (30 -> +5,
   underfit) and gently above. Curve at WDL 0.25: 30 -> +5, 35 -> +37, 40 -> +43 avg, 44 -> +8, 47 -> +11,
   54 -> +20. Richer data overfits faster, so fewer epochs generalize better.
3. WDL has a sharp peak at 0.25. At 40 sb: 0.20 -> +10, 0.25 -> +43 avg, 0.30 -> +19, 0.40 -> -3.5. Weighting
   game results more heavily hurts, because the result is a noisier target than the eval.
4. 768h loses at this time control: it is ~28% slower in nps, and the extra eval quality does not pay for the
   lost search depth at 10+0.1. 512h is the right size for STC; 768h may still help at longer time controls.
5. The best recipe reproduces: 40 sb / WDL 0.25 gave +48 (jihan76) and +38 (jihan83), both at LOS ~100%.

## Best recipe

    HIDDEN=512, batch=16384, batches/sb=12208 (200M/sb), superbatches=40 (6 epochs over 1.344B),
    WDL=0.25, CosineDecayLR 0.001 -> 1e-7 over 40 sb, AdamW.

To go further, generate deeper data (higher soft_nodes) and keep quiet filtering. Avoid more than ~50
superbatches (overfits), WDL above 0.25, or 768h at short time control.

## Tooling

- The trainer (`training/src/main.rs`) reads every hyperparameter from `TRAIN_*` env vars, so no recompile is
  needed between runs: `TRAIN_NET_ID`, `TRAIN_HIDDEN`, `TRAIN_SUPERBATCHES`, `TRAIN_WDL` (and `TRAIN_WDL_END`
  for a linear schedule), `TRAIN_LR_INITIAL`/`_FINAL`, `TRAIN_BATCH_SIZE`, `TRAIN_BATCHES_PER_SB`,
  `TRAIN_SAVE_RATE`, `TRAIN_THREADS`. HIDDEN is a runtime argument; only the engine's `weights.zig` is
  compile-time for the architecture.
- `build.zig` takes `-Dnet=<path>` to embed any `.nnue`. `scripts/build_net_engine.sh <net> <name> [hidden]`
  builds an engine for a given net; `scripts/match.sh <cand> <ref> [games] [conc] [tc] [tag]` runs a match.
- When reading fastchess output, the "Results of ..." block prints every `ratinginterval` games; only trust
  it once it shows the full game count and the log contains "Finished match".

## Earlier work (depth-9 / soft ~5000 data) — superseded

The best result on the old data was -12 to -18 Elo (40 sb, WDL 0.25, 1050-game SPRT); no net beat bingshan,
which pointed to data quality as the limit. Carried-over lessons: overfitting is the main failure mode
(200-400 sb is far too long); cosine LR clearly beats step LR; WDL 0.25 is best and 0.75 is much worse;
256h/384h are too small; the LR must decay to near zero at the final superbatch. Shallow soft-5000 data
mixed in actively hurt.
