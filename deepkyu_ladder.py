#!/usr/bin/env python3
"""Campaign driver for the deep-kyu even-game ladder (14k anchor -> 25k).

State lives in <run>/ladder.json:
  anchor : the shipped gtp_human14k.cfg bot, never modified
  ranks  : 15k..25k, each with its weakening dial x and lock state
  curve  : measured W(x) (ELO of weakening vs the x=0 config), as (x, W) points

Rung r is (rank r-1) vs (rank r); its target gap is +100 with a 95% CI inside [70,130].
A correction moves ONLY the weaker rank's dial: if rung r measures g, that rank needs
(100 - g) more ELO of weakening, i.e. W_target = W(x_r) + (100 - g), inverted through the curve.

Subcommands: status | cfg | propose | set | curve
"""
import argparse, json, math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deepkyu_cfg as dc
import deepkyu_tally as dt

RUN = os.environ.get("DEEPKYU_RUN", os.path.expanduser("~/.katago_tune/deepkyu"))
STATE = os.path.join(RUN, "ladder.json")
# Natural gaps measured by the previous calibration at 40 visits (docs/HumanSL_Rank_Ladder.md).
# Used only as the prior when estimating the ladder-wide curve gain.
PRIOR_G = {"15k": 29.0, "16k": 24.0, "17k": 44.0, "18k": 70.0, "19k": 32.0, "20k": 8.0,
           "21k": 23.0, "22k": 29.0, "23k": -1.0, "24k": 55.0, "25k": 86.0}
# Per-rank response scale: the fraction of the shared W(x) curve that this profile actually realises.
# Anchored on THREE directly measured points rather than an interpolation between two, after the
# placed-span measurement showed a linear interpolation is wrong in shape. Measured at the placed
# dials (172 games/pair): the 15k->20k dial contribution is 118 ELO where the old model said 352,
# and 20k->25k is 484 where it said 205. Solving those against the shared curve gives
# c(15k)=1.00 (its own probe defines the curve), c(20k)=0.32, c(25k)=0.41 -- i.e. the response
# collapses quickly from 15k to about 19k and is then roughly flat, not linear to 25k.
RANK_C = {"15k": 1.00, "16k": 0.75, "17k": 0.55, "18k": 0.42, "19k": 0.36, "20k": 0.32,
          "21k": 0.33, "22k": 0.35, "23k": 0.37, "24k": 0.39, "25k": 0.41}
X_FLOOR = -0.65  # early temp 0.05: the sharpest end of the dial
RANKS = ["15k", "16k", "17k", "18k", "19k", "20k", "21k", "22k", "23k", "24k", "25k"]

DEFAULT_STATE = {
    "anchor": {"rank": "14k", "profile": "preaz_14k", "lam": "3.40040", "maxVisits": 40,
               "searchThreads": 8, "sym": 2, "early": 0.70, "late": 0.25, "halflife": 30},
    "ranks": [{"rank": r, "x": 0.0, "locked": False} for r in RANKS],
    # W(x): ELO by which dial x weakens a rank relative to its own x=0 config. Seeded from the
    # 15k self-pair chain probe; refined by `curve` as more games land.
    "curve": [[0.0, 0.0], [1.0, 100.0], [2.0, 200.0], [3.0, 300.0], [4.3, 430.0],
              [5.5, 550.0], [7.0, 700.0]],
}


def load():
    if os.path.exists(STATE):
        return json.load(open(STATE))
    return json.loads(json.dumps(DEFAULT_STATE))


def save(st):
    os.makedirs(RUN, exist_ok=True)
    json.dump(st, open(STATE, "w"), indent=1)


def rank_c(st, rank):
    return float(st.get("rank_c", {}).get(rank, RANK_C.get(rank, 1.0)))


def w_of_rank(st, rank, x):
    """ELO of weakening this particular rank gets at dial x."""
    return rank_c(st, rank) * w_of_x(st, x)


def x_of_w_rank(st, rank, w):
    """Inverse: the dial that gives this rank w ELO of weakening."""
    c = rank_c(st, rank)
    return x_of_w(st, w / max(0.05, c))


def w_of_x(st, x):
    pts = st["curve"]
    if x <= pts[0][0]:                        # below x=0 the dial SHARPENS: extrapolate, don't clamp
        (x0, w0), (x1, w1) = pts[0], pts[1]
        return w0 + (w1 - w0) / (x1 - x0) * (x - x0)
    for (x0, w0), (x1, w1) in zip(pts, pts[1:]):
        if x <= x1:
            return w0 + (w1 - w0) * (x - x0) / (x1 - x0)
    (x0, w0), (x1, w1) = pts[-2], pts[-1]
    slope = (w1 - w0) / (x1 - x0)
    return w1 + slope * (x - x1)


