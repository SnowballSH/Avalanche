//! See "Fine-tuning from a shipped net" in docs/NNUE.md.

use bullet::nn::{ExecutionContext, Shape, optimiser::AdamWParams};
use bullet_compiler::tensor::TValue;
use bullet_trainer::{
    model::ModelWeights,
    optimiser::{Optimiser, OptimiserState},
};

use crate::{QA, QB, multilayer};

const FEATURE_WEIGHTS: &str = "l0w";
const FACTORISER: &str = "l0f";
const STORED_BYTES: usize = size_of::<i16>();
const FILE_ALIGNMENT: usize = 64;

struct Section {
    id: &'static str,
    quantum: i16,
    transposed: bool,
}

const SECTIONS_IN_FILE_ORDER: [Section; 4] = [
    Section {
        id: FEATURE_WEIGHTS,
        quantum: QA,
        transposed: false,
    },
    Section {
        id: "l0b",
        quantum: QA,
        transposed: false,
    },
    Section {
        id: "l1w",
        quantum: QB,
        transposed: true,
    },
    Section {
        id: "l1b",
        quantum: QA * QB,
        transposed: false,
    },
];

fn dequantise(stored: i16, quantum: i16) -> f32 {
    f32::from(stored) / f32::from(quantum)
}

fn column_major(row_major: &[f32], shape: Shape) -> Vec<f32> {
    let (rows, cols) = (shape.rows(), shape.cols());
    let mut values = vec![0.0; row_major.len()];
    for row in 0..rows {
        for col in 0..cols {
            values[rows * col + row] = row_major[cols * row + col];
        }
    }
    values
}

fn section_values(section: &Section, stored: &[u8], shape: Shape) -> Vec<f32> {
    let file_order: Vec<f32> = stored
        .as_chunks::<STORED_BYTES>()
        .0
        .iter()
        .map(|bytes| dequantise(i16::from_le_bytes(*bytes), section.quantum))
        .collect();
    if section.transposed {
        column_major(&file_order, shape)
    } else {
        file_order
    }
}

fn has_weight(weights: &ModelWeights, id: &str) -> bool {
    weights.iter().any(|(name, _)| name == id)
}

fn validate(weights: &ModelWeights, net: &[u8]) -> Result<(), String> {
    if multilayer::is_multilayer_file(net) {
        return Err(String::from(
            "it is a multi-layer (format v2, AVALNNUE) net; only a single-layer net can initialise \
             a run",
        ));
    }
    let payload: usize = SECTIONS_IN_FILE_ORDER
        .iter()
        .map(|section| weights.get(section.id).values.size() * STORED_BYTES)
        .sum();
    let expected = payload.next_multiple_of(FILE_ALIGNMENT);
    if net.len() != expected {
        return Err(format!(
            "it is {} bytes, but a net of this run's input layout and hidden size is {expected} bytes",
            net.len()
        ));
    }
    Ok(())
}

pub fn load_into(weights: &mut ModelWeights, net: &[u8]) -> Result<(), String> {
    validate(weights, net)?;

    let mut offset = 0;
    for section in &SECTIONS_IN_FILE_ORDER {
        let (size, shape) = {
            let current = weights.get(section.id);
            (current.values.size(), current.shape)
        };
        let stored = &net[offset..offset + size * STORED_BYTES];
        offset += stored.len();
        let values = section_values(section, stored, shape);
        assert!(weights.set(section.id, TValue::F32(values)));
    }

    if has_weight(weights, FACTORISER) {
        let size = weights.get(FACTORISER).values.size();
        assert!(weights.set(FACTORISER, TValue::F32(vec![0.0; size])));
    }
    Ok(())
}

fn changed_by_clip(values: &[f32], quantum: i16, clip: f32) -> usize {
    let stored = |weight: f32| (f64::from(weight) * f64::from(quantum)).round();
    values
        .iter()
        .filter(|&&weight| stored(weight.clamp(-clip, clip)) != stored(weight))
        .count()
}

pub fn check_clips(weights: &ModelWeights, feature_weight_clip: f32) -> Result<(), String> {
    let default_clip = AdamWParams::default().max_weight;
    for section in &SECTIONS_IN_FILE_ORDER {
        let clip = if section.id == FEATURE_WEIGHTS {
            feature_weight_clip
        } else {
            default_clip
        };
        let values = weights.get(section.id).values.f32();
        let changed = changed_by_clip(values, section.quantum, clip);
        if changed > 0 {
            let hint = if clip < default_clip {
                format!("; TRAIN_FACTORISER=0 clips them to ±{default_clip} instead")
            } else {
                String::new()
            };
            return Err(format!(
                "{changed} of its {} weights are outside the ±{clip} the optimiser clips them to, so \
                 the first training step would change the net{hint}",
                section.id
            ));
        }
    }
    Ok(())
}

pub fn init_optimiser<Opt>(
    optimiser: &mut Optimiser<ExecutionContext, Opt>,
    path: &str,
    feature_weight_clip: f32,
) -> Result<(), String>
where
    Opt: OptimiserState<ExecutionContext>,
{
    let net = std::fs::read(path).map_err(|err| format!("cannot read it: {err}"))?;
    let mut weights = optimiser
        .cpu_weights()
        .map_err(|err| format!("cannot read the graph's weights: {err:?}"))?
        .clone();
    load_into(&mut weights, &net)?;
    check_clips(&weights, feature_weight_clip)?;
    weights
        .write_to_device(optimiser.weights())
        .map_err(|err| format!("cannot write the weights to the device: {err:?}"))
}

