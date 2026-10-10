#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy>=2"]
# ///
"""Fit Avalanche's UCI WDL logistic on self-play data.

    m    = min(240, ply) / 64
    a(m) = ((AS[0]*m + AS[1])*m + AS[2])*m + AS[3]
    b(m) = ((BS[0]*m + BS[1])*m + BS[2])*m + BS[3]
    x    = clamp(score, -2000, 2000)
    win  = 1 / (1 + exp((a - x) / b))
    loss = 1 / (1 + exp((a + x) / b))
    draw = 1 - win - loss

Usage:
    python3 scripts/fit_wdl.py
    python3 scripts/fit_wdl.py --data 'data/*.viribin' --samples 20000000
    python3 scripts/fit_wdl.py --data 'games/*.pgn' --score-scale <pawn value of the engine that played / 100>
    python3 scripts/fit_wdl.py --emit /tmp/wdl_coeffs.zig
"""

from __future__ import annotations

import argparse
import bz2
import glob
import math
import os
import re
import sys
from dataclasses import dataclass, field
from enum import IntEnum
from itertools import pairwise
from multiprocessing import Pool
from operator import methodcaller
from pathlib import Path
from typing import TYPE_CHECKING, NamedTuple, Protocol

import numpy as np

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Sequence

    from numpy.typing import NDArray

type IntArray = NDArray[np.int64]
type FloatArray = NDArray[np.float64]
type Objective = Callable[[FloatArray], tuple[float, FloatArray]]