def x_of_w(st, w):
    pts = st["curve"]
    if w <= pts[0][1]:
        (x0, w0), (x1, w1) = pts[0], pts[1]
        return x0 + (x1 - x0) / (w1 - w0) * (w - w0)
    for (x0, w0), (x1, w1) in zip(pts, pts[1:]):
        if w <= w1:
            return x0 + (x1 - x0) * (w - w0) / (w1 - w0)
    (x0, w0), (x1, w1) = pts[-2], pts[-1]
    slope = (x1 - x0) / (w1 - w0)
    return x1 + slope * (w - w1)


def bots(st):
    """Anchor + every rank at its current dial, as resolved deepkyu_cfg bot specs."""
    out = [dc.resolve(dict(st["anchor"]))]
    for r in st["ranks"]:
        out.append(dc.resolve({"rank": r["rank"], "maxVisits": 1, "x": r["x"], "sym": 1}))
    return out


def rungs(st):
    """[(stronger bot name, weaker bot name, weaker rank), ...] top-down."""
    bs = bots(st)
    return [(bs[i]["name"], bs[i + 1]["name"], bs[i + 1]["rank"]) for i in range(len(bs) - 1)]


def sgf_dir():
    return os.path.join(RUN, "sgfs", "ladder")


def tally(st):
    totals, nfiles = dt.scan([sgf_dir()], os.path.join(RUN, "cache_ladder.json"))
    return [dt.pair_stats(totals, s, w) for s, w, _r in rungs(st)], nfiles


def cmd_status(st, a):
    rows, nfiles = tally(st)
    print("%-3s %-22s %-22s %6s %6s %8s %-18s %5s %5s %s"
          % ("#", "stronger", "weaker", "N", "wr%", "gap", "95% CI", "nores", "avgmv", "status"))
    ncert = 0
    for i, (row, (_s, _w, rank)) in enumerate(zip(rows, rungs(st))):
        x = st["ranks"][i]["x"]
        if row["decided"] == 0:
            print("%-3d %-22s %-22s %6d %6s %8s %-18s %5d %5s x=%.2f no games"
                  % (i + 1, row["strong"], row["weak"], 0, "-", "-", "-", row["noresult"], "-", x))
            continue
        # NOT `need~N`. That was games_needed() over the gap posterior -- the ONE-SIDED cost,
        # "games until the interval fits inside [70,130]". The rule in force also requires the
        # interval to CONTAIN 100, which bounds the half-width BELOW as well as above, so there
        # is no such N: for a true gap of 90 no sample size certifies with certainty (the truth
        # is P = 0.71) and for a bucket off centre more games make a certificate LESS likely.
        # The live rung 4 printed `need~19066` for a dial whose P(ever certify) was 0.001.
        # What replaces it is true under the rule actually in force: the probability, and the
        # games it takes in the worlds where it happens.
        stat = dt.outlook_str(dt.cert_outlook(row["weak_wins"] + 0.5 * row["draws"],
                                              row["decided"]))
        ncert += 1 if row["certified"] else 0
        print("%-3d %-22s %-22s %6d %6.1f %+8.1f [%+6.1f,%+6.1f] %5d %5.0f x=%.2f %s"
              % (i + 1, row["strong"], row["weak"], row["decided"], 100 * row["winrate"],
                 row["gap"], row["lo"], row["hi"], row["noresult"], row["avg_moves"], x, stat))
    print("\nfiles=%d  CERTIFIED %d/%d  band [%g,%g]" % (nfiles, ncert, len(rows), dt.BAND_LO, dt.BAND_HI))
    print("GOAL_MET=%d" % (1 if ncert == len(rows) else 0))
    return rows


def cmd_cfg(st, a):
    bs = bots(st)
    rg = rungs(st)
    which = [int(t) for t in a.rungs.split(",")] if a.rungs else list(range(1, len(rg) + 1))
    pairs = [(rg[i - 1][0], rg[i - 1][1]) for i in which]
    # No thread cap. The 37 GB deadlock that first looked like a thread-count problem was entirely
    # nnMaxBatchSize (32 or 16 -> 36 GB -> swap thrash -> 0 games/h); at batch 8 the anchor rung
    # measures 33.3 games/h at 12 game threads and 11 GB, vs 31 games/h and 18 GB at 4 -- more
    # threads is better on BOTH axes. Note a rung-1 game runs ~8-20 min, so any throughput window
    # shorter than that reads 0 games regardless of the true rate; measure over >=18 min.
    text = dc.build(bs, pairs, a.game_threads, a.nn_batch, a.games_total, dc.MAIN_MODEL,
                    fp32=True, nn_cache_pow=21, nn_server_threads=a.nn_server_threads)
    open(a.out, "w").write(text)
    print("wrote %s: %d bots, rungs %s" % (a.out, len(bs), which), file=sys.stderr)
    for i in which:
        print("  rung %d: %s vs %s" % (i, rg[i - 1][0], rg[i - 1][1]), file=sys.stderr)


