mod schedule;
mod validation;

use std::str::FromStr;

use bullet::{
    game::{
        formats::bulletformat::ChessBoard,
        inputs::{Chess768, ChessBucketsMirrored, SparseInputType, get_num_buckets},
        outputs::MaterialCount,
    },
    nn::{
        ExecutionContext, InitSettings, Shape,
        optimiser::{AdamW, AdamWParams},
    },
    trainer::{
        save::SavedFormat,
        schedule::{TrainingSchedule, TrainingSteps, lr::LrScheduler, wdl},
        settings::LocalSettings,
    },
    value::{
        ValueTrainer, ValueTrainerBuilder,
        loader::{DirectSequentialDataLoader, ViriBinpackLoader, viribinpack::ViriFilter},
    },
};
use bullet_trainer::{optimiser::OptimiserState, reader::DataReader};
use schedule::{BaseLr, LinearWarmup, LrKind};
use validation::ValidationConfig;
use viriformat::{
    chess::{board::Board, chessmove::Move},
    dataformat::{Filter, WDL},
};

// Architecture constants — must match engine's weights.zig
const NUM_OUTPUT_BUCKETS: usize = 8;
const QA: i16 = 255;
const QB: i16 = 64;
const EVAL_SCALE: f32 = 400.0;

// Pawnocchio / Alexandria-style 16-bucket half-board layout (files a–d).
// ChessBucketsMirrored expands this to 64 squares via file mirroring.
#[rustfmt::skip]
const BUCKET_LAYOUT_16: [usize; 32] = [
    0,  1,  2,  3,
    4,  5,  6,  7,
    8,  8,  9,  9,
    10, 10, 11, 11,
    12, 12, 13, 13,
    12, 12, 13, 13,
    14, 14, 15, 15,
    14, 14, 15, 15,
];

// --- env-var helpers (lets us launch many experiments without recompiling) ---
fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}
fn env_f32(key: &str, default: f32) -> f32 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}
fn env_string(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}
fn env_bool(key: &str, default: bool) -> bool {
    match std::env::var(key) {
        Ok(v) => matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => default,
    }
}

fn fail(message: &str) -> ! {
    eprintln!("Error: {message}");
    std::process::exit(1);
}

/// Unlike the lenient helpers above, a value that is set but does not parse is an error.
fn env_strict<T>(key: &str, default: T) -> Result<T, String>
where
    T: FromStr<Err: std::fmt::Display>,
{
    match std::env::var(key) {
        Ok(value) => value
            .parse()
            .map_err(|err| format!("{key}={value} is not valid: {err}")),
        Err(_) => Ok(default),
    }
}

/// Stored by `Avalanche tbfilter format=viri` for positions whose label contradicts the Syzygy tables.
const TABLEBASE_MASKED_EVAL: i16 = i16::MAX;

const VIRI_FILTER: Filter = Filter {
    min_ply: 8,
    min_pieces: 4,
    max_eval: 10000,
    filter_tactical: true,
    filter_check: true,
    filter_castling: false,
    max_eval_incorrectness: 2500,
    random_fen_skipping: false,
    random_fen_skip_probability: 0.0,
    wdl_filtered: false,
    wdl_model_params_a: [0.0; 4],
    wdl_model_params_b: [0.0; 4],
    material_min: 17,
    material_max: 78,
    mom_target: 58,
    wdl_heuristic_scale: 1.0,
};

const _: () = assert!(
    VIRI_FILTER.max_eval <= TABLEBASE_MASKED_EVAL as u32,
    "the filter must drop tablebase-masked positions"
);

// Initially taken from https://github.com/JonathanHallstrom/bullet/blob/bb5a2725b7beb2178aa59fa38f163aeb31bac7fc/examples/advanced.rs
fn viri_filter(board: &Board, mv: Move, eval: i16, wdl_float: f32) -> bool {
    let wdl = match wdl_float {
        x if x >= 0.9 => WDL::Win,
        x if x <= 0.1 => WDL::Loss,
        _ => WDL::Draw,
    };

    let mut rng = rand::rng();
    !VIRI_FILTER.should_filter(mv, eval as i32, board, wdl, &mut rng)
}

