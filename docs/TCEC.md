# TCEC

The files under `tcec/` are what the Top Chess Engine Championship's updater needs to build and
run Avalanche on its Linux machines.

| File | Kept by | What it does |
|---|---|---|
| `tcec/update.sh` | TCEC, as a copy | Downloads `tcec/install.sh` from the `master` branch and sources it. It holds nothing else, so the copy never goes stale |
| `tcec/install.sh` | this repository | Builds the engine and sets `EXE`. Everything that can change between versions is here |
| `tcec/version.py` | TCEC, as a copy | `uci_version`: the engine is named by the version its binary reports |
| `tcec/engine.json` | TCEC, as a copy | The UCI options Avalanche runs with there. Its name has no version because `version.py` supplies it |

## What `update.sh` leaves behind

`update.sh` is run from a directory of TCEC's choosing. When it returns:

- `EXE` is the absolute path of a binary that was built for the CPU of that machine and whose
  bench node count and NNUE checksum matched the committed `bench.nodes` and `nnue-speed.checksum`
  (`scripts/verify_binary.sh`).
- `EXE` is unset if any step failed: the download of `install.sh`, the checkout, the toolchain
  download, the build or the verification. A broken binary is never reported as built.

The directory then holds `install.sh` and an `Avalanche` checkout with the Zig toolchain unpacked
inside it. A later run in the same directory reuses both.

## What `install.sh` does

1. Clones the repository, or updates an existing clone, to the tip of `master`.
2. Downloads the Zig release named by `minimum_zig_version` in `build.zig.zon`, unless it is already
   there. A Zig upgrade of the engine therefore needs no change to either script.
3. Builds with `zig build --release=fast -Dversion=<version>` (docs/BUILD.md).
4. Verifies the binary and sets `EXE`.

`install.sh` is sourced, never executed: it ends a failed run with `return` and hands `EXE` to the
shell that called `update.sh`.

## Version reported at TCEC

The version comes from `version` in `build.zig.zon` and the commit that was built:

| Commit built | `id name` |
|---|---|
| the one tagged `v<version>` | `Avalanche 5.0.0` |
| any other | `Avalanche 5.0.0-dev-1a2b3c4d`, with the first eight digits of the commit |

Two builds of the same commit report the same version, and every new commit on `master` reports a
new one, which is what lets `version.py` be the constant `uci_version`.

## The `tcec` branch

Up to version 4.0.0 these files lived on a separate `tcec` branch that was merged from `master`
by hand before a season, and `update.sh` built that branch. The branch is deprecated: it stays at
4.0.0 so that a copy of the old `update.sh` keeps building, receives no further commits, and will be
deleted once TCEC runs the `update.sh` described here.
