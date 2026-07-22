"""Offline: play varied 9x9 games with KataGo and save per-ply endgame analysis.

Opening moves are sampled from the raw policy with temperature (variety, seeded);
the rest are KataGo's best move. Each non-opening ply records the top candidate
moves (move, scoreLead, policy prior, visits) and the count of unsettled points
(from ownership), enough to detect the endgame phase and build puzzles.

    python -m katago.puzzles.tools.gen_games \
        --katago cpp/build/katago --model cpp/tests/models/g170e-*.bin.gz \
        --config cpp/configs/analysis_example.cfg --out /tmp/games --start 0 --num 30
"""
import argparse
import json
import os
import random
import time

from katago.puzzles.tools.kata_engine import KataGo, gtp

SIZE = 9
KOMI = 7.5


def _policy_move(policy, rng, temp):
    ws = [(i, policy[i] ** (1.0 / temp)) for i in range(SIZE * SIZE)
          if policy[i] and policy[i] > 0]
    tot = sum(w for _, w in ws)
    if tot <= 0:
        return None
    r = rng.random() * tot
    acc = 0.0
    for i, w in ws:
        acc += w
        if acc >= r:
            return gtp(i % SIZE, i // SIZE)
    return None


def _unsettled(ownership, thr=0.6):
    return sum(1 for v in ownership if abs(v) < thr)


def play_game(kata, seed, opening_len=8, opening_temp=1.3,
              opening_visits=2, endgame_visits=600, max_ply=100):
    rng = random.Random("game|%d" % seed)
    moves, rows = [], []
    passes = 0
    for ply in range(max_ply):
        color = "B" if ply % 2 == 0 else "W"
        opening = ply < opening_len
        resp = kata.query({
            "moves": moves, "rules": "tromp-taylor", "komi": KOMI,
            "boardXSize": SIZE, "boardYSize": SIZE, "analyzeTurns": [len(moves)],
            "maxVisits": opening_visits if opening else endgame_visits,
            "includePolicy": opening, "includeOwnership": not opening,
        })
        mis = resp["moveInfos"]
        best = min(mis, key=lambda m: m["order"])
        if opening:
            mv = _policy_move(resp["policy"], rng, opening_temp) or best["move"]
            rows.append({"ply": ply, "color": color, "opening": True})
        else:
            mv = best["move"]
            top = sorted(mis, key=lambda m: m["order"])[:8]
            rows.append({
                "ply": ply, "color": color, "opening": False,
                "unsettled": _unsettled(resp.get("ownership", [])),
                "mis": [{"mv": m["move"], "sl": round(m["scoreLead"], 3),
                         "pr": round(m.get("prior", 0.0), 4), "v": m["visits"]}
                        for m in top],
            })
        moves.append([color, mv])
        passes = passes + 1 if mv == "pass" else 0
        if passes >= 2:
            break
    return {"seed": seed, "komi": KOMI, "size": SIZE, "moves": moves, "rows": rows}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--katago", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--out", required=True, help="directory for game JSONs")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--num", type=int, default=30)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    kata = KataGo(args.katago, args.config, args.model)
    t0 = time.time()
    try:
        for seed in range(args.start, args.start + args.num):
            fn = os.path.join(args.out, "game_%04d.json" % seed)
            if os.path.exists(fn):
                continue
            t = time.time()
            game = play_game(kata, seed)
            with open(fn, "w") as f:
                json.dump(game, f)
            print("game %d: %d plies %.0fs (total %.0fs)"
                  % (seed, len(game["moves"]), time.time() - t, time.time() - t0),
                  flush=True)
    finally:
        kata.close()
    print("DONE in %.0fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