struct TrainConfig {
    hidden_size: usize,
    superbatches: usize,
    batch_size: usize,
    batches_per_superbatch: usize,
    wdl_proportion: f32,
    wdl_end: f32,
    lr_schedule: LrKind,
    lr_initial: f32,
    lr_final: f32,
    warmup_superbatches: usize,
    net_id: String,
    save_rate: usize,
    threads: usize,
    use_factoriser: bool,
    dataset_paths: Vec<String>,
    shuffle_mb: usize,
    start_superbatch: usize,
    validation: Option<ValidationConfig>,
}

/// Every `*.viribin` file in the directory named by the env variable `key`, sorted, so a directory of
/// cleaned chunks is one dataset.
fn viribin_files(key: &str, dir: &str) -> Result<Vec<String>, String> {
    let entries =
        std::fs::read_dir(dir).map_err(|err| format!("cannot read {key} {dir}: {err}"))?;
    let mut files: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "viribin"))
        .map(|path| path.to_string_lossy().into_owned())
        .collect();
    files.sort();
    if files.is_empty() {
        return Err(format!("{key} {dir} contains no .viribin files"));
    }
    Ok(files)
}

fn lr_schedule_from_env() -> Result<LrKind, String> {
    let name = env_string("TRAIN_LR_SCHEDULE", "cosine");
    LrKind::parse(&name).ok_or_else(|| {
        format!(
            "unknown TRAIN_LR_SCHEDULE={name}; supported: {}",
            LrKind::SUPPORTED
        )
    })
}

fn shuffle_mb_from_env() -> Result<usize, String> {
    match env_strict("TRAIN_SHUFFLE_MB", 128)? {
        0 => Err(String::from("TRAIN_SHUFFLE_MB must be at least 1")),
        shuffle_mb => Ok(shuffle_mb),
    }
}

fn warmup_superbatches_from_env(superbatches: usize) -> Result<usize, String> {
    let warmup: usize = env_strict("TRAIN_WARMUP_SB", 0)?;
    if warmup > superbatches {
        return Err(format!(
            "TRAIN_WARMUP_SB={warmup} exceeds TRAIN_SUPERBATCHES={superbatches}"
        ));
    }
    Ok(warmup)
}

