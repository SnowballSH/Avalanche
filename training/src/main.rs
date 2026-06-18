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
const HIDDEN_SIZE: usize = 512;
const NUM_OUTPUT_BUCKETS: usize = 8;
const QA: i16 = 255;
const QB: i16 = 64;
const EVAL_SCALE: f32 = 400.0;

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

    // Training hyperparameters — fine-tuning from jihan58 checkpoint
    let superbatches = 47;
    let batch_size = 16_384;
    let batches_per_superbatch = 12208;
    let wdl_proportion = 0.25;
    let threads = num_cpus();
    let save_rate = 10;

    println!("=== Avalanche NNUE Trainer ===");
    println!("Architecture: (768 -> {HIDDEN_SIZE})x2 -> 1x{NUM_OUTPUT_BUCKETS}");
    println!("Data: {:?}", dataset_paths);
    println!("Superbatches: {superbatches}");
    println!("Batch size: {batch_size}");
    println!("Positions/superbatch: {}", batch_size * batches_per_superbatch);
    println!("Threads: {threads}");
    println!("WDL: {wdl_proportion}");
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
        .build(|builder, stm_inputs, ntm_inputs, output_buckets| {
            let l0 = builder.new_affine("l0", 768, HIDDEN_SIZE);
            let l1 = builder.new_affine("l1", 2 * HIDDEN_SIZE, NUM_OUTPUT_BUCKETS);

            let stm_hidden = l0.forward(stm_inputs).screlu();
            let ntm_hidden = l0.forward(ntm_inputs).screlu();
            let hidden_layer = stm_hidden.concat(ntm_hidden);
            l1.forward(hidden_layer).select(output_buckets)
        });

    let schedule = TrainingSchedule {
        net_id: "jihan73".to_string(),
        eval_scale: EVAL_SCALE,
        steps: TrainingSteps {
            batch_size,
            batches_per_superbatch,
            start_superbatch: 1,
            end_superbatch: superbatches,
        },
        wdl_scheduler: wdl::ConstantWDL { value: wdl_proportion },
        lr_scheduler: lr::CosineDecayLR {
            initial_lr: 0.001,
            final_lr: 0.0000001,
            final_superbatch: superbatches,
        },
        save_rate,
    };

    let settings = LocalSettings {
        threads,
        test_set: None,
        output_directory: "checkpoints",
        batch_queue_size: 64,
    };

    let path_strs: Vec<&str> = dataset_paths.iter().copied().collect();

    // Auto-detect format: .viribin files use ViriBinpackLoader with custom filter
    let use_viri = path_strs.iter().any(|p| p.ends_with(".viribin"));

    if use_viri {
        println!("Using ViriBinpackLoader with custom filter");
        println!("  filter: min_ply=8, min_pieces=4, max_eval=10000, filter_tactical, filter_check");
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
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().max(1))
        .unwrap_or(4)
}
