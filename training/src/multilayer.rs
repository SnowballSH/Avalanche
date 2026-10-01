//! The multi-layer head, `TRAIN_ARCH=multi`:
//! `(768x16hm -> H)x2 -> pairwise CReLU -> L1(H -> 16) -> [CReLU, CReLU^2] -> L2(32 -> 32) CReLU -> L3(32 -> 1)`,
//! with L1, L2 and L3 bucketed by material.
//!
//! docs/NNUE.md specifies the network and the file. The engine side is src/engine/nnue/head_multi.zig
//! and the header is `MULTI_HEADER` in src/engine/weights.zig; every constant here has a twin there.

use bullet::{
    game::{inputs::ChessBucketsMirrored, outputs::MaterialCount},
    nn::{
        InitSettings, Shape,
        optimiser::{AdamW, AdamWParams},
    },
    trainer::save::SavedFormat,
    value::ValueTrainerBuilder,
};

use crate::{
    BUCKET_LAYOUT_16, EVAL_SCALE, NUM_OUTPUT_BUCKETS, QA, Session, TrainConfig,
    feature_transformer_format, print_banner, resume_from_env, run_trainer,
};

const L1_SIZE: usize = 16;
const L2_SIZE: usize = 32;
/// Inputs of L2: the CReLU of each L1 output, then the square of each.
const L2_INPUTS: usize = 2 * L1_SIZE;

/// The engine stores a pairwise product as `(a * b + 256) >> FT_SHIFT`, 0..=127.
const FT_SHIFT: u32 = 9;
/// Fixed-point position of the L1 output and of every later activation.
const ACT_BITS: u32 = 13;
/// Fixed-point position of the L2 and L3 weights.
const WEIGHT_BITS: u32 = 10;
/// Fixed-point position of the L2 and L3 biases.
const SUM_BITS: u32 = ACT_BITS + WEIGHT_BITS;

const FORMAT_VERSION: u32 = 1;
const HEAD_MULTI: u32 = 1;
const MAGIC: &[u8; 8] = b"AVALNNUE";
const HEADER_SIZE: usize = 64;

/// An L1 weight is stored as `round(w * L1_WEIGHT_SCALE)`: a pairwise product of 1.0 is the integer
/// `255 * 255 / 2^FT_SHIFT`, and the L1 sum has to land on `2^ACT_BITS`.
const L1_WEIGHT_SCALE: f64 = (1u64 << (ACT_BITS + FT_SHIFT)) as f64 / (QA as f64 * QA as f64);
/// Keeps `round(w * L1_WEIGHT_SCALE)` inside an i8.
const L1_WEIGHT_CLIP: f32 = (126.9 / L1_WEIGHT_SCALE) as f32;
/// The engine accepts L2 and L3 weights up to 2047 / 2^WEIGHT_BITS; this is bullet's default clip.
const WEIGHT_CLIP: f32 = 1.98;

const _: () = assert!(
    WEIGHT_CLIP * ((1u32 << WEIGHT_BITS) as f32) < 2047.0,
    "L2 and L3 weights must fit the engine's range"
);

/// The 64-byte header the engine compares byte for byte: the magic, then little-endian u32 fields.
fn header(input_buckets: usize, hidden_size: usize) -> Vec<u8> {
    let fields = [
        FORMAT_VERSION,
        HEAD_MULTI,
        input_buckets as u32,
        hidden_size as u32,
        NUM_OUTPUT_BUCKETS as u32,
        L1_SIZE as u32,
        L2_SIZE as u32,
        QA as u32,
        FT_SHIFT,
        ACT_BITS,
        WEIGHT_BITS,
        EVAL_SCALE as u32,
    ];
    let mut bytes = MAGIC.to_vec();
    for field in fields {
        bytes.extend_from_slice(&field.to_le_bytes());
    }
    bytes.resize(HEADER_SIZE, 0);
    bytes
}

/// bullet keeps the weights of an affine layer column-major: `values[input * rows + row]`, and a
/// bucketed layer's row is `bucket * outputs + output`.
///
/// L1 goes to `[bucket][input / 4][output][input % 4]`, scaled: the four weights that one output has
/// for one block of four inputs are adjacent, which is what the engine's sparse dot product reads.
fn l1_weights_layout(values: &[f32], inputs: usize) -> Vec<f32> {
    let rows = NUM_OUTPUT_BUCKETS * L1_SIZE;
    assert_eq!(values.len(), rows * inputs);
    assert_eq!(inputs % 4, 0);
    let blocks = inputs / 4;

    let mut layout = vec![0.0; values.len()];
    for bucket in 0..NUM_OUTPUT_BUCKETS {
        for input in 0..inputs {
            for output in 0..L1_SIZE {
                let weight = f64::from(values[input * rows + bucket * L1_SIZE + output]);
                let index = ((bucket * blocks + input / 4) * L1_SIZE + output) * 4 + input % 4;
                layout[index] = (weight * L1_WEIGHT_SCALE) as f32;
            }
        }
    }
    layout
}

