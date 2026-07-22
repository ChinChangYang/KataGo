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
from katago.puzzles.endgame import KOMI, _fmt, result_string, to_sgf

DIFFICULTY_MIN = 1
DIFFICULTY_MAX = 999
_COLS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
_PUZZLES_PATH = os.path.join(os.path.dirname(__file__), "games", "puzzles.json")
_WINDOW = 24  # how many nearest-difficulty puzzles a seed selects among

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

    stm = Board.BLACK if entry["to_move"] == "B" else Board.WHITE
    board = _board_from(entry)
    black_lead = entry["best_black_lead"]            # black-minus-white incl. komi
    result = result_string(black_lead)
    stm_char = "Black" if stm == Board.BLACK else "White"
    trap = ""
    if entry.get("natural_cost", 0) > 0:
        trap = (" The natural move %s loses about %.1f point(s)."
                % (entry["natural_move"], entry["natural_cost"]))
    comment = (
        "%s to play (real KataGo game endgame). Difficulty %d/999. "
        "Find the best move and play to two passes; scored by area, komi %s. "
        "KataGo's move: %s; expected result with best play: %s.%s"
        % (stm_char, difficulty, _fmt(KOMI), entry["best_move"], result, trap)
    )
    sgf = to_sgf(board, stm, comment)
    return EndgamePuzzle(
        sgf=sgf,
        side_to_move=stm,
        best_first_moves=[entry["best_move"]],
        optimal_score=black_lead,
        difficulty=difficulty,
        natural_move=entry.get("natural_move", ""),
        natural_cost=entry.get("natural_cost", 0.0),
    )


def generate_endgame_sgf(difficulty: int, seed: int) -> str:
    return generate_endgame_puzzle(difficulty, seed).sgf