#[cfg(test)]
mod tests {
    use bullet::{
        game::inputs::{ChessBucketsMirrored, SparseInputType},
        nn::ModelBuilder,
    };
    use bullet_trainer::model::{ModelDefinition, QuantTarget};

    use super::*;
    use crate::{
        BUCKET_LAYOUT_16, FACTORISED_CLIP, NUM_OUTPUT_BUCKETS, bucketed_single_head,
        buckets16_save_format,
    };

    const SINGLE_LAYER_NET: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../nets/dianguang-1.nnue");
    const HIDDEN: usize = 1024;

    fn buckets16_weights(hidden_size: usize, use_factoriser: bool) -> ModelWeights {
        let inputs = ChessBucketsMirrored::new(BUCKET_LAYOUT_16);
        let builder = ModelBuilder::default();
        let input_shape = (inputs.num_inputs(), 1);
        let stm = builder.new_sparse_input("stm", input_shape, inputs.max_active());
        let ntm = builder.new_sparse_input("nstm", input_shape, inputs.max_active());
        let buckets = builder.new_sparse_input("buckets", (NUM_OUTPUT_BUCKETS, 1), 1);
        let output = bucketed_single_head(&builder, stm, ntm, buckets, hidden_size, use_factoriser);
        let definition = ModelDefinition::new(
            builder.ir().clone(),
            None,
            [(output.node(), String::from("output"))],
        );
        ModelWeights::new(&definition, 1)
    }

    fn saved(weights: &ModelWeights, use_factoriser: bool) -> Vec<u8> {
        weights
            .to_quantised_buffer(&buckets16_save_format(use_factoriser), true)
            .unwrap()
    }

    fn assert_reproduces_the_file(use_factoriser: bool) {
        let net = std::fs::read(SINGLE_LAYER_NET).unwrap();
        let mut weights = buckets16_weights(HIDDEN, use_factoriser);
        if use_factoriser {
            let size = weights.get(FACTORISER).values.size();
            assert!(weights.set(FACTORISER, TValue::F32(vec![1.0; size])));
        }
        load_into(&mut weights, &net).unwrap();
        assert!(saved(&weights, use_factoriser) == net);
    }

    #[test]
    fn a_net_loaded_and_saved_is_the_same_file_with_a_factoriser() {
        assert_reproduces_the_file(true);
    }

    #[test]
    fn a_net_loaded_and_saved_is_the_same_file_without_a_factoriser() {
        assert_reproduces_the_file(false);
    }

    #[test]
    fn every_stored_value_survives_the_save_quantisation() {
        for section in &SECTIONS_IN_FILE_ORDER {
            let stored: Vec<i16> = (i16::MIN..=i16::MAX).collect();
            let floats: Vec<f32> = stored
                .iter()
                .map(|&value| dequantise(value, section.quantum))
                .collect();
            let requantised = QuantTarget::I16(section.quantum)
                .quantise(true, &floats)
                .unwrap();
            let expected: Vec<u8> = stored
                .iter()
                .flat_map(|value| value.to_le_bytes())
                .collect();
            assert!(requantised == expected, "quantum {}", section.quantum);
        }
    }

    #[test]
    fn a_net_of_another_size_is_refused() {
        let net = std::fs::read(SINGLE_LAYER_NET).unwrap();
        let mut weights = buckets16_weights(HIDDEN / 2, true);
        let error = load_into(&mut weights, &net).unwrap_err();
        assert!(error.contains(&format!("{} bytes", net.len())), "{error}");

        let mut weights = buckets16_weights(HIDDEN, true);
        let error = load_into(&mut weights, &net[..net.len() - 1]).unwrap_err();
        assert!(
            error.contains(&format!("is {} bytes", net.len())),
            "{error}"
        );
    }

    #[test]
    fn a_multilayer_net_is_refused() {
        let mut net = std::fs::read(SINGLE_LAYER_NET).unwrap();
        net[..8].copy_from_slice(b"AVALNNUE");
        let mut weights = buckets16_weights(HIDDEN, true);
        let error = load_into(&mut weights, &net).unwrap_err();
        assert!(error.contains("multi-layer"), "{error}");
    }

    #[test]
    fn clipping_counts_only_weights_whose_stored_value_would_move() {
        let weights = [0.5, 252.0 / 255.0, 253.0 / 255.0, -505.0 / 255.0];
        assert_eq!(changed_by_clip(&weights, QA, FACTORISED_CLIP), 2);
        // -505 / 255 is outside ±1.98, but 1.98 still rounds to 505.
        assert_eq!(changed_by_clip(&weights, QA, 1.98), 0);
    }

    #[test]
    fn a_net_trained_with_a_factoriser_fits_the_default_clip_but_not_the_factorised_one() {
        let net = std::fs::read(SINGLE_LAYER_NET).unwrap();
        let mut weights = buckets16_weights(HIDDEN, false);
        load_into(&mut weights, &net).unwrap();
        check_clips(&weights, AdamWParams::default().max_weight).unwrap();

        let feature_weights = weights.get(FEATURE_WEIGHTS).values.f32();
        let beyond = changed_by_clip(feature_weights, QA, FACTORISED_CLIP);
        assert!(beyond > 0);
        let error = check_clips(&weights, FACTORISED_CLIP).unwrap_err();
        assert!(
            error.contains(&format!("{beyond} of its l0w weights")),
            "{error}"
        );
    }
}
