use clap::{Parser, Subcommand};
use datatool::dupes::dupes;
use datatool::validate::validate;
use std::path::PathBuf;
use std::process::ExitCode;
use viriformat::dataformat::Filter;

#[derive(Parser)]
#[command(about = "Avalanche training-data tools")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Replays every game in a viriformat file and reports statistics as JSON.
    Validate {
        file: PathBuf,
        #[arg(long)]
        expect_positions: Option<u64>,
        #[arg(long)]
        filter: Option<PathBuf>,
    },
    /// Estimates the duplicate-position rate across viriformat files from a deterministic sample.
    Dupes {
        #[arg(required = true)]
        files: Vec<PathBuf>,
        #[arg(long, default_value_t = 10)]
        sample_per_mille: u64,
    },
}

fn main() -> anyhow::Result<ExitCode> {
    match Cli::parse().command {
        Command::Validate {
            file,
            expect_positions,
            filter,
        } => {
            let filter = filter.map(|path| Filter::from_path(&path)).transpose()?;
            let report = validate(&file, filter.as_ref())?;
            println!("{}", serde_json::to_string(&report)?);
            let enough = expect_positions.is_none_or(|n| report.positions >= n);
            Ok(if report.valid && enough {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            })
        }
        Command::Dupes {
            files,
            sample_per_mille,
        } => {
            println!(
                "{}",
                serde_json::to_string(&dupes(&files, sample_per_mille)?)?
            );
            Ok(ExitCode::SUCCESS)
        }
    }
}
