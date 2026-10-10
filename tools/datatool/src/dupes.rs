use crate::{header, replay};
use anyhow::anyhow;
use serde::Serialize;
use std::collections::HashSet;
use std::fs::File;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use viriformat::dataformat::Game;

const PER_MILLE: u64 = 1000;

#[derive(Debug, PartialEq, Serialize)]
pub struct DupesReport {
    pub sampled: u64,
    pub distinct: u64,
    pub duplicate_rate: f64,
}

pub fn dupes(files: &[PathBuf], sample_per_mille: u64) -> anyhow::Result<DupesReport> {
    let mut seen = HashSet::new();
    let mut sampled = 0u64;
    for path in files {
        let mut reader = BufReader::new(File::open(path)?);
        let mut games = 0u64;
        while !reader.fill_buf()?.is_empty() {
            let game = Game::deserialise_from(&mut reader, Vec::new())?;
            replay::visit_positions(&game, |board, _, _| {
                let hash = identity_hash(&board.to_marlinformat(0, 0, 0).as_bytes());
                if hash % PER_MILLE < sample_per_mille {
                    sampled += 1;
                    seen.insert(hash);
                }
            })
            .map_err(|problem| anyhow!("{}: game {games}: {problem}", path.display()))?;
            games += 1;
        }
    }
    let distinct = seen.len() as u64;
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
    packed[..=header::SIDE_TO_MOVE_AND_EN_PASSANT].hash(&mut hasher);
    hasher.finish()
}
