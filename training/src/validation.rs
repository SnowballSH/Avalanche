//! Held-out validation. bullet's `ValueTrainer::run` has neither a validation pass nor a superbatch hook,
//! so a validated run drives `bullet_trainer::run::train` directly, the layer `ValueTrainer::run` wraps.

use std::{
    cell::RefCell,
    collections::BTreeMap,
    fmt::Debug,
    fs::File,
    io::{BufRead, BufReader},
    sync::Arc,
};

use bullet::{
    game::{formats::bulletformat::ChessBoard, inputs::SparseInputType, outputs::OutputBuckets},
    nn::ExecutionContext,
    trainer::{
        save::SavedFormat,
        schedule::{TrainingSchedule, lr::LrScheduler, wdl::WdlScheduler},
        settings::LocalSettings,
    },
    value::{loader::LoadableDataType, save},
};
use bullet_compiler::{
    ir::NodeId,
    tensor::{DType, TValue},
};
use bullet_gpu::{buffer::Buffer, function::Function, runtime::Stream};
use bullet_trainer::{
    model::{ModelDefinition, ModelInputs, ModelInputsMapper, TensorMap},
    optimiser::{Optimiser, OptimiserState},
    reader::{DataReader, ReadMapLoader},
    run::{self, HostPool, Step, logger},
};
use viriformat::{
    chess::{board::Board, chessmove::Move},
    dataformat::{Game, WDL},
};

type DeviceBuffer = Arc<Buffer<ExecutionContext>>;

/// Same shape as bullet's `ViriFilter::Custom`: whether to keep a position, given its game result as
/// 1.0, 0.5 or 0.0.
pub type PositionFilter = fn(&Board, Move, i16, f32) -> bool;

pub struct ValidationConfig {
    pub files: Vec<String>,
    pub batches: usize,
    pub filter: PositionFilter,
}

/// For bullet's GPU and training errors, which implement `Debug` but not `Display`.
fn describe(error: impl Debug) -> String {
    format!("{error:?}")
}

fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

fn result_score(wdl: WDL) -> f32 {
    match wdl {
        WDL::Win => 1.0,
        WDL::Draw => 0.5,
        WDL::Loss => 0.0,
    }
}

/// Appends the positions of `path` that pass `filter`, game by game in file order, stopping after the
/// game that brings `positions` to `count`.
fn append_file_positions(
    path: &str,
    filter: PositionFilter,
    count: usize,
    positions: &mut Vec<ChessBoard>,
) -> Result<(), String> {
    let invalid = |err: &dyn std::fmt::Display| format!("validation file {path}: {err}");
    let file = File::open(path).map_err(|err| invalid(&err))?;
    let mut reader = BufReader::new(file);
    let mut moves = Vec::new();

    while positions.len() < count && !reader.fill_buf().map_err(|err| invalid(&err))?.is_empty() {
        let game = Game::deserialise_from(&mut reader, moves).map_err(|err| invalid(&err))?;
        game.splat_to_bulletformat_with_filter_callback(
            |position| {
                positions.push(position);
                Ok(())
            },
            |mv, eval, board, wdl, _| !filter(board, mv, eval as i16, result_score(wdl)),
        )
        .map_err(|err| invalid(&err))?;
        moves = game.moves;
    }
    Ok(())
}

/// The first `count` positions of `files` that pass `filter`, in file and game order.
///
/// The files are parsed here rather than through bullet's `ViriBinpackLoader`, which shuffles with a
/// time seed and loops over its files forever: this way the set is identical on every run and resume
/// for any batch size, and held-out files that are too small are an error instead of repeated positions.
fn load_positions(
    files: &[String],
    filter: PositionFilter,
    count: usize,
) -> Result<Vec<ChessBoard>, String> {
    let mut positions = Vec::with_capacity(count);
    for path in files {
        append_file_positions(path, filter, count, &mut positions)?;
    }

    if positions.len() < count {
        return Err(format!(
            "the validation files hold {} positions that pass the filter, but TRAIN_VALIDATION_BATCHES \
             x TRAIN_BATCH_SIZE needs {count}",
            positions.len()
        ));
    }
    positions.truncate(count);
    Ok(positions)
}

