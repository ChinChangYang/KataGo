"""Offline: extract "Black to play and win by 0.5" endgame puzzles from game JSONs.

Each puzzle is a mostly-settled endgame position, always **Black to play**, with a
**per-puzzle komi** chosen so that best play wins by exactly Black+0.5 while the
**natural (highest-policy) move loses**. The exact best-play margin is the game's own
final area score (each game was played to a settled two-pass end); the amount the
natural move loses is KataGo's per-move scoreLead estimate.

Difficulty is scored from how non-obvious KataGo's best move is (low policy prior),
how tempting/costly the natural trap is, and board complexity, then mapped to
[1, 999] by percentile across the corpus. Writes ``puzzles.json``.

    python -m katago.puzzles.tools.build_corpus --games /tmp/games \
        --out katago/puzzles/games/puzzles.json
"""
import argparse
import glob
import json
import os

from katago.game.board import Board
from katago.puzzles.endgame import area_score
from katago.puzzles.tools.kata_engine import gtp_to_xy

SIZE = 9
_COLS = "ABCDEFGHJ"
MAX_UNSETTLED = 14    # endgame == mostly-settled board (yose, not middlegame)
MIN_PLY = 22
MIN_GAP = 0.30        # best must beat 2nd best by this (a genuine decision)
MIN_TRAP_COST = 1.0   # the natural move must lose at least this many points
MAX_KOMI_ABS = 12.0   # keep the per-puzzle komi in a sane range (drop blowouts)


def _replay(moves, upto):
    b = Board(SIZE)
    for color, mv in moves[:upto]:
        pla = Board.BLACK if color == "B" else Board.WHITE
        xy = gtp_to_xy(mv)
        b.play(pla, Board.PASS_LOC if xy is None else b.loc(xy[0], xy[1]))
    return b


def _final_score(moves):
    """Exact final area score S = Black - White of the settled end position."""
    bl, wh = area_score(_replay(moves, len(moves)))
    return bl - wh


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


def _candidates(game, final_s):
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
        if natural["mv"] == best["mv"]:
            continue                            # must have a genuine trap
        nat_cost = sign * (best["sl"] - natural["sl"])
        if nat_cost < MIN_TRAP_COST:
            continue                            # the tempting move must lose
        # Best play from here reaches the game's settled end -> margin S; from the
        # mover's view that is M, and komi = M - 0.5 makes best play exactly +0.5.
        M = final_s if color == "B" else -final_s
        komi = M - 0.5
        if abs(komi) > MAX_KOMI_ABS:
            continue                            # avoid absurd blowout komi
        raw = (3.0 * (1.0 - best["pr"])
               + 1.5 * (0.5 + min(nat_cost, 3.0) / 3.0)
               + 0.08 * row["unsettled"])
        out.append({
            "seed": game["seed"], "ply": row["ply"], "flip": color == "W",
            "komi": komi, "best_move": best["mv"], "natural_move": natural["mv"],
            "natural_cost": round(nat_cost, 2), "best_prior": best["pr"],
            "second_gap": round(gap, 2), "unsettled": row["unsettled"],
            "raw": round(raw, 4), "_moves": moves, "_upto": row["ply"],
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
            game = json.load(f)
        cands += _candidates(game, _final_score(game["moves"]))
    if not cands:
        raise SystemExit("no candidates found")

    cands.sort(key=lambda c: c["raw"])
    n = len(cands)
    for i, c in enumerate(cands):
        c["difficulty"] = 1 + round(998 * i / max(1, n - 1))
        bs, ws = _stones(_replay(c.pop("_moves"), c.pop("_upto")))
        if c.pop("flip"):                       # make it always Black to play
            bs, ws = ws, bs
        c["to_move"] = "B"
        c["bstones"], c["wstones"] = bs, ws
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(cands, f)
    print("wrote %d puzzles (all Black to play, win by 0.5); raw %.2f..%.2f -> %s"
          % (n, cands[0]["raw"], cands[-1]["raw"], args.out))


if __name__ == "__main__":
    main()