def cmd_propose(st, a):
    rows, _ = tally(st)
    print("%-3s %-6s %6s %8s %10s %8s %8s" % ("#", "rank", "N", "gap", "W now", "W want", "x new"))
    for i, row in enumerate(rows):
        rk = st["ranks"][i]
        if row["decided"] < a.min_games:
            print("%-3d %-6s %6d %8s %10s %8s %8s (need >=%d games)"
                  % (i + 1, rk["rank"], row["decided"], "-", "-", "-", "-", a.min_games))
            continue
        wnow = w_of_x(st, rk["x"])
        want = wnow + (target_gap_for(st, i) - row["gap"])
        xnew = max(X_FLOOR, x_of_w(st, want))
        flag = "" if abs(row["gap"] - 100.0) > a.deadband else "  (within deadband, keep)"
        print("%-3d %-6s %6d %+8.1f %10.1f %8.1f %8.3f%s"
              % (i + 1, rk["rank"], row["decided"], row["gap"], wnow, want, xnew, flag))


ELO_PER_LOGIT = 400.0 / math.log(10.0)   # 173.7178


def _hist(st, rank):
    """Every dial this rank has ever been set to, current one last."""
    h = st.setdefault("history", {}).setdefault(rank, [])
    cur = [r["x"] for r in st["ranks"] if r["rank"] == rank][0]
    out, seen = [], set()
    for x in list(h) + [cur]:                 # dedupe: a repeated dial is ONE bucket of games
        k = round(float(x), 6)
        if k not in seen:
            seen.add(k); out.append(float(x))
    st["history"][rank] = out
    return out


def fit_rung(st, totals, i, min_gain_games=60, zero_only=False):
    """(g, c) for rung i: gap = g + c * [W(x_weak) - W(x_strong)].

    g is the rung's NATURAL gap (both ranks at dial 0); c is how much steeper the real response is
    than the shared W curve. Both are dial-invariant, so a dial move never discards knowledge --
    the games just sit at a different point on the W axis. c needs two well-sampled dial spreads
    to be identifiable; otherwise it takes the ladder-wide value from `gain`.
    """
    rank = st["ranks"][i]["rank"]
    samples = _rung_samples(st, totals, i)
    if zero_only:
        # Use only games where both ranks sat at the same dial: there gap == g exactly, with no
        # dependence on the W curve being right. Keeps the first placement model-free.
        samples = [s0 for s0 in samples if abs(s0[0]) < 5.0]
    if not samples:
        return None
    dWs = sorted(set(round(s0[0], 3) for s0 in samples if s0[2] >= min_gain_games))
    fit_c = len(dWs) >= 2 and (max(dWs) - min(dWs)) > 40.0
    c = float(st.get("gain_c", 1.0))
    if fit_c:
        lo, hi = 0.15, 8.0
        for _ in range(80):
            m1 = lo + 0.382 * (hi - lo); m2 = lo + 0.618 * (hi - lo)
            if _nll(samples, _profile_g(samples, m1), m1) < _nll(samples, _profile_g(samples, m2), m2):
                hi = m2
            else:
                lo = m1
        c = 0.5 * (lo + hi)
    g = _profile_g(samples, c)
    fisher = 0.0
    for dW, _w, n, _x in samples:
        z = max(-30.0, min(30.0, -(g + c * dW) / ELO_PER_LOGIT))
        pp = 1.0 / (1.0 + math.exp(-z))
        fisher += n * pp * (1 - pp) / (ELO_PER_LOGIT ** 2)
    se = float("inf") if fisher <= 0 else 1.0 / math.sqrt(fisher)
    Wstrong_now = 0.0 if i == 0 else w_of_rank(st, st["ranks"][i - 1]["rank"], st["ranks"][i - 1]["x"])
    return {"K": g + c * (w_of_rank(st, rank, st["ranks"][i]["x"]) - Wstrong_now), "g": g, "c": c,
            "fit_c": fit_c, "se": se, "n": sum(s0[2] for s0 in samples), "samples": samples,
            "Wstrong": Wstrong_now}


