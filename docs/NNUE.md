# NNUE

Avalanche has one feature transformer and two output heads. A build runs one head, fixed at compile
time.

| Head | Network | Selected by |
|---|---|---|
| single (default) | `(768x16hm -> 1024)x2 -> SCReLU -> 1x8` | `-Dhead=single`, `TRAIN_ARCH=single` |
| multi | `(768x16hm -> 1024)x2 -> pairwise CReLU -> L1(1024 -> 16) -> [CReLU, CReLU²] -> L2(32 -> 32) CReLU -> L3(32 -> 1)`, L1 to L3 x8 | `-Dhead=multi`, `TRAIN_ARCH=multi` |

`-Dhead` defaults to `auto`: the head of the `-Dnet` file, recognised by its header. So
`zig build -Dnet=multi.nnue` and `make EVALFILE=multi.nnue` build a multi-layer engine with no other
flag, and the default build (`nets/nezha.nnue`) is single-layer. An explicit `-Dhead` that
contradicts the file is a compile error.

`setoption name EvalFile` loads a network of the build's architecture. A file of the other
architecture is refused with `WrongArchitecture` and the current network stays in use.

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
| `L1_WEIGHT_SCALE` | 2²² / 255² = 64.5027 | an L1 weight is stored as `round(w * 64.5027)` |
| `WEIGHT_BITS` | 10 | fixed point of L2 and L3 weights: 1024 is 1.0 |
| `SUM_BITS` | 23 | fixed point of L2 and L3 biases and sums |
| `SCALE` | 400 | centipawns per unit of output |

`L1_WEIGHT_SCALE` is chosen so that `stored weight * stored activation = w * a * 2¹³` exactly:
`64.5027 * 127.002 = 8192`. The L1 sum is therefore a plain Q13 number and its bias is `b * 8192`.

### Integer formula

`>>` is an arithmetic shift (rounds toward minus infinity), so `(x + 2^(n-1)) >> n` rounds to
nearest, halves up. Everything is i32 except the last line.

```
1. Pairwise, 1024 values in 0..127, own first:
     p[i]       = (clamp(own[i], 0, 255) * clamp(own[i + 512], 0, 255) + 256) >> 9     i < 512
     p[512 + i] = (clamp(opp[i], 0, 255) * clamp(opp[i + 512], 0, 255) + 256) >> 9

2. L1, for j < 16:
     z1[j] = l1b[b][j] + sum over i < 1024 of p[i] * l1w[b][i / 4][j][i % 4]

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
| 25167936 | `l1w[bucket][block][j][k]`, input `4 * block + k` | i8 | 8 x 256 x 16 x 4 | `round(w * 64.5027)` |
| 25299008 | `l1b[bucket][j]` | i32 | 8 x 16 | `round(b * 2¹³)` |
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
| format version | 1 |
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
| reserved | 0 |
| reserved | 0 |

The engine compares all 64 bytes with the header of its own architecture. A file that does not
start with `AVALNNUE` is not a multi-layer network (`WrongArchitecture`); one that does but differs
later is `UnsupportedHeader`. A single-layer file has no header: its first bytes are
feature-transformer weights. Change the format version whenever a formula or a section changes.

### Invariants

The loader refuses a file that breaks one (`WeightOutOfRange`, `BiasOutOfRange`); the trainer
enforces them by clipping, and bullet's quantiser fails the save rather than wrap a value.

| Value | Stored range | Float range | Trainer |
|---|---|---|---|
| `l1w` | any i8 | ±1.9689 | AdamW clip ±126.9 / 64.5027 = ±1.9674 |
| `l2w`, `l3w` | ±2047 | ±1.999 | AdamW clip ±1.98 (stored ±2028) |
| `l1b`, `l2b`, `l3b` | ±2³⁰ | ±131072 (`l1b`), ±128 | AdamW default clip ±1.98 |
| `l0w`, `l0b` | i16 | | as for the single-layer net: ±0.99 with the factoriser |

Why no i32 sum can overflow:

- L1: `1024 * 127 * 128 < 2²⁴`, plus a bias up to 2³⁰.
- L2 and L3: `32 * 8192 * 2047 < 2²⁹`, plus a bias up to 2³⁰, so below 2³¹.
- The square: `8192² + 4096 < 2²⁷`.
- Accumulators cannot overflow i16 for trained weights, as for the single-layer net; that is not
  checked on load.

### Inference paths

`head_multi.evaluate_scalar` is the formula above, one loop per stage. `evaluate_simd` is what the
engine calls; it must return the same number for every input, and the tests compare the two on
random weights and accumulators.

| Stage | SIMD |
|---|---|
| pairwise | `@Vector` u16 multiply (255² + 256 fits), portable |
| non-zero blocks | `@Vector(16, u32) != 0` to a bit mask, portable |
| L1 | x86: `pmaddubsw` + `pmaddwd` (SSSE3, AVX2, AVX-512BW). AArch64: `sdot`. Otherwise, wasm included, and in Debug builds: widening `@Vector` multiply |
| dual activation, L2, L3 | `@Vector` i32, portable |

Only L1 uses target intrinsics, and its three variants compute an exact i32 sum, so the result does
not depend on the target. AVX-512 VNNI (`vpdpbusd`) would be one instruction instead of two; it is
not used because no machine was available to test it.

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

## Parity

Three commands of the engine binary, available in every build:

```
Avalanche nnue-parity <net> [positions|bench] [verbose]
Avalanche nnue-random <out> [seed] [full]
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
network (`|l1w| <= 12`, `|l2w|, |l3w| <= 400`), with `full` over the whole valid range.
`nnue-speed` times the build's head on the bench positions.

### Tolerances

| Comparison | Tolerance | Measured on random weights |
|---|---|---|
| integer vs float with quantised pairwise | 0.75 cp | max 0.53 cp, any weight range |
| integer vs float, trained-magnitude weights | 16 cp | max 7.4 cp, mean 1.2 cp, mean abs eval 100 to 180 cp |
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

The unit tests (`src/tests/nnue_multi.zig`) assert the first two rows on random accumulators, and
the scalar-against-SIMD equality on both weight ranges.

### Trainer against engine, on a GPU machine

This has not been run: the trainer needs CUDA. It checks what the tests above cannot, that
bullet's graph and save format mean what this document says.

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

Pass: `integer vs trainer evaluations` has a mean of a few centipawns and a maximum below about
25 cp, and `integer vs float, quantised pairwise` is below 0.75 cp. The trainer evaluates the
unquantised weights, so this difference also contains the rounding of the weights themselves, the
i8 L1 weights above all; the 16 cp tolerance above does not apply to it. A failure of the layout
looks like the third row of the table: differences as large as the evaluations.

Then build the engine from that file (`zig build --release=fast -Dnet=...`) and run
`zig build test -Dnet=...` once, which repeats every test of this document with the trained net
embedded, and `Avalanche bench` on an x86 and an ARM machine: the node counts must be equal.

## Tests

`zig build test` in the default build covers both heads: the multi-layer head's weights are passed
explicitly, so its tests do not need a multi-layer build. `-Dtest-filter=<text>` runs the tests
whose name contains the text.
