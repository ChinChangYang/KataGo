"""Algorithm-assisted Go endgame puzzle generation.

The current generator serves 9x9 endgame ("yose") puzzles taken from real KataGo
games (see :mod:`katago.puzzles.realgame`): a mostly-settled position from a real
9x9 KataGo self-play game, with KataGo's best move and expected result as the
answer, graded by KataGo. Difficulty is an integer 1..999.

Also available: :mod:`katago.puzzles.endgame`, an earlier fully self-contained
generator that *constructs* positions and certifies them with an exact minimax
solver (no neural net). Its helpers (``area_score``, ``to_sgf``, ``EndgameSolver``)
are reused by the real-game path.
"""

from katago.puzzles.endgame import KOMI, area_score, best_endgame_moves, to_sgf
from katago.puzzles.realgame import (
    DIFFICULTY_MAX,
    DIFFICULTY_MIN,
    EndgamePuzzle,
    generate_endgame_puzzle,
    generate_endgame_sgf,
)

__all__ = [
    "DIFFICULTY_MAX",
    "DIFFICULTY_MIN",
    "EndgamePuzzle",
    "KOMI",
    "area_score",
    "best_endgame_moves",
    "generate_endgame_puzzle",
    "generate_endgame_sgf",
    "to_sgf",
]