fn validation_from_env() -> Result<Option<ValidationConfig>, String> {
    let dir = std::env::var("TRAIN_VALIDATION_DIR").unwrap_or_default();
    if dir.is_empty() {
        return Ok(None);
    }
    let batches = env_strict("TRAIN_VALIDATION_BATCHES", 64)?;
    if batches == 0 {
        return Err(String::from("TRAIN_VALIDATION_BATCHES must be at least 1"));
    }
    Ok(Some(ValidationConfig {
        files: viribin_files("TRAIN_VALIDATION_DIR", &dir)?,
        batches,
        filter: viri_filter,
    }))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dataset_paths = match std::env::var("TRAIN_DATA_DIR") {
        Ok(dir) => viribin_files("TRAIN_DATA_DIR", &dir).unwrap_or_else(|err| fail(&err)),
        Err(_) if args.is_empty() => vec![String::from("data/training.bin")],
        Err(_) => args,
    };

    for path in &dataset_paths {
        if !std::path::Path::new(path).exists() {
            eprintln!("Error: Data file not found: {path}");
            eprintln!("Usage: avalanche-trainer [data_file1.bin] [data_file2.bin] ...");
            eprintln!("Default: data/training.bin");
            std::process::exit(1);
        }
    }

    let input_mode = env_string("TRAIN_INPUT", "buckets16");
    let hidden_size = env_usize("TRAIN_HIDDEN", 1024);
    if matches!(input_mode.as_str(), "buckets16" | "buckets") && hidden_size != 1024 {
        eprintln!(
            "WARNING: TRAIN_HIDDEN={hidden_size} but engine weights.zig uses HIDDEN_SIZE=1024; \
             buckets nets will not load unless the engine is rebuilt with a matching hidden size."
        );
    }
    let superbatches = env_usize("TRAIN_SUPERBATCHES", 40);
    let start_superbatch = env_usize("TRAIN_START_SB", 1);
    if start_superbatch == 0 || start_superbatch > superbatches {
        eprintln!("Error: TRAIN_START_SB={start_superbatch} must be in 1..={superbatches}");
        std::process::exit(1);
    }
    let batch_size = env_usize("TRAIN_BATCH_SIZE", 16_384);
    let batches_per_superbatch = env_usize("TRAIN_BATCHES_PER_SB", 12208);
    let wdl_proportion = env_f32("TRAIN_WDL", 0.25);
    let wdl_end = env_f32("TRAIN_WDL_END", wdl_proportion);
    let lr_schedule = lr_schedule_from_env().unwrap_or_else(|err| fail(&err));
    let warmup_superbatches =
        warmup_superbatches_from_env(superbatches).unwrap_or_else(|err| fail(&err));
    let shuffle_mb = shuffle_mb_from_env().unwrap_or_else(|err| fail(&err));
    let validation = validation_from_env().unwrap_or_else(|err| fail(&err));
    let lr_initial = env_f32("TRAIN_LR_INITIAL", 0.001);
    let lr_final = env_f32("TRAIN_LR_FINAL", 0.0000001);
    let net_id = env_string("TRAIN_NET_ID", "net");
    let save_rate = env_usize("TRAIN_SAVE_RATE", 10);
    let threads = env_usize("TRAIN_THREADS", num_cpus());
    let use_factoriser = env_bool("TRAIN_FACTORISER", true);

    let cfg = TrainConfig {
        hidden_size,
        superbatches,
        batch_size,
        batches_per_superbatch,
        wdl_proportion,
        wdl_end,
        lr_schedule,
        lr_initial,
        lr_final,
        warmup_superbatches,
        net_id,
        save_rate,
        threads,
        use_factoriser,
        dataset_paths,
        shuffle_mb,
        start_superbatch,
        validation,
    };

    match input_mode.as_str() {
        "chess768" | "768" => run_chess768(cfg),
        "buckets16" | "buckets" => run_buckets16(cfg),
        other => {
            eprintln!("Error: unknown TRAIN_INPUT={other:?}");
            eprintln!("Supported: buckets16 (default), chess768");
            std::process::exit(1);
        }
    }
}

fn print_banner(cfg: &TrainConfig, arch: &str) {
    println!("=== Avalanche NNUE Trainer ===");
    println!("net_id: {}", cfg.net_id);
    println!("Input: {arch}");
    println!(
        "Architecture: ({arch} -> {})x2 -> 1x{NUM_OUTPUT_BUCKETS}",
        cfg.hidden_size
    );
    println!("Data: {:?}", cfg.dataset_paths);
    println!("Superbatches: {}", cfg.superbatches);
    println!("Batch size: {}", cfg.batch_size);
    println!("Batches/superbatch: {}", cfg.batches_per_superbatch);
    println!(
        "Positions/superbatch: {}",
        cfg.batch_size * cfg.batches_per_superbatch
    );
    println!("Threads: {}", cfg.threads);
    println!("WDL: {} -> {}", cfg.wdl_proportion, cfg.wdl_end);
    match cfg.lr_schedule {
        LrKind::Constant => println!("LR: constant {}", cfg.lr_initial),
        kind => println!(
            "LR: {} {} -> {} over {} sb",
            kind.name(),
            cfg.lr_initial,
            cfg.lr_final,
            cfg.superbatches
        ),
    }
    if cfg.warmup_superbatches > 0 {
        println!("LR warmup: linear over {} sb", cfg.warmup_superbatches);
    }
    if let Some(validation) = &cfg.validation {
        println!(
            "Validation: {} batches from {:?}",
            validation.batches, validation.files
        );
    }
    println!("==============================");
    println!();
}

type OutputBuckets = MaterialCount<NUM_OUTPUT_BUCKETS>;

/// A built trainer plus what `ValueTrainer` keeps private but a validated run has to supply again.
struct Session<'a, Opt: OptimiserState<ExecutionContext>, I: SparseInputType> {
    trainer: &'a mut ValueTrainer<Opt, I, OutputBuckets>,
    inputs: I,
    saved_format: &'a [SavedFormat],
    cfg: &'a TrainConfig,
}

