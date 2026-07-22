"""Serve 9x9 endgame puzzles taken from real KataGo games.

Each puzzle is a mostly-settled position from a real 9x9 KataGo self-play game
(random/high-temperature opening for variety). The "answer" is KataGo's best move
and its expected result; the app plays the position out to two passes and grades
it with KataGo ("score by AI"). Difficulty (integer 1..999) is calibrated across
the corpus by how non-obvious the best move is (low policy prior), whether the
natural move is a costly trap, and board complexity.

The puzzle corpus (``games/puzzles.json``) is generated offline by the pipeline in
``tools/`` (build KataGo, self-play, extract). This module is a pure, deterministic
selector over that corpus -- no neural net is needed at runtime.
"""

from __future__ import annotations

import json
import os
import random
from dataclasses import dataclass
from typing import List, Optional

from katago.game.board import Board
from katago.puzzles.endgame import _fmt, to_sgf

DIFFICULTY_MIN = 1
DIFFICULTY_MAX = 999
_COLS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
_PUZZLES_PATH = os.path.join(os.path.dirname(__file__), "games", "puzzles.json")
_WINDOW = 10  # how many nearest-difficulty puzzles a seed selects among

_CACHE: Optional[List[dict]] = None


def _load() -> List[dict]:
    global _CACHE
    if _CACHE is None:
        with open(_PUZZLES_PATH) as f:
            _CACHE = json.load(f)
    return _CACHE


def _xy(coord: str):
    return _COLS.index(coord[0]), 9 - int(coord[1:])


@dataclass
class EndgamePuzzle:
    sgf: str
    side_to_move: int
    best_first_moves: List[str]   # KataGo's best move (GTP)
    optimal_score: float          # KataGo expected black-area - white-area incl. komi
    difficulty: int
    natural_move: str = ""        # the tempting move (highest policy prior)
    natural_cost: float = 0.0     # points the natural move loses vs best


def _board_from(entry: dict) -> Board:
    b = Board(9)
    for coord in entry["bstones"]:
        x, y = _xy(coord)
        b.set_stone(Board.BLACK, b.loc(x, y))
    for coord in entry["wstones"]:
        x, y = _xy(coord)
        b.set_stone(Board.WHITE, b.loc(x, y))
    return b


def generate_endgame_puzzle(difficulty: int, seed: int) -> EndgamePuzzle:
    """Deterministically pick a real-game endgame puzzle of the requested
    difficulty (integer 1..999, clamped). Same ``(difficulty, seed)`` -> identical
    puzzle."""
    difficulty = max(DIFFICULTY_MIN, min(DIFFICULTY_MAX, int(difficulty)))
    puzzles = _load()
    if not puzzles:
        raise RuntimeError("empty puzzle corpus at %s" % _PUZZLES_PATH)

    # The nearest-difficulty window, tie-broken deterministically; a seed selects
    # within it for variety.
    order = sorted(range(len(puzzles)),
                   key=lambda i: (abs(puzzles[i]["difficulty"] - difficulty),
                                  puzzles[i]["difficulty"], i))
    window = order[: min(_WINDOW, len(order))]
    rng = random.Random("realgame|%d|%d" % (difficulty, int(seed)))
    entry = puzzles[rng.choice(window)]

    # Every puzzle is Black to play; the per-puzzle komi is set so that best play
    # wins by exactly 0.5, while the natural (tempting) move loses.
    board = _board_from(entry)
    komi = entry["komi"]
    comment = (
        "Black to play and win by 0.5 (real KataGo game endgame). Difficulty %d/999. "
        "Komi %s. Play to two passes; scored by area. KataGo's move: %s wins by 0.5; "
        "the natural move %s loses about %.1f point(s)."
        % (difficulty, _fmt(komi), entry["best_move"],
           entry["natural_move"], entry["natural_cost"])
    )
    sgf = to_sgf(board, Board.BLACK, comment, komi=komi)
    return EndgamePuzzle(
        sgf=sgf,
        side_to_move=Board.BLACK,
        best_first_moves=[entry["best_move"]],
        optimal_score=0.5,               # Black wins by exactly 0.5 with best play
        difficulty=difficulty,
        natural_move=entry.get("natural_move", ""),
        natural_cost=entry.get("natural_cost", 0.0),
    )


def generate_endgame_sgf(difficulty: int, seed: int) -> str:
    return generate_endgame_puzzle(difficulty, seed).sgf
