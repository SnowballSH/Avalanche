use crate::header;
use serde::Serialize;
use std::fs::File;
use std::io::{BufRead, BufReader, ErrorKind};
use std::path::Path;
use std::sync::atomic::Ordering;
use viriformat::chess::CHESS960;
use viriformat::dataformat::{Filter, Game, WDL};

const MAX_ERRORS: usize = 10;
const EVAL_BUCKETS: [i32; 5] = [100, 300, 1000, 3000, 10000];

#[derive(Debug, Default, Serialize)]
pub struct Report {
    pub games: u64,
    pub positions: u64,
    pub white_wins: u64,
    pub draws: u64,
    pub black_wins: u64,
    pub castles: u64,
    pub min_game_len: u64,
    pub max_game_len: u64,
    pub abs_eval_histogram: [u64; EVAL_BUCKETS.len() + 1],
    pub filter_pass: Option<u64>,
    pub errors: Vec<String>,
    pub valid: bool,
}

impl Report {
    fn error(&mut self, message: String) {
        if self.errors.len() < MAX_ERRORS {
            self.errors.push(message);
        }
    }

    fn add_game(&mut self, game: &Game, filter: Option<&Filter>) -> Result<(), String> {
        header::check(&game.initial_position.as_bytes())
            .map_err(|problem| format!("game {}: invalid start position: {problem}", self.games))?;
        let mut board = game.initial_position();
        for (ply, mv) in game.moves().enumerate() {
            if !board.legal_moves().contains(&mv) {
                return Err(format!(
                    "game {}: illegal move {mv:?} at ply {ply}",
                    self.games
                ));
            }
            if mv.is_castle() {
                self.castles += 1;
            }
            board.make_move_simple(mv);
        }

        let len = game.len() as u64;
        self.min_game_len = if self.games == 0 {
            len
        } else {
            self.min_game_len.min(len)
        };
        self.max_game_len = self.max_game_len.max(len);
        match game.outcome() {
            WDL::Win => self.white_wins += 1,
            WDL::Draw => self.draws += 1,
            WDL::Loss => self.black_wins += 1,
        }
        game.visit_positions(|_, eval| {
            let bucket = EVAL_BUCKETS
                .iter()
                .position(|&bound| eval.abs() < bound)
                .unwrap_or(EVAL_BUCKETS.len());
            self.abs_eval_histogram[bucket] += 1;
        });
        if let Some(filter) = filter {
            *self.filter_pass.get_or_insert(0) += game.filter_pass_count(filter);
        }
        self.games += 1;
        self.positions += len;
        Ok(())
    }
}

/// Replays every game in a viriformat file with the reference move generator.
///
/// Enables the crate's process-wide Chess960 move generation: Avalanche encodes every castle as
/// king-takes-rook, and only the Chess960 generator produces castles for non-standard king/rook files.
///
/// # Errors
/// Returns an error only when the file cannot be opened or read; malformed data is reported in `Report::errors`.
pub fn validate(path: &Path, filter: Option<&Filter>) -> anyhow::Result<Report> {
    CHESS960.store(true, Ordering::SeqCst);
    let mut reader = BufReader::new(File::open(path)?);
    let mut report = Report::default();
    while !reader.fill_buf()?.is_empty() {
        let outcome = match Game::deserialise_from(&mut reader, Vec::new()) {
            Ok(game) => report.add_game(&game, filter),
            Err(e) if e.kind() == ErrorKind::UnexpectedEof => {
                Err(format!("game {}: truncated", report.games))
            }
            Err(e) => Err(format!("game {}: {e}", report.games)),
        };
        if let Err(message) = outcome {
            report.error(message);
            break;
        }
    }
    report.valid = report.errors.is_empty() && report.games > 0;
    Ok(report)
}
