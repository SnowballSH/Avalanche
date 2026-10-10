from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import numpy as np

import fit_wdl
from fit_wdl import SCORE_LIMIT, Outcome

GAME_WITH_UNSIGNED_ZERO_SCORES = """[Event "?"]
[Result "1-0"]

1. e4 {book} e5 {book} 2. Nf3 {+0.35/18 1.2s} Nc6 {-0.30/17 1.0s} 3. Bb5 {0.00/21 0.84s} a6 {0.00/20 0.5s}
4. Qh5 {+M3/12 0.01s} g6 {-M3/11 0.01s, White mates} 1-0
"""

GAME_FROM_A_SHORT_FEN_WITH_BLACK_TO_MOVE = """[Event "?"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -"]
[Result "0-1"]

1... c5 {+0.00/20 0.5s} 2. Nf3 {-0.12/19 0.4s} d6 {+0.50/18 0.3s, Black wins by adjudication} 0-1
"""

EVERY_POSITION = fit_wdl.Sampling(min_ply=0, max_abs_score=SCORE_LIMIT, keep_probability=1.0)
USAGE_ERROR = 2


def positions_of(game: str) -> fit_wdl.PgnPositions:
    positions = fit_wdl.PgnPositions(score_scale=1.0)
    positions.add_game(game)
    return positions


