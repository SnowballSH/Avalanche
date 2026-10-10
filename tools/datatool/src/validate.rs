use crate::replay;
use serde::Serialize;
use std::fs::File;
use std::io::{self, BufRead, BufReader, ErrorKind};
use std::path::Path;
use viriformat::dataformat::{Filter, Game, WDL};

const EVAL_BUCKETS: [i32; 5] = [100, 300, 1000, 3000, 10000];

type EvalHistogram = [u64; EVAL_BUCKETS.len() + 1];

fn eval_bucket(eval: i32) -> usize {
    EVAL_BUCKETS
        .iter()
        .position(|&bound| eval.abs() < bound)
        .unwrap_or(EVAL_BUCKETS.len())
}

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
    pub abs_eval_histogram: EvalHistogram,
    pub filter_pass: Option<u64>,
    pub errors: Vec<String>,
    pub valid: bool,
}

impl Report {
    fn add_game(&mut self, game: &Game, filter: Option<&Filter>) -> Result<(), String> {
        let mut castles = 0;
        let mut abs_eval_histogram = EvalHistogram::default();
        replay::visit_positions(game, |_, mv, eval| {
            castles += u64::from(mv.is_castle());
            abs_eval_histogram[eval_bucket(eval)] += 1;
        })?;

        self.castles += castles;
        for (total, count) in self.abs_eval_histogram.iter_mut().zip(abs_eval_histogram) {
            *total += count;
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
        if let Some(filter) = filter {
            *self.filter_pass.get_or_insert(0) += game.filter_pass_count(filter);
        }
        self.games += 1;
        self.positions += len;
        Ok(())
    }
}

pub fn validate(path: &Path, filter: Option<&Filter>) -> io::Result<Report> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut report = Report::default();
    while !reader.fill_buf()?.is_empty() {
        let outcome = match Game::deserialise_from(&mut reader, Vec::new()) {
            Ok(game) => report.add_game(&game, filter),
            Err(e) if e.kind() == ErrorKind::UnexpectedEof => Err(String::from("truncated")),
            Err(e) => Err(e.to_string()),
        };
        if let Err(problem) = outcome {
            report
                .errors
                .push(format!("game {}: {problem}", report.games));
            break;
        }
    }
    report.valid = report.errors.is_empty() && report.games > 0;
    Ok(report)
}
