#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Avalanche SPRT testing CLI — a thin, friendly wrapper around fastchess.

Run SPRT matches of the current working tree against a previous git commit (built
automatically) or against any foreign UCI engine, at the standard time controls.

Examples:
    scripts/sprt.py vs-commit HEAD~1                 # current vs previous commit, STC
    scripts/sprt.py --tc ltc vs-commit v2.1.0        # long time control
    scripts/sprt.py --tc smp --bounds regression vs-commit master
    scripts/sprt.py vs-engine /path/to/other-engine  # current vs a foreign engine
    scripts/sprt.py build HEAD~5                      # just build a ref, print its path

Global options go BEFORE the subcommand; the subcommand's own arguments
(ref / engine path / --name) go after.

The time-control presets and the SPRT bound presets are the TIME_CONTROLS and
BOUNDS tables of this file.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, NoReturn

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence

REPO = Path(__file__).resolve().parent.parent
FASTCHESS = REPO / "fastchess" / "fastchess"
CACHE = REPO / ".sprt-cache"
BIN_CACHE = CACHE / "bin"


@dataclass(frozen=True)
class TimeControl:
    tc: str
    threads: int
    hash_mb: int
    parallel_games: bool


@dataclass(frozen=True)
class Bounds:
    elo0: float
    elo1: float


TIME_CONTROLS = {
    "stc": TimeControl(tc="5+0.05", threads=1, hash_mb=16, parallel_games=True),
    "ltc": TimeControl(tc="50+0.5", threads=1, hash_mb=64, parallel_games=True),
    "smp": TimeControl(tc="30+0.3", threads=4, hash_mb=1024, parallel_games=False),
}
DEFAULT_TIME_CONTROL = "stc"

BOUNDS = {
    "gain": Bounds(0.0, 10.0),
    "regression": Bounds(-10.0, 0.0),
    "simplify": Bounds(-5.0, 1.0),
}
DEFAULT_BOUNDS = "gain"

ALPHA = 0.05
BETA = 0.05

DEFAULT_BOOK = REPO / "books" / "UHO_4060_v4.epd"
DEFAULT_MAX_ROUNDS = 50000
GAMES_PER_ROUND = 2
RATING_INTERVAL = 10
ASSUMED_CPUS = 4
CPUS_LEFT_FREE = 2

DRAW_MOVENUMBER = 34
DRAW_MOVECOUNT = 8
DRAW_SCORE = 8

RESIGN_MOVECOUNT = 3
RESIGN_SCORE = 400

INTERRUPTED_STATUS = 130

USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def colored(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if USE_COLOR else text


def bold(text: str) -> str:
    return colored("1", text)


def info(text: str) -> None:
    print(colored("36", "::"), text)


def warn(text: str) -> None:
    print(colored("33", "!!"), text)


def die(message: str) -> NoReturn:
    print(colored("31", "error:"), message, file=sys.stderr)
    sys.exit(1)


def run(command: Sequence[str | Path], *, cwd: Path, quiet: bool = False) -> None:
    argv = [str(argument) for argument in command]
    if not quiet:
        info(colored("90", "$ " + " ".join(argv)))
    subprocess.run(argv, cwd=cwd, check=True)


def capture(command: Sequence[str | Path], *, cwd: Path) -> str:
    argv = [str(argument) for argument in command]
    return subprocess.run(argv, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def require(tool: str) -> None:
    if shutil.which(tool) is None:
        die(f"`{tool}` is required but was not found on PATH.")


def zig_build(source: Path, prefix: Path, target_name: str) -> Path:
    run(["zig", "build", "--release=fast", f"-Dtarget-name={target_name}", "--prefix", prefix], cwd=source)
    binary = prefix / "bin" / target_name
    if not binary.exists():
        die(f"build did not produce {binary}")
    return binary


def build_working_tree() -> Path:
    require("zig")
    info(f"Building current working tree -> {bold('Avalanche-current')}")
    return zig_build(REPO, CACHE / "current", "Avalanche-current")


def resolve_sha(ref: str) -> str:
    try:
        return capture(["git", "rev-parse", "--short", ref], cwd=REPO)
    except subprocess.CalledProcessError:
        die(f"git could not resolve ref '{ref}'")


def remove_worktree(worktree: Path) -> None:
    run(["git", "worktree", "remove", "--force", worktree], cwd=REPO, quiet=True)


def build_ref(ref: str) -> Path:
    require("zig")
    require("git")
    sha = resolve_sha(ref)
    BIN_CACHE.mkdir(parents=True, exist_ok=True)
    cached = BIN_CACHE / f"Avalanche-{sha}"
    if cached.exists():
        info(f"Reusing cached build for {bold(ref)} ({sha}): {cached.name}")
        return cached

    worktree = CACHE / f"wt-{sha}"
    if worktree.exists():
        remove_worktree(worktree)
    info(f"Building ref {bold(ref)} ({sha}) in a temporary worktree")
    run(["git", "worktree", "add", "--detach", "--force", worktree, sha], cwd=REPO)
    try:
        shutil.copy2(zig_build(worktree, worktree / "out", "Avalanche"), cached)
    finally:
        remove_worktree(worktree)
    return cached


class Arguments(argparse.Namespace):
    tc: str
    tc_string: str | None
    threads: int | None
    hash_mb: int | None
    concurrency: int | None
    bounds: str
    elo0: float | None
    elo1: float | None
    alpha: float
    beta: float
    book: Path
    max_rounds: int
    pgn: Path | None
    extra: str | None
    no_adj: bool
    command: str
    ref: str
    optional_ref: str | None
    engine: Path
    name: str | None


@dataclass(frozen=True)
class Player:
    binary: Path
    name: str


@dataclass(frozen=True)
class Match:
    tc: str
    threads: int
    hash_mb: int
    concurrency: int
    bounds: Bounds
    alpha: float
    beta: float
    book: Path
    max_rounds: int
    adjudicated: bool
    pgn: Path | None
    extra: tuple[str, ...]

    @classmethod
    def from_arguments(cls, args: Arguments) -> Match:
        preset = TIME_CONTROLS[args.tc]
        if args.concurrency is not None:
            concurrency = args.concurrency
        elif preset.parallel_games:
            concurrency = max(1, (os.cpu_count() or ASSUMED_CPUS) - CPUS_LEFT_FREE)
        else:
            concurrency = 1
        if args.elo0 is not None and args.elo1 is not None:
            bounds = Bounds(args.elo0, args.elo1)
        else:
            bounds = BOUNDS[args.bounds]
        return cls(
            tc=args.tc_string or preset.tc,
            threads=preset.threads if args.threads is None else args.threads,
            hash_mb=preset.hash_mb if args.hash_mb is None else args.hash_mb,
            concurrency=concurrency,
            bounds=bounds,
            alpha=args.alpha,
            beta=args.beta,
            book=args.book.absolute(),
            max_rounds=args.max_rounds,
            adjudicated=not args.no_adj,
            pgn=args.pgn.absolute() if args.pgn else None,
            extra=tuple(args.extra.split()) if args.extra else (),
        )

    def check_prerequisites(self) -> None:
        if not FASTCHESS.exists():
            die(f"fastchess binary not found at {FASTCHESS}")
        if not self.book.exists():
            die(
                f"opening book not found: {self.book}\n"
                "       Opening books are not committed; place one there or pass --book <path>."
            )

    def fastchess_command(self, new: Player, opponent: Player) -> list[str]:
        book_format = "pgn" if self.book.suffix.lower() == ".pgn" else "epd"
        command = [
            str(FASTCHESS),
            "-engine",
            f"cmd={new.binary}",
            f"name={new.name}",
            "-engine",
            f"cmd={opponent.binary}",
            f"name={opponent.name}",
            "-each",
            f"tc={self.tc}",
            f"option.Hash={self.hash_mb}",
            f"option.Threads={self.threads}",
            "proto=uci",
            "-openings",
            f"file={self.book}",
            f"format={book_format}",
            "order=random",
            "-games",
            str(GAMES_PER_ROUND),
            "-rounds",
            str(self.max_rounds),
            "-repeat",
            "-sprt",
            f"elo0={self.bounds.elo0}",
            f"elo1={self.bounds.elo1}",
            f"alpha={self.alpha}",
            f"beta={self.beta}",
            "-concurrency",
            str(self.concurrency),
            "-ratinginterval",
            str(RATING_INTERVAL),
            "-recover",
        ]
        if self.adjudicated:
            command += [
                "-draw",
                f"movenumber={DRAW_MOVENUMBER}",
                f"movecount={DRAW_MOVECOUNT}",
                f"score={DRAW_SCORE}",
                "-resign",
                f"movecount={RESIGN_MOVECOUNT}",
                f"score={RESIGN_SCORE}",
            ]
        if self.pgn:
            command += ["-pgnout", f"file={self.pgn}", "notation=uci"]
        return [*command, *self.extra]

    def play(self, new: Player, opponent: Player) -> int:
        print()
        print(bold("  Avalanche SPRT"))
        print(f"    {new.name}  vs  {opponent.name}")
        print(
            f"    tc={self.tc}  threads={self.threads}  hash={self.hash_mb}MB  concurrency={self.concurrency}"
        )
        print(
            f"    book={self.book.name}  sprt=[{self.bounds.elo0}, {self.bounds.elo1}]"
            f" alpha={self.alpha} beta={self.beta}"
        )
        print(f"    max rounds={self.max_rounds} ({GAMES_PER_ROUND} games each, color-balanced)")
        print()
        return subprocess.run(self.fastchess_command(new, opponent), cwd=REPO, check=False).returncode


def vs_commit(args: Arguments) -> int:
    match = Match.from_arguments(args)
    match.check_prerequisites()
    current = Player(build_working_tree(), "current")
    return match.play(current, Player(build_ref(args.ref), f"ref-{resolve_sha(args.ref)}"))


def vs_engine(args: Arguments) -> int:
    opponent = args.engine.expanduser()
    if not opponent.exists():
        die(f"engine not found: {opponent}")
    match = Match.from_arguments(args)
    match.check_prerequisites()
    current = Player(build_working_tree(), "current")
    return match.play(current, Player(opponent.resolve(), args.name or opponent.name))


def build(args: Arguments) -> int:
    print(build_ref(args.optional_ref) if args.optional_ref else build_working_tree())
    return 0


COMMANDS: dict[str, Callable[[Arguments], int]] = {
    "vs-commit": vs_commit,
    "vs-engine": vs_engine,
    "build": build,
}


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--tc",
        choices=list(TIME_CONTROLS),
        default=DEFAULT_TIME_CONTROL,
        help=f"time-control preset (default: {DEFAULT_TIME_CONTROL})",
    )
    parser.add_argument("--tc-string", help="override the raw fastchess tc, e.g. 8+0.08")
    parser.add_argument("--threads", type=int, help="override UCI Threads per engine")
    parser.add_argument("--hash", type=int, dest="hash_mb", metavar="MB", help="override UCI Hash per engine")
    parser.add_argument("--concurrency", type=int, help="override number of parallel games")
    parser.add_argument(
        "--bounds",
        choices=list(BOUNDS),
        default=DEFAULT_BOUNDS,
        help=f"SPRT bound preset (default: {DEFAULT_BOUNDS})",
    )
    parser.add_argument("--elo0", type=float, help="override SPRT elo0 (use with --elo1)")
    parser.add_argument("--elo1", type=float, help="override SPRT elo1 (use with --elo0)")
    parser.add_argument("--alpha", type=float, default=ALPHA, help=f"SPRT alpha (default {ALPHA})")
    parser.add_argument("--beta", type=float, default=BETA, help=f"SPRT beta (default {BETA})")
    parser.add_argument("--book", type=Path, default=DEFAULT_BOOK, help="opening book (epd/pgn)")
    parser.add_argument(
        "--max-rounds",
        type=int,
        default=DEFAULT_MAX_ROUNDS,
        help=f"max rounds if the SPRT never decides (default {DEFAULT_MAX_ROUNDS})",
    )
    parser.add_argument("--pgn", type=Path, help="write games to this PGN file")
    parser.add_argument("--extra", help="extra args appended verbatim to fastchess")
    parser.add_argument("--no-adj", action="store_true", help="disable standard draw/resign adjudication")

    commands = parser.add_subparsers(dest="command", required=True)
    commit = commands.add_parser("vs-commit", help="SPRT current vs a built git ref")
    commit.add_argument("ref", help="git commit/branch/tag to build and play against")
    engine = commands.add_parser("vs-engine", help="SPRT current vs a foreign UCI engine")
    engine.add_argument("engine", type=Path, help="path to the opponent engine binary")
    engine.add_argument("--name", help="display name for the opponent")
    build_only = commands.add_parser("build", help="build current or a ref; print its binary")
    build_only.add_argument(
        "optional_ref", metavar="ref", nargs="?", help="ref to build (omit = current tree)"
    )
    return parser


def main() -> int:
    parser = argument_parser()
    args = parser.parse_args(namespace=Arguments())
    if (args.elo0 is None) != (args.elo1 is None):
        parser.error("--elo0 and --elo1 must be given together")
    try:
        return COMMANDS[args.command](args)
    except subprocess.CalledProcessError as error:
        die(f"command failed (exit {error.returncode}): {error.cmd}")
    except KeyboardInterrupt:
        warn("interrupted")
        return INTERRUPTED_STATUS


if __name__ == "__main__":
    sys.exit(main())
