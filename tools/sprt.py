#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Avalanche SPRT testing CLI — a thin, friendly wrapper around fastchess.

Run SPRT matches of the current working tree against a previous git commit (built
automatically) or against any foreign UCI engine, at the standard time controls.

Examples:
    tools/test vs-commit HEAD~1                 # current vs previous commit, STC
    tools/test --tc ltc vs-commit v2.1.0        # long time control
    tools/test --tc smp --bounds regression vs-commit master
    tools/test vs-engine /path/to/other-engine  # current vs a foreign engine
    tools/test build HEAD~5                      # just build a ref, print its path

Global options go BEFORE the subcommand; the subcommand's own arguments
(ref / engine path / --name) go after.

Time-control presets and SPRT bound presets are configured at the top of this
file (see the "Configuration" block) — edit them there.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import NoReturn

REPO = Path(__file__).resolve().parent.parent
FASTCHESS = REPO / "fastchess" / "fastchess"
CACHE = REPO / ".sprt-cache"
BIN_CACHE = CACHE / "bin"

# =============================== Configuration ==============================
# Edit these knobs to taste; everything below is plumbing.

# Time-control presets. `--tc <name>` selects one; override individual pieces
# with --tc-string / --threads / --hash / --concurrency.
TC_PRESETS = {
    #          tc          threads  hash(MB)  run games in parallel?
    "stc": {"tc": "10+0.1", "threads": 1, "hash": 16, "parallel": True},
    "ltc": {"tc": "60+0.6", "threads": 1, "hash": 64, "parallel": True},
    "smp": {"tc": "30+0.3", "threads": 4, "hash": 256, "parallel": False},
}
DEFAULT_TC = "stc"

# SPRT [elo0, elo1] bound presets. `--bounds <name>` selects one (the names here
# are the valid choices); --elo0/--elo1 override per run. Add your own with a new
# line: "my_bounds": (elo0, elo1).
BOUNDS: dict[str, tuple[float, float]] = {
    "gain": (0.0, 5.0),         # is the new version stronger?
    "regression": (-5.0, 0.0),  # guard against a regression
    "simplify": (-3.0, 1.0),    # accept a simplification that is not a regression
}
DEFAULT_BOUNDS = "gain"

# SPRT error rates (override with --alpha / --beta).
ALPHA = 0.05
BETA = 0.05

# Default opening book, and the hard cap on rounds if the SPRT never decides.
DEFAULT_BOOK = REPO / "books" / "noob_4moves.epd"
DEFAULT_MAX_ROUNDS = 50000
# ============================================================================


# --- pretty output ---------------------------------------------------------
_USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if _USE_COLOR else s


def bold(s: str) -> str:
    return _c("1", s)


def info(s: str) -> None:
    print(_c("36", "::"), s)


def warn(s: str) -> None:
    print(_c("33", "!!"), s)


def die(s: str, code: int = 1) -> NoReturn:
    print(_c("31", "error:"), s, file=sys.stderr)
    sys.exit(code)


def run(
    cmd: Sequence[str | Path], cwd: Path | None = None, quiet: bool = False
) -> None:
    argv = [str(c) for c in cmd]
    if not quiet:
        info(_c("90", "$ " + " ".join(argv)))
    subprocess.run(argv, cwd=str(cwd) if cwd is not None else None, check=True)


def capture(cmd: Sequence[str | Path], cwd: Path | None = None) -> str:
    return subprocess.run(
        [str(c) for c in cmd], cwd=str(cwd) if cwd is not None else None,
        check=True, capture_output=True, text=True,
    ).stdout.strip()


# --- building engines ------------------------------------------------------
def require(tool: str) -> None:
    if shutil.which(tool) is None:
        die(f"`{tool}` is required but was not found on PATH.")


def build_current() -> Path:
    """Build the current working tree (picks up uncommitted changes)."""
    require("zig")
    out = CACHE / "current"
    info(f"Building current working tree -> {bold('Avalanche-current')}")
    run(["zig", "build", "--release=fast", "-Dtarget-name=Avalanche-current",
         "--prefix", str(out)], cwd=REPO)
    binary = out / "bin" / "Avalanche-current"
    if not binary.exists():
        die(f"build did not produce {binary}")
    return binary


