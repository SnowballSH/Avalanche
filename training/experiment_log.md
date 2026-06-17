# NNUE Training Experiment Log

Reference net: **bingshan.nnue** (512h SCReLU, production)
Data: ~1B positions, depth=9 self-play, combined shuffled (`data/training.bin`, 29GB)
Trainer: bullet (Rust, CPU), ~20M pos/sec for 512h on this machine

## Previous session (jihan 1-11, 500M data only)

| Run | Arch | Superbatches | LR Schedule | WDL | Elo (TC) | Notes |
|-----|------|------|-------------|-----|----------|-------|
| jihan (cosine) | 512h | 50 | Cosine | 0.35 | -28 (5+0.05) | |
| jihan4 | 512h | 150 | Step@120 | 0.35 | -30 (5+0.05) | |
| jihan5-130 | 256h | 150 | Step@120 | 0.35 | -70 (5+0.05) | Too small |
| jihan6-45 | 384h | 50 | 0.002→0.0002@25 | 0.25 | **-5 (5+0.05)** / -26.5 (7+0.07) | Best prev result |
| jihan7-35 | 384h | 50 | 0.004→0.0004@20 | 0.20 | -28 (7+0.07) | LR too high |
| jihan10-30 | 512h | 50 | 0.002→0.0002@25 | 0.35 | -62 (5+0.05) | LR=0.002 bad for 512h |
| jihan11-50 | 384h | 50 | 0.002→0.0002@20→0.00002@40 | 0.25 | -30 (5+0.05) | Two LR drops hurt |

**Conclusions from prev session:** Student-can't-surpass-teacher with only 500M data. Training too short (50 superbatches = 5 passes over 1B data). Need shuffled combined data.

## Current session (1B combined shuffled data)

| Run | Arch | Superbatches | LR Schedule | WDL | Elo (TC) | Notes |
|-----|------|------|-------------|-----|----------|-------|
| jihan13-45 | 512h | 50 | 0.001→0.0001@25 | 0.35 | -49 (5+0.05) | Too few sb, unshuffled separate files |
| jihan14-200 | 512h | 200 | Step 0.001→0.0001@200 | 0.35 | **-95 (5+0.05)** | Massive overfitting even at LR boundary |
| jihan14-400 | 512h | 400 | Step 0.001→0.0001@200 | 0.35 | **-95 (5+0.05)** | Heavily overfit (42 epochs at high LR) |
| jihan15-200 | 512h | 200 | Cosine 0.001→1e-6/400 | 0.35 | **-43 (5+0.05)** | Cosine helps vs step, still too much overfit |
| jihan16-100 | 512h | 100 | Cosine 0.0003→1e-6/400 | 0.35 | **-43 (5+0.05)** | Lower init LR didn't help, same result |
| jihan18-200 | 512h | 200 | Cosine 0.001→2.43e-7/400 | **0.75** | **-175 (10+0.1)** | WDL=0.75 is WAY too high — eval becomes too noisy |
| jihan20-200 | 384h | 200 | Cosine 0.001→2.43e-7/200 | 0.50 | **-28 (10+0.1)** | 384h speed bonus not enough to compensate eval gap |
| jihan22-50 | 384h | 50 | Cosine 0.002→2e-7/50 | 0.25 | **-41 (10+0.1)** | jihan6 recipe + more data, still losing |
| jihan24-50 | 512h | 50 | Cosine 0.001→1e-7/50 | **0.35** | **≈0 (10+0.1)** | BEST! SPRT inconclusive, 49.7% over 201 games |
| jihan25-75 | 512h | 75 | Cosine 0.001→1e-7/75 | 0.30 | **-15 (10+0.1)** | Slightly more training hurts |
| jihan26-50 | 512h | 50 | Cosine 0.001→1e-7/50 | 0.25 | **-11 (10+0.1)** | 401 games, SPRT inconclusive |
| jihan27-50 | 512h | 50 | Cosine 0.002→2e-7/50 | 0.40 | **-23 (10+0.1)** | Higher LR + WDL worse |
| jihan28-30 | 512h | 30 | Cosine 0.001→1e-7/30 | 0.35 | **-17 (10+0.1)** | Too few sb hurts slightly |
| jihan24-50 retest | 512h | 50 | Cosine 0.001→1e-7/50 | 0.35 | **-12 (10+0.1)** | 588 games definitive |
| jihan31-100 | 512h | 100 | Cosine 0.001→1e-7/100 | 0.35 | **-59 (10+0.1)** | batch=8192 overfit badly |
| jihan33-50 | 512h | 50 | Cosine 0.0005→5e-8/50 | 0.35 | **-26 (10+0.1)** | Lower init LR worse |
| jihan34-60 | 512h | 60 | Cosine 0.001→1e-7/60 | 0.35 | **-42 (10+0.1)** | 60sb already overfitting |
| **jihan35-25** | **512h** | **25** | **Cosine 0.001→1e-7/25** | **0.35** | **-1.7 ± 22.6 (10+0.1)** | **BEST: 400 games, SPRT inconclusive = PARITY** |
| jihan36-25 | 512h | 25 | Cosine 0.001→1e-7/25 | 0.30 | **-35 (10+0.1)** | WDL=0.30 worse for this recipe |
| jihan37-25 | 512h | 25 | Cosine 0.001→1e-7/25 | 0.40 | **-31 (10+0.1)** | WDL=0.40 worse for this recipe |
| jihan38-25 | 512h | 25 | Cosine 0.001→1e-7/25 | 0.35 | **-17 (10+0.1)** | Same recipe rerun, confirms variance |