fn run_trainer<Opt, I>(session: Session<Opt, I>)
where
    Opt: OptimiserState<ExecutionContext>,
    I: SparseInputType<RequiredDataType = ChessBoard>,
{
    let cfg = session.cfg;
    let (start, end) = (cfg.wdl_proportion, cfg.wdl_end);
    if (end - start).abs() > 1e-6 {
        run_with_wdl(session, wdl::LinearWDL { start, end });
    } else {
        run_with_wdl(session, wdl::ConstantWDL { value: start });
    }
    println!("Training complete. net_id={}", cfg.net_id);
}

fn run_with_wdl<Opt, I>(session: Session<Opt, I>, wdl_scheduler: impl wdl::WdlScheduler)
where
    Opt: OptimiserState<ExecutionContext>,
    I: SparseInputType<RequiredDataType = ChessBoard>,
{
    let cfg = session.cfg;
    let schedule = TrainingSchedule {
        net_id: cfg.net_id.clone(),
        eval_scale: EVAL_SCALE,
        steps: TrainingSteps {
            batch_size: cfg.batch_size,
            batches_per_superbatch: cfg.batches_per_superbatch,
            start_superbatch: cfg.start_superbatch,
            end_superbatch: cfg.superbatches,
        },
        wdl_scheduler,
        lr_scheduler: LinearWarmup {
            inner: BaseLr::new(
                cfg.lr_schedule,
                cfg.lr_initial,
                cfg.lr_final,
                cfg.superbatches,
            ),
            warmup_superbatches: cfg.warmup_superbatches,
            batches_per_superbatch: cfg.batches_per_superbatch,
        },
        save_rate: cfg.save_rate,
    };

    let paths: Vec<&str> = cfg.dataset_paths.iter().map(String::as_str).collect();
    if paths.iter().any(|path| path.ends_with(".viribin")) {
        println!(
            "Using ViriBinpackLoader (games interleaved across {} files, {} MB shuffle buffer) with custom filter",
            paths.len(),
            cfg.shuffle_mb
        );
        let reader = ViriBinpackLoader::new_interleave_multiple(
            &paths,
            cfg.shuffle_mb,
            cfg.threads.min(16),
            ViriFilter::Custom(viri_filter),
        );
        run_with_reader(session, &schedule, &reader);
    } else {
        println!("Using DirectSequentialDataLoader (bulletformat)");
        run_with_reader(session, &schedule, &DirectSequentialDataLoader::new(&paths));
    }
}

fn run_with_reader<Opt, I>(
    session: Session<Opt, I>,
    schedule: &TrainingSchedule<impl LrScheduler, impl wdl::WdlScheduler>,
    reader: &impl DataReader<ChessBoard>,
) where
    Opt: OptimiserState<ExecutionContext>,
    I: SparseInputType<RequiredDataType = ChessBoard>,
{
    let settings = LocalSettings {
        threads: session.cfg.threads,
        test_set: None,
        output_directory: "checkpoints",
        batch_queue_size: 64,
    };

    let Some(validation) = &session.cfg.validation else {
        session.trainer.run(schedule, &settings, reader);
        return;
    };
    validation::run(
        &mut session.trainer.optimiser,
        session.saved_format,
        session.inputs,
        OutputBuckets::default(),
        schedule,
        &settings,
        reader,
        validation,
    )
    .unwrap_or_else(|err| fail(&err));
}

fn run_chess768(cfg: TrainConfig) {
    print_banner(&cfg, "768");
    let hidden_size = cfg.hidden_size;

    let save_format = [
        SavedFormat::id("l0w").round().quantise::<i16>(QA),
        SavedFormat::id("l0b").round().quantise::<i16>(QA),
        SavedFormat::id("l1w")
            .round()
            .quantise::<i16>(QB)
            .transpose(),
        SavedFormat::id("l1b").round().quantise::<i16>(QA * QB),
    ];

    // validation.rs keeps its own copy of bullet's input mapper for this builder setup. Re-check it when
    // this gains wdl-adjust, datapoint-weight, win-rate-model or wdl-output options, or bullet is bumped.
    let mut trainer = ValueTrainerBuilder::default()
        .dual_perspective()
        .optimiser(AdamW)
        .inputs(Chess768)
        .output_buckets(MaterialCount::<NUM_OUTPUT_BUCKETS>)
        .save_format(&save_format)
        .loss_fn(|output, target| output.sigmoid().squared_error(target))
        .build(move |builder, stm_inputs, ntm_inputs, output_buckets| {
            let l0 = builder.new_affine("l0", 768, hidden_size);
            let l1 = builder.new_affine("l1", 2 * hidden_size, NUM_OUTPUT_BUCKETS);

            let stm_hidden = l0.forward(stm_inputs).screlu();
            let ntm_hidden = l0.forward(ntm_inputs).screlu();
            let hidden_layer = stm_hidden.concat(ntm_hidden);
            l1.forward(hidden_layer).select(output_buckets)
        });

    if let Ok(resume_path) = std::env::var("TRAIN_RESUME_FROM") {
        println!("Resuming from checkpoint: {resume_path}");
        trainer.load_from_checkpoint(&resume_path);
    }
    run_trainer(Session {
        trainer: &mut trainer,
        inputs: Chess768,
        saved_format: &save_format,
        cfg: &cfg,
    });
}