def resolve_sha(ref: str) -> str:
    try:
        return capture(["git", "rev-parse", "--short", ref], cwd=REPO)
    except subprocess.CalledProcessError:
        die(f"git could not resolve ref '{ref}'")


def build_ref(ref: str) -> Path:
    """Build a git ref in a throwaway worktree; cache the binary by SHA."""
    require("zig")
    require("git")
    sha = resolve_sha(ref)
    BIN_CACHE.mkdir(parents=True, exist_ok=True)
    cached = BIN_CACHE / f"Avalanche-{sha}"
    if cached.exists():
        info(f"Reusing cached build for {bold(ref)} ({sha}): {cached.name}")
        return cached

    wt = CACHE / f"wt-{sha}"
    if wt.exists():
        run(["git", "worktree", "remove", "--force", wt], cwd=REPO, quiet=True)
    info(f"Building ref {bold(ref)} ({sha}) in a temporary worktree")
    run(["git", "worktree", "add", "--detach", "--force", wt, sha], cwd=REPO)
    try:
        run(["zig", "build", "--release=fast", "-Dtarget-name=Avalanche",
             "--prefix", str(wt / "out")], cwd=wt)
        built = wt / "out" / "bin" / "Avalanche"
        if not built.exists():
            die(f"ref build did not produce {built}")
        shutil.copy2(built, cached)
    finally:
        run(["git", "worktree", "remove", "--force", wt], cwd=REPO, quiet=True)
    return cached


# --- fastchess -------------------------------------------------------------
def preflight(a: argparse.Namespace) -> None:
    """Validate cheap preconditions before spending time building engines."""
    if not FASTCHESS.exists():
        die(f"fastchess binary not found at {FASTCHESS}")
    if not Path(a.book).exists():
        die(
            f"opening book not found: {a.book}\n"
            "       Place noob_4moves.epd there, or pass --book <path>.\n"
            "       (noob_4moves.epd ships with the Stockfish/fastchess books;\n"
            "        e.g. https://github.com/official-stockfish/books )"
        )


def book_args(book: Path) -> list[str]:
    fmt = "pgn" if book.suffix.lower() == ".pgn" else "epd"
    return ["-openings", f"file={book}", f"format={fmt}", "order=random"]


def sprt_run(new_bin: Path, opp_bin: Path, new_name: str, opp_name: str,
             a: argparse.Namespace) -> int:
    preset = TC_PRESETS[a.tc]
    tc = a.tc_string or preset["tc"]
    threads = a.threads if a.threads is not None else preset["threads"]
    hashmb = a.hash if a.hash is not None else preset["hash"]
    if a.concurrency is not None:
        conc = a.concurrency
    elif preset["parallel"]:
        conc = max(1, (os.cpu_count() or 4) - 2)
    else:
        conc = 1
    elo0, elo1 = (a.elo0, a.elo1) if a.elo0 is not None else BOUNDS[a.bounds]

    cmd: list[str | Path] = [
        FASTCHESS,
        "-engine", f"cmd={new_bin}", f"name={new_name}",
        "-engine", f"cmd={opp_bin}", f"name={opp_name}",
        "-each", f"tc={tc}", f"option.Hash={hashmb}",
        f"option.Threads={threads}", "proto=uci",
        *book_args(Path(a.book)),
        "-games", "2", "-rounds", str(a.max_rounds), "-repeat",
        "-sprt", f"elo0={elo0}", f"elo1={elo1}", f"alpha={a.alpha}", f"beta={a.beta}",
        "-concurrency", str(conc),
        "-ratinginterval", "10",
        "-recover",
    ]
    if a.pgn:
        cmd += ["-pgnout", f"file={a.pgn}", "notation=uci"]
    if a.extra:
        cmd += a.extra.split()

    # Summary box.
    print()
    print(bold("  Avalanche SPRT"))
    print(f"    {new_name}  vs  {opp_name}")
    print(f"    tc={tc}  threads={threads}  hash={hashmb}MB  concurrency={conc}")
    print(f"    book={Path(a.book).name}  sprt=[{elo0}, {elo1}]"
          f" alpha={a.alpha} beta={a.beta}")
    print(f"    max rounds={a.max_rounds} (2 games each, color-balanced)")
    print()

    # Stream fastchess live so the user sees rolling Elo/LLR; fastchess stops
    # itself when the SPRT crosses a bound.
    proc = subprocess.run([str(c) for c in cmd], cwd=str(REPO))
    return proc.returncode


