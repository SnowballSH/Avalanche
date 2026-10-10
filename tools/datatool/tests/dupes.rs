use datatool::dupes::dupes;
use datatool::header::FULLMOVE_NUMBER;
use std::path::PathBuf;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

#[test]
fn a_file_counted_twice_is_fully_duplicated() {
    let once = dupes(&[fixture("std.viribin")], 1000).unwrap();
    let twice = dupes(&[fixture("std.viribin"), fixture("std.viribin")], 1000).unwrap();
    assert_eq!(twice.sampled, 2 * once.sampled);
    assert_eq!(twice.distinct, once.distinct);
    assert!(twice.duplicate_rate >= 0.5);
}

#[test]
fn sampling_is_deterministic_and_a_subset() {
    let full = dupes(&[fixture("std.viribin")], 1000).unwrap();
    let sample = dupes(&[fixture("std.viribin")], 100).unwrap();
    assert_eq!(sample, dupes(&[fixture("std.viribin")], 100).unwrap());
    assert!(sample.sampled < full.sampled);
}

fn dupes_error_after(name: &str, edit: impl FnOnce(&mut [u8])) -> String {
    let mut bytes = std::fs::read(fixture("std.viribin")).unwrap();
    edit(&mut bytes);
    let dir = std::env::temp_dir().join(format!("datatool-dupes-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("bad.viribin");
    std::fs::write(&path, &bytes).unwrap();
    let result = dupes(std::slice::from_ref(&path), 1000);
    std::fs::remove_file(&path).unwrap();
    std::fs::remove_dir(&dir).unwrap();
    result.unwrap_err().to_string()
}

#[test]
fn a_malformed_header_is_an_error_not_a_panic() {
    let error = dupes_error_after("header", |bytes| {
        bytes[..8].copy_from_slice(&u64::MAX.to_le_bytes())
    });
    assert!(error.contains("pieces"), "{error}");
}

#[test]
fn a_quiet_move_flagged_as_a_castle_is_an_error_not_a_panic() {
    const FIRST_MOVE_HIGH_BYTE: usize = 33;
    const CASTLE_FLAG: u8 = 0x80;
    let error = dupes_error_after("castle", |bytes| bytes[FIRST_MOVE_HIGH_BYTE] |= CASTLE_FLAG);
    assert!(error.contains("illegal move"), "{error}");
}

#[test]
fn a_fullmove_number_beyond_its_two_bytes_is_an_error_not_a_panic() {
    let error = dupes_error_after("fullmove", |bytes| bytes[FULLMOVE_NUMBER].fill(u8::MAX));
    assert!(error.contains("fullmove number"), "{error}");
}

#[test]
fn the_chess960_fixture_is_replayed_with_its_castling_moves() {
    let summary: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(fixture("frc.summary.json")).unwrap())
            .unwrap();
    let report = dupes(&[fixture("frc.viribin")], 1000).unwrap();
    assert_eq!(report.sampled, summary["positions"].as_u64().unwrap());
}
