# TCEC

The files under `tcec/` are what the Top Chess Engine Championship's updater needs to build and
run Avalanche on its Linux machines.

| File | Kept by | What it does |
|---|---|---|
| `tcec/update.sh` | TCEC, as a copy | Downloads `tcec/install.sh` from the `master` branch and sources it. It holds nothing else, so the copy does not go stale |
| `tcec/install.sh` | this repository | Builds the engine and sets `EXE`. Everything that can change between versions is here |
| `tcec/version.py` | TCEC, as a copy | `uci_version`: the engine is named by the version its binary reports |
| `tcec/engine.json` | TCEC, as a copy | The UCI options Avalanche runs with there |

`update.sh` holds the address of `tcec/install.sh` on `master`, so that file has to keep its path and
the branch its name.

## What `update.sh` leaves behind

TCEC's updater sources `update.sh` with bash in a directory of its choosing. The script needs `git`,
`wget`, `tar` with `xz`, and access to github.com, raw.githubusercontent.com and ziglang.org. When
it returns:

- On success its status is zero and `EXE` is the absolute path of a binary that was built for the
  CPU of that machine and whose bench node count and NNUE checksum match the committed
  `bench.nodes` and `nnue-speed.checksum` (`scripts/verify_binary.sh`).
- On any failure (the download of `install.sh`, the checkout, the toolchain download, the build or
  the verification) its status is not zero and `EXE` is unset, whatever it held before. A broken or
  stale binary is never reported as built.
- The working directory is the `Avalanche` checkout, if the run got that far.

The directory then holds `install.sh` and the `Avalanche` checkout with the Zig toolchain unpacked
inside it. A later run in the same directory downloads `install.sh` again and reuses the checkout
and the toolchain; a directory left by the script of the `tcec` branch can be reused too.
Toolchains of earlier Zig versions stay in the checkout until someone deletes them.

## What `install.sh` does

1. Clones the repository, or updates an existing clone, to the tip of `master`.
2. Downloads the Zig release named by `minimum_zig_version` in `build.zig.zon` from ziglang.org,
   unless it is already there. A Zig upgrade of the engine therefore needs no change to either
   script, as long as that field names a released version of Zig: a development build has no such
   download address.
3. Builds with `zig build --release=fast -Dversion=<version>` (docs/BUILD.md).
4. Verifies the binary and sets `EXE`.

## Version reported at TCEC

The version is made of `version` in `build.zig.zon` and the commit that was built:

| Commit built | `id name` |
|---|---|
| the one the tag `v<version>` points to | `Avalanche <version>`, for example `Avalanche 5.0.0` |
| any other | `Avalanche <version>-dev-<commit>`, for example `Avalanche 5.0.0-dev-1a2b3c4d`: a development build that follows that release |

Every new commit on `master` reports a new version, which is what lets `version.py` be the
constant `uci_version`.

A release has two parts that must agree: the commit that sets `version` in `build.zig.zon`, and the
tag `v<version>` on that same commit. Until the tag exists, that commit reports the `-dev-` form.
The `tcec` job of `.github/workflows/CI.yml` checks the agreement when the tag is pushed.

## What CI checks

The `tcec` job lints both scripts, runs `install.sh` against the commit under test, compares the
version the binary reports with the table above, and checks that a failed run leaves `EXE` unset.
Once a week it also runs `update.sh` from an empty directory, as TCEC does.

## Moving TCEC off the `tcec` branch

Up to version 4.0.0 these files lived on a separate `tcec` branch that was merged from `master` by
hand before a season, and its `update.sh` built that branch with a Zig version written into the
script. The branch is deprecated: it stays at 4.0.0 so that a copy of the old `update.sh` keeps
building, and it receives no further commits.

To move, TCEC replaces its copies of `update.sh`, `version.py` and `engine.json` with the ones
here. The branch can be deleted once that has happened.
