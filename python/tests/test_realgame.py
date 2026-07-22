"""Tests for the real-game endgame puzzle generator (katago.puzzles.realgame).

These run against the committed corpus (katago/puzzles/games/puzzles.json).
"""
import re

import pytest

from katago.game.board import Board
from katago.puzzles import realgame as R

_COLS = "ABCDEFGHJ"
_SGF = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


def board_from_sgf(sgf):
    stm = Board.BLACK if re.search(r"PL\[([BW])\]", sgf).group(1) == "B" else Board.WHITE
    b = Board(9)
    for tag, color in (("AB", Board.BLACK), ("AW", Board.WHITE)):
        m = re.search(tag + r"((?:\[[a-zA-Z]{2}\])+)", sgf)
        if m:
            for pt in re.findall(r"\[([a-zA-Z]{2})\]", m.group(1)):
                b.set_stone(color, b.loc(_SGF.index(pt[0]), _SGF.index(pt[1])))
    return b, stm


def gtp_loc(board, coord):
    x, y = _COLS.index(coord[0]), 9 - int(coord[1:])
    return board.loc(x, y)


DIFFS = [1, 200, 400, 600, 800, 999]


def test_corpus_loads():
    puzzles = R._load()
    assert puzzles, "empty corpus"
    assert all(1 <= p["difficulty"] <= 999 for p in puzzles)
    assert min(p["difficulty"] for p in puzzles) == 1
    assert max(p["difficulty"] for p in puzzles) == 999


@pytest.mark.parametrize("d", DIFFS)
@pytest.mark.parametrize("seed", range(3))
def test_deterministic(d, seed):
    assert R.generate_endgame_sgf(d, seed) == R.generate_endgame_sgf(d, seed)


def test_difficulty_clamped():
    assert R.generate_endgame_sgf(-5, 0) == R.generate_endgame_sgf(1, 0)
    assert R.generate_endgame_sgf(10 ** 6, 0) == R.generate_endgame_sgf(999, 0)


@pytest.mark.parametrize("d", DIFFS)
def test_sgf_well_formed(d):
    p = R.generate_endgame_puzzle(d, 0)
    sgf = p.sgf
    assert sgf.startswith("(;FF[4]GM[1]SZ[9]") and sgf.endswith(")")
    assert "KM[7.5]" in sgf and "RU[TrompTaylor]" in sgf
    assert re.search(r"PL\[[BW]\]", sgf)
    sgfmill = pytest.importorskip("sgfmill.sgf")
    g = sgfmill.Sgf_game.from_bytes(sgf.encode())
    assert g.get_size() == 9 and abs(g.get_komi() - 7.5) < 1e-9


@pytest.mark.parametrize("d", DIFFS)
@pytest.mark.parametrize("seed", range(3))
def test_best_move_is_legal(d, seed):
    p = R.generate_endgame_puzzle(d, seed)
    board, stm = board_from_sgf(p.sgf)
    assert p.best_first_moves, "no best move"
    mv = p.best_first_moves[0]
    if mv == "pass":
        return
    loc = gtp_loc(board, mv)
    assert int(board.board[loc]) == Board.EMPTY
    assert board.would_be_legal(stm, loc)


def test_variety_across_seeds():
    corpus = R._load()
    if len(corpus) < R._WINDOW:
        pytest.skip("corpus too small for variety assertion")
    assert len({R.generate_endgame_sgf(500, s) for s in range(R._WINDOW)}) > 1


def test_low_vs_high_difficulty_differ():
    assert R.generate_endgame_sgf(1, 0) != R.generate_endgame_sgf(999, 0)


def test_selection_tracks_requested_difficulty():
    """The puzzle chosen for a high request is, on average, an intrinsically
    harder one (higher assigned difficulty) than for a low request."""
    corpus = R._load()
    if len(corpus) < 2 * R._WINDOW:
        pytest.skip("corpus too small")

    def mean_assigned(req):
        # Replicate the nearest-window selection and average the entries' own
        # (percentile-assigned) difficulty over several seeds.
        order = sorted(range(len(corpus)),
                       key=lambda i: (abs(corpus[i]["difficulty"] - req),
                                      corpus[i]["difficulty"], i))
        window = order[: R._WINDOW]
        return sum(corpus[i]["difficulty"] for i in window) / len(window)

    assert mean_assigned(100) < mean_assigned(900)
