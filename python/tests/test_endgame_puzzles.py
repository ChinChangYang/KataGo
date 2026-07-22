"""Unit tests for the algorithm-only 9x9 endgame puzzle generator.

Run from the ``python/`` directory: ``pytest`` (see ``pytest.ini``).

The interesting properties are verified *independently* of the generator's own
internal state by reconstructing the board from the emitted SGF text and
re-solving it.
"""

import re
import time

import pytest

from katago.game.board import Board
from katago.puzzles import endgame as E

DIFFICULTIES = [1, 150, 300, 500, 700, 999]
SEEDS = list(range(4))
_SGF_CHARS = E._SGF_CHARS


# --------------------------------------------------------------------------- #
# Helpers: reconstruct a board straight from the emitted SGF (no internal state).
# --------------------------------------------------------------------------- #
def board_from_sgf(sgf):
    size = int(re.search(r"SZ\[(\d+)\]", sgf).group(1))
    stm = Board.BLACK if re.search(r"PL\[([BW])\]", sgf).group(1) == "B" else Board.WHITE
    board = Board(size)
    for tag, color in (("AB", Board.BLACK), ("AW", Board.WHITE)):
        m = re.search(tag + r"((?:\[[a-zA-Z]{2}\])+)", sgf)
        if not m:
            continue
        for pt in re.findall(r"\[([a-zA-Z]{2})\]", m.group(1)):
            board.set_stone(color, board.loc(_SGF_CHARS.index(pt[0]), _SGF_CHARS.index(pt[1])))
    return board, stm


def stm_wins(value, stm):
    return (value - E.KOMI) > 0 if stm == Board.BLACK else (E.KOMI - value) > 0


def solve_contested(board, stm):
    """Per-first-move values over the contested cells (== the full game, since
    the generator forbids stray dame and eye-fills are dominated)."""
    return E.EndgameSolver(E._contested_empties(board)).evaluate_root(board, stm)


def replay_optimal(board, stm):
    solver = E.EndgameSolver(E._contested_empties(board))
    b = board.copy()
    to_move, passes, guard = stm, 0, 0
    while passes < 2 and guard < 80:
        guard += 1
        cp = b.copy(); cp.play(to_move, Board.PASS_LOC)
        best_loc = Board.PASS_LOC
        best_val = solver._value(cp, Board.get_opp(to_move), passes + 1)
        for loc in solver._candidates(b, to_move):
            c = b.copy(); c.play(to_move, loc)
            v = solver._value(c, Board.get_opp(to_move), 0)
            if (v > best_val) if to_move == Board.BLACK else (v < best_val):
                best_val, best_loc = v, loc
        b.play(to_move, best_loc)
        passes = passes + 1 if best_loc == Board.PASS_LOC else 0
        to_move = Board.get_opp(to_move)
    return E.score_black_minus_white(b)


def mistake_always_loses(board, stm):
    """Under optimal opponent play, every non-optimal move loses for STM."""
    solver = E.EndgameSolver(E._contested_empties(board))
    ok = [True]
    seen = set()

    def moves(b, to_move):
        vals = {}
        for loc in solver._candidates(b, to_move):
            c = b.copy(); c.play(to_move, loc)
            vals[loc] = solver._value(c, Board.get_opp(to_move), 0)
        cp = b.copy(); cp.play(to_move, Board.PASS_LOC)
        vals[Board.PASS_LOC] = solver._value(cp, Board.get_opp(to_move), 1)
        return vals

    def rec(b, to_move, passes):
        if passes >= 2:
            return
        key = (b.board.tobytes(), to_move, passes, b.simple_ko_point)
        if key in seen:
            return
        seen.add(key)
        vals = moves(b, to_move)
        best = max(vals.values()) if to_move == Board.BLACK else min(vals.values())
        if to_move == stm and stm_wins(best, stm):
            for v in vals.values():
                if v != best and stm_wins(v, stm):
                    ok[0] = False
        for loc, v in vals.items():
            if to_move != stm and v != best:
                continue
            c = b.copy()
            c.play(to_move, loc)
            rec(c, Board.get_opp(to_move), passes + 1 if loc == Board.PASS_LOC else 0)

    rec(board, stm, 0)
    return ok[0]


# --------------------------------------------------------------------------- #
# Scoring.
# --------------------------------------------------------------------------- #
def test_area_score_split_board():
    b = Board(9)
    for y in range(9):
        for x in range(9):
            if x < 4:
                b.set_stone(Board.BLACK, b.loc(x, y))
            elif x > 4:
                b.set_stone(Board.WHITE, b.loc(x, y))
    assert E.area_score(b) == (36, 36)


def test_area_score_counts_enclosed_territory():
    b = Board(9)
    for y in range(9):
        b.set_stone(Board.BLACK, b.loc(1, y))
        b.set_stone(Board.WHITE, b.loc(7, y))
    assert E.area_score(b) == (18, 18)


def test_solver_is_order_independent():
    """Regression: the minimax value must not depend on the move-list order."""
    p = E.generate_endgame_puzzle(999, 0)
    board, stm = board_from_sgf(p.sgf)
    contested = E._contested_empties(board)
    a = E.EndgameSolver(contested).evaluate_root(board, stm)
    b = E.EndgameSolver(list(reversed(contested))).evaluate_root(board, stm)
    assert a == b


