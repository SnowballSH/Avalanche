#![cfg(not(feature = "cuda"))]

use std::process::Command;

#[test]
fn a_build_without_a_gpu_backend_refuses_to_train() {
    let output = Command::new(env!("CARGO_BIN_EXE_avalanche-trainer"))
        .current_dir(std::env::temp_dir())
        .output()
        .unwrap();
    let message = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success());
    assert!(message.contains("`cuda` feature"), "{message}");
}
