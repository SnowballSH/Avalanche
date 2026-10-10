use datatool::header::{
    BYTES as HEADER_BYTES, FULLMOVE_NUMBER, GAME_RESULT, HALFMOVE_CLOCK, OCCUPANCY, PIECES,
    SIDE_TO_MOVE_AND_EN_PASSANT,
};
use datatool::validate::{Report, validate};
use std::path::{Path, PathBuf};

const MOVE_BYTES: usize = 4;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn summary(name: &str) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(fixture(name)).unwrap()).unwrap()
}

fn scratch_copy(name: &str, bytes: &[u8]) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("datatool-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("chunk.viribin");
    std::fs::write(&path, bytes).unwrap();
    path
}

fn remove_scratch(path: &Path) {
    std::fs::remove_file(path).unwrap();
    std::fs::remove_dir(path.parent().unwrap()).unwrap();
}

#[test]
fn standard_fixture_matches_the_engine_summary() {
    let report = validate(&fixture("std.viribin"), None).unwrap();
    let expected = summary("std.summary.json");
    assert!(report.valid, "{:?}", report.errors);
    assert_eq!(report.positions, expected["positions"].as_u64().unwrap());
    assert_eq!(report.games, expected["games"].as_u64().unwrap());
    assert_eq!(report.white_wins, expected["white_wins"].as_u64().unwrap());
    assert_eq!(report.black_wins, expected["black_wins"].as_u64().unwrap());
}

#[test]
fn frc_fixture_replays_every_castling_move() {
    let report = validate(&fixture("frc.viribin"), None).unwrap();
    assert!(report.valid, "{:?}", report.errors);
    assert!(report.castles > 0, "the FRC fixture must exercise castling");
    assert_eq!(
        report.positions,
        summary("frc.summary.json")["positions"].as_u64().unwrap()
    );
}

#[test]
fn truncated_file_is_invalid() {
    let bytes = std::fs::read(fixture("std.viribin")).unwrap();
    let path = scratch_copy("truncated", &bytes[..bytes.len() - 3]);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    assert!(!report.valid);
    assert!(report.errors.iter().any(|e| e.contains("truncated")));
}

#[test]
fn corrupted_move_is_invalid() {
    let mut bytes = std::fs::read(fixture("std.viribin")).unwrap();
    bytes[HEADER_BYTES] ^= 0x3f;
    let path = scratch_copy("corrupt", &bytes);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("illegal move")),
        "{:?}",
        report.errors
    );
}

#[test]
fn empty_file_is_invalid() {
    let path = scratch_copy("empty", &[]);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    assert!(!report.valid);
}

#[test]
fn start_position_without_a_king_is_invalid() {
    let mut bytes = std::fs::read(fixture("std.viribin")).unwrap();
    let king = (0..2 * PIECES.len())
        .find(|&i| (bytes[PIECES.start + i / 2] >> (4 * (i & 1))) & 0x0f == piece_code('K'))
        .unwrap();
    let shift = 4 * (king & 1);
    let byte = &mut bytes[PIECES.start + king / 2];
    *byte = (*byte & !(0x0f << shift)) | (piece_code('N') << shift);
    let path = scratch_copy("kingless", &bytes);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("king")),
        "{:?}",
        report.errors
    );
}

fn validate_with_header(name: &str, edit: impl FnOnce(&mut [u8])) -> Report {
    let mut bytes = std::fs::read(fixture("std.viribin")).unwrap();
    edit(&mut bytes[..HEADER_BYTES]);
    let path = scratch_copy(name, &bytes);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    report
}

#[test]
fn header_with_more_than_32_pieces_is_invalid() {
    let report = validate_with_header("overfull", |header| {
        header[OCCUPANCY].copy_from_slice(&u64::MAX.to_le_bytes())
    });
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("pieces")),
        "{:?}",
        report.errors
    );
}

