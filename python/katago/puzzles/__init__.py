"""Algorithm-only Go puzzle generation (no neural net).

Currently provides a 9x9 endgame ("biggest move") puzzle generator whose
correctness is certified at generation time by exact minimax search over the
contested region.  See :mod:`katago.puzzles.endgame`.
"""

from katago.puzzles.endgame import (
    Difficulty,
    EndgamePuzzle,
    KOMI,
    area_score,
    best_endgame_moves,
    generate_endgame_puzzle,
    generate_endgame_sgf,
)

__all__ = [
    "Difficulty",
    "EndgamePuzzle",
    "KOMI",
    "area_score",
    "best_endgame_moves",
    "generate_endgame_puzzle",
    "generate_endgame_sgf",
]
