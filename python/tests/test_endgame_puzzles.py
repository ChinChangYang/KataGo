"""Unit tests for the algorithm-only 9x9 endgame puzzle generator.

Run from the ``python/`` directory: ``pytest`` (see ``pytest.ini``).

The interesting properties are verified *independently* of the generator's own
internal state by reconstructing the board from the emitted SGF text and
re-solving it, so the tests would catch a generator that emitted a position not
matching its own certification.
"""

import re
import time

import pytest

from katago.game.board import Board
from katago.puzzles import endgame as E

ALL_DIFFICULTIES = list(E.Difficulty)
SEEDS = list(range(6))
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


def replay_optimal(board, stm):
    """Play optimal moves for both sides to two passes; return final black-white."""
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
    """Under optimal opponent play, every non-optimal move loses for STM.

    Uses the doors as the move set; the generator guarantees there is no other
    contested point, so this is the full game.
    """
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
        key = (int(b.pos_zobrist()), to_move, passes)
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
                continue  # opponent plays only optimal moves
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
            # column 4 empty -> dame (borders both), neutral
    assert E.area_score(b) == (36, 36)


def test_area_score_counts_enclosed_territory():
    b = Board(9)
    # Black wall on column 1, White wall on column 7.
    for y in range(9):
        b.set_stone(Board.BLACK, b.loc(1, y))
        b.set_stone(Board.WHITE, b.loc(7, y))
    black, white = E.area_score(b)
    assert black == 18  # 9 stones (col 1) + 9 enclosed points (col 0)
    assert white == 18  # 9 stones (col 7) + 9 enclosed points (col 8)
    # Columns 2..6 border both colours -> dame, counted for neither.


# --------------------------------------------------------------------------- #
# Determinism.
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("difficulty", ALL_DIFFICULTIES)
@pytest.mark.parametrize("seed", SEEDS)
def test_deterministic(difficulty, seed):
    a = E.generate_endgame_puzzle(difficulty, seed)
    b = E.generate_endgame_puzzle(difficulty, seed)
    assert a.sgf == b.sgf
    assert a.best_first_moves == b.best_first_moves
    assert a.optimal_score == b.optimal_score


def test_distinct_seeds_differ():
    sgfs = {E.generate_endgame_sgf(E.Difficulty.MEDIUM, s) for s in range(8)}
    assert len(sgfs) > 1


# --------------------------------------------------------------------------- #
# SGF format.
# --------------------------------------------------------------------------- #
def test_sgf_shape():
    sgf = E.generate_endgame_sgf(E.Difficulty.HARD, 0)
    assert sgf.startswith("(;FF[4]GM[1]SZ[9]")
    assert sgf.endswith(")")
    assert "KM[7.5]" in sgf and "RU[TrompTaylor]" in sgf
    assert re.search(r"PL\[[BW]\]", sgf)
    assert "AB[" in sgf and "AW[" in sgf


def test_sgf_parses_with_sgfmill():
    sgfmill_sgf = pytest.importorskip("sgfmill.sgf")
    for d in ALL_DIFFICULTIES:
        g = sgfmill_sgf.Sgf_game.from_bytes(E.generate_endgame_sgf(d, 0).encode())
        assert g.get_size() == 9
        assert abs(g.get_komi() - 7.5) < 1e-9


@pytest.mark.parametrize("difficulty", ALL_DIFFICULTIES)
def test_sgf_roundtrips(difficulty):
    p = E.generate_endgame_puzzle(difficulty, 1)
    board, stm = board_from_sgf(p.sgf)
    reserialized = E.to_sgf(board, stm, "x")
    strip = lambda s: re.sub(r"C\[.*?\]", "", s)
    assert strip(reserialized) == strip(p.sgf)


# --------------------------------------------------------------------------- #
# Core puzzle invariants (reconstructed from SGF).
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("difficulty", ALL_DIFFICULTIES)
@pytest.mark.parametrize("seed", SEEDS)
def test_puzzle_invariants(difficulty, seed):
    p = E.generate_endgame_puzzle(difficulty, seed)
    board, stm = board_from_sgf(p.sgf)

    # Razor-thin, decisive win for the side to move.
    assert 0 < abs(p.optimal_score) < 2
    assert stm_wins(replay_optimal(board, stm), stm)
    assert (p.optimal_score > 0) == (stm == Board.BLACK)

    # Unique biggest first move.
    assert len(p.best_first_moves) == 1

    # Both frames unconditionally alive: two real eyes each.
    assert E._count_real_eyes(board, Board.BLACK) >= 2
    assert E._count_real_eyes(board, Board.WHITE) >= 2

    # Over EVERY legal first move (all empties, including eye-fills), only the
    # unique optimal door wins for the side to move.
    solver = E.EndgameSolver(E.empty_points(board))
    per = solver.evaluate_root(board, stm)
    winners = [loc for loc, v in per.items() if stm_wins(v, stm)]
    assert len(winners) == 1
    assert board.loc_to_str(winners[0]) == p.best_first_moves[0]

    # The optimal line, replayed to two passes, matches the claimed score.
    assert replay_optimal(board, stm) - E.KOMI == p.optimal_score

    # Any mistake, against best opposition, loses.
    assert mistake_always_loses(board, stm)


@pytest.mark.parametrize("difficulty", ALL_DIFFICULTIES)
def test_best_endgame_moves_helper(difficulty):
    p = E.generate_endgame_puzzle(difficulty, 2)
    board, stm = board_from_sgf(p.sgf)
    value, moves = E.best_endgame_moves(board, stm)
    assert abs(value - p.optimal_score) < 1e-9
    assert [board.loc_to_str(m) for m in moves] == p.best_first_moves


def test_difficulty_gadget_counts():
    # More difficult puzzles present more contested points (moves to order).
    def doors(d):
        board, _ = board_from_sgf(E.generate_endgame_sgf(d, 0))
        return len(E._contested_empties(board))

    assert doors(E.Difficulty.VERY_EASY) == 2
    assert doors(E.Difficulty.MEDIUM) == 3
    assert doors(E.Difficulty.HARD) == 3


# --------------------------------------------------------------------------- #
# Performance (loose bound; generation is meant to be interactive).
# --------------------------------------------------------------------------- #
def test_generation_is_fast():
    t0 = time.time()
    for d in ALL_DIFFICULTIES:
        for s in range(5):
            E.generate_endgame_puzzle(d, s)
    elapsed = time.time() - t0
    assert elapsed < 15.0, "generation too slow: %.1fs for 25 puzzles" % elapsed