def cmd_fit(st, a):
    totals, _ = dt.scan([sgf_dir()], os.path.join(RUN, "cache_ladder.json"))
    print("%-3s %-6s %6s %9s %8s %9s %8s  %s" % ("#", "rank", "N", "K", "±95%", "gap@x", "x new", "dials used"))
    for i in range(len(st["ranks"])):
        f = fit_rung(st, totals, i)
        rk = st["ranks"][i]
        if f is None:
            print("%-3d %-6s %6d %9s %8s %9s %8s" % (i + 1, rk["rank"], 0, "-", "-", "-", "-")); continue
        gap_now = f["K"]          # K already carries the dial term for the CURRENT dials
        Wprev = 0.0 if i == 0 else w_of_rank(st, st["ranks"][i - 1]["rank"], st["ranks"][i - 1]["x"])
        xnew = max(X_FLOOR, x_of_w_rank(st, rk["rank"],
                                        Wprev + (target_gap(st) - f["g"]) / max(0.15, f["c"])))
        print("%-3d %-6s %6d %+9.1f %8.1f %+9.1f %8.3f  %s"
              % (i + 1, rk["rank"], f["n"], f["g"], 1.96 * f["se"], gap_now, xnew,
                 ",".join("%.2f(%d)" % (s[3], s[2]) for s in f["samples"])))


def target_gap_for(st, i):
    """Per-rung target. The rungs do NOT have to share a step: each only needs its own CI inside
    [70,130], and they have very different per-game costs (rung 1 plays the 40-visit 14k anchor at
    ~86 games/h against ~500 for the rest). Cost is convex in |gap-100|, so the exact optimum gives
    the EXPENSIVE rung the gap nearest 100 and compresses the cheap ones: 127 h against 147 h for a
    uniform step."""
    tg = st.get("targets")
    if isinstance(tg, list) and i < len(tg):
        return float(tg[i])
    return target_gap(st)


def target_gap(st):
    """The per-rung step this ladder is being built to. The goal is a 95% CI inside [70,130], not
    a gap of exactly 100, so when the deep end's reachable range cannot afford 100 the whole ladder
    is built to a smaller uniform step -- which keeps every rung equally far from the band edges
    and therefore equally cheap to certify."""
    return float(st.get("target", 100.0))


def cmd_rescale(st, a):
    """Rescale every rank's weakening by one factor so the whole 15k->25k ladder spans 10*target.

    Measuring the placed ladder end-to-end (15k vs 20k vs 25k at their current dials) is far less
    noisy than summing ten rungs, and the total span is what the per-rung step follows from:
        span = sum(natural gaps) + W_25k - W_15k
    so scaling the dial-induced part by k lands the span on 10*target without needing each rung's
    natural gap to be known.
    """
    ranks = [r["rank"] for r in st["ranks"]]
    Ws = [w_of_rank(st, r["rank"], r["x"]) for r in st["ranks"]]
    spread = Ws[-1] - Ws[0]
    measured = float(a.measured_span)
    want = 10.0 * target_gap(st)
    k = (want - measured + spread) / spread if spread > 0 else 1.0
    print("placed spread (W_25k - W_15k) = %.0f, measured span = %.0f, want %.0f -> scale %.3f"
          % (spread, measured, want, k))
    print("%-6s %9s %9s %9s %9s" % ("rank", "W old", "W new", "x old", "x new"))
    for rk, W in zip(st["ranks"], Ws):
        Wnew = Ws[0] + k * (W - Ws[0])
        wmax = w_of_rank(st, rk["rank"], a.max_x)
        x = max(X_FLOOR, min(a.max_x, x_of_w_rank(st, rk["rank"], Wnew)))
        print("%-6s %9.0f %9.0f %9.3f %9.3f%s" % (rk["rank"], W, Wnew, rk["x"], x,
                                                  "  OVER FLOOR" if Wnew > wmax + 1 else ""))
        if a.apply:
            rk["x"] = round(x, 4); _hist(st, rk["rank"])
    if a.apply:
        save(st); print("applied")


def cmd_target(st, a):
    if "," in a.value:
        st["targets"] = [float(v) for v in a.value.split(",")]
        st["target"] = sum(st["targets"]) / len(st["targets"])
        save(st)
        for i, t in enumerate(st["targets"]):
            print("  rung %-2d target %5.1f -> %5d games (the CONTAINMENT half only; see "
                  "`status` for" % (i + 1, t, dt.games_needed(t)))
            print("             the two-sided outlook, which is a probability, not a count)")
        return
    st["target"] = float(a.value); st.pop("targets", None); save(st)
    n = dt.games_needed(st["target"])
    print("per-rung target %.1f ELO -> %s games/rung for a 90%% chance the 95%% CI FITS inside "
          "[%g,%g]" % (st["target"], n, dt.BAND_LO, dt.BAND_HI))
    print("  (the CONTAINMENT half only -- the rule also requires the interval to contain %g, "
          "which no" % dt.BAND_MID)
    print("   single N delivers. `status` prints the two-sided outlook per rung.)")


