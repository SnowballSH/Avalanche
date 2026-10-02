//! `TRAIN_INIT_NET`: start a single-layer run from the weights of a quantised net file instead of a
//! random initialisation, for fine-tuning a net whose float checkpoint no longer exists.
//!
//! The file is the one the single-layer save format writes (docs/NNUE.md): `l0w`, `l0b`, `l1w`, `l1b` as
//! little-endian i16, then padding to a multiple of 64 bytes. Reading it back inverts that format, and
//! saving the result without a training step reproduces the file byte for byte.

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
/// bullet pads a quantised file to a multiple of this many bytes.
const FILE_ALIGNMENT: usize = 64;

/// One weight of the graph as the single-layer save format stores it.
struct Section {
    id: &'static str,
    /// The file holds `round(weight * quantum)`.
    quantum: i16,
    /// The file is row-major where bullet's weights are column-major.
    transposed: bool,
}

/// In file order; `run_buckets16` and `run_chess768` in main.rs write exactly these.
const SECTIONS: [Section; 4] = [
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

/// A float whose `round(weight * quantum)`, the save format's quantisation, is `stored` again: an f32
/// quotient is off by a relative 2^-24, far less than half a quantum for any i16.
fn dequantise(stored: i16, quantum: i16) -> f32 {
    f32::from(stored) / f32::from(quantum)
}

/// Inverse of bullet's `SavedFormat::transpose`.
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
        .chunks_exact(STORED_BYTES)
        .map(|bytes| dequantise(i16::from_le_bytes([bytes[0], bytes[1]]), section.quantum))
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
    let payload: usize = SECTIONS
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

/// Replaces the weights of a single-layer graph by those of the quantised file `net`. A factoriser
/// becomes zero: the file's feature weights already contain it.
pub fn load_into(weights: &mut ModelWeights, net: &[u8]) -> Result<(), String> {
    validate(weights, net)?;

    let mut offset = 0;
    for section in &SECTIONS {
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

/// How many values the optimiser's clipping to `±clip` would move to a different stored integer.
fn changed_by_clip(values: &[f32], quantum: i16, clip: f32) -> usize {
    let stored = |weight: f32| (f64::from(weight) * f64::from(quantum)).round();
    values
        .iter()
        .filter(|&&weight| stored(weight.clamp(-clip, clip)) != stored(weight))
        .count()
}

/// The optimiser clips every weight on each step, so a loaded weight outside the clip would jump on
/// the first one. `feature_weight_clip` is the clip of `l0w`; the rest have bullet's default.
pub fn check_clips(weights: &ModelWeights, feature_weight_clip: f32) -> Result<(), String> {
    let default_clip = AdamWParams::default().max_weight;
    for section in &SECTIONS {
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

/// Loads the net file at `path` into the optimiser's weights; the optimiser state stays fresh.
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

    const NEZHA: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../nets/nezha.nnue");
    const NEZHA_HIDDEN: usize = 1024;

    /// The weights `run_buckets16` trains, built without a device.
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

    /// What bullet's `save_quantised` writes for these weights.
    fn saved(weights: &ModelWeights, use_factoriser: bool) -> Vec<u8> {
        weights
            .to_quantised_buffer(&buckets16_save_format(use_factoriser), true)
            .unwrap()
    }

    fn assert_reproduces_nezha(use_factoriser: bool) {
        let nezha = std::fs::read(NEZHA).unwrap();
        let mut weights = buckets16_weights(NEZHA_HIDDEN, use_factoriser);
        if use_factoriser {
            let size = weights.get(FACTORISER).values.size();
            assert!(weights.set(FACTORISER, TValue::F32(vec![1.0; size])));
        }
        load_into(&mut weights, &nezha).unwrap();
        assert!(saved(&weights, use_factoriser) == nezha);
    }

    #[test]
    fn nezha_loaded_and_saved_is_the_same_file_with_a_factoriser() {
        assert_reproduces_nezha(true);
    }

    #[test]
    fn nezha_loaded_and_saved_is_the_same_file_without_a_factoriser() {
        assert_reproduces_nezha(false);
    }

    #[test]
    fn every_stored_value_survives_the_save_quantisation() {
        for section in &SECTIONS {
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
        let nezha = std::fs::read(NEZHA).unwrap();
        let mut weights = buckets16_weights(NEZHA_HIDDEN / 2, true);
        let error = load_into(&mut weights, &nezha).unwrap_err();
        assert!(error.contains("25200704 bytes"), "{error}");

        let mut weights = buckets16_weights(NEZHA_HIDDEN, true);
        let error = load_into(&mut weights, &nezha[..nezha.len() - 1]).unwrap_err();
        assert!(error.contains("is 25200704 bytes"), "{error}");
    }

    #[test]
    fn a_multilayer_net_is_refused() {
        let mut net = std::fs::read(NEZHA).unwrap();
        net[..8].copy_from_slice(b"AVALNNUE");
        let mut weights = buckets16_weights(NEZHA_HIDDEN, true);
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
    fn nezha_fits_the_default_clip_but_not_the_factorised_one() {
        let nezha = std::fs::read(NEZHA).unwrap();
        let mut weights = buckets16_weights(NEZHA_HIDDEN, false);
        load_into(&mut weights, &nezha).unwrap();
        check_clips(&weights, AdamWParams::default().max_weight).unwrap();
        let error = check_clips(&weights, FACTORISED_CLIP).unwrap_err();
        assert!(error.contains("16036 of its l0w weights"), "{error}");
    }
}
