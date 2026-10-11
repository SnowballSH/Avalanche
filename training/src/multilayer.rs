//! See "Multi-layer head" in docs/NNUE.md.

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
    Arch, BUCKET_LAYOUT_16, EVAL_SCALE, NUM_OUTPUT_BUCKETS, QA, Session, TrainConfig,
    feature_transformer_format, print_banner, resume_from_env, run_trainer,
};

const L1_SIZE: usize = 16;
const L2_SIZE: usize = 32;
const L2_INPUTS: usize = 2 * L1_SIZE;

const FT_SHIFT: u32 = 9;
const ACT_BITS: u32 = 13;
const WEIGHT_BITS: u32 = 10;
const SUM_BITS: u32 = ACT_BITS + WEIGHT_BITS;

const FORMAT_VERSION: u32 = 2;
const HEAD_MULTI: u32 = 1;
const MAGIC: &[u8; 8] = b"AVALNNUE";
const HEADER_SIZE: usize = 64;

pub fn is_multilayer_file(first_bytes: &[u8]) -> bool {
    first_bytes.starts_with(MAGIC)
}

const FT_EFFECTIVE_INPUTS: usize = 32;

const L1_WEIGHT_SCALE: f64 = (1u64 << (ACT_BITS + FT_SHIFT)) as f64 / (QA as f64 * QA as f64);
const L1_SHIFT_MAX: u32 = 7;
const L1_WEIGHT_CLIP: f32 = (126.9 / L1_WEIGHT_SCALE) as f32;
const WEIGHT_CLIP: f32 = 1.98;

const _: () = assert!(
    WEIGHT_CLIP * ((1u32 << WEIGHT_BITS) as f32) < 2047.0,
    "L2 and L3 weights must fit the engine's range"
);

/// `l1_shift` and the layout both go through this, so the shift is chosen on exactly the numbers that
/// get rounded.
fn l1_stored(weight: f32, shift: u32) -> f32 {
    (f64::from(weight) * L1_WEIGHT_SCALE * f64::from(1u32 << shift)) as f32
}

fn l1_shift(l1_weights: &[f32]) -> u32 {
    let max = l1_weights
        .iter()
        .fold(0.0f32, |max, weight| max.max(weight.abs()));
    let mut shift = 0;
    while shift < L1_SHIFT_MAX && l1_stored(max, shift + 1).round() <= 127.0 {
        shift += 1;
    }
    shift
}

fn header(input_buckets: usize, hidden_size: usize, l1_shift: u32) -> Vec<u8> {
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
        l1_shift,
    ];
    let mut bytes = MAGIC.to_vec();
    for field in fields {
        bytes.extend_from_slice(&field.to_le_bytes());
    }
    bytes.resize(HEADER_SIZE, 0);
    bytes
}

/// bullet keeps the weights of an affine layer column-major, `values[input * rows + row]`, and a
/// bucketed layer's row is `bucket * outputs + output`.
fn l1_weights_layout(values: &[f32], inputs: usize, shift: u32) -> Vec<f32> {
    let rows = NUM_OUTPUT_BUCKETS * L1_SIZE;
    assert_eq!(values.len(), rows * inputs);
    assert_eq!(inputs % 4, 0);
    let blocks = inputs / 4;

    let mut layout = vec![0.0; values.len()];
    for bucket in 0..NUM_OUTPUT_BUCKETS {
        for input in 0..inputs {
            for output in 0..L1_SIZE {
                let weight = values[input * rows + bucket * L1_SIZE + output];
                let index = ((bucket * blocks + input / 4) * L1_SIZE + output) * 4 + input % 4;
                layout[index] = l1_stored(weight, shift);
            }
        }
    }
    layout
}

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

fn report_max(name: &'static str, stored_scale: f64, stored_limit: f64) -> impl Fn(&[f32]) {
    move |values| {
        let max = values
            .iter()
            .fold(0.0f32, |max, value| max.max(value.abs()));
        println!(
            "  {name}: max |value| {max:.4}, stored as {:.0} of {stored_limit:.0}",
            (f64::from(max) * stored_scale).round()
        );
    }
}

