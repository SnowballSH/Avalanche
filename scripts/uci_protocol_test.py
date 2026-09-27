#!/usr/bin/env python3
"""End-to-end UCI protocol checks for Avalanche.

Usage: scripts/uci_protocol_test.py [engine command...]

The engine command defaults to the native release build. To test the wasm
build, pass e.g. `node web/src/node/cli.ts zig-out/web/avalanche.wasm`.
Tests for options the engine does not advertise (Threads > 1, EvalFile on
wasm) are skipped.

Covers MultiPV, pondering (ponderhit and stop), go infinite, go mate,
searchmoves, bestmove/ponder output, Chess960 castling notation and the
strength-limiting options. Uses only the Python standard library.
"""

from __future__ import annotations

import queue
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Engine:
    command: list[str]
    process: subprocess.Popen = field(init=False)
    options: dict[str, str] = field(init=False, default_factory=dict)
    lines: "queue.Queue[str]" = field(init=False, default_factory=queue.Queue)

    def __post_init__(self) -> None:
        self.process = subprocess.Popen(
            self.command,
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


class Skipped(Exception):
    pass


def require_option(engine: Engine, name: str, predicate=lambda spec: True) -> None:
    spec = engine.options.get(name)
    if spec is None or not predicate(spec):
        raise Skipped(f"engine does not offer {name} as needed" + (f" (type {spec})" if spec else ""))


def test_uci_advertises_options(engine: Engine) -> None:
    for required in ("MultiPV", "Ponder", "UCI_Chess960", "UCI_LimitStrength", "UCI_Elo", "Skill Level", "Clear Hash", "Move Overhead"):
        assert required in engine.options, f"missing option {required}"
    assert "MoveOverhead" not in engine.options


def test_legacy_move_overhead_name(engine: Engine) -> None:
    engine.send("setoption name MoveOverhead value 30")
    engine.expect_silence("info string setoption failed", 0.3)
    engine.send("setoption name Move Overhead value 25")
    engine.expect_silence("info string setoption failed", 0.3)


def test_eval_command(engine: Engine) -> None:
    engine.send("position startpos")
    engine.send("eval")
    output = engine.read_until("info string Final evaluation", 5)
    assert any(line.startswith("info string NNUE evaluation ") for line in output), output
    engine.send("position fen 4k3/8/8/8/8/8/8/QQQ1K3 w - - 0 1")
    engine.send("eval")
    final = engine.read_until("info string Final evaluation", 5)[-1]
    assert int(final.split()[4]) > 500, final


def test_eval_file_rejects_bad_network(engine: Engine) -> None:
    require_option(engine, "EvalFile")
    engine.send("setoption name EvalFile value /nonexistent/net.nnue")
    line = engine.read_until("info string EvalFile", 5)[-1]
    assert "failed to load" in line, line
    engine.send("setoption name EvalFile value <embedded>")
    restored = engine.read_until("info string EvalFile", 5)[-1]
    assert restored.startswith("info string EvalFile: using ") and "<embedded>" not in restored, restored


def test_search_names_the_network(engine: Engine) -> None:
    output, _ = engine.search("position startpos", "go depth 2")
    announcements = [line for line in output if line.startswith("info string NNUE evaluation using ")]
    assert len(announcements) == 1, output
    assert re.search(r"using \S+ \(768x\d+->\d+->\d+, \d+ MiB\)$", announcements[0]), announcements[0]


def test_live_currmove_after_delay(engine: Engine) -> None:
    output, best = engine.search("position startpos moves e2e4 c7c5", "go movetime 4500", 30)
    currmoves = [line for line in output if " currmove " in line]
    assert currmoves, "no currmove reported during a 4.5 s search"
    assert all(" currmovenumber " in line for line in currmoves)
    assert best.startswith("bestmove ")


def test_threads_with_thread_pool(engine: Engine) -> None:
    require_option(engine, "Threads", lambda spec: " max 1" not in spec)
    engine.send("setoption name Threads value 4")
    engine.send("setoption name MultiPV value 2")
    for _ in range(3):
        _, best = engine.search("position startpos", "go depth 12")
        assert best.split()[1] != "0000", best
    engine.send("setoption name NumaPolicy value none")
    _, best = engine.search("position startpos moves d2d4", "go movetime 500")
    engine.send("setoption name NumaPolicy value auto")
    engine.send("setoption name Threads value 2")
    _, best = engine.search("position startpos moves c2c4", "go nodes 200000")
    engine.send("setoption name Threads value 1")
    engine.send("setoption name MultiPV value 1")
    assert best.split()[1] != "0000", best


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
    engine = Engine(sys.argv[1:] or [str(default)])
    failures = 0
    skipped = 0
    try:
        engine.send("uci")
        for line in engine.read_until("uciok", 30):
            if line.startswith("option name "):
                name, _, spec = line.removeprefix("option name ").partition(" type ")
                engine.options[name] = spec
        for test in TESTS:
            try:
                test(engine)
                engine.sync()
                print(f"PASS {test.__name__}")
            except Skipped as reason:
                skipped += 1
                print(f"SKIP {test.__name__}: {reason}")
            except AssertionError as error:
                failures += 1
                print(f"FAIL {test.__name__}: {error}")
                engine.send("stop")
                engine.sync()
    finally:
        engine.close()
    print(f"{len(TESTS) - failures - skipped}/{len(TESTS)} passed, {skipped} skipped, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