def count(scan: fit_wdl.Scan, x_bin: int, score: int, outcome: Outcome) -> int:
    return int(scan.counts[x_bin, fit_wdl.ZERO_SCORE_BIN + score // fit_wdl.SCORE_STEP, outcome])


class MoveCommentTest(unittest.TestCase):
    def test_a_signed_score_is_scaled_to_internal_centipawns(self) -> None:
        self.assertEqual(fit_wdl.mover_score("+0.35/18 1.2s", score_scale=2.0), 70)
        self.assertEqual(fit_wdl.mover_score("-0.30/17 1.0s", score_scale=1.0), -30)

    def test_a_zero_score_without_a_sign_is_a_score(self) -> None:
        self.assertEqual(fit_wdl.mover_score("0.00/21 0.84s", score_scale=1.0), 0)

    def test_a_mate_score_counts_as_the_score_limit(self) -> None:
        self.assertEqual(fit_wdl.mover_score("+M3/12 0.01s", score_scale=1.0), SCORE_LIMIT)
        self.assertEqual(fit_wdl.mover_score("-M3/11 0.01s", score_scale=1.0), -SCORE_LIMIT)

    def test_a_score_beyond_the_limit_is_clamped_to_it(self) -> None:
        self.assertEqual(fit_wdl.mover_score("+99.00/30 0.1s", score_scale=1.0), SCORE_LIMIT)

    def test_a_book_move_has_no_score(self) -> None:
        self.assertIsNone(fit_wdl.mover_score("book", score_scale=1.0))


class FirstPlyTest(unittest.TestCase):
    def test_a_game_without_a_fen_tag_starts_at_ply_zero(self) -> None:
        self.assertEqual(fit_wdl.first_ply(None), 0)

    def test_a_full_fen_gives_the_ply_of_its_move_number_and_side(self) -> None:
        self.assertEqual(fit_wdl.first_ply("8/8/8/8/8/8/8/K1k5 w - - 0 3"), 4)
        self.assertEqual(fit_wdl.first_ply("8/8/8/8/8/8/8/K1k5 b - - 0 3"), 5)

    def test_a_fen_without_move_counters_keeps_its_side_to_move(self) -> None:
        self.assertEqual(fit_wdl.first_ply("8/8/8/8/8/8/8/K1k5 w - -"), 0)
        self.assertEqual(fit_wdl.first_ply("8/8/8/8/8/8/8/K1k5 b - -"), 1)


class PgnGameTest(unittest.TestCase):
    def test_every_scored_move_is_a_position_seen_by_its_mover(self) -> None:
        positions = positions_of(GAME_WITH_UNSIGNED_ZERO_SCORES)
        self.assertEqual(positions.plies, [2, 3, 4, 5, 6, 7])
        self.assertEqual(positions.scores, [35, -30, 0, 0, SCORE_LIMIT, -SCORE_LIMIT])
        self.assertEqual(positions.outcomes, [Outcome.WIN, Outcome.LOSS] * 3)

    def test_black_owns_the_first_score_of_a_game_that_starts_with_black_to_move(self) -> None:
        positions = positions_of(GAME_FROM_A_SHORT_FEN_WITH_BLACK_TO_MOVE)
        self.assertEqual(positions.plies, [1, 2, 3])
        self.assertEqual(positions.scores, [0, -12, 50])
        self.assertEqual(positions.outcomes, [Outcome.WIN, Outcome.LOSS, Outcome.WIN])

    def test_comments_without_a_score_are_counted_apart_from_book_moves(self) -> None:
        positions = positions_of(GAME_WITH_UNSIGNED_ZERO_SCORES.replace("{-0.30/17 1.0s}", "{-0,30 / 17}"))
        self.assertEqual(positions.book_moves, 2)
        self.assertEqual(positions.unreadable_comments, 1)
        self.assertEqual(positions.plies, [2, 4, 5, 6, 7])

    def test_a_game_without_a_decided_result_is_left_out(self) -> None:
        self.assertEqual(positions_of(GAME_WITH_UNSIGNED_ZERO_SCORES.replace("1-0", "*")).plies, [])


class ScanTest(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)

    def test_a_pgn_file_is_binned_by_ply_and_score(self) -> None:
        path = self.directory / "games.pgn"
        path.write_text(
            GAME_WITH_UNSIGNED_ZERO_SCORES + "\n" + GAME_FROM_A_SHORT_FEN_WITH_BLACK_TO_MOVE, encoding="utf-8"
        )
        scan = fit_wdl.PgnJob(path, EVERY_POSITION, seed=0, score_scale=1.0).scan()
        self.assertEqual((scan.seen, scan.kept, scan.book_moves, scan.unreadable_comments), (9, 9, 2, 0))
        self.assertEqual(count(scan, 4 // fit_wdl.PLY_STEP, 0, Outcome.WIN), 1)
        self.assertEqual(count(scan, 5 // fit_wdl.PLY_STEP, 0, Outcome.LOSS), 1)
        self.assertEqual(count(scan, 1 // fit_wdl.PLY_STEP, 0, Outcome.WIN), 1)
        self.assertEqual(count(scan, 7 // fit_wdl.PLY_STEP, -SCORE_LIMIT, Outcome.LOSS), 1)

    def test_the_sampling_filters_apply_to_ply_and_score(self) -> None:
        path = self.directory / "games.pgn"
        path.write_text(GAME_WITH_UNSIGNED_ZERO_SCORES, encoding="utf-8")
        sampling = fit_wdl.Sampling(min_ply=3, max_abs_score=100, keep_probability=1.0)
        scan = fit_wdl.PgnJob(path, sampling, seed=0, score_scale=1.0).scan()
        self.assertEqual((scan.seen, scan.kept), (6, 3))

    def test_a_viriformat_game_is_read_from_its_header_and_move_words(self) -> None:
        header = np.zeros(1, dtype=fit_wdl.VIRI_HEADER)
        header["occupancy"] = 0xFFFF_0000_0000_FFFF
        header["side_and_en_passant"] = fit_wdl.VIRI_BLACK_TO_MOVE
        header["fullmove"] = 2
        header["white_outcome"] = Outcome.WIN
        moves = np.zeros(2, dtype=fit_wdl.VIRI_MOVE)
        moves["move"] = 1
        moves["white_score"] = [50, -30]
        terminator = np.zeros(1, dtype=fit_wdl.VIRI_WORD)
        path = self.directory / "games.viribin"
        path.write_bytes(header.tobytes() + moves.tobytes() + terminator.tobytes())

        scan = fit_wdl.ViriJob(path, EVERY_POSITION, seed=0).scan()
        self.assertEqual((scan.seen, scan.kept), (2, 2))
        self.assertEqual(count(scan, 3 // fit_wdl.PLY_STEP, -50, Outcome.LOSS), 1)
        self.assertEqual(count(scan, 4 // fit_wdl.PLY_STEP, -30, Outcome.WIN), 1)

    def test_bullet_records_are_binned_by_piece_count(self) -> None:
        records = np.zeros(3, dtype=fit_wdl.BULLET_RECORD)
        records["occupancy"] = [0b111, 0b1_1111, 0b1]
        records["score"] = [40, -120, 0]
        records["outcome"] = [Outcome.WIN, Outcome.DRAW, Outcome.LOSS]
        path = self.directory / "positions.bullet"
        path.write_bytes(records.tobytes())

        scan = fit_wdl.BulletJob(
            path, byte_start=0, byte_length=path.stat().st_size, max_abs_score=100
        ).scan()
        self.assertEqual((scan.seen, scan.kept), (3, 1))
        self.assertEqual(count(scan, 3 - fit_wdl.MIN_PIECES, 40, Outcome.WIN), 1)


class CommandLineTest(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.pgn = Path(directory.name) / "games.pgn"
        self.pgn.write_text(
            GAME_WITH_UNSIGNED_ZERO_SCORES + "\n" + GAME_FROM_A_SHORT_FEN_WITH_BLACK_TO_MOVE, encoding="utf-8"
        )
        self.bullet = Path(directory.name) / "positions.bullet"
        self.bullet.write_bytes(np.zeros(1, dtype=fit_wdl.BULLET_RECORD).tobytes())

    def run_main(self, *arguments: str) -> tuple[int | str | None, str]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                status: int | str | None = fit_wdl.main(arguments)
            except SystemExit as exit_request:
                status = exit_request.code
        return status, output.getvalue()

    def test_match_games_are_fitted_and_the_skipped_comments_reported(self) -> None:
        status, output = self.run_main("--data", str(self.pgn), "--workers", "1")
        self.assertEqual(status, 0, output)
        self.assertIn("scanned 9 positions, kept 9 after filters", output)
        self.assertIn("comments without a score: 2 book moves, 0 unreadable", output)
        self.assertIn("const AS: [4]f64", output)

    def test_a_score_bound_beyond_the_histogram_is_rejected(self) -> None:
        status, output = self.run_main("--data", str(self.pgn), "--max-abs-score", str(SCORE_LIMIT + 1))
        self.assertEqual(status, USAGE_ERROR, output)
        self.assertIn("--max-abs-score", output)

    def test_a_ply_filter_is_rejected_for_data_that_stores_no_ply(self) -> None:
        status, output = self.run_main("--data", str(self.bullet), "--min-ply", "8")
        self.assertEqual(status, USAGE_ERROR, output)
        self.assertIn("--min-ply", output)

    def test_a_score_scale_is_rejected_for_data_in_internal_units(self) -> None:
        status, output = self.run_main("--data", str(self.bullet), "--score-scale", "1.38")
        self.assertEqual(status, USAGE_ERROR, output)
        self.assertIn("--score-scale", output)


if __name__ == "__main__":
    unittest.main()