SCORE_LIMIT = 2000
SCORE_STEP = 10
N_SCORE_BINS = 2 * (SCORE_LIMIT // SCORE_STEP) + 1
ZERO_SCORE_BIN = N_SCORE_BINS // 2

PLY_CAP = 240
PLY_STEP = 4
PLY_SCALE = 64

MIN_PIECES = 2
MAX_PIECES = 32
PIECE_SCALE = 16


class Outcome(IntEnum):
    LOSS = 0
    DRAW = 1
    WIN = 2


WIN_DRAW_LOSS = (Outcome.WIN, Outcome.DRAW, Outcome.LOSS)


@dataclass(frozen=True)
class XVariable:
    label: str
    formula: str
    in_engine_model: bool
    n_bins: int
    bin_width: int
    first_bin_centre: int
    cap: int
    scale: int
    reported_at: tuple[int, ...]

    def m(self, value: IntArray) -> FloatArray:
        return np.minimum(self.cap, value) / self.scale

    def bin_m(self, bins: IntArray) -> FloatArray:
        return self.m(bins * self.bin_width + self.first_bin_centre)


PLY = XVariable(
    label="ply",
    formula=f"min({PLY_CAP}, ply) / {PLY_SCALE}",
    in_engine_model=True,
    n_bins=PLY_CAP // PLY_STEP + 1,
    bin_width=PLY_STEP,
    first_bin_centre=PLY_STEP // 2,
    cap=PLY_CAP,
    scale=PLY_SCALE,
    reported_at=(0, 16, 32, 64, 96, 128, 160, 200, 240),
)
MATERIAL = XVariable(
    label="piece count",
    formula=f"clamp(pieces, {MIN_PIECES}, {MAX_PIECES}) / {PIECE_SCALE}",
    in_engine_model=False,
    n_bins=MAX_PIECES - MIN_PIECES + 1,
    bin_width=1,
    first_bin_centre=MIN_PIECES,
    cap=MAX_PIECES,
    scale=PIECE_SCALE,
    reported_at=(4, 8, 12, 16, 20, 24, 28, 32),
)


def empty_histogram(x_variable: XVariable) -> IntArray:
    return np.zeros((x_variable.n_bins, N_SCORE_BINS, len(Outcome)), dtype=np.int64)


def accumulate(counts: IntArray, x_bin: IntArray, score: IntArray, outcome: IntArray) -> None:
    score_bin = np.rint(score / SCORE_STEP).astype(np.int64) + ZERO_SCORE_BIN
    flat = (x_bin * N_SCORE_BINS + score_bin) * len(Outcome) + outcome
    counts += np.bincount(flat, minlength=counts.size).reshape(counts.shape)


@dataclass
class Scan:
    counts: IntArray
    seen: int = 0
    kept: int = 0
    book_moves: int = 0
    unreadable_comments: int = 0

    def add(self, other: Scan) -> None:
        self.counts += other.counts
        self.seen += other.seen
        self.kept += other.kept
        self.book_moves += other.book_moves
        self.unreadable_comments += other.unreadable_comments


class ScanJob(Protocol):
    def scan(self) -> Scan: ...


@dataclass(frozen=True)
class Sampling:
    min_ply: int
    max_abs_score: int
    keep_probability: float

    def ply_histogram(self, ply: IntArray, score: IntArray, outcome: IntArray, seed: int) -> Scan:
        keep = (ply >= self.min_ply) & (np.abs(score) <= self.max_abs_score)
        if self.keep_probability < 1.0:
            keep &= np.random.default_rng(seed).random(ply.size) < self.keep_probability
        scan = Scan(empty_histogram(PLY), seen=ply.size, kept=int(keep.sum()))
        accumulate(scan.counts, np.minimum(ply[keep] // PLY_STEP, PLY.n_bins - 1), score[keep], outcome[keep])
        return scan


VIRI_HEADER = np.dtype(
    [
        ("occupancy", "<u8"),
        ("pieces", "V16"),
        ("side_and_en_passant", "u1"),
        ("halfmove_clock", "u1"),
        ("fullmove", "<u2"),
        ("score", "<i2"),
        ("white_outcome", "u1"),
        ("extra", "u1"),
    ]
)
VIRI_MOVE = np.dtype([("move", "<u2"), ("white_score", "<i2")])
VIRI_WORD = np.dtype("<u4")
VIRI_HEADER_WORDS = VIRI_HEADER.itemsize // VIRI_WORD.itemsize
VIRI_BLACK_TO_MOVE = 0x80
VIRI_ESTIMATED_MOVE_SHARE = 0.9


def viri_game_bounds(words: NDArray[np.uint32]) -> tuple[IntArray, IntArray]:
    zero_words = np.flatnonzero(words == 0)
    first_moves: list[int] = []
    terminators: list[int] = []
    first_move = VIRI_HEADER_WORDS
    while first_move <= words.size:
        # A header may hold zero words; a move word cannot (its move is never 0), so the first zero
        # word at or after the first move is the game's terminator.
        following = int(np.searchsorted(zero_words, first_move))
        if following >= zero_words.size:
            break
        terminator = int(zero_words[following])
        first_moves.append(first_move)
        terminators.append(terminator)
        first_move = terminator + 1 + VIRI_HEADER_WORDS
    return np.asarray(first_moves, dtype=np.int64), np.asarray(terminators, dtype=np.int64)


@dataclass(frozen=True)
class ViriJob:
    path: Path
    sampling: Sampling
    seed: int

    def scan(self) -> Scan:
        words = np.fromfile(self.path, dtype=VIRI_WORD)
        first_move, terminator = viri_game_bounds(words)
        header_words = first_move[:, np.newaxis] - VIRI_HEADER_WORDS + np.arange(VIRI_HEADER_WORDS)
        headers = words[header_words].view(VIRI_HEADER)[:, 0]
        played = (headers["white_outcome"] <= Outcome.WIN) & (terminator > first_move)
        headers, first_move, n_moves = headers[played], first_move[played], (terminator - first_move)[played]

        black_first = (headers["side_and_en_passant"] & VIRI_BLACK_TO_MOVE) != 0
        first_ply = np.maximum(0, (headers["fullmove"].astype(np.int64) - 1) * 2) + black_first
        moves_before_game = np.cumsum(n_moves) - n_moves
        move_in_game = np.arange(n_moves.sum(), dtype=np.int64) - np.repeat(moves_before_game, n_moves)
        moves = words[np.repeat(first_move, n_moves) + move_in_game].view(VIRI_MOVE)
        white_score = moves["white_score"].astype(np.int64)
        white_outcome = np.repeat(headers["white_outcome"].astype(np.int64), n_moves)
        white_to_move = np.repeat(~black_first, n_moves) ^ (move_in_game % 2 == 1)
        return self.sampling.ply_histogram(
            ply=np.repeat(first_ply, n_moves) + move_in_game,
            score=np.where(white_to_move, white_score, -white_score),
            outcome=np.where(white_to_move, white_outcome, Outcome.WIN - white_outcome),
            seed=self.seed,
        )


PGN_GAME_START = re.compile(r"\n(?=\[Event )")
PGN_RESULT = re.compile(r'\[Result "([^"]+)"\]')
PGN_FEN = re.compile(r'\[FEN "([^"]+)"\]')
PGN_COMMENT = re.compile(r"\{([^}]*)\}")
PGN_SCORE = re.compile(r"^([+-]?)(M?)(\d+(?:\.\d+)?)/")
PGN_BOOK_MOVE = "book"
PGN_WHITE_OUTCOMES = {"1-0": Outcome.WIN, "1/2-1/2": Outcome.DRAW, "0-1": Outcome.LOSS}
PGN_ESTIMATED_BYTES_PER_MOVE = 120
FEN_FIELD_DEFAULTS = ("", "w", "-", "-", "0", "1")
FEN_SIDE_TO_MOVE = 1
FEN_FULLMOVE = 5


def first_ply(fen: str | None) -> int:
    given = (fen or "").split()
    fields = [*given, *FEN_FIELD_DEFAULTS[len(given) :]]
    return max(0, (int(fields[FEN_FULLMOVE]) - 1) * 2) + (fields[FEN_SIDE_TO_MOVE] == "b")


def mover_score(comment: str, score_scale: float) -> int | None:
    match = PGN_SCORE.match(comment.strip())
    if match is None:
        return None
    sign, mate, magnitude = match.groups()
    raw = SCORE_LIMIT if mate else float(magnitude) * 100.0 * score_scale
    return round((-1 if sign == "-" else 1) * min(raw, SCORE_LIMIT))


@dataclass
class PgnPositions:
    score_scale: float
    plies: list[int] = field(default_factory=list)
    scores: list[int] = field(default_factory=list)
    outcomes: list[int] = field(default_factory=list)
    book_moves: int = 0
    unreadable_comments: int = 0

    def add_game(self, game: str) -> None:
        result = PGN_RESULT.search(game)
        if result is None or result[1] not in PGN_WHITE_OUTCOMES:
            return
        white_outcome = PGN_WHITE_OUTCOMES[result[1]]
        fen = PGN_FEN.search(game)
        movetext = game[game.rindex("]") + 1 :]
        start = first_ply(fen[1] if fen else None)
        for ply, comment in enumerate(PGN_COMMENT.findall(movetext), start):
            score = mover_score(comment, self.score_scale)
            if score is None:
                if comment.strip() == PGN_BOOK_MOVE:
                    self.book_moves += 1
                else:
                    self.unreadable_comments += 1
                continue
            white_to_move = ply % 2 == 0
            self.plies.append(ply)
            self.scores.append(score)
            self.outcomes.append(white_outcome if white_to_move else Outcome.WIN - white_outcome)


@dataclass(frozen=True)
class PgnJob:
    path: Path
    sampling: Sampling
    seed: int
    score_scale: float

    def scan(self) -> Scan:
        opener = bz2.open if self.path.suffix == ".bz2" else open
        with opener(self.path, "rt", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        positions = PgnPositions(self.score_scale)
        for game in PGN_GAME_START.split(text):
            positions.add_game(game)
        scan = self.sampling.ply_histogram(
            ply=np.asarray(positions.plies, dtype=np.int64),
            score=np.asarray(positions.scores, dtype=np.int64),
            outcome=np.asarray(positions.outcomes, dtype=np.int64),
            seed=self.seed,
        )
        scan.book_moves = positions.book_moves
        scan.unreadable_comments = positions.unreadable_comments
        return scan


BULLET_RECORD = np.dtype(
    [("occupancy", "<u8"), ("pieces", "V16"), ("score", "<i2"), ("outcome", "u1"), ("rest", "V5")]
)
BULLET_BLOCK_RECORDS = 64 * 1024
BULLET_BLOCK_BYTES = BULLET_BLOCK_RECORDS * BULLET_RECORD.itemsize


@dataclass(frozen=True)
class BulletJob:
    path: Path
    byte_start: int
    byte_length: int
    max_abs_score: int

    def scan(self) -> Scan:
        with self.path.open("rb") as file:
            file.seek(self.byte_start)
            raw = file.read(self.byte_length - self.byte_length % BULLET_RECORD.itemsize)
        records = np.frombuffer(raw[: len(raw) - len(raw) % BULLET_RECORD.itemsize], dtype=BULLET_RECORD)
        score = records["score"].astype(np.int64)
        outcome = records["outcome"].astype(np.int64)
        pieces = np.bitwise_count(records["occupancy"]).astype(np.int64)
        keep = (
            (np.abs(score) <= self.max_abs_score)
            & (outcome <= Outcome.WIN)
            & (pieces >= MIN_PIECES)
            & (pieces <= MAX_PIECES)
        )
        scan = Scan(empty_histogram(MATERIAL), seen=records.size, kept=int(keep.sum()))
        accumulate(scan.counts, pieces[keep] - MIN_PIECES, score[keep], outcome[keep])
        return scan


class Arguments(argparse.Namespace):
    data: list[str] | None
    format: str
    samples: int
    workers: int
    min_ply: int
    max_abs_score: int
    seed: int
    emit: Path | None
    score_scale: float

    def sampling(self, positions_available: int) -> Sampling:
        keep_probability = min(1.0, self.samples / max(1, positions_available))
        return Sampling(self.min_ply, self.max_abs_score, keep_probability)


SEED_BOUND = 1 << 62


def total_bytes(paths: Iterable[Path]) -> int:
    return sum(path.stat().st_size for path in paths)


def plan_viri(paths: Sequence[Path], args: Arguments, rng: np.random.Generator) -> Sequence[ScanJob]:
    sampling = args.sampling(int(total_bytes(paths) * VIRI_ESTIMATED_MOVE_SHARE / VIRI_WORD.itemsize))
    return [ViriJob(path, sampling, int(rng.integers(SEED_BOUND))) for path in paths]


def plan_pgn(paths: Sequence[Path], args: Arguments, rng: np.random.Generator) -> Sequence[ScanJob]:
    sampling = args.sampling(int(total_bytes(paths) / PGN_ESTIMATED_BYTES_PER_MOVE))
    return [PgnJob(path, sampling, int(rng.integers(SEED_BOUND)), args.score_scale) for path in paths]


def plan_bullet(paths: Sequence[Path], args: Arguments, rng: np.random.Generator) -> Sequence[ScanJob]:
    jobs = []
    for _ in range(max(1, math.ceil(args.samples / BULLET_BLOCK_RECORDS))):
        path = paths[int(rng.integers(len(paths)))]
        size = path.stat().st_size
        start = int(rng.integers(max(1, size // BULLET_BLOCK_BYTES))) * BULLET_BLOCK_BYTES
        jobs.append(BulletJob(path, start, min(BULLET_BLOCK_BYTES, size - start), args.max_abs_score))
    return jobs


@dataclass(frozen=True)
class DataFormat:
    name: str
    x_variable: XVariable
    plan: Callable[[Sequence[Path], Arguments, np.random.Generator], Sequence[ScanJob]]


VIRI = DataFormat("viri", PLY, plan_viri)
PGN = DataFormat("pgn", PLY, plan_pgn)
BULLET = DataFormat("bullet", MATERIAL, plan_bullet)
FORMATS = {data_format.name: data_format for data_format in (VIRI, PGN, BULLET)}
AUTO_FORMAT = "auto"


def detect_format(paths: Sequence[Path]) -> DataFormat:
    if all(path.suffix == ".viribin" for path in paths):
        return VIRI
    if all(path.name.endswith((".pgn", ".pgn.bz2")) for path in paths):
        return PGN
    return BULLET


def scan_all(jobs: Sequence[ScanJob], x_variable: XVariable, workers: int) -> Scan:
    total = Scan(empty_histogram(x_variable))
    scan_job = methodcaller("scan")
    if workers > 1 and len(jobs) > 1:
        with Pool(min(workers, len(jobs))) as pool:
            for scan in pool.imap_unordered(scan_job, jobs, chunksize=1):
                total.add(scan)
    else:
        for job in jobs:
            total.add(job.scan())
    return total


def cubic(coefficients: FloatArray, m: FloatArray) -> FloatArray:
    value: FloatArray = ((coefficients[0] * m + coefficients[1]) * m + coefficients[2]) * m + coefficients[3]
    return value


@dataclass(frozen=True)
class Cells:
    m: FloatArray
    score: FloatArray
    wins: FloatArray
    draws: FloatArray
    losses: FloatArray

    @classmethod
    def non_empty(cls, counts: IntArray, x_variable: XVariable) -> Cells:
        x_bin, score_bin = np.meshgrid(np.arange(x_variable.n_bins), np.arange(N_SCORE_BINS), indexing="ij")
        wins, draws, losses = (counts[:, :, outcome].astype(np.float64).ravel() for outcome in WIN_DRAW_LOSS)
        live = (wins + draws + losses) > 0
        return cls(
            m=x_variable.bin_m(x_bin).ravel()[live],
            score=((score_bin - ZERO_SCORE_BIN) * SCORE_STEP).astype(np.float64).ravel()[live],
            wins=wins[live],
            draws=draws[live],
            losses=losses[live],
        )

    @property
    def positions(self) -> FloatArray:
        return self.wins + self.draws + self.losses


class Prediction(NamedTuple):
    width: FloatArray
    win_exponent: FloatArray
    loss_exponent: FloatArray
    win: FloatArray
    loss: FloatArray
    draw: FloatArray


MIN_WIDTH = 1.0
MAX_EXPONENT = 60.0
MIN_PROBABILITY = 1e-12
N_PARAMETERS = 8
INITIAL_THETA = (0.0, 0.0, 0.0, 200.0, 0.0, 0.0, 0.0, 120.0)


def predict(theta: FloatArray, cells: Cells) -> Prediction:
    midpoint = cubic(theta[:4], cells.m)
    width = np.maximum(cubic(theta[4:], cells.m), MIN_WIDTH)
    win_exponent = (midpoint - cells.score) / width
    loss_exponent = (midpoint + cells.score) / width
    win = 1.0 / (1.0 + np.exp(np.clip(win_exponent, -MAX_EXPONENT, MAX_EXPONENT)))
    loss = 1.0 / (1.0 + np.exp(np.clip(loss_exponent, -MAX_EXPONENT, MAX_EXPONENT)))
    return Prediction(width, win_exponent, loss_exponent, win, loss, 1.0 - win - loss)


def mean_nll_and_gradient(theta: FloatArray, cells: Cells, n_positions: float) -> tuple[float, FloatArray]:
    width, win_exponent, loss_exponent, win, loss, draw = predict(theta, cells)
    win_floor = np.maximum(win, MIN_PROBABILITY)
    loss_floor = np.maximum(loss, MIN_PROBABILITY)
    draw_floor = np.maximum(draw, MIN_PROBABILITY)
    log_likelihood = (
        cells.wins * np.log(win_floor) + cells.draws * np.log(draw_floor) + cells.losses * np.log(loss_floor)
    )

    win_slope = win * (1.0 - win)
    loss_slope = loss * (1.0 - loss)
    win_weight = cells.wins / win_floor
    draw_weight = cells.draws / draw_floor
    loss_weight = cells.losses / loss_floor

    def mean_nll_slope(d_win: FloatArray, d_loss: FloatArray) -> FloatArray:
        return -(win_weight * d_win + loss_weight * d_loss - draw_weight * (d_win + d_loss)) / n_positions

    d_midpoint = mean_nll_slope(-win_slope / width, -loss_slope / width)
    d_width = mean_nll_slope(win_slope * win_exponent / width, loss_slope * loss_exponent / width)
    m = cells.m
    powers = (m * m * m, m * m, m, 1.0)
    gradient = np.array([(slope * power).sum() for slope in (d_midpoint, d_width) for power in powers])
    return -log_likelihood.sum() / n_positions, gradient


ADAM_STEPS = 4000
ADAM_LEARNING_RATE = 2.0


def adam_warm_up(objective: Objective, theta: FloatArray) -> FloatArray:
    momentum = np.zeros(N_PARAMETERS)
    velocity = np.zeros(N_PARAMETERS)
    for step in range(1, ADAM_STEPS + 1):
        _, gradient = objective(theta)
        momentum = 0.9 * momentum + 0.1 * gradient
        velocity = 0.999 * velocity + 0.001 * gradient * gradient
        unbiased_momentum = momentum / (1.0 - 0.9**step)
        unbiased_velocity = velocity / (1.0 - 0.999**step)
        theta = theta - ADAM_LEARNING_RATE * unbiased_momentum / (np.sqrt(unbiased_velocity) + 1e-8)
    return theta


NEWTON_ITERATIONS = 200
NEWTON_INITIAL_DAMPING = 1e-6
NEWTON_MIN_DAMPING = 1e-9
NEWTON_MAX_DAMPING = 1e6
NEWTON_CONVERGED_BELOW = 1e-13
HESSIAN_RELATIVE_STEP = 1e-5
LINE_SEARCH_HALVINGS = 30
LINE_SEARCH_MIN_DECREASE = 1e-14


def finite_difference_hessian(objective: Objective, theta: FloatArray, gradient: FloatArray) -> FloatArray:
    hessian = np.zeros((N_PARAMETERS, N_PARAMETERS))
    for i in range(N_PARAMETERS):
        step = max(HESSIAN_RELATIVE_STEP, abs(theta[i]) * HESSIAN_RELATIVE_STEP)
        bumped = theta.copy()
        bumped[i] += step
        _, bumped_gradient = objective(bumped)
        hessian[:, i] = (bumped_gradient - gradient) / step
    return 0.5 * (hessian + hessian.T)


def backtracking_line_search(
    objective: Objective, theta: FloatArray, direction: FloatArray, value: float
) -> tuple[FloatArray, float] | None:
    scale = 1.0
    for _ in range(LINE_SEARCH_HALVINGS):
        candidate = theta + scale * direction
        trial, _ = objective(candidate)
        if np.isfinite(trial) and trial < value - LINE_SEARCH_MIN_DECREASE:
            return candidate, trial
        scale *= 0.5
    return None


def damped_newton(objective: Objective, theta: FloatArray) -> tuple[FloatArray, float]:
    damping = NEWTON_INITIAL_DAMPING
    best, _ = objective(theta)
    for _ in range(NEWTON_ITERATIONS):
        value, gradient = objective(theta)
        hessian = finite_difference_hessian(objective, theta, gradient)
        try:
            direction = np.linalg.solve(hessian + damping * np.eye(N_PARAMETERS), -gradient)
        except np.linalg.LinAlgError:
            break
        improved = backtracking_line_search(objective, theta, direction, value)
        if improved is None:
            damping *= 10.0
            if damping > NEWTON_MAX_DAMPING:
                break
            continue
        theta, improved_value = improved
        damping = max(damping * 0.5, NEWTON_MIN_DAMPING)
        converged = abs(best - improved_value) < NEWTON_CONVERGED_BELOW
        best = improved_value
        if converged:
            break
    return theta, best


def fit(cells: Cells) -> FloatArray:
    n_positions = float(cells.positions.sum())

    def objective(theta: FloatArray) -> tuple[float, FloatArray]:
        return mean_nll_and_gradient(theta, cells, n_positions)

    theta, mean_nll = damped_newton(objective, adam_warm_up(objective, np.array(INITIAL_THETA)))
    print(f"  final mean NLL: {mean_nll:.6f}  (log-loss per position)")
    return theta


CALIBRATION_SCORE_EDGES = (-SCORE_LIMIT, -800, -400, -200, -80, -20, 20, 80, 200, 400, 800, SCORE_LIMIT + 1)


def report_calibration(theta: FloatArray, cells: Cells, x_variable: XVariable) -> None:
    print()
    print("Calibration by score bucket (side-to-move POV, permille):")
    print("   score      n        emp W/D/L        model W/D/L")
    prediction = predict(theta, cells)
    for low, high in pairwise(CALIBRATION_SCORE_EDGES):
        bucket = (cells.score >= low) & (cells.score < high)
        n = cells.positions[bucket].sum()
        if n == 0:
            continue
        observed = [counts[bucket].sum() / n * 1000.0 for counts in (cells.wins, cells.draws, cells.losses)]
        expected = [
            (probability[bucket] * cells.positions[bucket]).sum() / n * 1000.0
            for probability in (prediction.win, prediction.draw, prediction.loss)
        ]
        print(
            f"  [{low:5d},{high:5d})  {int(n):>10d}   "
            f"{observed[0]:4.0f}/{observed[1]:4.0f}/{observed[2]:4.0f}   "
            f"{expected[0]:4.0f}/{expected[1]:4.0f}/{expected[2]:4.0f}"
        )

    print()
    print(f"a(m), b(m) across {x_variable.label}:")
    values = np.asarray(x_variable.reported_at, dtype=np.int64)
    m = x_variable.m(values)
    for value, midpoint, width in zip(values, cubic(theta[:4], m), cubic(theta[4:], m), strict=True):
        print(f"  {x_variable.label} {value:>4}: a = {midpoint:8.2f}  b = {width:8.2f}")


def zig_snippet(theta: FloatArray, x_variable: XVariable) -> str:
    midpoint = ", ".join(f"{value:.8f}" for value in theta[:4])
    width = ", ".join(f"{value:.8f}" for value in theta[4:])
    note = x_variable.formula if x_variable.in_engine_model else f"{x_variable.formula} (NOT used by wdl.zig)"
    return f"// m = {note}\nconst AS: [4]f64 = .{{ {midpoint} }};\nconst BS: [4]f64 = .{{ {width} }};\n"


DEFAULT_DATA = "data/old_data/*.viribin"
MAX_DEFAULT_WORKERS = 48


def score_bound(text: str) -> int:
    bound = int(text)
    if not 0 <= bound <= SCORE_LIMIT:
        message = f"must be between 0 and {SCORE_LIMIT}, the range of the score histogram"
        raise argparse.ArgumentTypeError(message)
    return bound


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--data", action="append", help=f"file or glob (repeatable); default {DEFAULT_DATA}")
    parser.add_argument("--format", choices=[AUTO_FORMAT, *FORMATS], default=AUTO_FORMAT)
    parser.add_argument(
        "--samples", type=int, default=8_000_000, help="approximate number of positions to fit on"
    )
    parser.add_argument("--workers", type=int, default=min(MAX_DEFAULT_WORKERS, os.cpu_count() or 1))
    parser.add_argument("--min-ply", type=int, default=0)
    parser.add_argument("--max-abs-score", type=score_bound, default=SCORE_LIMIT)
    parser.add_argument("--seed", type=int, default=20260728)
    parser.add_argument("--emit", type=Path, help="also write the Zig snippet to this path")
    parser.add_argument(
        "--score-scale",
        type=float,
        default=1.0,
        help="pgn only: internal centipawns per UCI centipawn (PAWN_VALUE / 100 for a normalizing engine)",
    )
    return parser


def data_files(patterns: Iterable[str]) -> list[Path]:
    matches = (Path(match) for pattern in patterns for match in sorted(glob.glob(pattern)))  # noqa: PTH207
    return [path for path in matches if path.is_file()]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argument_parser()
    args = parser.parse_args(argv, namespace=Arguments())
    patterns = args.data or [DEFAULT_DATA]
    paths = data_files(patterns)
    if not paths:
        print(f"no data files matched {patterns}", file=sys.stderr)
        return 1
    data_format = detect_format(paths) if args.format == AUTO_FORMAT else FORMATS[args.format]
    x_variable = data_format.x_variable
    if x_variable is not PLY and args.min_ply > 0:
        parser.error(f"--min-ply does not apply to --format {data_format.name}, which stores no ply")
    if data_format is not PGN and args.score_scale != 1.0:
        parser.error(f"--score-scale applies to --format {PGN.name} only; other formats hold internal scores")

    print("=== Avalanche WDL fit ===")
    print(f"format:   {data_format.name} ({len(paths)} file(s), {total_bytes(paths) / 1e9:.2f} GB)")
    print(f"m from:   {x_variable.formula}")
    print(f"samples:  ~{args.samples}")
    print(f"workers:  {args.workers}")
    print()

    jobs = data_format.plan(paths, args, np.random.default_rng(args.seed))
    scan = scan_all(jobs, x_variable, args.workers)
    print(f"scanned {scan.seen} positions, kept {scan.kept} after filters")
    if data_format is PGN:
        print(
            f"comments without a score: {scan.book_moves} book moves, {scan.unreadable_comments} unreadable"
        )
    if scan.kept == 0:
        print("no positions survived the filters", file=sys.stderr)
        return 1

    cells = Cells.non_empty(scan.counts, x_variable)
    print(f"fitting on {cells.m.size} non-empty histogram cells")
    theta = fit(cells)
    report_calibration(theta, cells, x_variable)

    snippet = zig_snippet(theta, x_variable)
    print()
    print("--- paste into src/engine/wdl.zig ---")
    print(snippet, end="")
    print("-------------------------------------")
    if args.emit:
        args.emit.write_text(snippet, encoding="utf-8")
        print(f"wrote {args.emit}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
