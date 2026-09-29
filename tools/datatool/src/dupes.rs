use serde::Serialize;
use std::collections::HashSet;
use std::fs::File;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use viriformat::dataformat::Game;

const IDENTITY_BYTES: usize = 25;

#[derive(Debug, PartialEq, Serialize)]
pub struct DupesReport {
    pub sampled: u64,
    pub distinct: u64,
    pub duplicate_rate: f64,
}

/// Counts repeated positions among a deterministic hash-selected sample of `sample_per_mille`/1000 positions.
///
/// A position's identity is occupancy, pieces, side to move and en passant; move counters are ignored so that
/// transpositions reached at different move numbers count as duplicates.
///
/// # Errors
/// Returns an error when a file cannot be read or contains a malformed game.
pub fn dupes(files: &[PathBuf], sample_per_mille: u64) -> anyhow::Result<DupesReport> {
    let mut seen = HashSet::new();
    let mut sampled = 0u64;
    for path in files {
        let mut reader = BufReader::new(File::open(path)?);
        while !reader.fill_buf()?.is_empty() {
            let game = Game::deserialise_from(&mut reader, Vec::new())?;
            game.visit_positions(|board, _| {
                let hash = identity_hash(&board.to_marlinformat(0, 0, 0).as_bytes());
                if hash % 1000 < sample_per_mille {
                    sampled += 1;
                    seen.insert(hash);
                }
            });
        }
    }
    let distinct = seen.len() as u64;
    #[allow(clippy::cast_precision_loss)]
    let duplicate_rate = if sampled == 0 {
        0.0
    } else {
        1.0 - distinct as f64 / sampled as f64
    };
    Ok(DupesReport {
        sampled,
        distinct,
        duplicate_rate,
    })
}

fn identity_hash(packed: &[u8; 32]) -> u64 {
    let mut hasher = DefaultHasher::new();
    packed[..IDENTITY_BYTES].hash(&mut hasher);
    hasher.finish()
}
