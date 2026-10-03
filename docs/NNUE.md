# NNUE

Avalanche has one feature transformer and two output heads. A build runs one head, fixed at compile
time.

| Head | Network | Selected by |
|---|---|---|
| single | `(768x16hm -> 1024)x2 -> SCReLU -> 1x8` | `-Dhead=single`, `TRAIN_ARCH=single` |
| multi (default build) | `(768x16hm -> 1024)x2 -> pairwise CReLU -> L1(1024 -> 16) -> [CReLU, CReLU²] -> L2(32 -> 32) CReLU -> L3(32 -> 1)`, L1 to L3 x8 | `-Dhead=multi`, `TRAIN_ARCH=multi` |

`-Dhead` defaults to `auto`: the head of the `-Dnet` file, recognised by its header. So
`zig build -Dnet=multi.nnue` and `make EVALFILE=multi.nnue` build a multi-layer engine with no other
flag, and the default build (`nets/dianguang-3.nnue`) is multi-layer. An explicit `-Dhead` that
contradicts the file is a compile error.

`setoption name EvalFile` loads a network of the build's architecture. A file of the other
architecture is refused with `WrongArchitecture`, and a file that is neither (truncated, garbage)
with `NotANetwork` in a multi-layer build or `WrongSize` in a single-layer one. The current network
stays in use.

Code: `src/engine/nnue.zig` (accumulators), `src/engine/nnue/head_single.zig`,
`src/engine/nnue/head_multi.zig`, `src/engine/weights.zig` (file layouts, loading),
`training/src/main.rs` and `training/src/multilayer.rs` (trainer).

## Shared by both heads

