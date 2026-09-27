#!/usr/bin/env python3
"""End-to-end UCI protocol checks for Avalanche.

Usage: scripts/uci_protocol_test.py [path/to/Avalanche]

Covers MultiPV, pondering (ponderhit and stop), go infinite, go mate,
searchmoves, bestmove/ponder output, Chess960 castling notation and the
strength-limiting options. Uses only the Python standard library.
"""

from __future__ import annotations

import queue
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Engine:
    path: str
    process: subprocess.Popen = field(init=False)
    lines: "queue.Queue[str]" = field(init=False, default_factory=queue.Queue)

    def __post_init__(self) -> None:
        self.process = subprocess.Popen(
            [self.path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.lines.put(line.rstrip("\r\n"))

    def send(self, command: str) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

    def read_until(self, prefix: str, timeout: float) -> list[str]:
        deadline = time.monotonic() + timeout
        seen: list[str] = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for {prefix!r}; last lines: {seen[-5:]}")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                continue
            seen.append(line)
            if line.startswith(prefix):
                return seen

    def expect_silence(self, prefix: str, duration: float) -> None:
        deadline = time.monotonic() + duration
        while (remaining := deadline - time.monotonic()) > 0:
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                return
            if line.startswith(prefix):
                raise AssertionError(f"unexpected {line!r}")

    def sync(self) -> None:
        self.send("isready")
        self.read_until("readyok", 10)

    def search(self, position: str, go: str, timeout: float = 60) -> tuple[list[str], str]:
        self.send(position)
        self.send(go)
        output = self.read_until("bestmove", timeout)
        return output, output[-1]

    def close(self) -> None:
        self.send("quit")
        self.process.wait(timeout=10)


def fields(line: str) -> dict[str, str]:
    tokens = line.split()
    result = {}
    for key in ("depth", "multipv", "cp", "mate"):
        if key in tokens:
            result[key] = tokens[tokens.index(key) + 1]
    if "pv" in tokens:
        result["pv"] = " ".join(tokens[tokens.index("pv") + 1 :])
    return result


def bestmove_parts(line: str) -> tuple[str, str | None]:
    tokens = line.split()
    return tokens[1], tokens[3] if len(tokens) >= 4 and tokens[2] == "ponder" else None


def test_uci_advertises_options(engine: Engine) -> None:
    engine.send("uci")
    output = engine.read_until("uciok", 10)
    names = {line.split(" type ")[0].removeprefix("option name ") for line in output if line.startswith("option name")}
    for required in ("MultiPV", "Ponder", "UCI_Chess960", "UCI_LimitStrength", "UCI_Elo", "Skill Level", "Clear Hash"):
        assert required in names, f"missing option {required}"


def test_multipv_reports_distinct_sorted_lines(engine: Engine) -> None:
    engine.send("setoption name MultiPV value 3")
    output, best = engine.search("position startpos", "go depth 8")
    final = [fields(line) for line in output if line.startswith("info depth 8 ")]
    assert [f["multipv"] for f in final] == ["1", "2", "3"], final
    first_moves = [f["pv"].split()[0] for f in final]
    assert len(set(first_moves)) == 3, first_moves
    scores = [int(f["cp"]) for f in final]
    assert scores == sorted(scores, reverse=True), scores
    assert bestmove_parts(best)[0] == first_moves[0]
    engine.send("setoption name MultiPV value 1")


def test_bestmove_carries_ponder_move(engine: Engine) -> None:
    output, best = engine.search("position startpos moves e2e4", "go depth 10")
    move, ponder = bestmove_parts(best)
    last_pv = [fields(line)["pv"] for line in output if line.startswith("info depth")][-1].split()
    assert ponder is not None and last_pv[:2] == [move, ponder], (best, last_pv)


def test_ponderhit_releases_bestmove(engine: Engine) -> None:
    engine.sync()
    engine.send("position startpos moves e2e4 e7e5")
    engine.send("go ponder wtime 3000 btime 3000")
    engine.expect_silence("bestmove", 1.5)
    engine.send("ponderhit")
    engine.read_until("bestmove", 10)


def test_stop_while_pondering(engine: Engine) -> None:
    engine.sync()
    engine.send("position startpos moves d2d4")
    engine.send("go ponder wtime 60000 btime 60000")
    engine.expect_silence("bestmove", 1.0)
    engine.send("stop")
    engine.read_until("bestmove", 5)


def test_infinite_waits_for_stop(engine: Engine) -> None:
    engine.sync()
    # A mate-in-one ends the iterative deepening quickly; bestmove must still wait.
    engine.send("position fen 6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")
    engine.send("go infinite")
    engine.expect_silence("bestmove", 1.5)
    engine.send("isready")
    engine.read_until("readyok", 5)
    engine.send("stop")
    output = engine.read_until("bestmove", 5)
    assert bestmove_parts(output[-1])[0] == "a1a8"


def test_go_mate_finds_mate(engine: Engine) -> None:
    output, best = engine.search("position fen r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", "go mate 1", 20)
    assert bestmove_parts(best)[0] == "h5f7", best
    assert any(fields(line).get("mate") == "1" for line in output)


def test_searchmoves_restricts_root(engine: Engine) -> None:
    _, best = engine.search("position startpos", "go depth 6 searchmoves a2a3 h2h3")
    assert bestmove_parts(best)[0] in ("a2a3", "h2h3"), best


def test_chess960_castling_notation(engine: Engine) -> None:
    fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
    engine.send("setoption name UCI_Chess960 value true")
    _, best = engine.search(f"position fen {fen} moves e1h1", "go depth 3 searchmoves e8a8")
    assert bestmove_parts(best)[0] == "e8a8", best
    engine.send("setoption name UCI_Chess960 value false")
    _, best = engine.search(f"position fen {fen} moves e1g1", "go depth 3 searchmoves e8c8")
    assert bestmove_parts(best)[0] == "e8c8", best


def test_frc_start_position_search(engine: Engine) -> None:
    engine.send("setoption name UCI_Chess960 value true")
    _, best = engine.search("position fen bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9", "go depth 8")
    assert best.startswith("bestmove ") and best.split()[1] != "0000", best
    engine.send("setoption name UCI_Chess960 value false")


def test_skill_level_limits_depth(engine: Engine) -> None:
    engine.send("setoption name Skill Level value 2")
    output, best = engine.search("position startpos", "go depth 20")
    depths = {int(fields(line)["depth"]) for line in output if line.startswith("info depth")}
    assert max(depths) <= 3, depths
    assert best.split()[1] != "0000"
    engine.send("setoption name Skill Level value 20")


def test_limit_strength_by_elo(engine: Engine) -> None:
    engine.send("setoption name UCI_LimitStrength value true")
    engine.send("setoption name UCI_Elo value 1400")
    output, best = engine.search("position startpos moves e2e4", "go movetime 2000")
    depths = {int(fields(line)["depth"]) for line in output if line.startswith("info depth")}
    assert max(depths) <= 3, depths
    engine.send("setoption name UCI_LimitStrength value false")


def test_clear_hash_button(engine: Engine) -> None:
    engine.send("setoption name Clear Hash")
    engine.expect_silence("info string setoption failed", 0.3)


TESTS = [value for name, value in sorted(globals().items()) if name.startswith("test_")]


def main() -> int:
    default = Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "Avalanche"
    engine = Engine(sys.argv[1] if len(sys.argv) > 1 else str(default))
    failures = 0
    try:
        engine.read_until("Avalanche", 10)
        for test in TESTS:
            try:
                test(engine)
                engine.sync()
                print(f"PASS {test.__name__}")
            except AssertionError as error:
                failures += 1
                print(f"FAIL {test.__name__}: {error}")
                engine.send("stop")
                engine.sync()
    finally:
        engine.close()
    print(f"{len(TESTS) - failures}/{len(TESTS)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