/// L2 goes to `[bucket][input][output]`: one column per input, as the engine multiplies it.
fn l2_weights_layout(values: &[f32]) -> Vec<f32> {
    let rows = NUM_OUTPUT_BUCKETS * L2_SIZE;
    assert_eq!(values.len(), rows * L2_INPUTS);

    let mut layout = vec![0.0; values.len()];
    for bucket in 0..NUM_OUTPUT_BUCKETS {
        for input in 0..L2_INPUTS {
            for output in 0..L2_SIZE {
                layout[(bucket * L2_INPUTS + input) * L2_SIZE + output] =
                    values[input * rows + bucket * L2_SIZE + output];
            }
        }
    }
    layout
}

/// The file, in order: header, feature transformer, L1, L2, L3. bullet pads it to a multiple of 64 bytes.
fn save_format(input_buckets: usize, hidden_size: usize, use_factoriser: bool) -> Vec<SavedFormat> {
    let mut format = vec![SavedFormat::custom(header(input_buckets, hidden_size))];
    format.extend(feature_transformer_format(use_factoriser, input_buckets));
    format.extend([
        SavedFormat::id("l1w")
            .transform(move |_, values| l1_weights_layout(&values, hidden_size))
            .round()
            .quantise::<i8>(1),
        SavedFormat::id("l1b")
            .round()
            .quantise::<i32>(1 << ACT_BITS),
        SavedFormat::id("l2w")
            .transform(|_, values| l2_weights_layout(&values))
            .round()
            .quantise::<i32>(1 << WEIGHT_BITS),
        SavedFormat::id("l2b")
            .round()
            .quantise::<i32>(1 << SUM_BITS),
        // Rows are buckets here, so the transpose is already `[bucket][input]`.
        SavedFormat::id("l3w")
            .transpose()
            .round()
            .quantise::<i32>(1 << WEIGHT_BITS),
        SavedFormat::id("l3b")
            .round()
            .quantise::<i32>(1 << SUM_BITS),
    ]);
    format
}

