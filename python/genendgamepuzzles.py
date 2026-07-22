#!/usr/bin/env python3
"""Generate algorithm-only 9x9 endgame ("biggest move") puzzles as SGF.

No neural net is used.  Each puzzle is a settled 9x9 position, area-scored under
Tromp-Taylor rules with komi 7.5, in which the side to move wins the game if and
only if they play the biggest endgame moves in the correct order.  Correctness is
certified at generation time by exact minimax search, and the same
``(difficulty, seed)`` always produces the identical puzzle.

Examples
--------
    python genendgamepuzzles.py --difficulty medium --seed 42
    python genendgamepuzzles.py -d 4 -s 7 --show
    python genendgamepuzzles.py --difficulty hard --seed 0 --count 5

See ``katago/puzzles/endgame.py`` for the library API.
"""

import argparse
import re
import sys

from katago.game.board import Board
from katago.puzzles.endgame import Difficulty, generate_endgame_puzzle

_DIFF_ALIASES = {
    "1": Difficulty.VERY_EASY, "very_easy": Difficulty.VERY_EASY, "veryeasy": Difficulty.VERY_EASY,
    "2": Difficulty.EASY, "easy": Difficulty.EASY,
    "3": Difficulty.MEDIUM, "medium": Difficulty.MEDIUM,
    "4": Difficulty.HARD, "hard": Difficulty.HARD,
    "5": Difficulty.VERY_HARD, "very_hard": Difficulty.VERY_HARD, "veryhard": Difficulty.VERY_HARD,
}


def _parse_difficulty(text):
    key = text.strip().lower().replace("-", "_")
    if key in _DIFF_ALIASES:
        return _DIFF_ALIASES[key]
    raise argparse.ArgumentTypeError(
        "difficulty must be 1-5 or one of: very_easy, easy, medium, hard, very_hard"
    )


def _board_from_sgf(sgf):
    """Reconstruct the board from our own SGF (for --show)."""
    chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    size = int(re.search(r"SZ\[(\d+)\]", sgf).group(1))
    board = Board(size)
    for tag, color in (("AB", Board.BLACK), ("AW", Board.WHITE)):
        m = re.search(tag + r"((?:\[[a-zA-Z]{2}\])+)", sgf)
        if not m:
            continue
        for pt in re.findall(r"\[([a-zA-Z]{2})\]", m.group(1)):
            board.set_stone(color, board.loc(chars.index(pt[0]), chars.index(pt[1])))
    return board


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate a 9x9 endgame puzzle as SGF (algorithm-only, no neural net).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "-d", "--difficulty", type=_parse_difficulty, default=Difficulty.MEDIUM,
        help="1-5 or very_easy|easy|medium|hard|very_hard",
    )
    parser.add_argument("-s", "--seed", type=int, default=0, help="integer seed")
    parser.add_argument(
        "-n", "--count", type=int, default=1,
        help="generate this many puzzles from consecutive seeds starting at --seed",
    )
    parser.add_argument(
        "--show", action="store_true",
        help="also print the board and the solution to stderr",
    )
    args = parser.parse_args(argv)

    for i in range(args.count):
        seed = args.seed + i
        puzzle = generate_endgame_puzzle(args.difficulty, seed)
        print(puzzle.sgf)
        if args.show:
            side = "Black" if puzzle.side_to_move == Board.BLACK else "White"
            sys.stderr.write(
                "# difficulty=%s seed=%d  %s to play  best=%s  result=%+.1f\n"
                % (args.difficulty.name, seed, side, ",".join(puzzle.best_first_moves),
                   puzzle.optimal_score)
            )
            sys.stderr.write(_board_from_sgf(puzzle.sgf).to_string() + "\n\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