fn save_format(input_buckets: usize, hidden_size: usize, use_factoriser: bool) -> Vec<SavedFormat> {
    let weight_one = f64::from(1u32 << WEIGHT_BITS);
    let bias_limit = f64::from(1u32 << 30);
    let reported = |id: &'static str, scale: f64, limit: f64| {
        let report = report_max(id, scale, limit);
        SavedFormat::id(id).transform(move |_, values| {
            report(&values);
            values
        })
    };

    // The header depends on the weights being saved, through the L1 shift, so it is not a fixed
    // `SavedFormat::custom`. It is written byte by byte as i8, and has no id, which keeps it out of
    // bullet's raw.bin.
    let header_format = SavedFormat::empty()
        .transform(move |store, _| {
            let shift = l1_shift(store.get("l1w").values.f32());
            header(input_buckets, hidden_size, shift)
                .into_iter()
                .map(|byte| f32::from(byte as i8))
                .collect()
        })
        .quantise::<i8>(1);

    let mut format = vec![header_format];
    format.extend(feature_transformer_format(use_factoriser, input_buckets));
    format.extend([
        SavedFormat::id("l1w")
            .transform(move |_, values| {
                let shift = l1_shift(&values);
                report_max("l1w", L1_WEIGHT_SCALE * f64::from(1u32 << shift), 127.0)(&values);
                println!("  l1w: L1 shift {shift} of {L1_SHIFT_MAX}");
                l1_weights_layout(&values, hidden_size, shift)
            })
            .round()
            .quantise::<i8>(1),
        SavedFormat::id("l1b")
            .transform(move |store, values| {
                let scale = f64::from(1u32 << (ACT_BITS + l1_shift(store.get("l1w").values.f32())));
                report_max("l1b", scale, bias_limit)(&values);
                values
                    .into_iter()
                    .map(|bias| (f64::from(bias) * scale) as f32)
                    .collect()
            })
            .round()
            .quantise::<i32>(1),
        reported("l2w", weight_one, 2047.0)
            .transform(|_, values| l2_weights_layout(&values))
            .round()
            .quantise::<i32>(1 << WEIGHT_BITS),
        reported("l2b", f64::from(1u32 << SUM_BITS), bias_limit)
            .round()
            .quantise::<i32>(1 << SUM_BITS),
        // Rows are buckets here, so the transpose is already `[bucket][input]`.
        reported("l3w", weight_one, 2047.0)
            .transpose()
            .round()
            .quantise::<i32>(1 << WEIGHT_BITS),
        reported("l3b", f64::from(1u32 << SUM_BITS), bias_limit)
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
    let l1_sparsity = cfg.l1_sparsity;
    if l1_sparsity > 0.0 {
        println!(
            "L1 sparsity penalty: {l1_sparsity} x mean pairwise activation, added to the training loss"
        );
        println!("  (the printed training loss includes it; the validation loss does not)");
        println!();
    }

    let save_format = save_format(NUM_INPUT_BUCKETS, hidden_size, use_factoriser);
    let inputs = ChessBucketsMirrored::new(BUCKET_LAYOUT_16);
    let mut trainer = ValueTrainerBuilder::default()
        .dual_perspective()
        .optimiser(AdamW)
        .inputs(inputs)
        .output_buckets(MaterialCount::<NUM_OUTPUT_BUCKETS>)
        .save_format(&save_format)
        .build_custom(
            move |builder, (stm_inputs, ntm_inputs, output_buckets), target| {
                let mut l0 = builder.new_affine("l0", 768 * NUM_INPUT_BUCKETS, hidden_size);
                l0.init_with_effective_input_size(FT_EFFECTIVE_INPUTS);
                if use_factoriser {
                    let l0f = builder.new_weights(
                        "l0f",
                        Shape::new(hidden_size, 768),
                        InitSettings::Zeroed,
                    );
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

                let pairwise = stm_hidden.concat(ntm_hidden);

                let l1_out = l1.forward(pairwise).select(output_buckets).crelu();
                let dual = l1_out.concat(l1_out * l1_out);
                let l2_out = l2.forward(dual).select(output_buckets).crelu();
                let output = l3.forward(l2_out).select(output_buckets);

                let mut loss = output.sigmoid().squared_error(target);
                if l1_sparsity > 0.0 {
                    let mean_activation = pairwise.reduce_sum_rows() / (hidden_size as f32);
                    loss = loss + l1_sparsity * mean_activation;
                }
                (output, loss)
            },
        );

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

    resume_from_env(&mut trainer, Arch::Multi);
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
        let bytes = header(16, 1024, 3);
        assert_eq!(bytes.len(), 64);
        assert_eq!(&bytes[..8], b"AVALNNUE");
        let fields: Vec<u32> = bytes[8..]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|chunk| u32::from_le_bytes(*chunk))
            .collect();
        assert_eq!(
            fields,
            [2, 1, 16, 1024, 8, 16, 32, 255, 9, 13, 10, 400, 3, 0]
        );
    }

    #[test]
    fn l1_layout_groups_blocks_of_four_inputs() {
        let inputs = 8;
        let rows = NUM_OUTPUT_BUCKETS * L1_SIZE;
        let source_tag = |bucket: usize, input: usize, output: usize| {
            ((bucket * 100 + input) * 100 + output) as f32 / 1_000_000.0
        };
        let mut values = vec![0.0; rows * inputs];
        for bucket in 0..NUM_OUTPUT_BUCKETS {
            for input in 0..inputs {
                for output in 0..L1_SIZE {
                    values[input * rows + bucket * L1_SIZE + output] =
                        source_tag(bucket, input, output);
                }
            }
        }

        let shift = 2;
        let layout = l1_weights_layout(&values, inputs, shift);
        let at = |bucket: usize, block: usize, output: usize, k: usize| {
            layout[((bucket * 2 + block) * L1_SIZE + output) * 4 + k]
        };
        for (bucket, block, output, k) in [(0, 0, 0, 0), (3, 1, 7, 2), (7, 1, 15, 3)] {
            let expected =
                f64::from(source_tag(bucket, block * 4 + k, output)) * L1_WEIGHT_SCALE * 4.0;
            assert!((f64::from(at(bucket, block, output, k)) - expected).abs() < 1e-4);
        }
    }

    const SHIFTS_THE_ENGINE_TESTS_ALSO_ASSERT: [(&[f32], u32); 6] = [
        (&[0.5, -1.9689], 0),
        (&[1.0], 0),
        (&[-0.98, 0.1], 1),
        (&[0.2166, -0.01], 3),
        (&[0.001], L1_SHIFT_MAX),
        (&[0.0], L1_SHIFT_MAX),
    ];

    #[test]
    fn l1_shift_fills_the_i8_range() {
        for (l1_weights, shift) in SHIFTS_THE_ENGINE_TESTS_ALSO_ASSERT {
            assert_eq!(l1_shift(l1_weights), shift, "{l1_weights:?}");
        }
        assert_eq!(l1_shift(&[L1_WEIGHT_CLIP, -L1_WEIGHT_CLIP]), 0);

        for step in 1..2000 {
            let max = step as f32 * 0.001;
            if max > L1_WEIGHT_CLIP {
                break;
            }
            let shift = l1_shift(&[max, -max / 3.0]);
            let stored = l1_stored(max, shift).round();
            assert!(
                stored <= 127.0,
                "{max} at shift {shift} is stored as {stored}"
            );
            assert!(
                shift == L1_SHIFT_MAX || stored >= 63.0,
                "{max} wastes range at shift {shift}"
            );
        }
    }

    #[test]
    fn l2_layout_is_one_column_per_input() {
        let rows = NUM_OUTPUT_BUCKETS * L2_SIZE;
        let (input, bucket, output) = (5, 3, 9);
        let mut values = vec![0.0; rows * L2_INPUTS];
        values[input * rows + bucket * L2_SIZE + output] = 1.0;
        let layout = l2_weights_layout(&values);
        assert_eq!(layout[(bucket * L2_INPUTS + input) * L2_SIZE + output], 1.0);
        assert_eq!(layout.iter().filter(|&&weight| weight != 0.0).count(), 1);
    }

    #[test]
    fn clipped_weights_quantise_into_range() {
        assert!((f64::from(L1_WEIGHT_CLIP) * L1_WEIGHT_SCALE).round() <= 127.0);
        assert!((WEIGHT_CLIP * (1 << WEIGHT_BITS) as f32).round() <= 2047.0);
    }
}