/// Mirrors the mapper `ValueTrainer` builds privately for a scalar-output net without datapoint weights
/// or a win-rate model, which is how both of this trainer's nets are built.
fn value_mapper<I, O>(
    inputs: I,
    buckets: O,
    eval_scale: f32,
    wdl: impl WdlScheduler,
) -> ModelInputsMapper<ChessBoard>
where
    I: SparseInputType<RequiredDataType = ChessBoard>,
    O: OutputBuckets<ChessBoard>,
{
    let num_inputs = inputs.num_inputs();
    let max_active = inputs.max_active();
    let score_scale = 1.0 / eval_scale;

    let layout = ModelInputs::default()
        .add_sparse("stm", (num_inputs, 1), max_active)
        .add_sparse("nstm", (num_inputs, 1), max_active)
        .add_sparse("buckets", (1, 1), 1)
        .add_dense("targets", (1, 1))
        .add_dense("entry_weights", (1, 1));

    ModelInputsMapper::build(
        &layout,
        move |pos: &ChessBoard, step, ((((stm, ntm), bucket), targets), weights)| {
            let mut active = 0;
            inputs.map_features(pos, |our, opp| {
                assert!(
                    our < num_inputs && opp < num_inputs,
                    "Input feature index exceeded input size!"
                );
                stm[active] = our as i32;
                ntm[active] = opp as i32;
                active += 1;
            });
            assert!(
                active <= max_active,
                "More inputs provided than the specified maximum!"
            );
            if active < max_active {
                stm[active] = -1;
                ntm[active] = -1;
            }

            bucket[0] = i32::from(buckets.bucket(pos));
            weights[0] = 1.0;

            let score = sigmoid(score_scale * f32::from(pos.score()));
            let result = f32::from(pos.result() as u8) / 2.0;
            let blend = wdl.blend(step.batch(), step.superbatch(), step.final_superbatch());
            assert!(
                (0.0..=1.0).contains(&blend),
                "WDL proportion must be in [0, 1]"
            );
            targets[0] = blend * result + (1.0 - blend) * score;
        },
    )
}

/// The summed batch loss from a forward-only function, after bullet's `ModelEvaluator`, which is fixed
/// to a batch size of 1.
///
/// It runs the model up to its output and applies the loss on the host: `(sigmoid(output) - target)²`,
/// the loss of both of this trainer's nets. The model's own loss node is not used, so a term a net adds
/// to its training loss (`TRAIN_L1_SPARSITY`) is not part of the validation loss, which stays comparable
/// between runs with different penalties.
struct LossEvaluator {
    stream: Arc<Stream<ExecutionContext>>,
    function: Function<ExecutionContext>,
    bound: BTreeMap<NodeId, DeviceBuffer>,
    weights: BTreeMap<String, NodeId>,
    inputs: BTreeMap<String, NodeId>,
    output: DeviceBuffer,
    batch_size: usize,
}

/// A device buffer that must hold one f32 per position of a batch.
fn batch_values(buffer: &DeviceBuffer, batch_size: usize, name: &str) -> Result<Vec<f32>, String> {
    match buffer.to_host().map_err(describe)? {
        TValue::F32(values) if values.len() == batch_size => Ok(values),
        other => Err(format!(
            "unexpected {name} tensor for a batch of {batch_size}: {other:?}"
        )),
    }
}

