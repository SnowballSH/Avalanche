//! See "Training" in docs/NNUE.md.

use std::{
    fs::File,
    io::{BufRead, BufReader},
};

use bullet::game::formats::bulletformat::ChessBoard;
use viriformat::{
    chess::{board::Board, chessmove::Move},
    dataformat::{Game, WDL},
};

pub type PositionFilter =
    fn(board: &Board, played: Move, eval: i16, white_score_of_the_game: f32) -> bool;

fn result_score(wdl: WDL) -> f32 {
    match wdl {
        WDL::Win => 1.0,
        WDL::Draw => 0.5,
        WDL::Loss => 0.0,
    }
}

fn visit_positions(
    path: &str,
    filter: PositionFilter,
    mut visit: impl FnMut(ChessBoard),
) -> Result<(), String> {
    let invalid = |err: &dyn std::fmt::Display| format!("validation file {path}: {err}");
    let file = File::open(path).map_err(|err| invalid(&err))?;
    let mut reader = BufReader::new(file);
    let mut moves = Vec::new();

    while !reader.fill_buf().map_err(|err| invalid(&err))?.is_empty() {
        let game = Game::deserialise_from(&mut reader, moves).map_err(|err| invalid(&err))?;
        game.splat_to_bulletformat_with_filter_callback(
            |position| {
                visit(position);
                Ok(())
            },
            |mv, eval, board, wdl, _| !filter(board, mv, eval as i16, result_score(wdl)),
        )
        .map_err(|err| invalid(&err))?;
        moves = game.moves;
    }
    Ok(())
}

fn count_positions(path: &str, filter: PositionFilter) -> Result<usize, String> {
    let mut count = 0;
    visit_positions(path, filter, |_| count += 1)?;
    Ok(count)
}

fn quotas(available: &[usize], needed: usize) -> Vec<usize> {
    let mut order: Vec<usize> = (0..available.len()).collect();
    order.sort_by_key(|&file| (available[file], file));

    let mut quotas = vec![0; available.len()];
    let mut remaining = needed;
    for (served, &file) in order.iter().enumerate() {
        let share = remaining.div_ceil(available.len() - served);
        quotas[file] = share.min(available[file]);
        remaining -= quotas[file];
    }
    quotas
}

/// True for the last position of each of `quota` equal strides over the `available` positions, so
/// for exactly `quota` of them, evenly spaced.
fn is_sampled(index: usize, available: usize, quota: usize) -> bool {
    (index + 1) * quota / available > index * quota / available
}

fn sample_file(
    path: &str,
    filter: PositionFilter,
    available: usize,
    quota: usize,
) -> Result<Vec<ChessBoard>, String> {
    let mut sample = Vec::with_capacity(quota);
    if quota == 0 {
        return Ok(sample);
    }

    let mut seen = 0;
    visit_positions(path, filter, |position| {
        if seen < available && is_sampled(seen, available, quota) {
            sample.push(position);
        }
        seen += 1;
    })?;

    if seen != available {
        return Err(format!(
            "validation file {path}: {seen} positions pass the filter, but {available} did when the \
             file was counted; the file changed, or the filter is not deterministic"
        ));
    }
    Ok(sample)
}

fn interleave<T>(lists: Vec<Vec<T>>) -> Vec<T> {
    let total = lists.iter().map(Vec::len).sum();
    let mut sources: Vec<_> = lists.into_iter().map(Vec::into_iter).collect();
    let mut mixed = Vec::with_capacity(total);
    while mixed.len() < total {
        mixed.extend(sources.iter_mut().filter_map(Iterator::next));
    }
    mixed
}