#[test]
fn header_with_an_unknown_piece_code_is_invalid() {
    const UNKNOWN_PIECE_CODE: u8 = 7;
    let report = validate_with_header("badpiece", |header| {
        header[PIECES.start] = (header[PIECES.start] & 0xf0) | UNKNOWN_PIECE_CODE
    });
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("piece code")),
        "{:?}",
        report.errors
    );
}

#[test]
fn header_with_an_unknown_game_result_is_invalid() {
    const FIRST_UNKNOWN_RESULT: u8 = 3;
    let report = validate_with_header("badresult", |header| {
        header[GAME_RESULT] = FIRST_UNKNOWN_RESULT
    });
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("game result")),
        "{:?}",
        report.errors
    );
}

#[test]
fn header_with_a_fullmove_number_of_zero_is_invalid() {
    let report = validate_with_header("movezero", |header| header[FULLMOVE_NUMBER].fill(0));
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("fullmove number")),
        "{:?}",
        report.errors
    );
}

#[test]
fn halfmove_clock_at_the_limit_of_its_byte_is_invalid() {
    let report = validate_with_header("clock", |header| header[HALFMOVE_CLOCK] = u8::MAX);
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("halfmove clock")),
        "{:?}",
        report.errors
    );
}

const WHITE_TO_MOVE: u8 = 0;
const NO_EN_PASSANT: u8 = 64;
const DRAW: u8 = 1;

const A1: u8 = 0;
const E1: u8 = 4;
const F1: u8 = 5;
const G1: u8 = 6;
const H1: u8 = 7;
const A2: u8 = 8;
const E2: u8 = 12;
const G2: u8 = 14;
const F6: u8 = 45;
const E8: u8 = 60;

fn piece_code(fen_letter: char) -> u8 {
    const BLACK: u8 = 8;
    let kind = "pnbrqk".find(fen_letter.to_ascii_lowercase()).unwrap() as u8;
    if fen_letter.is_ascii_lowercase() {
        kind | BLACK
    } else {
        kind
    }
}

fn piece_codes_by_square(fen_board: &str) -> Vec<(u8, u8)> {
    let mut pieces = Vec::new();
    for (rank, row) in (0..8u8).rev().zip(fen_board.split('/')) {
        let mut file = 0;
        for symbol in row.chars() {
            match symbol.to_digit(10) {
                Some(empty_squares) => file += empty_squares as u8,
                None => {
                    pieces.push((8 * rank + file, piece_code(symbol)));
                    file += 1;
                }
            }
        }
    }
    pieces.sort_unstable();
    pieces
}

fn one_move_game(fen_board: &str, side_to_move_and_en_passant: u8, from: u8, to: u8) -> Vec<u8> {
    let mut game = vec![0u8; HEADER_BYTES + 2 * MOVE_BYTES];
    let pieces = piece_codes_by_square(fen_board);
    let occupancy = pieces
        .iter()
        .fold(0u64, |occupancy, (square, _)| occupancy | 1 << square);
    game[OCCUPANCY].copy_from_slice(&occupancy.to_le_bytes());
    for (index, (_, piece)) in pieces.iter().enumerate() {
        game[PIECES.start + index / 2] |= piece << (4 * (index & 1));
    }
    game[SIDE_TO_MOVE_AND_EN_PASSANT] = side_to_move_and_en_passant;
    game[FULLMOVE_NUMBER].copy_from_slice(&1u16.to_le_bytes());
    game[GAME_RESULT] = DRAW;
    let played = u16::from(from) | u16::from(to) << 6;
    game[HEADER_BYTES..HEADER_BYTES + 2].copy_from_slice(&played.to_le_bytes());
    game
}

fn validate_bytes(name: &str, bytes: &[u8]) -> Report {
    let path = scratch_copy(name, bytes);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    report
}

#[test]
fn start_position_whose_side_to_move_can_capture_the_king_is_invalid() {
    let game = one_move_game(
        "4k3/8/8/8/8/8/8/K3R3",
        WHITE_TO_MOVE | NO_EN_PASSANT,
        E1,
        E8,
    );
    let report = validate_bytes("kingcapture", &game);
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("king")),
        "{:?}",
        report.errors
    );
}

