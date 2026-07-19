use bullet::{
    game::{
        inputs::{Chess768, ChessBucketsMirrored, get_num_buckets},
        outputs::MaterialCount,
    },
    nn::{
        InitSettings, Shape,
        optimiser::{AdamW, AdamWParams},
    },
    trainer::{
        save::SavedFormat,
        schedule::{TrainingSchedule, TrainingSteps, lr, wdl},
        settings::LocalSettings,
    },
    value::{
        ValueTrainerBuilder,
        loader::{DirectSequentialDataLoader, ViriBinpackLoader, viribinpack::ViriFilter},
    },
};
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

// Initially taken from https://github.com/JonathanHallstrom/bullet/blob/bb5a2725b7beb2178aa59fa38f163aeb31bac7fc/examples/advanced.rs
fn viri_filter(board: &Board, mv: Move, eval: i16, wdl_float: f32) -> bool {
    let wdl = match wdl_float {
        x if x >= 0.9 => WDL::Win,
        x if x <= 0.1 => WDL::Loss,
        _ => WDL::Draw,
    };

    const FILTER: Filter = Filter {
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

    let mut rng = rand::rng();
    !FILTER.should_filter(mv, eval as i32, board, wdl, &mut rng)
}

struct TrainConfig {
    hidden_size: usize,
    superbatches: usize,
    batch_size: usize,
    batches_per_superbatch: usize,
    wdl_proportion: f32,
    wdl_end: f32,
    lr_initial: f32,
    lr_final: f32,
    net_id: String,
    save_rate: usize,
    threads: usize,
    use_factoriser: bool,
    dataset_paths: Vec<String>,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let default_path = String::from("data/training.bin");
    let dataset_paths: Vec<String> = if args.is_empty() {
        vec![default_path]
    } else {
        args
    };

    for path in &dataset_paths {
        if !std::path::Path::new(path).exists() {
            eprintln!("Error: Data file not found: {path}");
            eprintln!("Usage: avalanche-trainer [data_file1.bin] [data_file2.bin] ...");
            eprintln!("Default: data/training.bin");
            std::process::exit(1);
        }
    }

    let input_mode = env_string("TRAIN_INPUT", "chess768");
    let hidden_size = env_usize("TRAIN_HIDDEN", 1024);
    if matches!(input_mode.as_str(), "buckets16" | "buckets") && hidden_size != 1024 {
        eprintln!(
            "WARNING: TRAIN_HIDDEN={hidden_size} but engine weights.zig uses HIDDEN_SIZE=1024; \
             buckets nets will not load unless the engine is rebuilt with a matching hidden size."
        );
    }
    let superbatches = env_usize("TRAIN_SUPERBATCHES", 40);
    let batch_size = env_usize("TRAIN_BATCH_SIZE", 16_384);
    let batches_per_superbatch = env_usize("TRAIN_BATCHES_PER_SB", 12208);
    let wdl_proportion = env_f32("TRAIN_WDL", 0.25);
    let wdl_end = env_f32("TRAIN_WDL_END", wdl_proportion);
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
        lr_initial,
        lr_final,
        net_id,
        save_rate,
        threads,
        use_factoriser,
        dataset_paths,
    };

    match input_mode.as_str() {
        "chess768" | "768" => run_chess768(cfg),
        "buckets16" | "buckets" => run_buckets16(cfg),
        other => {
            eprintln!("Error: unknown TRAIN_INPUT={other:?}");
            eprintln!("Supported: chess768 (default), buckets16");
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
    println!(
        "LR: cosine {} -> {} over {} sb",
        cfg.lr_initial, cfg.lr_final, cfg.superbatches
    );
    println!("==============================");
    println!();
}

// ValueTrainer is a concrete generic struct (not a trait), so share the run
// loop via a macro that works for both Chess768 and ChessBucketsMirrored.
macro_rules! run_trainer {
    ($trainer:expr, $cfg:expr) => {{
        let cfg = $cfg;
        let mut trainer = $trainer;
        let steps = TrainingSteps {
            batch_size: cfg.batch_size,
            batches_per_superbatch: cfg.batches_per_superbatch,
            start_superbatch: 1,
            end_superbatch: cfg.superbatches,
        };
        let lr_scheduler = lr::CosineDecayLR {
            initial_lr: cfg.lr_initial,
            final_lr: cfg.lr_final,
            final_superbatch: cfg.superbatches,
        };

        let settings = LocalSettings {
            threads: cfg.threads,
            test_set: None,
            output_directory: "checkpoints",
            batch_queue_size: 64,
        };

        let path_strs: Vec<&str> = cfg.dataset_paths.iter().map(|s| s.as_str()).collect();
        let use_viri = path_strs.iter().any(|p| p.ends_with(".viribin"));
        let net_id = cfg.net_id.clone();
        let wdl_proportion = cfg.wdl_proportion;
        let wdl_end = cfg.wdl_end;
        let save_rate = cfg.save_rate;
        let threads = cfg.threads;

        macro_rules! run_with_schedule {
            ($wdl_sched:expr) => {{
                let schedule = TrainingSchedule {
                    net_id: net_id.clone(),
                    eval_scale: EVAL_SCALE,
                    steps,
                    wdl_scheduler: $wdl_sched,
                    lr_scheduler,
                    save_rate,
                };
                if use_viri {
                    println!("Using ViriBinpackLoader with custom filter");
                    let dataloader = ViriBinpackLoader::new_concat_multiple(
                        &path_strs,
                        128,
                        threads.min(16),
                        ViriFilter::Custom(viri_filter),
                    );
                    trainer.run(&schedule, &settings, &dataloader);
                } else {
                    println!("Using DirectSequentialDataLoader (bulletformat)");
                    let dataloader = DirectSequentialDataLoader::new(&path_strs);
                    trainer.run(&schedule, &settings, &dataloader);
                }
            }};
        }

        if (wdl_end - wdl_proportion).abs() > 1e-6 {
            run_with_schedule!(wdl::LinearWDL {
                start: wdl_proportion,
                end: wdl_end
            });
        } else {
            run_with_schedule!(wdl::ConstantWDL {
                value: wdl_proportion
            });
        }

        println!("Training complete. net_id={net_id}");
    }};
}

fn run_chess768(cfg: TrainConfig) {
    print_banner(&cfg, "768");
    let hidden_size = cfg.hidden_size;

    let mut trainer = ValueTrainerBuilder::default()
        .dual_perspective()
        .optimiser(AdamW)
        .inputs(Chess768)
        .output_buckets(MaterialCount::<NUM_OUTPUT_BUCKETS>)
        .save_format(&[
            SavedFormat::id("l0w").round().quantise::<i16>(QA),
            SavedFormat::id("l0b").round().quantise::<i16>(QA),
            SavedFormat::id("l1w")
                .round()
                .quantise::<i16>(QB)
                .transpose(),
            SavedFormat::id("l1b").round().quantise::<i16>(QA * QB),
        ])
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
    run_trainer!(trainer, cfg);
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

    let mut trainer = ValueTrainerBuilder::default()
        .dual_perspective()
        .optimiser(AdamW)
        .inputs(ChessBucketsMirrored::new(BUCKET_LAYOUT_16))
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
    run_trainer!(trainer, cfg);
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().max(1))
        .unwrap_or(4)
}
