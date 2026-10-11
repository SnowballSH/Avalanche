#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""End-to-end UCI protocol checks for Avalanche.

Usage: python3 scripts/uci_protocol_test.py [engine command...]

The engine command defaults to the native release build. To test the wasm
build, pass e.g. `node web/src/node/cli.ts zig-out/web/avalanche.wasm`.
Tests for options the engine does not advertise (Threads > 1, EvalFile on
wasm) are skipped, and so are the tests of the engine's own command line when
the engine command has more than one word.
"""

from __future__ import annotations

import contextlib
import queue
import re
import subprocess
import sys
import threading
import time
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, ClassVar

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence

DEFAULT_ENGINE = Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "Avalanche"

OPTION = re.compile(
    r"option name (?P<name>.+?) type (?P<kind>\S+)"
    r"(?: default (?P<default>.*?))?(?: min (?P<minimum>-?\d+) max (?P<maximum>-?\d+))?(?: var \S+)*"
)
BESTMOVE = re.compile(r"bestmove (?P<move>\S+)(?: ponder (?P<ponder>\S+))?")
NNUE_EVALUATION = re.compile(r"info string NNUE evaluation -?\d+ cp \(white side\)")
FINAL_EVALUATION = re.compile(r"info string Final evaluation (-?\d+) cp \(white side\)")
NETWORK_ANNOUNCEMENT = re.compile(r"using \S+ \(768x\d+->\d+->(\d+|pairwise->\d+x2->\d+->1x\d+), \d+ MiB\)$")
SCORE_WITH_WDL = re.compile(r" score \S+ -?\d+ wdl (\d+) (\d+) (\d+)(?: (?:lower|upper)bound)? nodes ")

HANDSHAKE_TIMEOUT = 30.0
READY_TIMEOUT = 10.0
STOP_TIMEOUT = 10.0
QUIT_TIMEOUT = 10.0
SEARCH_TIMEOUT = 60.0
EVALUATION_TIMEOUT = 5.0
COMMAND_LINE_TIMEOUT = 60.0
SETOPTION_FAILURE_WINDOW = 0.3
BESTMOVE_HELD_BACK_FOR = 1.5

LIVE_INFO_DELAY_SECONDS = 3.0
LIVE_INFO_TIMEOUT = 120.0
NULL_MOVE = "0000"
INFO_FIELDS: tuple[str, ...] = ("depth", "multipv", "cp", "mate", "nodes")
THREADS_UNDER_TEST = 4
MULTIPV_UNDER_TEST = 3
MULTIPV_DEPTH = 8
WEAK_SKILL_LEVEL = 2
WEAK_ELO = 1400
WEAK_SEARCH_MAX_DEPTH = 1 + WEAK_SKILL_LEVEL
NEW_GAME_DEPTH = 12
WDL_DEPTH = 6
PERMILLE = 1000
TUNABLE = "LMRWeight"
LARGEST_CLOCK = 2**63 - 1
LARGEST_INCREMENT = 2**64 - 1
GENFENS_COUNT = 3
USAGE_ERROR = 2

THREE_QUEENS_UP_WHITE = "4k3/8/8/8/8/8/8/QQQ1K3 w - - 0 1"
THREE_QUEENS_UP_BLACK = "qqq1k3/8/8/8/8/8/8/4K3 b - - 0 1"
BACK_RANK_MATE_IN_ONE = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"
SCHOLARS_MATE_IN_ONE = "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
BOTH_SIDES_CAN_CASTLE = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
CHESS960_MIDDLEGAME = "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9"


def optional_int(text: str | None) -> int | None:
    return None if text is None else int(text)


@dataclass(frozen=True)
class UciOption:
    kind: str
    default: str
    maximum: int | None


@dataclass(frozen=True)
class SearchResult:
    output: list[str]
    move: str
    ponder: str | None


class Engine:
    def __init__(self, command: Sequence[str]) -> None:
        process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )
        if process.stdin is None or process.stdout is None:
            message = "the engine was started without pipes"
            raise RuntimeError(message)
        self.process = process
        self.stdin = process.stdin
        self.stdout = process.stdout
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.searching = False
        self.changed_options: set[str] = set()
        threading.Thread(target=self._pump, daemon=True).start()
        try:
            self.send("uci")
            handshake = self.read_until("uciok", HANDSHAKE_TIMEOUT)
        except BaseException:
            self.process.kill()
            raise
        self.options = {
            match["name"]: UciOption(match["kind"], match["default"] or "", optional_int(match["maximum"]))
            for match in map(OPTION.fullmatch, handshake)
            if match is not None
        }

    def _pump(self) -> None:
        for line in self.stdout:
            self.lines.put(line.rstrip("\r\n"))
        self.lines.put(None)

    def _next_line(self, deadline: float) -> str:
        try:
            line = self.lines.get(timeout=max(0.0, deadline - time.monotonic()))
        except queue.Empty:
            raise TimeoutError from None
        if line is None:
            self.lines.put(None)
            raise self._exit_report()
        if line.startswith("bestmove"):
            self.searching = False
        return line

    def _exit_report(self) -> AssertionError:
        return AssertionError(f"the engine exited with status {self.process.wait(timeout=QUIT_TIMEOUT)}")

    def exited(self) -> bool:
        return self.process.poll() is not None

    def send(self, command: str) -> None:
        try:
            self.stdin.write(command + "\n")
            self.stdin.flush()
        except OSError:
            raise self._exit_report() from None

    def read_until(self, prefix: str, timeout: float) -> list[str]:
        return self.read_until_match(lambda line: line.startswith(prefix), repr(prefix), timeout)

    def read_until_match(self, matches: Callable[[str], bool], description: str, timeout: float) -> list[str]:
        deadline = time.monotonic() + timeout
        seen: list[str] = []
        while True:
            try:
                seen.append(self._next_line(deadline))
            except TimeoutError:
                message = f"timed out waiting for {description}; last lines: {seen[-5:]}"
                raise AssertionError(message) from None
            if matches(seen[-1]):
                return seen

    def expect_silence(self, prefix: str, duration: float) -> None:
        deadline = time.monotonic() + duration
        while True:
            try:
                line = self._next_line(deadline)
            except TimeoutError:
                return
            if line.startswith(prefix):
                message = f"unexpected {line!r}"
                raise AssertionError(message)

    def sync(self) -> None:
        self.send("isready")
        self.read_until("readyok", READY_TIMEOUT)

    def set_option(self, name: str, value: str) -> None:
        if name not in self.options:
            message = f"the engine does not offer {name}"
            raise AssertionError(message)
        self.changed_options.add(name)
        self.send(f"setoption name {name} value {value}")

    def restore_option(self, name: str) -> None:
        self.send(f"setoption name {name} value {self.options[name].default}")

    def go(self, limits: str) -> None:
        self.searching = True
        self.send(f"go {limits}")

    def bestmove(self, timeout: float) -> SearchResult:
        output = self.read_until("bestmove", timeout)
        match = BESTMOVE.fullmatch(output[-1])
        if match is None:
            message = f"malformed {output[-1]!r}"
            raise AssertionError(message)
        return SearchResult(output, match["move"], match["ponder"])

    def search(self, position: str, limits: str) -> SearchResult:
        self.send(f"position {position}")
        self.go(limits)
        return self.bestmove(SEARCH_TIMEOUT)

    def stop(self) -> SearchResult:
        self.send("stop")
        return self.bestmove(STOP_TIMEOUT)

    def reset(self) -> None:
        if self.exited():
            return
        if self.searching:
            self.stop()
        for name in sorted(self.changed_options):
            self.restore_option(name)
        self.changed_options.clear()
        self.sync()

    def close(self) -> None:
        try:
            if not self.exited():
                self.send("quit")
            self.process.wait(timeout=QUIT_TIMEOUT)
        finally:
            self.process.kill()
            with contextlib.suppress(OSError):
                self.stdin.close()
            self.stdout.close()


def info_fields(line: str) -> dict[str, str]:
    tokens = line.split()
    fields = {key: tokens[tokens.index(key) + 1] for key in INFO_FIELDS if key in tokens}
    if "pv" in tokens:
        fields["pv"] = " ".join(tokens[tokens.index("pv") + 1 :])
    return fields


def iterations(result: SearchResult) -> list[dict[str, str]]:
    return [info_fields(line) for line in result.output if line.startswith("info depth")]


def searched_depths(result: SearchResult) -> set[int]:
    return {int(iteration["depth"]) for iteration in iterations(result)}


def final_nodes(result: SearchResult) -> int:
    return int(iterations(result)[-1]["nodes"])


class EngineCommandTest(unittest.TestCase):
    command: ClassVar[Sequence[str]] = (str(DEFAULT_ENGINE),)


class UciProtocolTest(EngineCommandTest):
    engine: ClassVar[Engine]

    @classmethod
    def setUpClass(cls) -> None:
        cls.engine = Engine(cls.command)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.engine.close()

    @classmethod
    def replace_exited_engine(cls) -> None:
        if cls.engine.exited():
            cls.engine.close()
            cls.engine = Engine(cls.command)

    def setUp(self) -> None:
        self.replace_exited_engine()
        self.addCleanup(self.engine.reset)

    def require_option(self, name: str) -> UciOption:
        option = self.engine.options.get(name)
        if option is None:
            self.skipTest(f"the engine does not offer {name}")
        return option

    def evaluation(self, position: str) -> int:
        self.engine.send(f"position {position}")
        self.engine.send("eval")
        output = self.engine.read_until("info string Final evaluation", EVALUATION_TIMEOUT)
        self.assertTrue(any(NNUE_EVALUATION.fullmatch(line) for line in output), output)
        final = FINAL_EVALUATION.fullmatch(output[-1])
        if final is None:
            self.fail(output[-1])
        return int(final[1])

    def setoption_failure(self, arguments: str) -> str:
        self.engine.send(f"setoption {arguments}")
        return self.engine.read_until("info string setoption failed", READY_TIMEOUT)[-1]

    def test_uci_advertises_options(self) -> None:
        for required in (
            "MultiPV",
            "Ponder",
            "UCI_Chess960",
            "UCI_LimitStrength",
            "UCI_Elo",
            "Skill Level",
            "Clear Hash",
            "Move Overhead",
        ):
            self.assertIn(required, self.engine.options)
        self.assertNotIn("MoveOverhead", self.engine.options)

    def test_legacy_move_overhead_name(self) -> None:
        self.engine.set_option("Move Overhead", "30")
        self.engine.expect_silence("info string setoption failed", SETOPTION_FAILURE_WINDOW)
        self.engine.send("setoption name MoveOverhead value 40")
        self.engine.expect_silence("info string setoption failed", SETOPTION_FAILURE_WINDOW)

    def test_syzygy_path_with_nothing_after_value_is_accepted(self) -> None:
        self.require_option("SyzygyPath")
        self.engine.send("setoption name SyzygyPath value")
        self.engine.expect_silence("info string setoption failed", SETOPTION_FAILURE_WINDOW)

    def test_eval_file_with_nothing_after_value_restores_the_embedded_network(self) -> None:
        self.require_option("EvalFile")
        self.engine.send("setoption name EvalFile value")
        answer = self.engine.read_until("info string ", EVALUATION_TIMEOUT)[-1]
        self.assertTrue(answer.startswith("info string EvalFile: using "), answer)

    def test_tunable_names_ignore_case(self) -> None:
        default = self.engine.options[TUNABLE].default
        self.engine.send(f"setoption name {TUNABLE.swapcase()} value {default}")
        self.engine.expect_silence("info string setoption failed", SETOPTION_FAILURE_WINDOW)

    def test_failed_setoption_names_the_reason(self) -> None:
        for arguments, reason in (
            ("name NoSuchOption value 1", "UnknownOption"),
            (f"name {TUNABLE} value x", "InvalidValue"),
        ):
            self.assertEqual(
                self.setoption_failure(arguments), f"info string setoption failed ({reason}): {arguments}"
            )

    def test_eval_command_reports_evaluations_from_whites_side(self) -> None:
        start = self.evaluation("startpos")
        self.assertGreater(self.evaluation(f"fen {THREE_QUEENS_UP_WHITE}"), max(start, 0))
        self.assertLess(self.evaluation(f"fen {THREE_QUEENS_UP_BLACK}"), min(start, 0))

    def test_eval_file_rejects_bad_network(self) -> None:
        embedded_placeholder = self.require_option("EvalFile").default
        self.engine.set_option("EvalFile", "/nonexistent/net.nnue")
        rejected = self.engine.read_until("info string EvalFile", EVALUATION_TIMEOUT)[-1]
        self.assertIn("failed to load", rejected)
        self.engine.restore_option("EvalFile")
        restored = self.engine.read_until("info string EvalFile", EVALUATION_TIMEOUT)[-1]
        self.assertTrue(restored.startswith("info string EvalFile: using "), restored)
        self.assertNotIn(embedded_placeholder, restored)

    def test_search_names_the_network(self) -> None:
        output = self.engine.search("startpos", "depth 2").output
        announcements = [line for line in output if line.startswith("info string NNUE evaluation using ")]
        self.assertEqual(len(announcements), 1, output)
        self.assertRegex(announcements[0], NETWORK_ANNOUNCEMENT)

    def test_go_after_ucinewgame_searches_the_start_position(self) -> None:
        self.engine.search("startpos moves e2e4 e7e5", f"depth {NEW_GAME_DEPTH}")
        self.engine.send("ucinewgame")
        self.engine.go(f"depth {NEW_GAME_DEPTH}")
        without_position = self.engine.bestmove(SEARCH_TIMEOUT)
        self.engine.send("ucinewgame")
        with_position = self.engine.search("startpos", f"depth {NEW_GAME_DEPTH}")
        self.assertEqual(final_nodes(without_position), final_nodes(with_position))

    def test_clock_and_increment_at_the_integer_limits_are_searched(self) -> None:
        result = self.engine.search("startpos", f"wtime {LARGEST_CLOCK} winc {LARGEST_INCREMENT} depth 4")
        self.assertNotEqual(result.move, NULL_MOVE)

    def test_show_wdl_reports_permille_between_score_and_nodes(self) -> None:
        self.engine.set_option("UCI_ShowWDL", "true")
        result = self.engine.search("startpos", f"depth {WDL_DEPTH}")
        lines = [line for line in result.output if line.startswith("info depth")]
        self.assertTrue(lines, result.output)
        for line in lines:
            permille = SCORE_WITH_WDL.search(line)
            if permille is None:
                self.fail(line)
            self.assertEqual(sum(map(int, permille.groups())), PERMILLE, line)

    def test_live_currmove_after_delay(self) -> None:
        self.engine.send("position startpos moves e2e4 c7c5")
        started = time.monotonic()
        self.engine.go("infinite")
        currmove = self.engine.read_until_match(
            lambda line: " currmove " in line, "a currmove line", LIVE_INFO_TIMEOUT
        )[-1]
        elapsed = time.monotonic() - started
        best = self.engine.stop()
        self.assertIn(" currmovenumber ", currmove)
        self.assertGreaterEqual(elapsed, LIVE_INFO_DELAY_SECONDS, "currmove reported too early")
        self.assertNotEqual(best.move, NULL_MOVE)

    def test_threads_with_thread_pool(self) -> None:
        maximum = self.require_option("Threads").maximum
        if maximum is None or maximum < THREADS_UNDER_TEST:
            self.skipTest(f"the engine runs at most {maximum} thread(s)")
        self.engine.set_option("Threads", str(THREADS_UNDER_TEST))
        self.engine.set_option("MultiPV", "2")
        for _ in range(3):
            self.assertNotEqual(self.engine.search("startpos", "depth 12").move, NULL_MOVE)
        self.engine.set_option("NumaPolicy", "none")
        self.engine.search("startpos moves d2d4", "movetime 500")
        self.engine.set_option("NumaPolicy", "auto")
        self.engine.set_option("Threads", str(THREADS_UNDER_TEST // 2))
        self.assertNotEqual(self.engine.search("startpos moves c2c4", "nodes 200000").move, NULL_MOVE)

    def test_multipv_reports_distinct_sorted_lines(self) -> None:
        self.engine.set_option("MultiPV", str(MULTIPV_UNDER_TEST))
        result = self.engine.search("startpos", f"depth {MULTIPV_DEPTH}")
        final = [
            info_fields(line) for line in result.output if line.startswith(f"info depth {MULTIPV_DEPTH} ")
        ]
        self.assertEqual([line["multipv"] for line in final], [str(n + 1) for n in range(MULTIPV_UNDER_TEST)])
        first_moves = [line["pv"].split()[0] for line in final]
        self.assertEqual(len(set(first_moves)), MULTIPV_UNDER_TEST, first_moves)
        scores = [int(line["cp"]) for line in final]
        self.assertEqual(scores, sorted(scores, reverse=True))
        self.assertEqual(result.move, first_moves[0])

    def test_bestmove_carries_ponder_move(self) -> None:
        result = self.engine.search("startpos moves e2e4", "depth 10")
        self.assertEqual(iterations(result)[-1]["pv"].split()[:2], [result.move, result.ponder])

    def test_ponderhit_releases_bestmove(self) -> None:
        self.engine.send("position startpos moves e2e4 e7e5")
        self.engine.go("ponder wtime 3000 btime 3000")
        self.engine.expect_silence("bestmove", BESTMOVE_HELD_BACK_FOR)
        self.engine.send("ponderhit")
        self.engine.bestmove(STOP_TIMEOUT)

    def test_stop_while_pondering(self) -> None:
        self.engine.send("position startpos moves d2d4")
        self.engine.go("ponder wtime 60000 btime 60000")
        self.engine.expect_silence("bestmove", BESTMOVE_HELD_BACK_FOR)
        self.engine.stop()

    def test_infinite_search_that_has_found_mate_waits_for_stop(self) -> None:
        self.engine.send(f"position fen {BACK_RANK_MATE_IN_ONE}")
        self.engine.go("infinite")
        self.engine.expect_silence("bestmove", BESTMOVE_HELD_BACK_FOR)
        self.engine.sync()
        self.assertEqual(self.engine.stop().move, "a1a8")

    def test_go_mate_finds_mate(self) -> None:
        result = self.engine.search(f"fen {SCHOLARS_MATE_IN_ONE}", "mate 1")
        self.assertEqual(result.move, "h5f7")
        self.assertTrue(any(info_fields(line).get("mate") == "1" for line in result.output), result.output)

    def test_searchmoves_restricts_root(self) -> None:
        result = self.engine.search("startpos", "depth 6 searchmoves a2a3 h2h3")
        self.assertIn(result.move, ("a2a3", "h2h3"))

    def test_chess960_castling_notation(self) -> None:
        self.engine.set_option("UCI_Chess960", "true")
        chess960 = self.engine.search(f"fen {BOTH_SIDES_CAN_CASTLE} moves e1h1", "depth 3 searchmoves e8a8")
        self.assertEqual(chess960.move, "e8a8")
        self.engine.set_option("UCI_Chess960", "false")
        standard = self.engine.search(f"fen {BOTH_SIDES_CAN_CASTLE} moves e1g1", "depth 3 searchmoves e8c8")
        self.assertEqual(standard.move, "e8c8")

    def test_frc_start_position_search(self) -> None:
        self.engine.set_option("UCI_Chess960", "true")
        self.assertNotEqual(self.engine.search(f"fen {CHESS960_MIDDLEGAME}", "depth 8").move, NULL_MOVE)

    def test_skill_level_limits_depth(self) -> None:
        self.engine.set_option("Skill Level", str(WEAK_SKILL_LEVEL))
        result = self.engine.search("startpos", "depth 20")
        self.assertLessEqual(max(searched_depths(result)), WEAK_SEARCH_MAX_DEPTH)
        self.assertNotEqual(result.move, NULL_MOVE)

    def test_limited_strength_reports_only_the_lines_multipv_asks_for(self) -> None:
        self.engine.set_option("Skill Level", str(WEAK_SKILL_LEVEL))
        result = self.engine.search("startpos", "depth 20")
        self.assertEqual({iteration["multipv"] for iteration in iterations(result)}, {"1"})

    def test_limit_strength_by_elo(self) -> None:
        self.engine.set_option("UCI_LimitStrength", "true")
        self.engine.set_option("UCI_Elo", str(WEAK_ELO))
        result = self.engine.search("startpos moves e2e4", "movetime 2000")
        self.assertLessEqual(max(searched_depths(result)), WEAK_SEARCH_MAX_DEPTH)

    def test_clear_hash_button(self) -> None:
        self.engine.send("setoption name Clear Hash")
        self.engine.expect_silence("info string setoption failed", SETOPTION_FAILURE_WINDOW)


class CommandLineTest(EngineCommandTest):
    def setUp(self) -> None:
        if len(self.command) > 1:
            self.skipTest("the engine command is a launcher that takes the arguments itself")

    def run_engine(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [*self.command, *arguments],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=COMMAND_LINE_TIMEOUT,
            check=False,
        )

    def test_arguments_run_as_uci_commands_before_standard_input(self) -> None:
        run = self.run_engine("isready", "quit")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("readyok", run.stdout.splitlines())

    def test_genfens_argument_prints_the_requested_positions_and_exits(self) -> None:
        run = self.run_engine(f"genfens {GENFENS_COUNT} seed 1 book None", "quit")
        self.assertEqual(run.returncode, 0, run.stderr)
        positions = [line for line in run.stdout.splitlines() if line.startswith("info string genfens ")]
        self.assertEqual(len(positions), GENFENS_COUNT, run.stdout)

    def test_argument_that_is_not_a_command_is_a_usage_error(self) -> None:
        run = self.run_engine("--version")
        self.assertEqual(run.returncode, USAGE_ERROR)
        self.assertEqual(run.stdout, "")
        self.assertIn("Usage: ", run.stderr)


if __name__ == "__main__":
    if sys.argv[1:]:
        EngineCommandTest.command = sys.argv[1:]
    unittest.main(argv=sys.argv[:1], verbosity=2)