# --- subcommands -----------------------------------------------------------
def cmd_vs_commit(a: argparse.Namespace) -> int:
    preflight(a)
    new_bin = build_current()
    opp_bin = build_ref(a.ref)
    return sprt_run(new_bin, opp_bin, "current", f"ref-{resolve_sha(a.ref)}", a)


def cmd_vs_engine(a: argparse.Namespace) -> int:
    opp = Path(a.engine).expanduser()
    if not opp.exists():
        die(f"engine not found: {opp}")
    preflight(a)
    new_bin = build_current()
    return sprt_run(new_bin, opp.resolve(), "current", a.name or opp.name, a)


def cmd_build(a: argparse.Namespace) -> int:
    binary = build_ref(a.ref) if a.ref else build_current()
    print(binary)
    return 0


# --- argument parsing ------------------------------------------------------
def add_common(p: argparse.ArgumentParser) -> None:
    # Global options; give them BEFORE the subcommand, e.g.
    #   tools/test --tc ltc --bounds regression vs-commit HEAD~1
    p.add_argument("--tc", choices=list(TC_PRESETS), default=DEFAULT_TC,
                   help=f"time-control preset (default: {DEFAULT_TC})")
    p.add_argument("--tc-string", help="override the raw fastchess tc, e.g. 8+0.08")
    p.add_argument("--threads", type=int, help="override UCI Threads per engine")
    p.add_argument("--hash", type=int, help="override UCI Hash (MB) per engine")
    p.add_argument("--concurrency", type=int, help="override number of parallel games")
    p.add_argument("--bounds", choices=list(BOUNDS), default=DEFAULT_BOUNDS,
                   help=f"SPRT bound preset (default: {DEFAULT_BOUNDS})")
    p.add_argument("--elo0", type=float, help="override SPRT elo0 (use with --elo1)")
    p.add_argument("--elo1", type=float, help="override SPRT elo1")
    p.add_argument("--alpha", type=float, default=ALPHA,
                   help=f"SPRT alpha (default {ALPHA})")
    p.add_argument("--beta", type=float, default=BETA,
                   help=f"SPRT beta (default {BETA})")
    p.add_argument("--book", default=str(DEFAULT_BOOK), help="opening book (epd/pgn)")
    p.add_argument(
        "--max-rounds", type=int, default=DEFAULT_MAX_ROUNDS, dest="max_rounds",
        help=f"max rounds if the SPRT never decides (default {DEFAULT_MAX_ROUNDS})",
    )
    p.add_argument("--pgn", help="write games to this PGN file")
    p.add_argument("--extra", help="extra args appended verbatim to fastchess")


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="tools/test", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_common(parser)  # global options are given before the subcommand
    sub = parser.add_subparsers(dest="command", required=True)

    p_commit = sub.add_parser("vs-commit", help="SPRT current vs a built git ref")
    p_commit.add_argument("ref", help="git commit/branch/tag to build and play against")
    p_commit.set_defaults(func=cmd_vs_commit)

    p_engine = sub.add_parser("vs-engine", help="SPRT current vs a foreign UCI engine")
    p_engine.add_argument("engine", help="path to the opponent engine binary")
    p_engine.add_argument("--name", default=None, help="display name for the opponent")
    p_engine.set_defaults(func=cmd_vs_engine)

    p_build = sub.add_parser("build", help="build current or a ref; print its binary")
    p_build.add_argument("ref", nargs="?", help="ref to build (omit = current tree)")
    p_build.set_defaults(func=cmd_build)

    args = parser.parse_args()
    if getattr(args, "elo0", None) is not None and getattr(args, "elo1", None) is None:
        die("--elo0 requires --elo1")
    try:
        return int(args.func(args))
    except subprocess.CalledProcessError as e:
        die(f"command failed (exit {e.returncode}): {e.cmd}")
    except KeyboardInterrupt:
        warn("interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
