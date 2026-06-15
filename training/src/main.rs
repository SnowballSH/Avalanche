use bullet::{
    game::{inputs::Chess768, outputs::MaterialCount},
    nn::optimiser::AdamW,
    trainer::{
        save::SavedFormat,
        schedule::{TrainingSchedule, TrainingSteps, lr, wdl},
        settings::{LocalSettings, TestDataset},
    },
    value::{ValueTrainerBuilder, loader::DirectSequentialDataLoader},
};

// Architecture constants — must match engine's weights.zig
const HIDDEN_SIZE: usize = 512;
const NUM_OUTPUT_BUCKETS: usize = 8;
const QA: i16 = 255;
const QB: i16 = 64;
const EVAL_SCALE: f32 = 400.0;

fn main() {
    // --- Configuration ---
    // Adjust these paths to your data files.
    // Data must be in bulletformat (.bin), use bullet-utils to convert/shuffle.
    let args: Vec<String> = std::env::args().skip(1).collect();
    let default_path = String::from("data/training.bin");
    let dataset_strings: Vec<&str> = if args.is_empty() {
        vec![default_path.as_str()]
    } else {
        args.iter().map(|s| s.as_str()).collect()
    };
    let dataset_paths = dataset_strings;

    // Check data exists
    for path in &dataset_paths {
        if !std::path::Path::new(path).exists() {
            eprintln!("Error: Data file not found: {path}");
            eprintln!("Usage: avalanche-trainer [data_file1.bin] [data_file2.bin] ...");
            eprintln!("Default: data/training.bin");
            std::process::exit(1);
        }
    }

    // Training hyperparameters
    let initial_lr = 0.001;
    let final_lr = 0.001 * 0.3f32.powi(5);
    let superbatches = 400;
    let batch_size = 16_384;
    let batches_per_superbatch = 6104; // ≈100M positions per superbatch
    let wdl_proportion = 0.35;
    let threads = num_cpus();
    let save_rate = 20;

    println!("=== Avalanche NNUE Trainer ===");
    println!("Architecture: (768 -> {HIDDEN_SIZE})x2 -> 1x{NUM_OUTPUT_BUCKETS}");
    println!("Data: {:?}", dataset_paths);
    println!("Superbatches: {superbatches}");
    println!("Batch size: {batch_size}");
    println!("Positions/superbatch: {}", batch_size * batches_per_superbatch);
    println!("Threads: {threads}");
    println!("LR: {initial_lr} -> {final_lr} (cosine)");
    println!("WDL: {wdl_proportion}");
    println!("==============================");
    println!();

    let mut trainer = ValueTrainerBuilder::default()
        .dual_perspective()
        .optimiser(AdamW)
        .inputs(Chess768)
        .output_buckets(MaterialCount::<NUM_OUTPUT_BUCKETS>)
        .save_format(&[
            // L0 weights: [768][512] i16, column-major (feature-indexed for incremental updates)
            SavedFormat::id("l0w").round().quantise::<i16>(QA),
            // L0 bias: [512] i16
            SavedFormat::id("l0b").round().quantise::<i16>(QA),
            // L1 weights: [8][1024] i16, transposed to row-major (bucket-indexed for inference)
            SavedFormat::id("l1w").round().quantise::<i16>(QB).transpose(),
            // L1 bias: [8] i16
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
        net_id: "avalanche".to_string(),
        eval_scale: EVAL_SCALE,
        steps: TrainingSteps {
            batch_size,
            batches_per_superbatch,
            start_superbatch: 1,
            end_superbatch: superbatches,
        },
        wdl_scheduler: wdl::ConstantWDL { value: wdl_proportion },
        lr_scheduler: lr::CosineDecayLR { initial_lr, final_lr, final_superbatch: superbatches },
        save_rate,
    };

    let test_path_string;
    let test_set = {
        let test_path = dataset_paths[0].replace(".bin", "_test.bin");
        if std::path::Path::new(&test_path).exists() {
            test_path_string = test_path;
            Some(TestDataset::at(test_path_string.as_str()))
        } else {
            None
        }
    };

    let settings = LocalSettings {
        threads,
        test_set,
        output_directory: "checkpoints",
        batch_queue_size: 64,
    };

    let path_strs: Vec<&str> = dataset_paths.iter().copied().collect();
    let dataloader = DirectSequentialDataLoader::new(&path_strs);

    trainer.run(&schedule, &settings, &dataloader);
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().max(1))
        .unwrap_or(4)
}
