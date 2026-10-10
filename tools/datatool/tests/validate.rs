use datatool::header::{
    FULLMOVE_NUMBER, GAME_RESULT, HALFMOVE_CLOCK, OCCUPANCY, PIECES, SIDE_TO_MOVE_AND_EN_PASSANT,
};
use datatool::validate::validate;
use std::path::{Path, PathBuf};

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
    bytes[32] ^= 0x3f;
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
    const WHITE_KING: u8 = 5;
    const WHITE_KNIGHT: u8 = 1;
    let mut bytes = std::fs::read(fixture("std.viribin")).unwrap();
    let king = (0..32usize)
        .find(|&i| (bytes[8 + i / 2] >> (4 * (i & 1))) & 0x0f == WHITE_KING)
        .unwrap();
    let shift = 4 * (king & 1);
    bytes[8 + king / 2] = (bytes[8 + king / 2] & !(0x0f << shift)) | (WHITE_KNIGHT << shift);
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

fn validate_with_header(name: &str, edit: impl FnOnce(&mut [u8])) -> datatool::validate::Report {
    let mut bytes = std::fs::read(fixture("std.viribin")).unwrap();
    edit(&mut bytes[..32]);
    let path = scratch_copy(name, &bytes);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    report
}

#[test]
fn header_with_more_than_32_pieces_is_invalid() {
    let report = validate_with_header("overfull", |header| {
        header[..8].copy_from_slice(&u64::MAX.to_le_bytes())
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
    let report = validate_with_header("badpiece", |header| header[8] = (header[8] & 0xf0) | 0x07);
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

const WHITE_PAWN: u8 = 0;
const WHITE_ROOK: u8 = 3;
const WHITE_KING: u8 = 5;
const BLACK_PAWN: u8 = 8;
const BLACK_KNIGHT: u8 = 9;
const BLACK_KING: u8 = 13;
const WHITE_TO_MOVE: u8 = 0;
const NO_EN_PASSANT: u8 = 64;
const DRAW: u8 = 1;

const A1: u8 = 0;
const A2: u8 = 8;
const E1: u8 = 4;
const E5: u8 = 36;
const F5: u8 = 37;
const F6: u8 = 45;
const E8: u8 = 60;
const H8: u8 = 63;

fn one_move_game(
    pieces_by_square: &[(u8, u8)],
    side_to_move_and_en_passant: u8,
    from: u8,
    to: u8,
) -> Vec<u8> {
    let mut game = vec![0u8; 40];
    let occupancy = pieces_by_square
        .iter()
        .fold(0u64, |occupancy, (square, _)| occupancy | 1 << square);
    game[OCCUPANCY].copy_from_slice(&occupancy.to_le_bytes());
    for (index, (_, piece)) in pieces_by_square.iter().enumerate() {
        game[PIECES.start + index / 2] |= piece << (4 * (index & 1));
    }
    game[SIDE_TO_MOVE_AND_EN_PASSANT] = side_to_move_and_en_passant;
    game[FULLMOVE_NUMBER].copy_from_slice(&1u16.to_le_bytes());
    game[GAME_RESULT] = DRAW;
    let played = u16::from(from) | u16::from(to) << 6;
    game[32..34].copy_from_slice(&played.to_le_bytes());
    game
}

fn validate_bytes(name: &str, bytes: &[u8]) -> datatool::validate::Report {
    let path = scratch_copy(name, bytes);
    let report = validate(&path, None).unwrap();
    remove_scratch(&path);
    report
}

#[test]
fn start_position_whose_side_to_move_can_capture_the_king_is_invalid() {
    let pieces = [(A1, WHITE_KING), (E1, WHITE_ROOK), (E8, BLACK_KING)];
    let game = one_move_game(&pieces, WHITE_TO_MOVE | NO_EN_PASSANT, E1, E8);
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
    let pieces = [
        (A1, WHITE_KING),
        (E5, WHITE_PAWN),
        (F5, BLACK_PAWN),
        (F6, BLACK_KNIGHT),
        (H8, BLACK_KING),
    ];
    let game = one_move_game(&pieces, WHITE_TO_MOVE | F6, A1, A2);
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
    let pieces = [
        (A1, WHITE_KING),
        (E5, WHITE_PAWN),
        (F5, BLACK_PAWN),
        (H8, BLACK_KING),
    ];
    let game = one_move_game(&pieces, WHITE_TO_MOVE | F6, A1, A2);
    let report = validate_bytes("enpassantok", &game);
    assert!(report.valid, "{:?}", report.errors);
}

fn first_game(file: &[u8]) -> &[u8] {
    const HEADER_BYTES: usize = 32;
    const MOVE_BYTES: usize = 4;
    let moves = file[HEADER_BYTES..]
        .chunks_exact(MOVE_BYTES)
        .position(|played| played == [0; MOVE_BYTES])
        .unwrap();
    &file[..HEADER_BYTES + (moves + 1) * MOVE_BYTES]
}

#[test]
fn no_corrupted_header_byte_makes_the_validator_panic() {
    const HEADER_BYTES: usize = 32;
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
