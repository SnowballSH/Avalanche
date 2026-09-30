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
