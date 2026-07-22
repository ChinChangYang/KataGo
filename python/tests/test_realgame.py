"""Tests for the "Black to play and win by 0.5" endgame generator.

Runs against the committed corpus (katago/puzzles/games/puzzles.json).
"""
import re

import pytest

from katago.game.board import Board
from katago.puzzles import realgame as R

_COLS = "ABCDEFGHJ"
_SGF = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIFFS = [1, 200, 400, 600, 800, 999]


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
    return board.loc(_COLS.index(coord[0]), 9 - int(coord[1:]))


def komi_of(sgf):
    return float(re.search(r"KM\[([-0-9.]+)\]", sgf).group(1))


def test_corpus_loads():
    puzzles = R._load()
    assert puzzles
    assert all(1 <= p["difficulty"] <= 999 for p in puzzles)
    assert min(p["difficulty"] for p in puzzles) == 1
    assert max(p["difficulty"] for p in puzzles) == 999
    # Every stored puzzle is Black to play, has a costly trap, and a half-integer komi.
    for p in puzzles:
        assert p["to_move"] == "B"
        assert p["natural_cost"] >= 1.0
        assert abs(p["komi"] % 1 - 0.5) < 1e-9


@pytest.mark.parametrize("d", DIFFS)
@pytest.mark.parametrize("seed", range(3))
def test_deterministic(d, seed):
    assert R.generate_endgame_sgf(d, seed) == R.generate_endgame_sgf(d, seed)


def test_difficulty_clamped():
    assert R.generate_endgame_sgf(-5, 0) == R.generate_endgame_sgf(1, 0)
    assert R.generate_endgame_sgf(10 ** 6, 0) == R.generate_endgame_sgf(999, 0)


@pytest.mark.parametrize("d", DIFFS)
@pytest.mark.parametrize("seed", range(3))
def test_always_black_and_win_by_half(d, seed):
    p = R.generate_endgame_puzzle(d, seed)
    assert p.side_to_move == Board.BLACK
    assert p.optimal_score == 0.5
    assert "PL[B]" in p.sgf
    assert p.natural_move and p.natural_cost >= 1.0


@pytest.mark.parametrize("d", DIFFS)
def test_sgf_well_formed_komi_varies(d):
    p = R.generate_endgame_puzzle(d, 0)
    sgf = p.sgf
    assert sgf.startswith("(;FF[4]GM[1]SZ[9]") and sgf.endswith(")")
    assert "RU[TrompTaylor]" in sgf and "PL[B]" in sgf
    k = komi_of(sgf)
    assert abs(k % 1 - 0.5) < 1e-9      # half-integer, per-puzzle komi (not fixed 7.5)
    sgfmill = pytest.importorskip("sgfmill.sgf")
    g = sgfmill.Sgf_game.from_bytes(sgf.encode())
    assert g.get_size() == 9 and abs(g.get_komi() - k) < 1e-9


def test_komi_varies_across_puzzles():
    komis = {komi_of(R.generate_endgame_sgf(d, 0)) for d in range(1, 1000, 50)}
    assert len(komis) > 1


@pytest.mark.parametrize("d", DIFFS)
@pytest.mark.parametrize("seed", range(3))
def test_best_move_is_legal(d, seed):
    p = R.generate_endgame_puzzle(d, seed)
    board, _ = board_from_sgf(p.sgf)
    mv = p.best_first_moves[0]
    if mv == "pass":
        return
    loc = gtp_loc(board, mv)
    assert int(board.board[loc]) == Board.EMPTY
    assert board.would_be_legal(Board.BLACK, loc)


def test_variety_across_seeds():
    if len(R._load()) < R._WINDOW:
        pytest.skip("corpus too small")
    assert len({R.generate_endgame_sgf(500, s) for s in range(R._WINDOW)}) > 1


def test_low_vs_high_difficulty_differ():
    assert R.generate_endgame_sgf(1, 0) != R.generate_endgame_sgf(999, 0)


def test_selection_tracks_requested_difficulty():
    corpus = R._load()
    if len(corpus) < 2 * R._WINDOW:
        pytest.skip("corpus too small")

    def mean_assigned(req):
        order = sorted(range(len(corpus)),
                       key=lambda i: (abs(corpus[i]["difficulty"] - req),
                                      corpus[i]["difficulty"], i))
        window = order[: R._WINDOW]
        return sum(corpus[i]["difficulty"] for i in window) / len(window)

    assert mean_assigned(100) < mean_assigned(900)