#[test]
fn en_passant_square_that_is_occupied_is_invalid() {
    let game = one_move_game("7k/8/5n2/4Pp2/8/8/8/K7", WHITE_TO_MOVE | F6, A1, A2);
    let report = validate_bytes("enpassant", &game);
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("en passant")),
        "{:?}",
        report.errors
    );
}

#[test]
fn en_passant_square_behind_a_pawn_that_just_advanced_two_squares_is_valid() {
    let game = one_move_game("7k/8/8/4Pp2/8/8/8/K7", WHITE_TO_MOVE | F6, A1, A2);
    let report = validate_bytes("enpassantok", &game);
    assert!(report.valid, "{:?}", report.errors);
}

#[test]
fn the_position_with_the_most_moves_a_game_can_reach_is_valid() {
    let game = one_move_game(
        "R6R/3Q4/1Q4Q1/4Q3/2Q4Q/Q4Q2/pp1Q4/kBNN1KB1",
        WHITE_TO_MOVE | NO_EN_PASSANT,
        F1,
        E2,
    );
    let report = validate_bytes("mostmoves", &game);
    assert!(report.valid, "{:?}", report.errors);
}

#[test]
fn start_position_with_more_moves_than_the_crate_can_list_is_invalid() {
    let game = one_move_game(
        "knQQQQQQ/pp5Q/Q6Q/Q6Q/Q6Q/Q6Q/Q6Q/QQQQQQQK",
        WHITE_TO_MOVE | NO_EN_PASSANT,
        H1,
        G2,
    );
    let report = validate_bytes("queens", &game);
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("list the moves")),
        "{:?}",
        report.errors
    );
}

#[test]
fn a_castling_right_that_adds_a_move_to_a_full_move_list_is_invalid() {
    const UNMOVED_ROOK: u8 = 6;
    let full_move_list = "kNN1BB2/rrQ4Q/Q4Q2/3Q4/1Q4Q1/4Q3/2Q3K1/R6R";
    let mut game = one_move_game(full_move_list, WHITE_TO_MOVE | NO_EN_PASSANT, G2, G1);
    let report = validate_bytes("fulllist", &game);
    assert!(report.valid, "{:?}", report.errors);

    let rook_on_a1 = &mut game[PIECES.start];
    assert_eq!(*rook_on_a1 & 0x0f, piece_code('R'));
    *rook_on_a1 = (*rook_on_a1 & 0xf0) | UNMOVED_ROOK;
    let report = validate_bytes("castlingright", &game);
    assert!(!report.valid);
    assert!(
        report.errors.iter().any(|e| e.contains("list the moves")),
        "{:?}",
        report.errors
    );
}

fn first_game(file: &[u8]) -> &[u8] {
    let moves = file[HEADER_BYTES..]
        .chunks_exact(MOVE_BYTES)
        .position(|played| played == [0; MOVE_BYTES])
        .unwrap();
    &file[..HEADER_BYTES + (moves + 1) * MOVE_BYTES]
}

#[test]
fn no_corrupted_header_byte_makes_the_validator_panic() {
    for name in ["std.viribin", "frc.viribin"] {
        let file = std::fs::read(fixture(name)).unwrap();
        let game = first_game(&file);
        let corruptions = (0..HEADER_BYTES).flat_map(|byte| {
            let bit_flips = (0..u8::BITS).map(move |bit| game[byte] ^ (1 << bit));
            bit_flips
                .chain([u8::MIN, u8::MAX])
                .map(move |value| (byte, value))
        });
        let panicking: Vec<(usize, u8)> = corruptions
            .filter(|&(byte, value)| {
                let mut corrupted = game.to_vec();
                corrupted[byte] = value;
                let path = scratch_copy(&format!("corrupt-{name}-{byte}-{value}"), &corrupted);
                let outcome = std::panic::catch_unwind(|| validate(&path, None));
                remove_scratch(&path);
                outcome.is_err()
            })
            .collect();
        assert!(panicking.is_empty(), "{name}: (byte, value) {panicking:?}");
    }
}
