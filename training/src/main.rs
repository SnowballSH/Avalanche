use bullet::{
    game::{inputs::Chess768, outputs::MaterialCount},
    nn::optimiser::AdamW,
    trainer::{
        save::SavedFormat,
        schedule::{TrainingSchedule, TrainingSteps, lr, wdl},
        settings::LocalSettings,
    },
    value::{ValueTrainerBuilder, loader::{DirectSequentialDataLoader, ViriBinpackLoader, viribinpack::ViriFilter}},
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

// --- env-var helpers (lets us launch many experiments without recompiling) ---
fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}
fn env_f32(key: &str, default: f32) -> f32 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}
fn env_string(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
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

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let default_path = String::from("data/training.bin");
    let dataset_strings: Vec<&str> = if args.is_empty() {
        vec![default_path.as_str()]
    } else {
        args.iter().map(|s| s.as_str()).collect()
    };
    let dataset_paths = dataset_strings;

    for path in &dataset_paths {
        if !std::path::Path::new(path).exists() {
            eprintln!("Error: Data file not found: {path}");
            eprintln!("Usage: avalanche-trainer [data_file1.bin] [data_file2.bin] ...");
            eprintln!("Default: data/training.bin");
            std::process::exit(1);
        }
    }

    // Hyperparameters, all overridable via TRAIN_* env vars (no recompile between
    // runs). HIDDEN is a runtime arg to new_affine, so changing it needs no recompile
    // here; only the engine's weights.zig is compile-time for the architecture.
    let hidden_size = env_usize("TRAIN_HIDDEN", 512);
    let superbatches = env_usize("TRAIN_SUPERBATCHES", 40);
    let batch_size = env_usize("TRAIN_BATCH_SIZE", 16_384);
    let batches_per_superbatch = env_usize("TRAIN_BATCHES_PER_SB", 12208);
    let wdl_proportion = env_f32("TRAIN_WDL", 0.25);
    let wdl_end = env_f32("TRAIN_WDL_END", wdl_proportion); // if != wdl, use LinearWDL
    let lr_initial = env_f32("TRAIN_LR_INITIAL", 0.001);
    let lr_final = env_f32("TRAIN_LR_FINAL", 0.0000001);
    let net_id = env_string("TRAIN_NET_ID", "net");
    let save_rate = env_usize("TRAIN_SAVE_RATE", 10);
    let threads = env_usize("TRAIN_THREADS", num_cpus());

    println!("=== Avalanche NNUE Trainer ===");
    println!("net_id: {net_id}");
    println!("Architecture: (768 -> {hidden_size})x2 -> 1x{NUM_OUTPUT_BUCKETS}");
    println!("Data: {:?}", dataset_paths);
    println!("Superbatches: {superbatches}");
    println!("Batch size: {batch_size}");
    println!("Batches/superbatch: {batches_per_superbatch}");
    println!("Positions/superbatch: {}", batch_size * batches_per_superbatch);
    println!("Threads: {threads}");
    println!("WDL: {wdl_proportion} -> {wdl_end}");
    println!("LR: cosine {lr_initial} -> {lr_final} over {superbatches} sb");
    println!("==============================");
    println!();

    let mut trainer = ValueTrainerBuilder::default()
        .dual_perspective()
        .optimiser(AdamW)
        .inputs(Chess768)
        .output_buckets(MaterialCount::<NUM_OUTPUT_BUCKETS>)
        .save_format(&[
            SavedFormat::id("l0w").round().quantise::<i16>(QA),
            SavedFormat::id("l0b").round().quantise::<i16>(QA),
            SavedFormat::id("l1w").round().quantise::<i16>(QB).transpose(),
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

    let steps = TrainingSteps {
        batch_size,
        batches_per_superbatch,
        start_superbatch: 1,
        end_superbatch: superbatches,
    };
    let lr_scheduler = lr::CosineDecayLR {
        initial_lr: lr_initial,
        final_lr: lr_final,
        final_superbatch: superbatches,
    };

    // Resume from a previous checkpoint (for multi-stage training)
    if let Ok(resume_path) = std::env::var("TRAIN_RESUME_FROM") {
        println!("Resuming from checkpoint: {resume_path}");
        trainer.load_from_checkpoint(&resume_path);
    }

    let settings = LocalSettings {
        threads,
        test_set: None,
        output_directory: "checkpoints",
        batch_queue_size: 64,
    };

    let path_strs: Vec<&str> = dataset_paths.iter().copied().collect();

    // Auto-detect format: .viribin files use ViriBinpackLoader with custom filter
    let use_viri = path_strs.iter().any(|p| p.ends_with(".viribin"));

    // Build the right dataloader once, then dispatch on the WDL scheduler type.
    // TrainingSchedule is generic over the WDL scheduler, so the two branches are
    // monomorphised separately; we duplicate the small run block to keep types concrete.
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
        run_with_schedule!(wdl::LinearWDL { start: wdl_proportion, end: wdl_end });
    } else {
        run_with_schedule!(wdl::ConstantWDL { value: wdl_proportion });
    }

    println!("Training complete. net_id={net_id}");
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().max(1))
        .unwrap_or(4)
}
