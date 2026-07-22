"""Offline: extract endgame puzzles from game JSONs and calibrate difficulty.

A candidate puzzle is an endgame position (mostly-settled board, past the opening)
with a real decision (best move clearly beats the 2nd best). Difficulty is scored
from how non-obvious KataGo's best move is (low policy prior), whether the natural
(highest-prior) move is a costly trap, and board complexity; scores are ranked
across the corpus and mapped to [1, 999] by percentile. Writes ``puzzles.json``.

    python -m katago.puzzles.tools.build_corpus --games /tmp/games \
        --out katago/puzzles/games/puzzles.json
"""
import argparse
import glob
import json
import os

from katago.game.board import Board
from katago.puzzles.tools.kata_engine import gtp_to_xy

SIZE = 9
_COLS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
MAX_UNSETTLED = 14   # endgame == mostly-settled board (yose, not middlegame)
MIN_PLY = 22
MIN_GAP = 0.30       # best must beat 2nd best by this (a genuine decision)


def _replay(moves, upto):
    b = Board(SIZE)
    for color, mv in moves[:upto]:
        pla = Board.BLACK if color == "B" else Board.WHITE
        xy = gtp_to_xy(mv)
        b.play(pla, Board.PASS_LOC if xy is None else b.loc(xy[0], xy[1]))
    return b


def _stones(board):
    bs, ws = [], []
    for y in range(SIZE):
        for x in range(SIZE):
            c = int(board.board[board.loc(x, y)])
            if c == Board.BLACK:
                bs.append(_COLS[x] + str(SIZE - y))
            elif c == Board.WHITE:
                ws.append(_COLS[x] + str(SIZE - y))
    return bs, ws


def _candidates(game):
    out = []
    moves = game["moves"]
    for row in game["rows"]:
        if row.get("opening") or row["ply"] < MIN_PLY:
            continue
        mis = row["mis"]
        if len(mis) < 2 or row["unsettled"] > MAX_UNSETTLED:
            continue
        color = row["color"]
        sign = 1 if color == "B" else -1        # mover maximises sign*scoreLead
        ranked = sorted(mis, key=lambda m: -sign * m["sl"])
        best, second = ranked[0], ranked[1]
        if best["mv"] == "pass":
            continue
        gap = sign * (best["sl"] - second["sl"])
        if gap < MIN_GAP:
            continue
        natural = max(mis, key=lambda m: m["pr"])
        is_trap = natural["mv"] != best["mv"]
        nat_cost = sign * (best["sl"] - natural["sl"]) if is_trap else 0.0
        raw = (3.0 * (1.0 - best["pr"])
               + (1.5 * (0.5 + min(nat_cost, 3.0) / 3.0) if is_trap else 0.0)
               + 0.08 * row["unsettled"])
        out.append({
            "seed": game["seed"], "ply": row["ply"], "to_move": color,
            "best_move": best["mv"], "best_black_lead": round(best["sl"], 2),
            "best_prior": best["pr"], "second_gap": round(gap, 2),
            "natural_move": natural["mv"], "natural_cost": round(max(nat_cost, 0.0), 2),
            "unsettled": row["unsettled"], "raw": round(raw, 4),
            "_moves": moves, "_upto": row["ply"],
        })
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--games", required=True, help="directory of game JSONs")
    ap.add_argument("--out", required=True, help="output puzzles.json path")
    args = ap.parse_args()

    cands = []
    for fn in sorted(glob.glob(os.path.join(args.games, "game_*.json"))):
        with open(fn) as f:
            cands += _candidates(json.load(f))
    if not cands:
        raise SystemExit("no candidates found")
    cands.sort(key=lambda c: c["raw"])
    n = len(cands)
    for i, c in enumerate(cands):
        c["difficulty"] = 1 + round(998 * i / max(1, n - 1))
        bs, ws = _stones(_replay(c.pop("_moves"), c.pop("_upto")))
        c["bstones"], c["wstones"] = bs, ws
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(cands, f)
    print("wrote %d puzzles from raw range %.2f..%.2f -> %s"
          % (n, cands[0]["raw"], cands[-1]["raw"], args.out))


if __name__ == "__main__":
    main()