pub fn load_positions(
    files: &[String],
    filter: PositionFilter,
    count: usize,
) -> Result<Vec<ChessBoard>, String> {
    let available = files
        .iter()
        .map(|path| count_positions(path, filter))
        .collect::<Result<Vec<_>, _>>()?;
    let found: usize = available.iter().sum();
    if found < count {
        return Err(format!(
            "the validation files hold {found} positions that pass the filter, but \
             TRAIN_VALIDATION_BATCHES x TRAIN_BATCH_SIZE needs {count}"
        ));
    }

    let quotas = quotas(&available, count);
    let samples = files
        .iter()
        .zip(available.iter().zip(&quotas))
        .map(|(path, (&available, &quota))| sample_file(path, filter, available, quota))
        .collect::<Result<Vec<_>, _>>()?;

    println!(
        "Validation sample: {count} positions from {} files, {} to {} per file",
        files.len(),
        quotas.iter().min().unwrap_or(&0),
        quotas.iter().max().unwrap_or(&0),
    );
    Ok(interleave(samples))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sampled(available: usize, quota: usize) -> Vec<usize> {
        (0..available)
            .filter(|&index| is_sampled(index, available, quota))
            .collect()
    }

    #[test]
    fn equal_files_share_equally_and_the_first_take_the_remainder() {
        assert_eq!(quotas(&[100, 100, 100], 30), [10, 10, 10]);
        assert_eq!(quotas(&[100, 100, 100], 10), [4, 3, 3]);
        assert_eq!(quotas(&[100, 100, 100], 11), [4, 4, 3]);
        assert_eq!(quotas(&[100], 7), [7]);
    }

    #[test]
    fn short_files_give_everything_and_the_others_make_up_for_them() {
        assert_eq!(quotas(&[100, 2, 100], 30), [14, 2, 14]);
        assert_eq!(quotas(&[100, 0, 3, 100], 40), [19, 0, 3, 18]);
        assert_eq!(quotas(&[5, 9, 6], 20), [5, 9, 6]);
        assert_eq!(quotas(&[50, 10, 12], 33), [11, 10, 12]);
    }

    #[test]
    fn quotas_sum_to_the_need_and_never_exceed_a_file() {
        let available = [1_999_873, 17, 2_000_411, 0, 52_429, 52_428, 1_250_000];
        for needed in [0, 1, 6, 7, 8, 1000, 104_857, 1_048_576, 5_355_158] {
            let quotas = quotas(&available, needed);
            assert_eq!(quotas.iter().sum::<usize>(), needed);
            assert!(quotas.iter().zip(&available).all(|(q, a)| q <= a));

            let unsaturated = quotas.iter().zip(&available).filter(|(q, a)| q < a);
            let (low, high) = unsaturated.fold((usize::MAX, 0), |(low, high), (&q, _)| {
                (low.min(q), high.max(q))
            });
            assert!(high <= low.saturating_add(1), "{needed}: {quotas:?}");
        }
    }

    #[test]
    fn the_stride_takes_exactly_the_quota_evenly_over_the_file() {
        assert_eq!(sampled(10, 10), (0..10).collect::<Vec<_>>());
        assert_eq!(sampled(10, 5), [1, 3, 5, 7, 9]);
        assert_eq!(sampled(10, 3), [3, 6, 9]);
        assert_eq!(sampled(7, 1), [6]);
        assert_eq!(sampled(7, 0), []);

        for (available, quota) in [(2_000_411, 52_429), (1000, 999), (1000, 7), (13, 13)] {
            let indices = sampled(available, quota);
            assert_eq!(indices.len(), quota);
            let gaps = indices.windows(2).map(|pair| pair[1] - pair[0]);
            let (low, high) = gaps.fold((usize::MAX, 0), |(low, high), gap| {
                (low.min(gap), high.max(gap))
            });
            assert!(low >= available / quota && high <= available.div_ceil(quota));
        }
    }

    #[test]
    fn interleaving_is_round_robin_and_passes_over_exhausted_lists() {
        let lists = vec![vec![1, 2, 3], vec![], vec![10], vec![20, 21]];
        assert_eq!(interleave(lists), [1, 10, 20, 2, 21, 3]);
        assert_eq!(interleave(Vec::<Vec<u8>>::new()), []);
    }
}