def cmd_sweep(st, a):
    """Re-anchor the whole chain top-down from the current natural-gap estimates.

    Each rung's g is dial-invariant, so once g is known the dial follows:
        W(x_r) = 100 - g_r + W(x_{r-1}),  with the 14k anchor at W = 0.
    Applied in order, so every rank is placed against its already-updated stronger neighbour.
    A rank with too few games keeps its current dial (its g is not yet worth acting on).
    """
    totals, _ = dt.scan([sgf_dir()], os.path.join(RUN, "cache_ladder.json"))
    print("%-3s %-6s %6s %9s %8s %9s %9s %8s" % ("#", "rank", "N", "g", "±95%", "x old", "x new", "move"))
    Wprev = 0.0
    for i in range(len(st["ranks"])):
        rk = st["ranks"][i]
        f = fit_rung(st, totals, i, zero_only=a.zero_only)
        xold = rk["x"]
        if f is None or f["n"] < a.min_games or not (f["se"] < a.max_se):
            print("%-3d %-6s %6s %9s %8s %9.3f %9s %8s"
                  % (i + 1, rk["rank"], f["n"] if f else 0, "-", "-", xold, "(keep)", "-"))
            Wprev = w_of_rank(st, rk["rank"], xold)
            continue
        # W(x) that puts this rung at +100, given the stronger rank's updated dial and this
        # rank's own measured curve gain c.
        Wtarget = Wprev + (target_gap_for(st, i) - f["g"]) / max(0.15, f["c"])   # in this rank's own ELO
        if not f["fit_c"] and not st.get("gain_c"):
            # c unknown: damp, because the shared curve's slope has been seen to be 2-3x off for
            # the deep ranks and an undamped step would oscillate.
            Wnow = w_of_rank(st, rk["rank"], xold)
            Wtarget = Wnow + a.gain * (Wtarget - Wnow)
        # Deadband: moving a dial discards that rank's certification games, so ignore a move
        # smaller than the measurement can justify.
        if abs(Wtarget - w_of_rank(st, rk["rank"], xold)) < a.deadband:
            print("%-3d %-6s %6d %+9.1f %8.1f %9.3f %9s %8s"
                  % (i + 1, rk["rank"], f["n"], f["g"], 1.96 * f["se"], xold, "(hold)", "-"))
            Wprev = w_of_rank(st, rk["rank"], xold)
            continue
        wmax = w_of_rank(st, rk["rank"], a.max_x)
        over = Wtarget > wmax + 1e-6      # target is below this profile's reachable floor
        xnew = max(X_FLOOR, min(a.max_x, x_of_w_rank(st, rk["rank"], Wtarget)))
        print("%-3d %-6s %6d %+9.1f %8.1f %9.3f %9.3f %+8.3f  c=%.2f%s%s"
              % (i + 1, rk["rank"], f["n"], f["g"], 1.96 * f["se"], xold, xnew, xnew - xold,
                 f["c"], "" if f["fit_c"] else " (damped)",
                 "  OVER FLOOR by %.0f" % (Wtarget - wmax) if over else ""))
        if a.apply:
            rk["x"] = round(xnew, 4)
            _hist(st, rk["rank"])
        Wprev = w_of_rank(st, rk["rank"], rk["x"])
    if a.apply:
        save(st)
        print("applied")


def _rung_samples(st, totals, i):
    """[(dW, wins, games, x_weak)] for rung i, over every dial pair either side has ever used."""
    rank = st["ranks"][i]["rank"]
    if i == 0:
        strong_dials = [(0.0, bots(st)[0]["name"])]
    else:
        srank = st["ranks"][i - 1]["rank"]
        strong_dials = [(w_of_rank(st, srank, x),
                         dc.resolve({"rank": srank, "maxVisits": 1, "x": x, "sym": 1})["name"])
                        for x in _hist(st, srank)]
    out = []
    for x in _hist(st, rank):
        wb = dc.resolve({"rank": rank, "maxVisits": 1, "x": x, "sym": 1})
        for Ws, sname in strong_dials:
            r = dt.pair_stats(totals, sname, wb["name"])
            if r["decided"] > 0:
                out.append((w_of_rank(st, rank, x) - Ws, r["weak_wins"] + 0.5 * r["draws"],
                            r["decided"], x))
    return out


def _nll(samples, g, c):
    t = 0.0
    for dW, w, n, _x in samples:
        z = max(-30.0, min(30.0, -(g + c * dW) / ELO_PER_LOGIT))
        pp = min(max(1.0 / (1.0 + math.exp(-z)), 1e-12), 1 - 1e-12)
        t -= w * math.log(pp) + (n - w) * math.log(1 - pp)
    return t