pub fn run(cfg: TrainConfig) {
    const NUM_INPUT_BUCKETS: usize = bullet::game::inputs::get_num_buckets(&BUCKET_LAYOUT_16);

    let hidden_size = cfg.hidden_size;
    let use_factoriser = cfg.use_factoriser;
    if !hidden_size.is_multiple_of(8) {
        crate::fail("TRAIN_ARCH=multi needs TRAIN_HIDDEN to be a multiple of 8");
    }

    let input = if use_factoriser {
        format!("768x{NUM_INPUT_BUCKETS}hm+factoriser")
    } else {
        format!("768x{NUM_INPUT_BUCKETS}hm")
    };
    print_banner(
        &cfg,
        &input,
        &format!(
            "pairwise -> {L1_SIZE}x2 -> {L2_SIZE} -> 1, each x{NUM_OUTPUT_BUCKETS} material buckets"
        ),
    );

    let save_format = save_format(NUM_INPUT_BUCKETS, hidden_size, use_factoriser);
    let inputs = ChessBucketsMirrored::new(BUCKET_LAYOUT_16);
    // validation.rs keeps its own copy of bullet's input mapper for this builder setup. Re-check it when
    // this gains wdl-adjust, datapoint-weight, win-rate-model or wdl-output options, or bullet is bumped.
    let mut trainer = ValueTrainerBuilder::default()
        .dual_perspective()
        .optimiser(AdamW)
        .inputs(inputs)
        .output_buckets(MaterialCount::<NUM_OUTPUT_BUCKETS>)
        .save_format(&save_format)
        .loss_fn(|output, target| output.sigmoid().squared_error(target))
        .build(move |builder, stm_inputs, ntm_inputs, output_buckets| {
            let mut l0 = builder.new_affine("l0", 768 * NUM_INPUT_BUCKETS, hidden_size);
            if use_factoriser {
                let l0f =
                    builder.new_weights("l0f", Shape::new(hidden_size, 768), InitSettings::Zeroed);
                l0.weights = l0.weights + l0f.repeat(NUM_INPUT_BUCKETS);
            }
            let l1 = builder.new_affine("l1", hidden_size, NUM_OUTPUT_BUCKETS * L1_SIZE);
            let l2 = builder.new_affine("l2", L2_INPUTS, NUM_OUTPUT_BUCKETS * L2_SIZE);
            let l3 = builder.new_affine("l3", L2_SIZE, NUM_OUTPUT_BUCKETS);

            // Pairwise: neuron i times neuron i + H/2, per perspective. Slicing the affine layer is
            // bullet's faster spelling of `l0.forward(x).crelu().pairwise_mul()`.
            let half = hidden_size / 2;
            let ft = |input, start, end| l0.slice(start, end).forward(input).crelu();
            let stm_hidden = ft(stm_inputs, 0, half) * ft(stm_inputs, half, hidden_size);
            let ntm_hidden = ft(ntm_inputs, 0, half) * ft(ntm_inputs, half, hidden_size);

            let l1_out = l1
                .forward(stm_hidden.concat(ntm_hidden))
                .select(output_buckets)
                .crelu();
            let dual = l1_out.concat(l1_out * l1_out);
            let l2_out = l2.forward(dual).select(output_buckets).crelu();
            l3.forward(l2_out).select(output_buckets)
        });

    if use_factoriser {
        crate::clip_factorised_feature_transformer(&mut trainer.optimiser);
    }
    let clip = |limit| AdamWParams {
        max_weight: limit,
        min_weight: -limit,
        ..Default::default()
    };
    trainer
        .optimiser
        .set_params_for_weight("l1w", clip(L1_WEIGHT_CLIP));
    for weights in ["l2w", "l3w"] {
        trainer
            .optimiser
            .set_params_for_weight(weights, clip(WEIGHT_CLIP));
    }

    resume_from_env(&mut trainer);
    run_trainer(Session {
        trainer: &mut trainer,
        inputs,
        saved_format: &save_format,
        cfg: &cfg,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_matches_the_engine() {
        let bytes = header(16, 1024);
        assert_eq!(bytes.len(), 64);
        assert_eq!(&bytes[..8], b"AVALNNUE");
        let fields: Vec<u32> = bytes[8..]
            .chunks_exact(4)
            .map(|chunk| u32::from_le_bytes(chunk.try_into().unwrap()))
            .collect();
        assert_eq!(
            fields,
            [1, 1, 16, 1024, 8, 16, 32, 255, 9, 13, 10, 400, 0, 0]
        );
    }

    #[test]
    fn l1_layout_groups_blocks_of_four_inputs() {
        let inputs = 8;
        let rows = NUM_OUTPUT_BUCKETS * L1_SIZE;
        // Each weight encodes where it came from.
        let code = |bucket: usize, input: usize, output: usize| {
            ((bucket * 100 + input) * 100 + output) as f32 / 1_000_000.0
        };
        let mut values = vec![0.0; rows * inputs];
        for bucket in 0..NUM_OUTPUT_BUCKETS {
            for input in 0..inputs {
                for output in 0..L1_SIZE {
                    values[input * rows + bucket * L1_SIZE + output] = code(bucket, input, output);
                }
            }
        }

        let layout = l1_weights_layout(&values, inputs);
        let at = |bucket: usize, block: usize, output: usize, k: usize| {
            layout[((bucket * 2 + block) * L1_SIZE + output) * 4 + k]
        };
        for (bucket, block, output, k) in [(0, 0, 0, 0), (3, 1, 7, 2), (7, 1, 15, 3)] {
            let expected = f64::from(code(bucket, block * 4 + k, output)) * L1_WEIGHT_SCALE;
            assert!((f64::from(at(bucket, block, output, k)) - expected).abs() < 1e-4);
        }
    }

    #[test]
    fn l2_layout_is_one_column_per_input() {
        let rows = NUM_OUTPUT_BUCKETS * L2_SIZE;
        let mut values = vec![0.0; rows * L2_INPUTS];
        values[5 * rows + 3 * L2_SIZE + 9] = 1.0; // input 5, bucket 3, output 9
        let layout = l2_weights_layout(&values);
        assert_eq!(layout[(3 * L2_INPUTS + 5) * L2_SIZE + 9], 1.0);
        assert_eq!(layout.iter().filter(|&&weight| weight != 0.0).count(), 1);
    }

    #[test]
    fn clipped_weights_quantise_into_range() {
        assert!((f64::from(L1_WEIGHT_CLIP) * L1_WEIGHT_SCALE).round() <= 127.0);
        assert!((WEIGHT_CLIP * (1 << WEIGHT_BITS) as f32).round() <= 2047.0);
    }
}