impl LossEvaluator {
    fn new<Opt: OptimiserState<ExecutionContext>>(
        optimiser: &Optimiser<ExecutionContext, Opt>,
        batch_size: usize,
    ) -> Result<Self, String> {
        let definition = optimiser.definition();
        let device = optimiser.device();
        let output_node = definition
            .outputs()
            .iter()
            .find(|(_, name)| name == "output")
            .map(|(node, _)| *node)
            .ok_or("the model defines no output")?;

        let output_only = ModelDefinition::new(
            definition.ir().clone(),
            None,
            [(output_node, String::from("output"))],
        );
        let forward = output_only
            .lower_forward(batch_size)
            .map_err(|err| err.to_string())?;
        let lowered = |node: &NodeId| {
            forward
                .map()
                .get(node)
                .copied()
                .ok_or_else(|| format!("model node {node:?} is missing from the lowered model"))
        };

        let weights = definition
            .ir()
            .weights()
            .iter()
            .map(|(node, (name, _))| Ok((name.clone(), lowered(node)?)))
            .collect::<Result<_, String>>()?;
        let inputs = definition
            .ir()
            .inputs()
            .iter()
            .map(|(node, name)| Ok((name.clone(), lowered(node)?)))
            .collect::<Result<_, String>>()?;

        let output_id = lowered(&output_node)?;
        let output = Buffer::zeroed(&device, DType::F32, batch_size).map_err(describe)?;
        let bound = BTreeMap::from([(output_id, output.clone())]);

        let stream = device.new_stream().map_err(describe)?;
        let mut function =
            Function::new(device, forward.ir().clone()).map_err(|err| err.to_string())?;
        function.prealloc().map_err(describe)?;

        Ok(Self {
            stream,
            function,
            bound,
            weights,
            inputs,
            output,
            batch_size,
        })
    }

    fn bind(&mut self, weights: &TensorMap<ExecutionContext>, batch: &TensorMap<ExecutionContext>) {
        let named = self.weights.iter().chain(&self.inputs);
        for (name, node) in named {
            if let Some(buffer) = weights.get(name).or_else(|| batch.get(name)) {
                self.bound.insert(*node, buffer.clone());
            }
        }
    }

    /// The loss summed over one batch, with the trainer's current weights.
    fn batch_loss(
        &mut self,
        weights: &TensorMap<ExecutionContext>,
        batch: &TensorMap<ExecutionContext>,
    ) -> Result<f64, String> {
        self.bind(weights, batch);
        self.function
            .execute(self.stream.clone(), &self.bound)
            .map_err(describe)?
            .value()
            .map_err(describe)?;

        let outputs = batch_values(&self.output, self.batch_size, "output")?;
        let targets = batch
            .get("targets")
            .ok_or("the batch has no targets")
            .map_err(String::from)
            .and_then(|buffer| batch_values(buffer, self.batch_size, "targets"))?;
        Ok(outputs
            .iter()
            .zip(&targets)
            .map(|(&output, &target)| f64::from(sigmoid(output) - target).powi(2))
            .sum())
    }
}

struct Validator {
    positions: Vec<ChessBoard>,
    batch_size: usize,
    mapper: ModelInputsMapper<ChessBoard>,
    pool: Arc<HostPool<ExecutionContext>>,
    evaluator: LossEvaluator,
    threads: u8,
}

impl Validator {
    fn new<Opt: OptimiserState<ExecutionContext>>(
        optimiser: &Optimiser<ExecutionContext, Opt>,
        mapper: ModelInputsMapper<ChessBoard>,
        config: &ValidationConfig,
        batch_size: usize,
        threads: u8,
    ) -> Result<Self, String> {
        let positions = load_positions(&config.files, config.filter, config.batches * batch_size)?;
        Ok(Self {
            positions,
            batch_size,
            mapper,
            pool: HostPool::new(optimiser.device()),
            evaluator: LossEvaluator::new(optimiser, batch_size)?,
            threads,
        })
    }

    /// Mean loss per position, normalised like the training loss bullet reports. Targets use the WDL
    /// blend of `step`, so the value is comparable to the training loss of the same superbatch, less
    /// any `TRAIN_L1_SPARSITY` penalty, which only the training loss contains.
    fn mean_loss<Opt: OptimiserState<ExecutionContext>>(
        &mut self,
        optimiser: &Optimiser<ExecutionContext, Opt>,
        step: Step,
    ) -> Result<f32, String> {
        let device = optimiser.device();
        let mut total = 0.0;
        for batch in self.positions.chunks_exact(self.batch_size) {
            let host = self
                .mapper
                .map(&self.pool, batch, step, self.threads)
                .map_err(describe)?;
            let on_device = host.to_device(&device).map_err(describe)?;
            total += self.evaluator.batch_loss(optimiser.weights(), &on_device)?;
        }
        Ok((total / self.positions.len() as f64) as f32)
    }