def _profile_g(samples, c):
    lo, hi = -3000.0, 3000.0
    for _ in range(160):
        m1 = lo + 0.382 * (hi - lo); m2 = lo + 0.618 * (hi - lo)
        if _nll(samples, m1, c) < _nll(samples, m2, c): hi = m2
        else: lo = m1
    return 0.5 * (lo + hi)


def cmd_sweep_up(st, a):
    """Place the chain BOTTOM-UP: pin the weakest rank at the dial family's maximum and work
    upward. Top-down placement spends the budget from the top and can run the deepest rank past
    its floor; bottom-up guarantees the deep end is reachable and lets any slack accumulate at the
    top, where 15k still has ~1900 ELO of range. The 14k seam then lands where it lands.
    """
    totals, _ = dt.scan([sgf_dir()], os.path.join(RUN, "cache_ladder.json"))
    n = len(st["ranks"])
    gs = []
    for i in range(n):
        f = fit_rung(st, totals, i, zero_only=a.zero_only)
        gs.append(None if f is None or f["n"] < a.min_games else f["g"])
    if any(g is None for g in gs[1:]):
        print("need a natural-gap estimate for every rung below 15k first (missing: %s)"
              % ", ".join(st["ranks"][i]["rank"] for i in range(1, n) if gs[i] is None))
        return
    W = [0.0] * n
    W[n - 1] = w_of_rank(st, st["ranks"][n - 1]["rank"], a.max_x)      # deepest rank at the floor
    for i in range(n - 1, 0, -1):
        W[i - 1] = W[i] + gs[i] - target_gap_for(st, i)                       # own-ELO weakening
    print("%-3s %-6s %9s %10s %10s %9s" % ("#", "rank", "g", "W own", "x new", "max W"))
    for i in range(n):
        rk = st["ranks"][i]
        wmax = w_of_rank(st, rk["rank"], a.max_x)
        x = max(X_FLOOR, x_of_w_rank(st, rk["rank"], W[i]))
        flag = "" if W[i] <= wmax + 1e-6 else "  OVER FLOOR"
        print("%-3d %-6s %9s %10.0f %10.3f %9.0f%s"
              % (i + 1, rk["rank"], "-" if gs[i] is None else "%+.0f" % gs[i], W[i], x, wmax, flag))
        if a.apply:
            rk["x"] = round(x, 4); _hist(st, rk["rank"])
    if a.apply:
        save(st); print("applied")


def cmd_nudge(st, a):
    """Model-free chain correction, propagated bottom-up from the MEASURED gaps.

    For rung r (rank r-1 vs rank r), gap = g_r + W_r - W_{r-1} in own-ELO. Whatever g_r and the
    response curve really are, they cancel:

        W_{r-1}_new = W_r_new + (gap_measured - T) - (W_r_old - W_{r-1}_old)

    so each rank is shifted by exactly the error its own rung measured. The curve is used only to
    turn a W back into a dial, and only locally. The deepest rank is held (it sits near its floor),
    so the accumulated drift lands on the shallow end, where 15k still has ~1700 ELO of range.
    """
    totals, _ = dt.scan([sgf_dir()], os.path.join(RUN, "cache_ladder.json"))
    rg = rungs(st)
    n = len(st["ranks"])
    Wold = [w_of_rank(st, r["rank"], r["x"]) for r in st["ranks"]]
    Wnew = list(Wold)
    rows = []
    for i in range(n - 1, 0, -1):                     # rung i is (rank i-1 vs rank i)
        strong, weak, _ = rg[i]
        r = dt.pair_stats(totals, strong, weak)
        if r["decided"] < a.min_games:
            rows.append((i, r["decided"], None)); continue
        Wnew[i - 1] = Wnew[i] + (r["gap"] - target_gap_for(st, i)) - (Wold[i] - Wold[i - 1])
        rows.append((i, r["decided"], r["gap"]))
    print("%-3s %-6s %6s %8s %9s %9s %8s %8s" % ("#", "rank", "N", "gap", "W old", "W new", "x old", "x new"))
    for i in range(n):
        rk = st["ranks"][i]
        meas = next((g for (j, _n, g) in rows if j == i + 1), None)
        wmax = w_of_rank(st, rk["rank"], a.max_x)
        x = max(X_FLOOR, min(a.max_x, x_of_w_rank(st, rk["rank"], Wnew[i])))
        print("%-3d %-6s %6s %8s %9.0f %9.0f %8.3f %8.3f%s"
              % (i + 1, rk["rank"], "-", "-" if meas is None else "%+.0f" % meas,
                 Wold[i], Wnew[i], rk["x"], x, "  OVER FLOOR" if Wnew[i] > wmax else ""))
        if a.apply and abs(Wnew[i] - Wold[i]) > a.deadband:
            rk["x"] = round(x, 4); _hist(st, rk["rank"])
    if a.apply:
        save(st); print("applied")