fn run_buckets16(cfg: TrainConfig) {
    const NUM_INPUT_BUCKETS: usize = get_num_buckets(&BUCKET_LAYOUT_16);
    assert_eq!(NUM_INPUT_BUCKETS, 16);

    let arch = if cfg.use_factoriser {
        format!("768x{NUM_INPUT_BUCKETS}hm+factoriser")
    } else {
        format!("768x{NUM_INPUT_BUCKETS}hm")
    };
    print_banner(&cfg, &arch);
    println!("King buckets: {NUM_INPUT_BUCKETS} (ChessBucketsMirrored, half-board layout)");
    println!("Factoriser: {}", cfg.use_factoriser);
    println!();

    let hidden_size = cfg.hidden_size;
    let use_factoriser = cfg.use_factoriser;

    let save_format: Vec<SavedFormat> = if use_factoriser {
        vec![
            SavedFormat::id("l0w")
                .transform(|store, weights| {
                    let factoriser = store.get("l0f").values.f32().repeat(NUM_INPUT_BUCKETS);
                    weights
                        .into_iter()
                        .zip(factoriser)
                        .map(|(a, b)| a + b)
                        .collect()
                })
                .round()
                .quantise::<i16>(QA),
            SavedFormat::id("l0b").round().quantise::<i16>(QA),
            SavedFormat::id("l1w")
                .round()
                .quantise::<i16>(QB)
                .transpose(),
            SavedFormat::id("l1b").round().quantise::<i16>(QA * QB),
        ]
    } else {
        vec![
            SavedFormat::id("l0w").round().quantise::<i16>(QA),
            SavedFormat::id("l0b").round().quantise::<i16>(QA),
            SavedFormat::id("l1w")
                .round()
                .quantise::<i16>(QB)
                .transpose(),
            SavedFormat::id("l1b").round().quantise::<i16>(QA * QB),
        ]
    };

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
                let expanded_factoriser = l0f.repeat(NUM_INPUT_BUCKETS);
                l0.weights = l0.weights + expanded_factoriser;
            }

            let l1 = builder.new_affine("l1", 2 * hidden_size, NUM_OUTPUT_BUCKETS);

            let stm_hidden = l0.forward(stm_inputs).screlu();
            let ntm_hidden = l0.forward(ntm_inputs).screlu();
            let hidden_layer = stm_hidden.concat(ntm_hidden);
            l1.forward(hidden_layer).select(output_buckets)
        });

    if use_factoriser {
        // Match bullet examples/progression/3_input_buckets.rs
        let stricter_clipping = AdamWParams {
            max_weight: 0.99,
            min_weight: -0.99,
            ..Default::default()
        };
        trainer
            .optimiser
            .set_params_for_weight("l0w", stricter_clipping);
        trainer
            .optimiser
            .set_params_for_weight("l0f", stricter_clipping);
    }

    if let Ok(resume_path) = std::env::var("TRAIN_RESUME_FROM") {
        println!("Resuming from checkpoint: {resume_path}");
        trainer.load_from_checkpoint(&resume_path);
    }
    run_trainer(Session {
        trainer: &mut trainer,
        inputs,
        saved_format: &save_format,
        cfg: &cfg,
    });
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().max(1))
        .unwrap_or(4)
}
