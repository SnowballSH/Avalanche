#!/usr/bin/env python3
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
    python3 scripts/fit_wdl.py --emit /tmp/wdl_coeffs.zig
"""

from __future__ import annotations

import argparse
import glob
import os
import sys
from multiprocessing import Pool

import numpy as np

SCORE_LIMIT = 2000
SCORE_STEP = 10
N_SCORE_BINS = 2 * (SCORE_LIMIT // SCORE_STEP) + 1

PLY_CAP = 240
PLY_STEP = 4
N_PLY_BINS = PLY_CAP // PLY_STEP + 1

MAT_MIN, MAT_MAX = 2, 32
N_MAT_BINS = MAT_MAX - MAT_MIN + 1

X_VARS = {
    "ply": (N_PLY_BINS, "min(240, ply) / 64", "ply"),
    "material": (N_MAT_BINS, "clamp(pieces, 2, 32) / 16", "piece count"),
}


def n_t_bins(x_var: str) -> int:
    return X_VARS[x_var][0]


def t_bin_to_m(x_var: str, bins: np.ndarray) -> np.ndarray:
    if x_var == "ply":
        return np.minimum(PLY_CAP, bins * PLY_STEP + PLY_STEP // 2) / 64.0
    return (bins + MAT_MIN) / 16.0


def score_bin_centres() -> np.ndarray:
    return (np.arange(N_SCORE_BINS) - (N_SCORE_BINS // 2)) * float(SCORE_STEP)


def accumulate(counts: np.ndarray, t_bin: np.ndarray, score: np.ndarray, outcome: np.ndarray) -> None:
    """Add samples into `counts`, shaped (n_t_bins, N_SCORE_BINS, 3)."""
    score_bin = np.rint(score / SCORE_STEP).astype(np.int64) + (N_SCORE_BINS // 2)
    flat = (t_bin.astype(np.int64) * N_SCORE_BINS + score_bin) * 3 + outcome.astype(np.int64)
    counts += np.bincount(flat, minlength=counts.size).reshape(counts.shape)


def scan_viri(job) -> tuple[np.ndarray, int, int]:
    """Return (counts, positions_seen, positions_kept) for one .viribin file.

    Every field in the format is 4-byte aligned (32-byte header, 4-byte
    move/score pairs, 4-byte terminator), so the file is read as one u32 array
    and games are located by binary-searching the precomputed zero-word
    positions: a zero word inside the move stream can only be the terminator.
    """
    path, keep_prob, min_ply, max_abs_score, seed, x_var = job
    words = np.fromfile(path, dtype="<u4")
    n = words.size
    zeros = np.flatnonzero(words == 0)

    starts, plies0, white0, results = [], [], [], []
    g = 0
    while g + 8 <= n:
        k = np.searchsorted(zeros, g + 8)
        if k >= zeros.size:
            break
        term = int(zeros[k])
        header_lo = int(words[g + 6])
        header_hi = int(words[g + 7])
        stm_ep = header_lo & 0xFF
        fullmove = (header_lo >> 16) & 0xFFFF
        result = (header_hi >> 16) & 0xFF
        black_to_move = (stm_ep & 0x80) != 0
        if result <= 2 and term > g + 8:
            starts.append(g + 8)
            plies0.append(max(0, (fullmove - 1) * 2) + (1 if black_to_move else 0))
            white0.append(0 if black_to_move else 1)
            results.append(result)
        g = term + 1

    empty = np.zeros((n_t_bins(x_var), N_SCORE_BINS, 3), dtype=np.int64)
    if not starts:
        return empty, 0, 0

    starts_a = np.asarray(starts, dtype=np.int64)
    # A game ends at its terminator: the first zero word at or after its first move.
    ends = zeros[np.searchsorted(zeros, starts_a)]
    lengths = ends.astype(np.int64) - starts_a
    keep_games = lengths > 0
    starts_a = starts_a[keep_games]
    lengths = lengths[keep_games]
    plies0_a = np.asarray(plies0, dtype=np.int64)[keep_games]
    white0_a = np.asarray(white0, dtype=np.int64)[keep_games]
    results_a = np.asarray(results, dtype=np.int64)[keep_games]

    total = int(lengths.sum())
    if total == 0:
        return empty, 0, 0

    within = np.arange(total, dtype=np.int64) - np.repeat(np.cumsum(lengths) - lengths, lengths)
    idx = np.repeat(starts_a, lengths) + within
    pairs = words[idx]
    score_white = (pairs >> 16).astype(np.uint16).view(np.int16).astype(np.int32)
    ply = np.repeat(plies0_a, lengths) + within
    white_to_move = np.repeat(white0_a, lengths) ^ (within & 1)
    result_white = np.repeat(results_a, lengths)

    sign = np.where(white_to_move == 1, 1, -1)
    score = score_white * sign
    outcome = np.where(white_to_move == 1, result_white, 2 - result_white)

    mask = (ply >= min_ply) & (np.abs(score) <= max_abs_score)
    if keep_prob < 1.0:
        rng = np.random.default_rng(seed)
        mask &= rng.random(total) < keep_prob
    if not mask.any():
        return empty, total, 0

    ply = ply[mask]
    score = score[mask]
    outcome = outcome[mask]

    counts = empty
    if x_var == "ply":
        t_bin = np.minimum(ply // PLY_STEP, N_PLY_BINS - 1)
    else:  # piece count is not recoverable from the move stream alone
        raise SystemExit("--x-var material requires --format bullet")
    accumulate(counts, t_bin, score, outcome)
    return counts, total, int(mask.sum())


BULLET_RECORD = 32


def scan_bullet(job) -> tuple[np.ndarray, int, int]:
    path, byte_start, byte_len, min_ply, max_abs_score, seed, x_var = job
    del min_ply, seed
    n_records = byte_len // BULLET_RECORD
    counts = np.zeros((n_t_bins(x_var), N_SCORE_BINS, 3), dtype=np.int64)
    if n_records == 0:
        return counts, 0, 0

    with open(path, "rb") as f:
        f.seek(byte_start)
        raw = f.read(n_records * BULLET_RECORD)
    n_records = len(raw) // BULLET_RECORD
    if n_records == 0:
        return counts, 0, 0

    block = np.frombuffer(raw[: n_records * BULLET_RECORD], dtype=np.uint8).reshape(n_records, BULLET_RECORD)
    occ = block[:, 0:8].copy().view(np.uint64).reshape(n_records)
    score = block[:, 24:26].copy().view(np.int16).reshape(n_records).astype(np.int32)
    outcome = block[:, 26].astype(np.int64)

    if hasattr(np, "bitwise_count"):
        pieces = np.bitwise_count(occ).astype(np.int64)
    else:
        pieces = np.zeros(n_records, dtype=np.int64)
        tmp = occ.copy()
        for _ in range(64):
            if not tmp.any():
                break
            pieces += (tmp & np.uint64(1)).astype(np.int64)
            tmp >>= np.uint64(1)

    mask = (np.abs(score) <= max_abs_score) & (outcome <= 2) & (pieces >= MAT_MIN) & (pieces <= MAT_MAX)
    if not mask.any():
        return counts, n_records, 0

    t_bin = np.clip(pieces[mask], MAT_MIN, MAT_MAX) - MAT_MIN
    accumulate(counts, t_bin, score[mask], outcome[mask])
    return counts, n_records, int(mask.sum())


def model_probs(theta: np.ndarray, m: np.ndarray, x: np.ndarray):
    a = ((theta[0] * m + theta[1]) * m + theta[2]) * m + theta[3]
    b = np.maximum(((theta[4] * m + theta[5]) * m + theta[6]) * m + theta[7], 1.0)
    u = (a - x) / b
    v = (a + x) / b
    pw = 1.0 / (1.0 + np.exp(np.clip(u, -60.0, 60.0)))
    pl = 1.0 / (1.0 + np.exp(np.clip(v, -60.0, 60.0)))
    pd = 1.0 - pw - pl
    return a, b, u, v, pw, pl, pd


EPS = 1e-12


def nll_and_grad(theta, m, x, nw, nd, nl, total):
    _a, b, u, v, pw, pl, pd = model_probs(theta, m, x)
    pwc = np.maximum(pw, EPS)
    plc = np.maximum(pl, EPS)
    pdc = np.maximum(pd, EPS)
    nll = -(nw * np.log(pwc) + nd * np.log(pdc) + nl * np.log(plc)).sum() / total

    gw = pw * (1.0 - pw)
    gl = pl * (1.0 - pl)
    dpw_da = -gw / b
    dpw_db = gw * u / b
    dpl_da = -gl / b
    dpl_db = gl * v / b

    cw = nw / pwc
    cd = nd / pdc
    cl = nl / plc
    d_da = -(cw * dpw_da + cl * dpl_da - cd * (dpw_da + dpl_da)) / total
    d_db = -(cw * dpw_db + cl * dpl_db - cd * (dpw_db + dpl_db)) / total

    m2 = m * m
    m3 = m2 * m
    grad = np.array(
        [
            (d_da * m3).sum(),
            (d_da * m2).sum(),
            (d_da * m).sum(),
            d_da.sum(),
            (d_db * m3).sum(),
            (d_db * m2).sum(),
            (d_db * m).sum(),
            d_db.sum(),
        ]
    )
    return nll, grad


def fit(m, x, nw, nd, nl, verbose=True):
    total = float(nw.sum() + nd.sum() + nl.sum())
    theta = np.array([0.0, 0.0, 0.0, 200.0, 0.0, 0.0, 0.0, 120.0])

    def f(t):
        return nll_and_grad(t, m, x, nw, nd, nl, total)

    # Adam warm-up: cheap and robust to the poor initial guess.
    mom = np.zeros(8)
    vel = np.zeros(8)
    lr = 2.0
    for step in range(1, 4001):
        _, g = f(theta)
        mom = 0.9 * mom + 0.1 * g
        vel = 0.999 * vel + 0.001 * g * g
        mhat = mom / (1.0 - 0.9**step)
        vhat = vel / (1.0 - 0.999**step)
        theta = theta - lr * mhat / (np.sqrt(vhat) + 1e-8)

    # Damped Newton with a finite-difference Hessian of the analytic gradient.
    lam = 1e-6
    best, _ = f(theta)
    for _ in range(200):
        val, g = f(theta)
        hess = np.zeros((8, 8))
        for i in range(8):
            h = max(1e-5, abs(theta[i]) * 1e-5)
            bumped = theta.copy()
            bumped[i] += h
            _, g2 = f(bumped)
            hess[:, i] = (g2 - g) / h
        hess = 0.5 * (hess + hess.T)
        try:
            step = np.linalg.solve(hess + lam * np.eye(8), -g)
        except np.linalg.LinAlgError:
            break
        alpha = 1.0
        cval = None
        for _ in range(30):
            cand = theta + alpha * step
            trial, _ = f(cand)
            if np.isfinite(trial) and trial < val - 1e-14:
                theta = cand
                cval = trial
                break
            alpha *= 0.5
        if cval is None:
            lam *= 10.0
            if lam > 1e6:
                break
            continue
        lam = max(lam * 0.5, 1e-9)
        if abs(best - cval) < 1e-13:
            best = cval
            break
        best = cval

    if verbose:
        print(f"  final mean NLL: {best:.6f}  (log-loss per position)")
    return theta, best


def report_calibration(theta, m, x, nw, nd, nl, x_var):
    print()
    print("Calibration by score bucket (side-to-move POV, permille):")
    print("   score      n        emp W/D/L        model W/D/L")
    _, _, _, _, pw, pl, pd = model_probs(theta, m, x)
    edges = [-2000, -800, -400, -200, -80, -20, 20, 80, 200, 400, 800, 2001]
    for lo, hi in zip(edges[:-1], edges[1:]):
        sel = (x >= lo) & (x < hi)
        n = nw[sel].sum() + nd[sel].sum() + nl[sel].sum()
        if n == 0:
            continue
        emp = np.array([nw[sel].sum(), nd[sel].sum(), nl[sel].sum()]) / n * 1000.0
        tot = nw[sel] + nd[sel] + nl[sel]
        pred = np.array([(pw[sel] * tot).sum(), (pd[sel] * tot).sum(), (pl[sel] * tot).sum()]) / n * 1000.0
        print(
            f"  [{lo:5d},{hi:5d})  {int(n):>10d}   "
            f"{emp[0]:4.0f}/{emp[1]:4.0f}/{emp[2]:4.0f}   {pred[0]:4.0f}/{pred[1]:4.0f}/{pred[2]:4.0f}"
        )

    print()
    label = X_VARS[x_var][2]
    print(f"a(m), b(m) across {label}:")
    for t in ([0, 16, 32, 64, 96, 128, 160, 200, 240] if x_var == "ply" else [4, 8, 12, 16, 20, 24, 28, 32]):
        mm = min(PLY_CAP, t) / 64.0 if x_var == "ply" else t / 16.0
        a = ((theta[0] * mm + theta[1]) * mm + theta[2]) * mm + theta[3]
        b = ((theta[4] * mm + theta[5]) * mm + theta[6]) * mm + theta[7]
        print(f"  {label} {t:>4}: a = {a:8.2f}  b = {b:8.2f}")


def zig_snippet(theta, x_var, n_positions, sources):
    a = ", ".join(f"{v:.8f}" for v in theta[:4])
    b = ", ".join(f"{v:.8f}" for v in theta[4:])
    note = "min(240, ply) / 64" if x_var == "ply" else "clamp(pieces, 2, 32) / 16 (NOT used by wdl.zig)"
    return (
        f"// m = {note}\n"
        f"const AS: [4]f64 = .{{ {a} }};\n"
        f"const BS: [4]f64 = .{{ {b} }};\n"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "--data",
        action="append",
        default=None,
        help="file or glob (repeatable); default data/old_data/*.viribin",
    )
    ap.add_argument("--format", choices=["auto", "viri", "bullet"], default="auto")
    ap.add_argument("--x-var", choices=["ply", "material"], default=None, help="default: ply for viri, material for bullet")
    ap.add_argument("--samples", type=int, default=8_000_000, help="approximate number of positions to fit on")
    ap.add_argument("--workers", type=int, default=min(48, os.cpu_count() or 1))
    ap.add_argument("--min-ply", type=int, default=0)
    ap.add_argument("--max-abs-score", type=int, default=SCORE_LIMIT)
    ap.add_argument("--seed", type=int, default=20260728)
    ap.add_argument("--emit", default=None, help="also write the Zig snippet to this path")
    args = ap.parse_args()

    patterns = args.data or ["data/old_data/*.viribin"]
    paths: list[str] = []
    for pat in patterns:
        hits = sorted(glob.glob(pat)) if any(ch in pat for ch in "*?[") else [pat]
        paths.extend(h for h in hits if os.path.isfile(h))
    if not paths:
        print(f"no data files matched {patterns}", file=sys.stderr)
        return 1

    fmt = args.format
    if fmt == "auto":
        fmt = "viri" if all(p.endswith(".viribin") for p in paths) else "bullet"
    x_var = args.x_var or ("ply" if fmt == "viri" else "material")
    if fmt == "bullet" and x_var == "ply":
        print("bulletformat does not store the ply; use --x-var material", file=sys.stderr)
        return 1

    total_bytes = sum(os.path.getsize(p) for p in paths)
    print("=== Avalanche WDL fit ===")
    print(f"format:   {fmt} ({len(paths)} file(s), {total_bytes / 1e9:.2f} GB)")
    print(f"m from:   {X_VARS[x_var][1]}")
    print(f"samples:  ~{args.samples}")
    print(f"workers:  {args.workers}")
    print()

    rng = np.random.default_rng(args.seed)
    if fmt == "viri":
        # ~90% of a .viribin file is move/score pairs, 4 bytes per position.
        est_positions = max(1, int(total_bytes * 0.9 / 4))
        keep = min(1.0, args.samples / est_positions)
        jobs = [
            (p, keep, args.min_ply, args.max_abs_score, int(rng.integers(1 << 62)), x_var)
            for p in paths
        ]
        worker = scan_viri
    else:
        # The file is already shuffled, so contiguous blocks are an unbiased and
        # far more I/O-friendly sample than scattered single records.
        block_bytes = 64 * 1024 * BULLET_RECORD
        want_blocks = max(1, int(np.ceil(args.samples * BULLET_RECORD / block_bytes)))
        jobs = []
        for _ in range(want_blocks):
            p = paths[int(rng.integers(len(paths)))]
            size = os.path.getsize(p)
            n_blocks = max(1, size // block_bytes)
            start = int(rng.integers(n_blocks)) * block_bytes
            jobs.append((p, start, min(block_bytes, size - start), args.min_ply, args.max_abs_score, 0, x_var))
        worker = scan_bullet

    counts = np.zeros((n_t_bins(x_var), N_SCORE_BINS, 3), dtype=np.int64)
    seen = kept = 0
    if args.workers > 1 and len(jobs) > 1:
        with Pool(min(args.workers, len(jobs))) as pool:
            for c, s, k in pool.imap_unordered(worker, jobs, chunksize=1):
                counts += c
                seen += s
                kept += k
    else:
        for job in jobs:
            c, s, k = worker(job)
            counts += c
            seen += s
            kept += k

    print(f"scanned {seen} positions, kept {kept} after filters")
    if kept == 0:
        print("no positions survived the filters", file=sys.stderr)
        return 1

    t_grid, s_grid = np.meshgrid(np.arange(n_t_bins(x_var)), np.arange(N_SCORE_BINS), indexing="ij")
    m_flat = t_bin_to_m(x_var, t_grid).ravel()
    x_flat = ((s_grid - (N_SCORE_BINS // 2)) * SCORE_STEP).astype(np.float64).ravel()
    nw = counts[:, :, 2].astype(np.float64).ravel()  # outcome 2 = side-to-move win
    nd = counts[:, :, 1].astype(np.float64).ravel()
    nl = counts[:, :, 0].astype(np.float64).ravel()
    live = (nw + nd + nl) > 0
    m_flat, x_flat, nw, nd, nl = m_flat[live], x_flat[live], nw[live], nd[live], nl[live]
    print(f"fitting on {live.sum()} non-empty histogram cells")

    theta, _ = fit(m_flat, x_flat, nw, nd, nl)
    report_calibration(theta, m_flat, x_flat, nw, nd, nl, x_var)

    sources = os.path.basename(paths[0]) if len(paths) == 1 else f"{len(paths)} files in {os.path.dirname(paths[0])}/"
    snippet = zig_snippet(theta, x_var, kept, sources)
    print()
    print("--- paste into src/engine/wdl.zig ---")
    print(snippet, end="")
    print("-------------------------------------")
    if args.emit:
        with open(args.emit, "w", encoding="utf-8") as f:
            f.write(snippet)
        print(f"wrote {args.emit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