def cmd_gain(st, a):
    """Joint MLE of the ladder-wide curve gain c (how much steeper the true response is than the
    shared W curve), with every rung's natural gap g profiled out. Identified by rungs that have
    games at two or more dial spreads -- e.g. the zero map (dW = 0) plus the working dials."""
    totals, _ = dt.scan([sgf_dir()], os.path.join(RUN, "cache_ladder.json"))
    per = []
    for i in range(len(st["ranks"])):
        sm = _rung_samples(st, totals, i)
        if sum(x[2] for x in sm) >= a.min_games:
            per.append((i, sm))
    spread = [len(set(round(x[0], 1) for x in sm)) for _i, sm in per]
    print("rungs with data: %d, of which %d have >=2 dial spreads"
          % (len(per), sum(1 for v in spread if v >= 2)))
    if not per:
        print("no data"); return

    def total_nll(c):
        return sum(_nll(sm, _profile_g(sm, c), c) for _i, sm in per)

    lo, hi = 0.15, 6.0
    for _ in range(70):
        m1 = lo + 0.382 * (hi - lo); m2 = lo + 0.618 * (hi - lo)
        if total_nll(m1) < total_nll(m2): hi = m2
        else: lo = m1
    c = 0.5 * (lo + hi)
    # crude CI: the c values where the profile deviance rises by 3.84
    base = total_nll(c); loC = hiC = c
    while loC > 0.16 and total_nll(loC) - base < 1.92: loC -= 0.05
    while hiC < 5.9 and total_nll(hiC) - base < 1.92: hiC += 0.05
    print("\nladder-wide curve gain c = %.2f  95%% ~[%.2f, %.2f]   (1.0 = the W curve is right)" % (c, loC, hiC))
    print("%-3s %-6s %7s %9s  %s" % ("#", "rank", "N", "g", "dial spreads (games)"))
    for i, sm in per:
        g = _profile_g(sm, c)
        print("%-3d %-6s %7d %+9.1f  %s" % (i + 1, st["ranks"][i]["rank"], sum(x[2] for x in sm), g,
              ", ".join("dW=%.0f(%d)" % (x[0], x[2]) for x in sm)))
    if a.apply:
        st["gain_c"] = round(c, 3); save(st); print("applied gain_c=%.3f" % c)


def cmd_plan(st, a):
    """One recommended action per rung: GRIND (keep playing at this dial), CORRECT (dial is
    off far enough that grinding cannot reach the band), or DONE."""
    rows, _ = tally(st)
    print("%-3s %-6s %6s %8s %-18s %7s  %s" % ("#", "rank", "N", "gap", "95% CI", "x", "action"))
    todo = []
    for i, row in enumerate(rows):
        rk = st["ranks"][i]
        x = rk["x"]
        if row["decided"] == 0:
            print("%-3d %-6s %6d %8s %-18s %7.3f  GRIND (no games)" % (i + 1, rk["rank"], 0, "-", "-", x))
            todo.append(i + 1); continue
        ci = "[%+6.1f,%+6.1f]" % (row["lo"], row["hi"])
        if row["certified"]:
            print("%-3d %-6s %6d %+8.1f %-18s %7.3f  DONE" % (i + 1, rk["rank"], row["decided"], row["gap"], ci, x))
            continue
        # WHAT `remaining` IS NOW, AND WHY IT CHANGED. It used to be need_median() minus the
        # banked games: the ONE-SIDED cost ("games until the interval fits inside [70,130]")
        # minus a bank credited at face value. Both halves were wrong under the rule in force.
        # The rule also requires the interval to CONTAIN 100, so there is no N at which a rung
        # certifies -- the honest answer is a probability -- and subtracting the bank credits
        # games that may have pushed the estimate OFF centre, where more games hurt. The live
        # rung 4 read `GRIND (>=14098 more)` for a dial whose P(ever certify) was 0.001.
        #
        # cert_outlook() simulates the two-sided rule forward from the realised (w, n) over the
        # bucket's own gap posterior, so `remaining` is now a MEDIAN CONDITIONAL ON CERTIFYING
        # and comes with the probability it is conditional on. It is None exactly when that
        # condition is too rare to plan around (dt.PCERT_LIVE), which is the same None the
        # CORRECT branch already keyed on -- so the branch is unchanged, only the number that
        # feeds it is true. ACTIVE is identical either way: both branches are advisory text.
        ol = dt.cert_outlook(row["weak_wins"] + 0.5 * row["draws"], row["decided"])
        remaining = ol["med_more"]
        if row["decided"] < a.min_games or (remaining is not None and remaining <= a.max_games):
            print("%-3d %-6s %6d %+8.1f %-18s %7.3f  GRIND (%s)"
                  % (i + 1, rk["rank"], row["decided"], row["gap"], ci, x,
                     dt.outlook_str(ol)))
            todo.append(i + 1)
        else:
            want = w_of_x(st, x) + (target_gap_for(st, i) - row["gap"])
            xnew = max(X_FLOOR, x_of_w(st, want))
            print("%-3d %-6s %6d %+8.1f %-18s %7.3f  CORRECT -> x=%.3f  (%s)"
                  % (i + 1, rk["rank"], row["decided"], row["gap"], ci, x, xnew,
                     dt.outlook_str(ol)))
            todo.append(i + 1)
    print("ACTIVE=%s" % ",".join(str(t) for t in todo))