- **Inputs.** 768 piece-square features per king bucket, 16 king buckets with horizontal mirroring
  (bullet's `ChessBucketsMirrored`, layout `BUCKET_LAYOUT_16`). For a perspective, with squares
  flipped vertically for black, the king on `k` and `m = 7` if the king is on files e to h, else 0:
  `feature = 768 * bucket[k] + 384 * [piece is the opponent's] + 64 * piece_type + (square ^ m)`.
- **Accumulator.** Per perspective, `acc[i] = l0b[i] + sum over active features f of l0w[f][i]`,
  i16, `i < 1024`. Quantised by `QA = 255`: 255 is 1.0.
- **Output bucket.** `b = min((piece_count - 2) / 4, 7)`.
- **Perspectives.** `own` is the accumulator of the side to move, `opp` the other one. The result
  is in centipawns for the side to move. `SCALE = 400`.

**Accumulator updates** (`src/engine/nnue.zig`). A move writes its position's accumulators into
the next frame of a stack, each perspective in one pass: the parent's values plus the rows of the
features that appeared, minus those that disappeared (two rows for a quiet move, three for a
capture). When a king moves to another bucket or crosses the mirror line, every feature of that
king's perspective changes. That perspective is then not updated at all: it is rebuilt from the
"Finny table", a cache with one accumulator per perspective, mirror side and bucket and the piece
sets it was computed for. The rebuild adds and removes only the rows by which the position
differs from the cached one, and writes the result to the cache and to the frame in the same pass.
Wrapping arithmetic makes the order of the additions irrelevant.

All integers in a file are little-endian. bullet pads a file with the bytes `bullet...` to a
multiple of 64 bytes; the engine ignores the padding.

## Single-layer head

```
s   = sum over i < 1024 of clamp(own[i], 0, 255)² * w[b][i] + clamp(opp[i], 0, 255)² * w[b][1024 + i]
out = trunc((trunc(s / 255) + bias[b]) * 400 / (255 * 64))
```

`trunc` is division rounding toward zero. `QB = 64`.

| Offset | Section | Type | Count | Quantisation |
|---|---|---|---|---|
| 0 | `l0w[feature][i]` | i16 | 12288 x 1024 | 255 |
| 25165824 | `l0b[i]` | i16 | 1024 | 255 |
| 25167872 | `w[bucket][j]`, own then opp | i16 | 8 x 2048 | 64 |
| 25200640 | `bias[bucket]` | i16 | 8 | 255 * 64 |
| 25200656 | padding | | 48 bytes | |

Total 25200704 bytes, no header. Invariant the loader checks: every output weight is in
[-128, 127]. The SIMD path multiplies `activation * weight` in i16, and 255 * 127 is the largest
product that fits.

## Multi-layer head

### Constants

| Name | Value | Meaning |
|---|---|---|
| `QA` | 255 | accumulator 1.0 |
| `FT_SHIFT` | 9 | pairwise product shift |
| pairwise 1.0 | 255² / 2⁹ = 127.002 | integer value of a pairwise product of 1.0 |
| `ACT_BITS` | 13 | fixed point of the L1 output and of every later activation: 8192 is 1.0 |
| `L1_WEIGHT_SCALE` | 2²² / 255² = 64.5027 | an L1 weight is stored as `round(w * 64.5027 * 2^e)` |
| `e`, the L1 shift | 0..7, per network, in the header | extra fixed-point bits of the L1 weights, bias and sum |
| `WEIGHT_BITS` | 10 | fixed point of L2 and L3 weights: 1024 is 1.0 |
| `SUM_BITS` | 23 | fixed point of L2 and L3 biases and sums |
| `SCALE` | 400 | centipawns per unit of output |

`L1_WEIGHT_SCALE` is chosen so that, at `e = 0`, `stored weight * stored activation = w * a * 2¹³`
exactly: `64.5027 * 127.002 = 8192`. The L1 sum is then a plain Q13 number.

**The L1 shift.** An i8 at scale 64.5 covers weights up to ±1.97, but the L1 weights of a trained
net are much smaller: the first net trained on a GPU had a largest `|l1w|` of 0.2166, 14 of 127
levels, and the rounding of those weights alone cost 23 cp on average against the trainer. So the
scale is per network. The trainer saves with the largest `e` in 0..7 at which every stored L1
weight still fits an i8 (`round(max|w| * 64.5027 * 2^e) <= 127`), which puts the largest weight at
64..127 levels; it stores `e` in the header and the L1 bias at the same scale. The L1 sum is then a
Q(13 + e) number, and the engine rounds it back to Q13 with one shift on 16 values. Everything
after that is the same for every network.

`e` stops at 7: a net that would take more has no L1 weight above 0.0154, which is not a net worth
storing better, and the cap keeps the bias range wide (see Invariants). L2 and L3 need no such
thing. Their weights are i32 at Q10, so a weight is rounded by at most 2⁻¹¹ whatever its size, and
there are only 32 inputs per sum, against 1024 for L1: the same GPU net used 1068 and 857 of 2047
levels there, and the float comparison with the engine's pairwise products, which contains all of
the L2 and L3 arithmetic, was within 0.54 cp.

### Integer formula

`>>` is an arithmetic shift (rounds toward minus infinity), so `(x + 2^(n-1)) >> n` rounds to
nearest, halves up. Everything is i32 except the last line.

```
1. Pairwise, 1024 values in 0..127, own first:
     p[i]       = (clamp(own[i], 0, 255) * clamp(own[i + 512], 0, 255) + 256) >> 9     i < 512
     p[512 + i] = (clamp(opp[i], 0, 255) * clamp(opp[i + 512], 0, 255) + 256) >> 9

2. L1, for j < 16, with the network's shift e:
     s[j]  = l1b[b][j] + sum over i < 1024 of p[i] * l1w[b][i / 4][j][i % 4]
     z1[j] = (s[j] + ((1 << e) >> 1)) >> e                  (z1 = s when e = 0)

3. Dual activation, 32 values in 0..8192:
     c[j]      = clamp(z1[j], 0, 8192)
     h[j]      = c[j]
     h[16 + j] = (c[j] * c[j] + 4096) >> 13

4. L2, for o < 32:
     z2[o] = l2b[b][o] + sum over k < 32 of h[k] * l2w[b][k][o]
     a[o]  = clamp((z2[o] + 512) >> 10, 0, 8192)

5. L3:
     z3 = l3b[b] + sum over o < 32 of a[o] * l3w[b][o]

6. Centipawns, in i64:
     out = (z3 * 400 + 2^22) >> 23
```

Float meaning, which is the trainer's forward pass: with `x = acc / 255`,
`p = crelu(x[i]) * crelu(x[i + 512])`, `z1 = W1 p + b1`, `h = [crelu(z1), crelu(z1)²]`,
`a = crelu(W2 h + b2)`, `out = 400 * (W3 a + b3)`, where `crelu(v) = clamp(v, 0, 1)`.

Why 0..127 for the pairwise activations and not 0..255:

- NEON `sdot` is signed x signed, so activations up to 127 run on every ARMv8.2 core; 0..255 would
  need `usdot` (the i8mm extension, absent on Apple M1).
- x86 `pmaddubsw` adds two u8 x i8 products with signed saturation. With activations up to 127 the
  largest sum is `2 * 127 * 128 = 32512 < 32767`, so it cannot saturate. That is what makes the x86
  path equal to the scalar one for every i8 weight, with no extra clipping rule.

The cost is one bit of activation resolution. The `+ 256` makes the product round to nearest
instead of down (`(255 * 255 + 256) >> 9` is still 127), which removes a bias of half a step on
each of the 1024 inputs.

Sparse L1: the engine skips every block of four inputs `p[4n .. 4n + 3]` that is all zero. That
changes nothing in the sum, only its cost. The weights of one block are 64 adjacent bytes.

### File layout

| Offset | Section | Type | Count | Stored as |
|---|---|---|---|---|
| 0 | header | bytes | 64 | below |
| 64 | `l0w[feature][i]` | i16 | 12288 x 1024 | `round(w * 255)` |
| 25165888 | `l0b[i]` | i16 | 1024 | `round(b * 255)` |
| 25167936 | `l1w[bucket][block][j][k]`, input `4 * block + k` | i8 | 8 x 256 x 16 x 4 | `round(w * 64.5027 * 2^e)` |
| 25299008 | `l1b[bucket][j]` | i32 | 8 x 16 | `round(b * 2^(13 + e))`, Q(13 + e) |
| 25299520 | `l2w[bucket][k][o]`, input `k`, output `o` | i32 | 8 x 32 x 32 | `round(w * 2¹⁰)` |
| 25332288 | `l2b[bucket][o]` | i32 | 8 x 32 | `round(b * 2²³)` |
| 25333312 | `l3w[bucket][o]` | i32 | 8 x 32 | `round(w * 2¹⁰)` |
| 25334336 | `l3b[bucket]` | i32 | 8 | `round(b * 2²³)` |
| 25334368 | padding | | 32 bytes | |

Total 25334400 bytes. The feature transformer is the single-layer one, moved by the 64-byte header.
L2 inputs `k < 16` are the CReLU values, `k >= 16` their squares.

Header: the 8 bytes `AVALNNUE`, then fourteen u32:

| Field | Value |
|---|---|
| format version | 2 |
| head | 1 (multi) |
| king input buckets | 16 |
| accumulator width | 1024 |
| output buckets | 8 |
| L1 outputs | 16 |
| L2 outputs | 32 |
| `QA` | 255 |
| `FT_SHIFT` | 9 |
| `ACT_BITS` | 13 |
| `WEIGHT_BITS` | 10 |
| `SCALE` | 400 |
| L1 shift `e` | 0..7, chosen by the trainer for this network |
| reserved | 0 |

Version 1 had no L1 shift (it was version 2 with `e = 0` and a reserved field in its place); no
network of it was ever used.

The engine compares all 64 bytes, except the L1 shift, with the header of its own architecture,
and requires the shift to be at most 7. Whenever a network becomes the active one, embedded or
loaded with `EvalFile`, the engine derives `head_multi.Prepared` from it: the shift, and the L2
weights in the order the `pairs` path below multiplies them. A file that does not
start with `AVALNNUE` is not a multi-layer network: `WrongArchitecture` if it has exactly the size
of a single-layer file, `NotANetwork` otherwise. One that starts with it but differs later is
`UnsupportedHeader`. A single-layer file has no header: its first bytes are
feature-transformer weights. Change the format version whenever a formula or a section changes.

### Invariants

The loader refuses a file that breaks one (`WeightOutOfRange`, `BiasOutOfRange`); the trainer
enforces them by clipping, and bullet's quantiser fails the save rather than wrap a value.

| Value | Stored range | Float range | Trainer |
|---|---|---|---|
| `e` | 0..7 | | largest value at which `l1w` fits an i8 |
| `l1w` | any i8 | ±1.9689 / 2^e | AdamW clip ±126.9 / 64.5027 = ±1.9674, so `e = 0` always fits |
| `l2w`, `l3w` | ±2047 | ±1.999 | AdamW clip ±1.98 (stored ±2028) |
| `l1b` | ±2³⁰ | ±2^(17 - e): ±131072 at `e = 0`, ±1024 at `e = 7` | AdamW default clip ±1.98 |
| `l2b`, `l3b` | ±2³⁰ | ±128 | AdamW default clip ±1.98 |
| `l0w`, `l0b` | i16 | | as for the single-layer net: ±0.99 with the factoriser |

Why no i32 sum can overflow:

- L1: the weights are i8 and the activations at most 127 whatever `e` is, so the sum of products
  is below `1024 * 127 * 128 < 2²⁴`. With a bias up to 2³⁰ and the rounding term `2^(e-1) <= 64`,
  `2³⁰ + 2²⁴ + 64 < 2³¹`. `e` only changes what the numbers mean, not how large they get. That is
  why the bound on `e` comes from the bias, not from overflow: at `e = 7` a bias of ±1024 still
  fits, 500 times the trainer's clip.
- L2 and L3: `32 * 8192 * 2047 < 2²⁹`, plus a bias up to 2³⁰, so below 2³¹.
- The square: `8192² + 4096 < 2²⁷`.
- Accumulators cannot overflow i16 for trained weights, as for the single-layer net; that is not
  checked on load.

### Inference paths

`head_multi.evaluate_scalar` is the formula above, one loop per stage. `evaluate_simd` is what the
engine calls; it must return the same number for every input, and the tests compare the two on
random weights and accumulators, stage by stage and end to end.

`evaluate_simd` is three functions: `activate` (step 1), `l1_sums` (step 2 before the shift) and
`finish` (the rest). Vectors are as wide as `std.simd.suggestVectorLength(u8)` says for the target:
512 bits with AVX-512 unless the CPU model prefers 256 (`x86_64_v4` and Intel's server models do),
256 with AVX2, 128 otherwise. The paths are chosen at compile time from the target's features:

| Stage | Path | Target | Instructions |
|---|---|---|---|
| pairwise | `mulhrs` | x86 with SSSE3, AVX2 or AVX-512BW | `pmulhrsw`, `packuswb` |
| | | wasm simd128 | `i16x8.q15mulr_sat_s`, `i8x16.narrow_i16x8_u` |
| | `umull` | AArch64 | `sqxtun`, `umull` |
| | `portable` | anything else, Debug | `@Vector` u16 multiply |
| non-zero blocks | | x86, wasm, Debug | compare to a bit mask, table lookup |
| | | AArch64 | `umaxp`, a multiplication for the mask, table lookup |
| L1 | `dpbusd` | AVX-512 VNNI (512 bits); AVX-512 VNNI + VL or AVX-VNNI (256 bits) | `vpdpbusd` |
| | `maddubs` | x86 with SSSE3, AVX2 or AVX-512BW | `pmaddubsw`, `pmaddwd` |
| | `sdot` | AArch64 with dotprod | `sdot` |
| | `extadd` | wasm simd128 | `i16x8.mul`, `i32x4.extadd_pairwise_i16x8_s` |
| | `portable` | anything else, Debug | widening `@Vector` multiply |
| L2 | `pairs` | x86 (SSE2, AVX2 or AVX-512BW) | `pmaddwd` |
| | | wasm simd128 | `i32x4.dot_i16x8_s` |
| | `wide` | anything else, Debug | `@Vector` i32 multiply |
| dual activation, L3 | | all | `@Vector` i32 |

`Avalanche nnue-speed` prints the paths of the build it is. Every path computes exact integers, so
the result does not depend on the target:

- **Pairwise, `mulhrs`.** `pmulhrsw(x, y)` is `(x * y + 2^14) >> 15`. With `x = clamp(a, 0, 255) << 6`
  that is `(a * b + 256) >> 9`, the formula, in one instruction and without leaving 16 bits. `b` is
  only capped at 255: a negative `b` gives a result of at most 0, and `packuswb`, which narrows two
  vectors of i16 to one of bytes with saturation to 0..255, makes it 0. `packuswb` works within
  128-bit lanes, so a shuffle of 8-byte groups puts its result back in order.
- **Pairwise, `umull`.** `sqxtun` narrows with saturation to 0..255, which is the clamp. `umull` is
  the u8 x u8 -> u16 product `p`, and `(p + 256) >> 9 = ((p >> 8) + 1) >> 1`: the high bytes of two
  vectors of products with one `uzp2`, then one rounding halving of 16 bytes.
- **Pairwise on wasm.** `i16x8.q15mulr_sat_s` is `pmulhrsw` (it differs only for
  -32768 x -32768, which cannot occur), and the narrowing has no lanes to put back in order.
- **Non-zero blocks.** Eight blocks (32 activations) give an 8-bit mask. A table of 256 entries
  holds, for each mask, the positions of its set bits packed in a u64, and their number. The search
  adds the index of the first block of the group to all eight bytes, writes the u64 at the end of
  the list and advances by the number: no branch depends on the activations. A block index fits a
  byte because there are 256 blocks. AArch64 has no instruction that turns a comparison into a
  mask: `umaxp` twice reduces 32 activations to the 8 block maxima in a u64, and a multiplication
  gathers one bit of each byte.
- **L1.** The weights of a block are 64 adjacent bytes, the 16 outputs' weights for its four
  inputs, so a non-zero block is one broadcast of its four activations and 64 byte products.
  `vpdpbusd` and `sdot` add the products into the i32 sums; they take several cycles, so the blocks
  go round-robin into independent partial sums (8 vectors with `vpdpbusd`, 16 with `sdot`), added
  at the end. `pmaddubsw` + `pmaddwd` cannot saturate with activations up to 127 (see "Integer
  formula") and feed a plain addition, so one sum is enough there.
- **L1, `extadd`.** Wasm has no byte dot product. A product of an activation and a weight fits an
  i16 (`127 * 128`), so it is an `i16x8.mul` of the sign-extended bytes, and
  `extadd_pairwise` adds neighbours into i32. That leaves each output as two i32, which are
  accumulated apart and added once, after the last block, because adding them needs a shuffle.
- **L2, `pairs`.** `pmaddwd` multiplies i16 lanes and adds neighbours into i32, so it does two of
  the 32 x 32 products per i32 lane where an i32 multiply does one (and `pmulld` is two
  micro-operations on Intel). An activation is at most 8192 and a weight at most 2047, so both fit
  an i16 and the sum of two products fits an i32. L1 output `j` contributes two L2 inputs, its
  CReLU value and its square, so `Prepared` stores their weights side by side for each L2 output,
  and one `pmaddwd` with the pair `(value, square)` in every lane adds both. AArch64 gains nothing
  from it (`smlal` handles as many lanes as `mla`), and keeps the i32 multiplies. About 12 of the
  16 L1 outputs are non-zero on the bench positions, too many for skipping the zeros to pay for
  the unpredictable loop.

### Performance

`Avalanche nnue-speed` times the head on the accumulators of the 50 bench positions. Its first
line is the whole evaluation, with the accumulators read from the second-level cache (50 positions
of 4 KiB). The stage times that follow are taken four positions at a time, with the inputs in the
first-level cache as they are in the search, so they add up to less than the first line.

Apple M4, `--release=fast`, random networks from `nnue-random` with seed 1, best of five runs (all
five within 6% of it). "Before" is the implementation this one replaced (commit 6137e9d). The search
column is `go nodes 12000000` from the start position, three runs, same node counts before and
after.

| Network | Non-zero L1 blocks | Before | After | Search |
|---|---|---|---|---|
| `sparse` | 60.4 of 256 | 206.1 ns | 134.3 ns | 1.42-1.44M -> 1.96-1.98M nps |
| default (dense) | 233.5 of 256 | 410.6 ns | 238.4 ns | 1.19-1.20M -> 1.77-1.81M nps |
| `full` (dense) | 233.5 of 256 | 413.6 ns | 237.2 ns | |

AMD EPYC 9R14 (Zen 4; 512-bit `mulhrs` and `dpbusd`), trained nets, single thread: `nnue-speed`
226.5 -> 146.8 ns and `bench` 1.22M -> 1.53M nps (+26%) for the net trained with the sparsity
penalty, 310.6 -> 171.5 ns and 1.10M -> 1.46M nps (+32%) for the one without; checksums and node
counts unchanged. The single-layer net of that comparison ran at 1.79M nps.

Stages after the change, inputs in the first-level cache: pairwise 34 ns, non-zero search 17 ns,
L1 products 33 ns (sparse) or 124 ns (dense), L2 and L3 29 ns. What changed, with the stages of the
dense network timed the way the first line is, before and after:

- **Non-zero search, 143 ns to 22 ns.** It was a loop over the set bits of a mask, one iteration
  per non-zero block, whose exit depended on the activations. `nnue-speed` repeats the same 50
  positions, which a branch predictor learns and a search does not offer, so the search gained
  more than the benchmark did.
- **L1 products, 175 ns to 137 ns.** There was one sum per output vector, so every block waited
  for the `sdot` of the one before it. What is left is the throughput of `sdot` on the M4: four
  per block, two per cycle. x86 gained `vpdpbusd`, one instruction for `pmaddubsw` + `pmaddwd`.
- **Pairwise, 64 ns to 48 ns.** It clamped both factors, multiplied, added and shifted in 16 bits.
- L2 and L3 are unchanged, 26 to 29 ns.

A later change (the `pairs` L2 and the wasm paths) left the M4 where it was,
since AArch64 keeps the `wide` L2: 150 ns per evaluation on the default net (84.7 of 256 blocks
non-zero; pairwise 35 ns, L1 63 ns of which the search 17 ns, L2 and L3 29 ns). It is for x86 and
wasm: X86_RESULT

On the M4 the head is at what the core can do in 128-bit vectors: the pairwise step and the L1
products are limited by loads per cycle, L2 by the multiplier.

Tried on the M4 and left out: a loop over all blocks without the index list for dense inputs
(6 ns of 240 on the dense networks, nothing below about 200 non-zero blocks), and partial sums in
L2 (no gain: 256 i32 multiply-accumulates at two per cycle are the limit). Also left out, with
the measurement that decided it:

- **Skipping zero L1 outputs in L2.** 12.4 of 16 are non-zero on the bench positions; the loop
  over the non-zero ones was slower than the full one (44 ns against 34 for L2 and L3).
- **Lazy accumulator updates.** Of the 15.8M accumulator frames of a `bench` run, 14.9M are
  evaluated or have an evaluated descendant, so at most 5% of the updates could be skipped.
- **Prefetching the weight rows of an accumulator update.** 1.5% slower in `bench`: the rows of a
  move are read sequentially already.
- **Reordering the feature-transformer outputs so that active ones share blocks.** It changes no
  evaluation. Sorting by how often each is non-zero (measured on the evaluations of a `bench` run,
  checked on the other half) lowers the non-zero blocks from 85.3 to 77.5, a greedy grouping by
  co-activation to 82.7: about 4 ns of 150, for a second version of every network file.

- **A search step of 16 blocks** (one mask, two table lookups; one `vptestmd` with AVX-512, one
  `bitmask` on wasm after narrowing). The search alone was 4 ns slower on an EPYC 9R14 at 256 and
  at 512 bits (24.4 to 28.2 and 19.8 to 24.2 ns), the same on the M4, and changed nothing in the
  whole L1 under wasm.

Not tried: `vpcompressb` instead of the table for the index list.

### What has been executed

The intrinsics are compiled only outside Debug (LLVM leaves them unresolved at `-ODebug`). So a
plain `zig build test` compares the scalar path with the *portable* paths only, and reports the test
`multi head: the SIMD comparisons cover the intrinsic paths` as skipped. To test the paths a release
binary runs:

```
zig build test -Doptimize=ReleaseSafe -Dtest-filter="multi "
```

On Apple Silicon the x86 paths up to AVX2 run under Rosetta: add `-Dtarget=x86_64-macos` and
`-Dcpu=haswell` (AVX2), `-Dcpu=nehalem` (SSSE3) or `-Dcpu=x86_64` (portable).

| Build | Pairwise | L1 | Executed |
|---|---|---|---|
| Apple Silicon | `umull` | `sdot` | yes, natively |
| AArch64 without dotprod (`-Dcpu=apple_m4-dotprod`) | `umull` | `portable` | yes, natively |
| x86 AVX2 (`haswell`) | `mulhrs`, 256 bits | `maddubs`, 256 bits | yes, under Rosetta |
| x86 SSSE3 (`nehalem`) | `mulhrs`, 128 bits | `maddubs`, 128 bits | yes, under Rosetta |
| x86 SSE2 (`x86_64`); Debug | `portable` | `portable` | yes |
| x86 AVX-512BW without VNNI (`-Dcpu=znver5-avx512vnni`) | `mulhrs`, 512 bits | `maddubs`, 512 bits | yes, on an EPYC 9R14 (Zen 4) |
| x86 AVX-512 VNNI (`znver4`, `znver5`) | `mulhrs`, 512 bits | `dpbusd`, 512 bits | yes, natively on an EPYC 9R14 |
| x86 at 256 bits with AVX-512 VNNI + VL (`icelake_server`) | `mulhrs`, 256 bits | `dpbusd`, 256 bits, EVEX | yes, on an EPYC 9R14 |
| x86 at 256 bits with AVX-VNNI (`alderlake`) | `mulhrs`, 256 bits | `dpbusd`, 256 bits, VEX | **no** |
| wasm simd128 | `portable` | `portable` | yes, by the `web/` tests (`bench` equal to native) |

The EPYC 9R14 runs were at commit 37fa538, with random weights and with two trained multi-layer
nets as `-Dnet`.

**The VEX-encoded `vpdpbusd` of AVX-VNNI has not been executed.** It is what a 256-bit build
without AVX-512 uses (Alder Lake and later Intel desktop CPUs with `-Dcpu=native`). Zen 4 has no
AVX-VNNI, so the `alderlake` build stops there on an illegal instruction, and Rosetta has none
either. It differs from the tested EVEX path only in the encoding of that one instruction, and the
generated code was read. To close it, on an Alder Lake or Zen 5 machine:

```
zig build test -Doptimize=ReleaseSafe -Dtest-filter="multi " -Dcpu=alderlake
```

The `nnue-speed` checksum of a given network must be the same on every machine and path.
Rerun the command on a machine of each kind after changing the head's code: CI machines do not
reliably have AVX-512, and OpenBench workers built with `-Dcpu=native` use the path of their CPU.

## Training

`TRAIN_ARCH=single` (default) or `multi`; everything else in `scripts/train.sh` applies to both:
the same loss, data loader, schedule and held-out validation. `multi` needs `TRAIN_INPUT=buckets16`.

```
TRAIN_ARCH=multi TRAIN_NET_ID=mynet TRAIN_DATA_DIR=/data/viri ./scripts/train.sh
zig build --release=fast -Dnet=training/checkpoints/mynet-40/quantised.bin
```

Two things differ from the single-layer recipe:

- **Initialisation.** The feature transformer is initialised as if it had 32 inputs
  (`init_with_effective_input_size(32)`, as in bullet's multi-layer example), because the default,
  scaled for all 12288 inputs, starts every pairwise product near zero.
- **`TRAIN_L1_SPARSITY`** (default 0, off). A coefficient `c > 0` adds `c * mean(p)` to the training
  loss of each position, `p` being its 1024 pairwise activations in 0..1. Fewer non-zero activations
  are fewer blocks for the engine's sparse L1. bullet's advanced example uses 0.005. The training loss
  bullet prints, and the `log.txt` of a checkpoint, **include** the penalty. The validation loss
  (`TRAIN_VALIDATION_DIR`) **does not**: it is always the plain `(sigmoid(output) - target)²`, so it is
  comparable between runs with different coefficients, and with a coefficient above 0 it is no longer
  comparable with the training loss of the same run. The variable is an error with `TRAIN_ARCH=single`.

`TRAIN_RESUME_FROM` with a checkpoint of the other architecture is refused, by the header of the
checkpoint's `quantised.bin`.

`quantised.bin` is the file above. bullet at the pinned revision expresses the whole network with
its builder: sliced-affine pairwise, `concat`, `crelu`, the square as `x * x`, and
`select(output_buckets)` for the three bucketed layers. The save format reorders `l1w` and `l2w`
from bullet's column-major layout and scales `l1w` (`training/src/multilayer.rs`).

### Fine-tuning from a shipped net

`TRAIN_INIT_NET=<path to .nnue>` starts a single-layer run from the weights of a quantised net file
instead of a random initialisation:

```
TRAIN_INIT_NET="$PWD/nets/nezha.nnue" TRAIN_FACTORISER=0 TRAIN_LR_INITIAL=0.0001 TRAIN_WARMUP_SB=1 \
    TRAIN_NET_ID=nezha-ft TRAIN_DATA_DIR=/data/viri ./scripts/train.sh
```

**Why.** bullet's checkpoints hold float weights and the optimiser state, and `TRAIN_RESUME_FROM`
needs one. A shipped net is only the quantised file, and after several generations of fine-tuning
its float checkpoints may be gone. Starting a run on new data from the shipped net's weights tells
"this data is worse" apart from "a net trained from scratch is behind a fine-tuned lineage".

**What it does** (`training/src/init_net.rs`). The file is read as the single-layer layout above
and each stored integer is divided by its scale: `l0w` and `l0b` by 255, `l1w` by 64 (and put back
from the file's `[bucket][input]` order into bullet's column-major one), `l1b` by 255 * 64. The
file's feature weights already contain the factoriser, so with `TRAIN_FACTORISER=1` the bucketed
weights get the file's values and the factoriser starts at zero. The optimiser state is fresh.
Saving without a training step writes the input file again, byte for byte: a float is
`stored / scale` to within a relative 2^-24, and the save rounds `float * scale` back to `stored`.
`cargo test` checks that on `nets/nezha.nnue`, with and without the factoriser.

**What it refuses**, each with a message naming the reason:

- `TRAIN_ARCH=multi`, and a file in the multi-layer format (magic `AVALNNUE`).
- `TRAIN_RESUME_FROM`, or a `TRAIN_START_SB` other than 1: those continue a run, this starts one.
- A file whose size is not exactly that of this run's input layout and `TRAIN_HIDDEN`.
- A net with weights outside the range the optimiser clips to, when the clip would change their
  stored value: the first step would move them, and the run would not start from the net it was
  given. The clip is ±1.98 for every weight, except ±0.99 for the feature weights when a factoriser
  is trained (so that bucketed weight plus factoriser stays within ±1.98). A net that was trained
  with a factoriser has merged feature weights up to ±1.98, so it needs `TRAIN_FACTORISER=0`:
  `nets/nezha.nnue` has 16036 feature weights beyond ±0.99. Refusing is a choice, not a limit: such
  weights can be split exactly into a non-zero factoriser plus a remainder within the clip whenever
  the buckets of one feature weight span at most 1.98, and that split is not implemented.

**Checking the load on the GPU.** `TRAIN_PARITY_FENS` accepts `TRAIN_INIT_NET` in place of
`TRAIN_RESUME_FROM`: the trainer loads the net, evaluates the positions with bullet's graph on the
device, writes `TRAIN_PARITY_OUT` and exits. No training step runs and no training data is read,
but the trainer still wants a data path that exists (`TRAIN_DATA_DIR` with at least one `.viribin`
file, or any existing file as the argument).

```
cd training
TRAIN_INIT_NET="$PWD/../nets/nezha.nnue" TRAIN_FACTORISER=0 TRAIN_PARITY_FENS=fens.txt \
    TRAIN_PARITY_OUT=parity.txt TRAIN_DATA_DIR=/path/to/viribin ./target/release/avalanche-trainer
```

`parity.txt` holds `<fen> | <centipawns>` for the side to move. `Avalanche nnue-parity` reads only
multi-layer nets, so a single-layer net is compared through the engine built with it: the UCI
`eval` command prints `NNUE evaluation <cp> (white side)` for the current position.

**What stays the caller's job.** The learning rate is whatever the schedule says: the defaults,
`TRAIN_LR_INITIAL=0.001` on a cosine to `TRAIN_LR_FINAL`, are for a net trained from scratch and
are high for a trained one, so lower `TRAIN_LR_INITIAL` (and choose `TRAIN_LR_SCHEDULE` and
`TRAIN_SUPERBATCHES` for the length of the fine-tune). `TRAIN_WARMUP_SB` defaults to 0, so the first
batch already runs at the full initial rate while Adam's moment estimates are still empty; set it
for a ramp from near zero. `TRAIN_WDL` is not taken from the net either.

The path is resolved from `training/`, where `scripts/train.sh` runs the trainer; pass an absolute
one.

## Parity

Three commands of the engine binary, available in every build:

```
Avalanche nnue-parity <net> [positions|bench] [verbose]
Avalanche nnue-random <out> [seed] [full] [sparse]
Avalanche nnue-speed
```

`nnue-parity` reads a multi-layer file and, for each position (the bench positions by default),
rebuilds both accumulators from the file and evaluates the head three ways:

- **integer**: `head_multi.evaluate`, the engine's path;
- **float**: the trainer's forward pass in f64 from the same quantised weights, no rounding anywhere;
- **float with quantised pairwise**: the same, but from the engine's 0..127 pairwise products.

It prints the maximum and mean absolute difference in centipawns. In a multi-layer build it also
loads the file as the engine would and checks that the engine's incremental evaluation equals the
integer value on every position; any mismatch makes the exit status 1.

A positions file has one FEN per line, optionally followed by `| <centipawns>`. With that column
the report adds the difference between the integer evaluation and the given numbers.

`nnue-random` writes a random network: by default with head weights of the magnitude of a trained
network (`|l1w| <= 0.19`, stored as up to 96 at `e = 3`; `|l2w|, |l3w| <= 400`), with `full` over
the whole valid range at `e = 0`. Both are dense: about nine L1 blocks in ten are non-zero on the
bench positions, because the feature-transformer biases are drawn from 0..128. `sparse` draws them
from -144..-16, which leaves about one block in four non-zero, as a network trained with
`TRAIN_L1_SPARSITY` aims for; it combines with `full`.
`nnue-speed` times the build's head on the bench positions; in a multi-layer build it also prints
the SIMD paths, the mean number of non-zero L1 blocks and the time of each stage (see
"Performance").

### Tolerances

| Comparison | Tolerance | Measured on random weights |
|---|---|---|
| integer vs float with quantised pairwise | 0.75 cp | max 0.53 cp, any weight range |
| integer vs float, trained-magnitude weights | 16 cp | max 6.0 cp, mean 1.2 cp, mean abs eval 100 to 180 cp |
| integer vs float, full-range weights | none | max 143 cp, mean 18 cp, mean abs eval 1200 cp |

- With the engine's own pairwise products, what is left is the final rounding to a whole
  centipawn (at most 0.5 cp) and the two rounding shifts (each at most 2⁻¹⁴ per activation). A wrong
  weight order, scale or shift anywhere after the pairwise step shows up here.
- Against exact pairwise products, each of up to 1024 inputs is off by at most half of 1/127, and
  L1 sums those errors weighted by `l1w`. The error grows with the size of the L1 weights, which
  is why it is only bounded for weights of trained magnitude. It is the price of u8 activations
  and is the same in every engine that uses them.
- A layout or formula mismatch gives a difference of the order of the evaluations themselves,
  hundreds of centipawns.
- A fourth tolerance, 16 cp max and 4 cp mean, is for the rounding of the L1 weights: float L1
  weights up to 0.2166, stored at the shift the trainer would pick, against those floats on the
  engine's pairwise products. Measured 8.1 cp max, 1.2 cp mean; without the shift, 81 and 17.

The unit tests (`src/tests/nnue_multi.zig`) assert the first two rows on random accumulators, and
the scalar-against-SIMD equality on both weight ranges at every L1 shift. Each SIMD stage also has
its own comparison: the pairwise products for every pair of values around the clamp, the non-zero
search and the L1 sums for every number of non-zero blocks from 0 to 256.

### Trainer against engine, on a GPU machine

The trainer needs CUDA. This checks what the tests above cannot, that bullet's graph and save
format mean what this document says.

```
# 1. A net. A short run is enough; parity does not need a strong net.
cd training
TRAIN_ARCH=multi TRAIN_NET_ID=parity TRAIN_SUPERBATCHES=4 TRAIN_SAVE_RATE=4 \
    TRAIN_DATA_DIR=/path/to/viribin ../scripts/train.sh

# 2. The trainer's own evaluation of the bench positions, from the unquantised checkpoint.
../zig-out/bin/Avalanche nnue-parity checkpoints/parity-4/quantised.bin bench verbose \
    | grep ' | ' | cut -d'|' -f1 > fens.txt
TRAIN_ARCH=multi TRAIN_RESUME_FROM=checkpoints/parity-4 TRAIN_PARITY_FENS=fens.txt \
    TRAIN_PARITY_OUT=parity.txt TRAIN_DATA_DIR=/path/to/viribin ./target/release/avalanche-trainer

# 3. The engine against it.
../zig-out/bin/Avalanche nnue-parity checkpoints/parity-4/quantised.bin parity.txt
```

Pass: `integer vs float, quantised pairwise` is below 0.75 cp, and `integer vs trainer
evaluations` is small against the evaluations themselves (see the measurement below). The trainer
evaluates the unquantised weights, so that difference also contains the rounding of the weights
themselves, the i8 L1 weights above all; the 16 cp tolerance above does not apply to it. A failure
of the layout looks like the third row of the table: differences as large as the evaluations.

First measurement, on commit d4d0dde (format version 1): a net trained for 3 superbatches of 200 batches on a tiny
dataset, before the 32-input initialisation was added; the 50 bench positions, mean abs eval
162 cp, max 773 cp. The trainer ran and saved a 25334400-byte file.

| Comparison | Max | Mean |
|---|---|---|
| integer vs float forward pass | 14.2 cp | 2.95 cp |
| integer vs float, quantised pairwise | 0.49 cp | 0.26 cp |
| integer vs trainer evaluations | 28.5 cp | 9.3 cp |

So the layout and the formulas match the file bullet saves. The 9 cp mean of the last row is
weight quantisation, mainly the i8 L1 weights at a resolution of 1/64.5.

Second measurement, on commit 31b3a0d (still format version 1), with the 32-input initialisation
and `TRAIN_L1_SPARSITY=0.005`; mean abs eval 196.7 cp. The trainer printed, at save: `l1w` max 0.2166,
stored as 14 of 127; `l2w` 1068 of 2047; `l3w` 857 of 2047.

| Comparison | Max | Mean |
|---|---|---|
| integer vs float forward pass | 3.0 cp | 0.9 cp |
| integer vs float, quantised pairwise | 0.54 cp | 0.23 cp |
| integer vs trainer evaluations | 83.8 cp | 22.7 cp |

The arithmetic is right; the last row is the L1 weights rounded to 14 levels. That is what the L1
shift of format version 2 removes: this net would be saved with `e = 3`, its largest weight at 112
of 127. A unit test reproduces the case with random weights of that size: 81 cp max and 17 cp mean
at `e = 0`, 8.1 cp and 1.2 cp at `e = 3`.

Third measurement, format version 2, same recipe as the second: the trainer chose `e = 3`, and the
file stores `l1w` at up to 116 of 127, `l2w` 1070 of 2047, `l3w` 869 of 2047. The 50 bench
positions, mean abs eval 195 cp, max 887 cp.

| Comparison | Max | Mean |
|---|---|---|
| integer vs float forward pass | 2.8 cp | 0.8 cp |
| integer vs float, quantised pairwise | 0.52 cp | 0.23 cp |
| integer vs trainer evaluations | 9.8 cp | 2.9 cp |

The shift does what it was added for: the last row fell from 83.8 cp max and 22.7 cp mean to 9.8
and 2.9, about 1.5% of the mean evaluation. The first row compares the integer and float forward
passes on the same quantised weights, so the rest of the last row, about 2 cp on average, is the
rounding of the weights, now at 116 levels for L1.

`nnue-parity` prints a net's L1 shift and the largest stored weight of each layer against its
limit, and the trainer prints the largest float weight of each section, and the shift, at every
save. If a fully trained net still shows a large last row with `l1w` near 127 levels, the next
step is quantisation-aware training of L1, not more bits.

Then build the engine from that file (`zig build --release=fast -Dnet=...`) and run

```
zig build test -Doptimize=ReleaseSafe -Dnet=<file> -Dtest-filter="multi "
zig build test -Doptimize=ReleaseSafe -Dnet=<file> -Dtest-filter="eval: "
zig build test -Doptimize=ReleaseSafe -Dnet=<file> -Dtest-filter="options: EvalFile"
```

which repeat the network tests of this document with the trained net embedded and the intrinsic
paths compiled in, and `Avalanche bench` on an x86 and an ARM machine: the node counts must be
equal.

## Tests

`zig build test` in the default build covers the multi-layer head. The multi-layer head's weights
are passed explicitly, so its tests run in a build of either head; the single-layer head is only
evaluated through the embedded network, so its tests need a single-layer build:
`zig build test -Dnet=nets/dianguang-1.nnue`. `-Dtest-filter=<text>` runs the tests
whose name contains the text. In Debug the intrinsics are not compiled, see "What has been executed";
use `-Doptimize=ReleaseSafe` for those.