    fn report<Opt: OptimiserState<ExecutionContext>>(
        &mut self,
        optimiser: &Optimiser<ExecutionContext, Opt>,
        step: Step,
        superbatch: usize,
    ) -> Result<(), String> {
        let loss = self.mean_loss(optimiser, step)?;
        println!("validation superbatch {superbatch} loss {loss}");
        Ok(())
    }
}

fn save_checkpoint<Opt: OptimiserState<ExecutionContext>>(
    optimiser: &Optimiser<ExecutionContext, Opt>,
    saved_format: &[SavedFormat],
    directory: &str,
    name: &str,
    losses: &[(usize, usize, f32)],
) {
    let path = format!("{directory}/{name}");
    save::save_to_checkpoint(optimiser, saved_format, &path);
    save::write_losses(&format!("{path}/log.txt"), losses);
    println!("Saved [{}]", logger::ansi(name, 31));
}

/// `ValueTrainer::run` with a validation pass after every superbatch, and one before training starts so
/// that a broken validation setup fails before any training time is spent. Only that first pass
/// and training itself can fail the run: a validation failure later on is a warning, validation is
/// switched off, and training carries on to a normal `Ok`.
#[allow(clippy::too_many_arguments)]
pub fn run<Opt, I, O>(
    optimiser: &mut Optimiser<ExecutionContext, Opt>,
    saved_format: &[SavedFormat],
    inputs: I,
    buckets: O,
    schedule: &TrainingSchedule<impl LrScheduler, impl WdlScheduler>,
    settings: &LocalSettings,
    reader: &impl DataReader<ChessBoard>,
    validation: &ValidationConfig,
) -> Result<(), String>
where
    Opt: OptimiserState<ExecutionContext>,
    I: SparseInputType<RequiredDataType = ChessBoard>,
    O: OutputBuckets<ChessBoard>,
{
    logger::clear_colours();
    println!("{}", logger::ansi("Training Preamble", "34;1"));
    schedule.display();
    settings.display();

    let steps = schedule.steps;
    let threads = settings.threads.clamp(1, usize::from(u8::MAX)) as u8;
    let mapper = value_mapper(
        inputs,
        buckets,
        schedule.eval_scale,
        schedule.wdl_scheduler.clone(),
    );
    let mut validator = Validator::new(
        optimiser,
        mapper.clone(),
        validation,
        steps.batch_size,
        threads,
    )?;
    validator.report(optimiser, Step::from(steps), steps.start_superbatch - 1)?;

    let dataloader = ReadMapLoader::new(reader.clone(), mapper, threads);
    let _ = std::fs::create_dir(settings.output_directory);

    let losses = RefCell::new(Vec::new());
    let mut loss_sum = 0.0;
    let mut batches_summed = 0.0;
    let mut validation_error = None;

    let training_schedule = run::TrainingSchedule {
        steps,
        log_rate: 128,
        lr_schedule: schedule.lr_scheduler.clone().boxed(),
    };

    run::train(
        optimiser,
        training_schedule,
        dataloader,
        |_, step, error| {
            loss_sum += error;
            batches_summed += 1.0;

            if step.batch().is_multiple_of(32) || step.batch() + 1 == step.batches_per_superbatch()
            {
                losses.borrow_mut().push((
                    step.superbatch(),
                    step.batch(),
                    loss_sum / batches_summed,
                ));
                loss_sum = 0.0;
                batches_summed = 0.0;
            }
        },
        |optimiser, step| {
            let superbatch = step.superbatch();
            if validation_error.is_none()
                && let Err(error) = validator.report(optimiser, step, superbatch)
            {
                eprintln!(
                    "Warning: validation failed at superbatch {superbatch} and is off for the rest \
                     of the run; training continues: {error}"
                );
                validation_error = Some((superbatch, error));
            }
            if schedule.should_save(superbatch) {
                let name = format!("{}-{superbatch}", schedule.net_id);
                save_checkpoint(
                    optimiser,
                    saved_format,
                    settings.output_directory,
                    &name,
                    &losses.borrow(),
                );
            }
        },
    )
    .map_err(describe)?;

    if let Some((superbatch, error)) = validation_error {
        eprintln!(
            "Warning: training finished and every checkpoint was saved, but there are no validation \
             losses from superbatch {superbatch} on: {error}"
        );
    }
    Ok(())
}