def cmd_set(st, a):
    for tok in a.assign.split(","):
        rank, val = tok.split("=")
        for r in st["ranks"]:
            if r["rank"] == rank.strip():
                _hist(st, r["rank"])          # record the dial being replaced
                r["x"] = float(val)
                _hist(st, r["rank"])          # and the new one
                print("%s -> x=%.4f" % (rank, r["x"]))
    save(st)


def cmd_curve(st, a):
    st["curve"] = [[float(p.split(":")[0]), float(p.split(":")[1])] for p in a.points.split(",")]
    save(st)
    print("curve:", st["curve"])


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status"); s.set_defaults(fn=cmd_status)
    s = sub.add_parser("cfg"); s.set_defaults(fn=cmd_cfg)
    s.add_argument("--out", default=os.path.join(RUN, "cfg", "ladder.cfg"))
    s.add_argument("--rungs", default="")
    s.add_argument("--game-threads", type=int, default=12)
    s.add_argument("--nn-batch", type=int, default=16)
    s.add_argument("--games-total", type=int, default=100000000)
    s.add_argument("--nn-server-threads", type=int, default=1)
    s = sub.add_parser("propose"); s.set_defaults(fn=cmd_propose)
    s.add_argument("--min-games", type=int, default=60)
    s.add_argument("--deadband", type=float, default=0.0)
    s = sub.add_parser("fit"); s.set_defaults(fn=cmd_fit)
    s = sub.add_parser("sweepup"); s.set_defaults(fn=cmd_sweep_up)
    s.add_argument("--apply", action="store_true")
    s.add_argument("--min-games", type=int, default=60)
    s.add_argument("--max-x", type=float, default=11.5, help="the dial family's maximum")
    s.add_argument("--zero-only", action="store_true")
    s = sub.add_parser("nudge"); s.set_defaults(fn=cmd_nudge)
    s.add_argument("--apply", action="store_true")
    s.add_argument("--min-games", type=int, default=100)
    s.add_argument("--max-x", type=float, default=11.5)
    s.add_argument("--deadband", type=float, default=8.0)
    s = sub.add_parser("gain"); s.set_defaults(fn=cmd_gain)
    s.add_argument("--apply", action="store_true")
    s.add_argument("--min-games", type=int, default=25)
    s = sub.add_parser("sweep"); s.set_defaults(fn=cmd_sweep)
    s.add_argument("--apply", action="store_true")
    s.add_argument("--min-games", type=int, default=60)
    s.add_argument("--max-se", type=float, default=45.0, help="skip a rung whose g is still this uncertain (1 sigma)")
    s.add_argument("--deadband", type=float, default=8.0, help="ELO of weakening below which a dial is left alone")
    s.add_argument("--gain", type=float, default=0.4, help="damping applied when the rank's curve gain c is not yet identifiable")
    s.add_argument("--zero-only", action="store_true", help="estimate g only from same-dial (dW=0) games")
    s.add_argument("--max-x", type=float, default=11.5, help="the dial family's maximum")
    s = sub.add_parser("plan"); s.set_defaults(fn=cmd_plan)
    s.add_argument("--min-games", type=int, default=80)
    s.add_argument("--max-games", type=int, default=700,
                   help="grind on if this many more games would certify; else move the dial")
    s = sub.add_parser("set"); s.set_defaults(fn=cmd_set)
    s.add_argument("assign", help="e.g. 16k=1.2,17k=1.9")
    s = sub.add_parser("rescale"); s.set_defaults(fn=cmd_rescale)
    s.add_argument("measured_span")
    s.add_argument("--apply", action="store_true")
    s.add_argument("--max-x", type=float, default=11.5)
    s = sub.add_parser("target"); s.set_defaults(fn=cmd_target)
    s.add_argument("value", help="one number, or a comma list of 11 per-rung targets")
    s = sub.add_parser("curve"); s.set_defaults(fn=cmd_curve)
    s.add_argument("points", help="e.g. 0:0,1:105,2:220")
    a = ap.parse_args()
    st = load()
    a.fn(st, a)


if __name__ == "__main__":
    main()
