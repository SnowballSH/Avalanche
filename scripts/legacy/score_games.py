import sys
import chess
import chess.engine
import chess.pgn
import os


# Function to process a single game
def process_game(game: chess.pgn.Game):
    board = game.board()
    fen_eval_result = []

    # Setup the engine
    with chess.engine.SimpleEngine.popen_uci("../old_binaries/Avalanche") as engine:
        ply = 0
        for move in game.mainline_moves():
            # Check the conditions specified
            if not (
                ply <= 7
                or board.is_check()
                or board.is_capture(move)
                or move.promotion is not None
                or board.gives_check(move)
            ):
                # Run the engine at depth 8
                info = engine.analyse(board, chess.engine.Limit(depth=8))
                score = info["score"].relative.score()
                if score is not None:
                    if board.turn == chess.BLACK:
                        score = -score
                    fen_eval_result.append((board.fen(), score, None))

            board.push(move)
            ply += 1

        # Update the result field for the positions
        result = game.headers["Result"]
        if result == "1-0":
            updated_result = 1.0
        elif result == "0-1":
            updated_result = 0.0
        else:
            updated_result = 0.5

        fen_eval_result = [
            (fen, eval_, updated_result) for fen, eval_, _ in fen_eval_result
        ]

    return fen_eval_result


def main():
    directory_path = sys.argv[1]

    with open(sys.argv[2], "w") as file:
        pass  # Clear the file

    # Open data.txt for appending
    with open(sys.argv[2], "a") as file:
        # Iterate over each file in the directory
        for filename in os.listdir(directory_path):
            if filename.endswith(".pgn"):
                with open(os.path.join(directory_path, filename)) as pgn_file:
                    while True:
                        game = chess.pgn.read_game(pgn_file)
                        if game is None:
                            break  # Reached end of file
                        fen_eval_results = process_game(game)
                        for fen, eval_, result in fen_eval_results:
                            file.write(f"{fen} | {eval_} | {result}\n")


if __name__ == "__main__":
    main()
