use datatool::dupes::dupes;
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