# --------------------------------------------------------------------------- #
# Difficulty (integer) and determinism.
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("difficulty", DIFFICULTIES)
@pytest.mark.parametrize("seed", SEEDS)
def test_deterministic(difficulty, seed):
    a = E.generate_endgame_puzzle(difficulty, seed)
    b = E.generate_endgame_puzzle(difficulty, seed)
    assert a.sgf == b.sgf
    assert a.best_first_moves == b.best_first_moves


def test_difficulty_is_clamped():
    assert E.generate_endgame_puzzle(-5, 0).sgf == E.generate_endgame_puzzle(1, 0).sgf
    assert E.generate_endgame_puzzle(10 ** 6, 0).sgf == E.generate_endgame_puzzle(999, 0).sgf


def test_distinct_seeds_differ():
    sgfs = {E.generate_endgame_sgf(500, s) for s in range(8)}
    assert len(sgfs) > 1


def test_difficulty_metric_increases():
    """Harder puzzles are structurally more complex on average (allowing a plateau
    at the 9x9 ceiling)."""
    def avg_complexity(d):
        return sum(E.generate_endgame_puzzle(d, s).complexity for s in range(6)) / 6.0

    easy, mid, hard = avg_complexity(1), avg_complexity(500), avg_complexity(999)
    assert easy < mid <= hard
    assert easy < hard


# --------------------------------------------------------------------------- #
# SGF format.
# --------------------------------------------------------------------------- #
def test_sgf_shape():
    sgf = E.generate_endgame_sgf(700, 0)
    assert sgf.startswith("(;FF[4]GM[1]SZ[9]")
    assert sgf.endswith(")")
    assert "KM[7.5]" in sgf and "RU[TrompTaylor]" in sgf
    assert re.search(r"PL\[[BW]\]", sgf)


def test_sgf_parses_with_sgfmill():
    sgfmill_sgf = pytest.importorskip("sgfmill.sgf")
    for d in DIFFICULTIES:
        g = sgfmill_sgf.Sgf_game.from_bytes(E.generate_endgame_sgf(d, 0).encode())
        assert g.get_size() == 9
        assert abs(g.get_komi() - 7.5) < 1e-9


@pytest.mark.parametrize("difficulty", DIFFICULTIES)
def test_sgf_roundtrips(difficulty):
    p = E.generate_endgame_puzzle(difficulty, 1)
    board, stm = board_from_sgf(p.sgf)
    strip = lambda s: re.sub(r"C\[.*?\]", "", s)
    assert strip(E.to_sgf(board, stm, "x")) == strip(p.sgf)


# --------------------------------------------------------------------------- #
# Core puzzle invariants (reconstructed from SGF).
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("difficulty", DIFFICULTIES)
@pytest.mark.parametrize("seed", SEEDS)
def test_puzzle_invariants(difficulty, seed):
    p = E.generate_endgame_puzzle(difficulty, seed)
    board, stm = board_from_sgf(p.sgf)

    # Razor-thin, decisive win for the side to move.
    assert 0 < abs(p.optimal_score) < 2
    assert (p.optimal_score > 0) == (stm == Board.BLACK)
    assert stm_wins(replay_optimal(board, stm), stm)
    assert replay_optimal(board, stm) - E.KOMI == p.optimal_score

    # Both frames unconditionally alive.
    assert E._count_real_eyes(board, Board.BLACK) >= 2
    assert E._count_real_eyes(board, Board.WHITE) >= 2

    # The winning first moves are exactly what the puzzle reports, and there is
    # at least one losing first move (a real test).
    per = solve_contested(board, stm)
    winners = sorted(board.loc_to_str(l) for l, v in per.items() if stm_wins(v, stm))
    assert winners == p.best_first_moves
    assert any(not stm_wins(v, stm) for v in per.values())


def test_hard_puzzles_have_traps():
    """At high difficulty there is a genuine reading trap: a first move that is a
    natural capture attempt yet loses (and generation labels >= 1 trap)."""
    for seed in range(6):
        p = E.generate_endgame_puzzle(999, seed)
        board, stm = board_from_sgf(p.sgf)
        per = solve_contested(board, stm)
        losing = [l for l, v in per.items() if not stm_wins(v, stm)]
        assert losing, "expected a losing first move at difficulty 999"


def test_any_mistake_loses_sample():
    for difficulty, seed in [(1, 0), (500, 0), (999, 0), (999, 3)]:
        p = E.generate_endgame_puzzle(difficulty, seed)
        board, stm = board_from_sgf(p.sgf)
        assert mistake_always_loses(board, stm)


@pytest.mark.parametrize("difficulty", [1, 500, 999])
def test_best_endgame_moves_helper(difficulty):
    p = E.generate_endgame_puzzle(difficulty, 2)
    board, stm = board_from_sgf(p.sgf)
    value, moves = E.best_endgame_moves(board, stm)
    assert abs(value - p.optimal_score) < 1e-9
    assert p.best_first_moves[0] in [board.loc_to_str(m) for m in moves]


# --------------------------------------------------------------------------- #
# Performance (loose bound; generation is meant to be interactive).
# --------------------------------------------------------------------------- #
def test_generation_is_reasonably_fast():
    t0 = time.time()
    for d in (1, 300, 600, 999):
        for s in range(3):
            E.generate_endgame_puzzle(d, s)
    assert time.time() - t0 < 20.0