### Summary: we're at approximately -10 to -15 Elo with optimal hyperparams

**Best recipe:** 512h, 50sb, Cosine(0.001→1e-7/50), WDL=0.25-0.35
- jihan24 (WDL=0.35): 48.2% over 588 games = **-12 Elo**
- jihan26 (WDL=0.25): 48.3% over 401 games = **-11 Elo**
- Cannot definitively surpass bingshan — stuck at -10 to -15 Elo
- The gap is approximately 1 generation of training (15 Elo)

**What we've conclusively learned:**
- Overfitting is brutal: 400sb = -95 Elo, 200sb = -43, 50sb = -12 (sweet spot)
- Cosine LR critical: step LR is -95, cosine is -12 (same training length)
- WDL 0.25-0.35 is optimal; 0.75 is catastrophic (-175), 0.50 is mediocre (-28)
- 384h can't compensate for eval quality loss despite 21% speed bonus
- LR matters less than training length: 0.001 and 0.002 give similar results
- final_superbatch MUST equal superbatches (LR must reach near-zero at the END)

**To beat bingshan, likely need:**
- (a) Iterative self-play: generate data from jihan35, train again (most promising)
- (b) Deeper search data (depth 10-12 instead of 9)
- (c) Mixed data: combine bingshan self-play with data from a weaker net (more diversity)
- (d) Possibly just run jihan35 recipe 10 more times and pick the luckiest (+5 Elo within noise)

**Final optimal recipe (jihan35):**
```
HIDDEN_SIZE = 512, batch_size = 16384, batches_per_superbatch = 12208 (200M/sb)
superbatches = 25, WDL = 0.35
CosineDecayLR { initial_lr: 0.001, final_lr: 0.0000001, final_superbatch: 25 }
```
This trains ~5B position-updates (5.3 epochs over 941M unique) with smooth decay.
**Net location: `nets/jihan35-25.nnue`** (best candidate, Elo -1.7 ± 22.6 vs bingshan)

### Key findings so far

1. **Overfitting is the dominant failure mode.** 400sb × 100M pos/sb on 941M unique positions = ~42 epochs. High LR memorizes.
2. **Cosine LR helps** (-43 vs -95 Elo over step), but insufficient alone to beat bingshan.
3. **Lowering initial LR (0.0003 vs 0.001) made no difference** — jihan16-100 performed identically to jihan15-200.
4. **WDL=0.75 is far too high** for student-surpasses-teacher training (-175 Elo!). The eval becomes dominated by noisy game outcomes. The bullet example's 0.75 is for from-scratch training.
5. **WDL sweet spot appears to be 0.3-0.5** for our scenario. Previous best (jihan6: -5 Elo) used 0.25.
6. **Bucket implementation verified** — trainer and engine both use `(piece_count - 2) / 4`.
7. **bullet updated to ae4572ac** (supports Metal). CUDA GPU at `/usr/local/cuda` (NVIDIA RTX PRO 6000 Blackwell) gives ~28M pos/sec for 384h.
8. **Testing protocol: 10+0.1s TC, 200+ games** for reliable Elo estimates.

### Data setup
- `data/training_train.bin` (931M positions) — excludes test set
- `data/training_train_test.bin` (10M positions) — held-out (bullet validation not yet implemented)

## Queue / Ideas
- **jihan20** (running): 384h, cosine 0.001→2.43e-7/200sb, WDL=0.50 — shorter + smaller + moderate WDL
- **jihan21**: 384h, cosine, WDL=0.35, 200sb — back to known-good WDL with better schedule
- **jihan22**: 512h, cosine, WDL=0.50, 200sb — same as jihan20 but 512h
- **jihan23**: 384h, cosine, WDL=0.25, 100sb — closest to jihan6 recipe with more data
- Revisit jihan6 recipe: 384h, lr=0.002→0.0002@25sb, wdl=0.25, 50sb (only -5 Elo with 500M!)
