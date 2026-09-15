#!/usr/bin/env python3
"""Place ONE ladder rung's weakening dial, and say where the NEXT chunk of games goes.

THE PROBLEM. A rung pits a stronger bot against a weaker one in even games; one scalar dial x on
the weaker bot (deepkyu_cfg.dial_params) makes it monotonically weaker. Pick x so the true even-game
gap is near the rung's target T, then certify at that dial under the dual-Z rule
(deepkyu_tally.pair_stats): the Wilson Z=2.50 interval on the weaker side's winrate, mapped through
gap = 400*log10((1-p)/p), must lie inside [70,130].

WHAT THIS VERSION IS. v1 of this tool lost a head-to-head against a naive bracket-and-interpolate
baseline, so its decision layer was DELETED and rebuilt around the simplest rule that can be stated
and checked. The statistical backbone (merge -> weighted PAVA -> order-restricted posterior) is
kept; everything downstream of it is new.

  1. FIT. p(x) by weighted PAVA, which for the binomial IS the order-restricted MLE
     (Robertson-Wright-Dykstra Thm 1.5.1). Dials no measurement can separate are pooled first;
     a G2 homogeneity test may un-merge. Two physically different bots that land on the same x are
     pooled for the fit only, loudly, and never share a banked-games credit.
  2. PRIORS, NAMED. Monotonicity alone says nothing about a dial that was never played, so the two
     things that do are stated as constants and swept in section 8: a warp prior inside a bracket
     (sigma_warp) and a slope prior outside the sampled hull, the latter clipped to [S_MIN, S_MAX]
     so no root is ever produced by dividing by a fitted zero.
  3. COST. Simulated under the rule actually in force -- the dual-Z rule, looked at every `check`
     games -- forward from the dial's own realised (w, n). No plug-in of a point estimate into a
     convex cost, no table lookup, no interpolation across a precomputed bank surface.
  4. ABANDONMENT. The price of a dial that will not work is a self-consistent continuation value:
         V*   = min_x (S_x + MOVE_COST) / q_x          [exact fixed point, closed form]
         V(x) = S_x + move(x) + (1 - q_x) * V*
     with S_x = E[games spent at x before it certifies, is refuted, or hits the cap] and
     q_x = P(certify at x), both averaged over the gap posterior at x. --selftest checks the closed
     form against value iteration. E[games_needed] with NO abandonment is INFINITE (the posterior
     puts real mass outside the band, where games_needed diverges), which is why nothing here ever
     takes that expectation; medians and simulated, capped expectations only.
  5. DECISION. One action exists: play the next chunk at a dial. The rule compares the SAME
     functional on the SAME posterior draws -- V(incumbent) against V(x*) -- with the paired
     Monte-Carlo error of that difference as the threshold. A dial is then played until the dual-Z
     rule certifies it, refutes it, or it passes the abandonment cap, which is exactly the policy
     V prices, and is what makes the loop terminate.
  6. HONESTY. Anything the data does not identify prints NOT IDENTIFIED, never a number.

MEASURED (deepkyu_bakeoff.py, where the dual-Z rule is RE-IMPLEMENTED from its specification and
is the referee -- nothing there asks this file or deepkyu_tally whether a run has finished).

  A. cold start, 5 independent monotone truths x 30 seeds = 150 runs per policy:

    policy                  valid certificates    median games   games per valid certificate
    interp (naive)                 43%                4727                46586
    grind  (naive, stronger)       49%                7727                38656
    this tool                     100%                4227                 4707      (8-10x better)

  B. --cold-real: every policy handed the REAL rung-1 observations and asked for the EXTRA games,
     over the 4 truths those counts do not contradict, 12 seeds each = 48 runs per policy:

    interp                         69%                4860                27116
    grind                          73%                4320                22217
    this tool                     100%                2700                 2970      (7-9x better)

     48/48 runs terminated in a valid certificate, in 2 to 14 rounds -- v1 never terminated at all.

Usage:
  python3 deepkyu_place.py --rung 1                      # live, from the ladder SGFs
  python3 deepkyu_place.py --data obs.json --target 100  # [{"x":..,"w":..,"n":..}, ...]
  python3 deepkyu_place.py --selftest                    # invariants + calibration
  python3 deepkyu_bakeoff.py --truth rung1 --seeds 30    # the head-to-head that justifies it
"""
import argparse, json, math, os, re, sys, time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deepkyu_cfg as dc
import deepkyu_tally as dt
import deepkyu_ladder as dl

# ---------------------------------------------------------------------------- constants
C_ELO = 400.0 / math.log(10.0)        # 173.7178 ELO per logit
BAND_LO, BAND_HI = dt.BAND_LO, dt.BAND_HI
Z_STOP = dt.Z_STOP                    # the interval that must fit before a rung may certify

SEED = 20260911
SEED_BOOT = 20260912
SEED_SIM = 20260910

# --- legal domain of the dial (deepkyu_cfg.dial_params + deepkyu_ladder.X_FLOOR) -------------
# early = 0.70 + x must stay positive and dial_params saturates at x = 11.5 (nnpt = 5.0).  A dial
# outside this is not playable, so it is never a candidate and never a probe.
X_MIN = float(getattr(dl, "X_FLOOR", -0.65))
X_MAX = 11.5

S_MAX = 1500.0        # ELO per unit x: Lipschitz bound used to decide two dials are one point
S_MIN = 50.0          # floor on any slope used for extrapolation; never divide by a fitted zero
MIN_SLOPE_W = 0.05    # no bracket narrower than this may carry a slope
SIGMA_WARP = 0.80     # within-bracket shape prior: gap = g_a + (g_b-g_a)*t**gamma,
                      # log gamma ~ N(0, SIGMA_WARP^2).  ONE constant, swept in section 7.
SIGMA_SLOPE = 0.70    # extrapolation slope prior, lognormal around the in-hull slope
DGAP_LAT = 5.0        # ELO per lattice step
LAT_MIN, LAT_MAX = 0.005, 0.05
MOVE_COST = 150.0     # games-equivalent price of leaving the current dial (cfg regen + restart)
DIAL_EPS = 0.02       # two dials closer than this are, for reporting purposes, one dial
CAP_GAMES = 20000     # games past which you re-place rather than keep paying
TOL_T = 5.0           # |median delivered gap - T| allowed at the shipped dial
Q_MIN = 0.02          # below this P(certify) a dial is not a candidate at all

CHI95 = {1: 3.841, 2: 5.991, 3: 7.815, 4: 9.488, 5: 11.070,
         6: 12.592, 7: 14.067, 8: 15.507, 9: 16.919}


def chi2_95(df):
    """95% point of chi2_df. Table below 10, Wilson-Hilferty above (scipy is not installed)."""
    if df in CHI95:
        return CHI95[df]
    return df * (1.0 - 2.0 / (9.0 * df) + 1.6448536 * math.sqrt(2.0 / (9.0 * df))) ** 3


# ---------------------------------------------------------------------------- transforms
def gap_of_p(p):
    """Even-game ELO gap from the WEAKER side's winrate. Same formula as dt.gapfromw."""
    p = np.clip(np.asarray(p, float), 1e-9, 1.0 - 1e-9)
    return 400.0 * np.log10((1.0 - p) / p)


def p_of_gap(g):
    return 1.0 / (1.0 + 10.0 ** (np.asarray(g, float) / 400.0))


def wilson_np(w, n, z):
    """Vectorised dt.wilson (fraction)."""
    n = np.maximum(np.asarray(n, float), 1e-12)
    p = np.asarray(w, float) / n
    den = 1.0 + z * z / n
    cen = (p + z * z / (2 * n)) / den
    mar = (z / den) * np.sqrt(np.maximum(p * (1 - p) / n + z * z / (4 * n * n), 0.0))
    return np.clip(cen - mar, 0.0, 1.0), np.clip(cen + mar, 0.0, 1.0)


P_BAND_HI = float(p_of_gap(BAND_LO))    # winrate at gap 70  (0.4008) -- the UPPER p of the band
P_BAND_LO = float(p_of_gap(BAND_HI))    # winrate at gap 130 (0.3231)


def cert_state(w, n):
    """(certified, refuted) under the dual-Z rule, vectorised.  Certified: the Z_STOP interval lies
    inside [70,130].  Refuted: it lies entirely outside, so no number of further games certifies.
    Depends on the OBSERVED (w, n) only -- never on the unknown true gap."""
    lo, hi = wilson_np(w, n, Z_STOP)
    certified = (hi <= P_BAND_HI) & (lo >= P_BAND_LO)
    refuted = (hi < P_BAND_LO) | (lo > P_BAND_HI)
    return certified, refuted


def sd_gap(w, n):
    """1 sigma of the OBSERVED gap at this dial."""
    n = max(float(n), 1.0)
    p = min(max(float(w) / n, 1.0 / (2 * n)), 1 - 1.0 / (2 * n))
    return C_ELO / math.sqrt(n * p * (1 - p))


def games_floor(T):
    """Games below which a dial cannot localise the crossing: enough that 1 sigma of the measured
    gap is half the band margin it is aiming at."""
    m = min(T - BAND_LO, BAND_HI - T)
    p = float(p_of_gap(T))
    return (C_ELO / (0.5 * m)) ** 2 / (p * (1 - p))


# ---------------------------------------------------------------------------- 1. loading
RE_NAME = re.compile(r"^(?P<rank>\d+[kd])_v(?P<v>\d+)_e(?P<e>[-\d.]+)_l(?P<l>[-\d.]+)"
                     r"(?:_h(?P<h>[-\d.]+))?(?:_s(?P<s>\d+))?(?:_q(?P<q>[-\d.]+))?"
                     r"(?:_p(?P<p>[-\d.]+))?(?:_r(?P<r>[-\d.]+))?_(?P<tag>[A-Za-z0-9]+)$")


def invert_bot_name(nm):
    """Bot NAME -> dial x, across ALL FOUR dial_params branches, or (None, reason).

    Verified both ways: dial_params(x) must reproduce all four fields and deepkyu_cfg.bot_name must
    rebuild the exact string, so a dial_params edit is a loud skip and not a silent re-mapping.
    """
    m = RE_NAME.match(nm)
    if not m:
        return None, "name does not parse"
    e = float(m.group("e")); late = float(m.group("l"))
    hl = float(m.group("h")) if m.group("h") else dc.HALFLIFE_BASE
    sym = int(m.group("s")) if m.group("s") else 2
    q = float(m.group("q")) if m.group("q") else 1.0
    nnpt = float(m.group("p")) if m.group("p") else 1.0
    rootpt = float(m.group("r")) if m.group("r") else 1.0
    if nnpt > 1.0 + 1e-9:                       # nnPolicyTemperature branch (x > X_HALFLIFE_CAP)
        x = dc.X_HALFLIFE_CAP + (nnpt - 1.0) * 3.0 / 4.0
    elif hl > dc.HALFLIFE_BASE + 1e-9:          # halflife branch (X_EARLY_CAP < x <= X_HALFLIFE_CAP)
        x = dc.X_EARLY_CAP + math.log2(hl / dc.HALFLIFE_BASE)
    else:                                       # early-temperature branch (the usual one)
        x = e - dc.TEMP_BASE_EARLY
    x = round(x, 6)
    de, dlate, dhl, dnnpt = dc.dial_params(x)
    for got, want, what in ((de, e, "early"), (dlate, late, "late"),
                            (dhl, hl, "halflife"), (dnnpt, nnpt, "nnpt")):
        if abs(got - want) > 2e-4 * max(1.0, abs(want)):
            return None, "dial_params(%.6f).%s = %.5f != %.5f in the name" % (x, what, got, want)
    rebuilt = dc.bot_name(m.group("rank"), int(m.group("v")), de, dlate, dhl, sym, q, dnnpt, rootpt)
    if rebuilt != nm:
        return None, "bot_name round-trip gives %s" % rebuilt
    return x, ""


def load_live(st, rung, cache_path, sgf_dirs):
    """Every dial this rank has ever been played at against the rung's stronger bot."""
    totals, nfiles = dt.scan(sgf_dirs, cache_path)
    rg = dl.rungs(st)
    if not (1 <= rung <= len(rg)):
        raise SystemExit("rung %d out of range 1..%d" % (rung, len(rg)))
    strong, _weak_now, rank = rg[rung - 1]
    names = set()
    for (pb, pw) in totals:
        names.add(pb); names.add(pw)
    if strong not in names:
        srank = strong.split("_")[0]
        seen = sorted(((sum(v[5] + v[3] for (pb, pw), v in totals.items() if nm in (pb, pw)), nm)
                       for nm in names if nm.startswith(srank + "_v")), reverse=True)[:6]
        raise SystemExit(
            "the rung's stronger bot %s has no games in %s.\nIts dial has moved since those games "
            "were played, so pair_stats would return zero for the old pairing and every banked-game"
            " credit below would be a lie. Refusing.\nBuckets that DO exist for %s: %s\n"
            "Fix by setting the stronger rank back to the dial the games were played at, or by "
            "pointing --sgf-dir at the matching run."
            % (strong, ", ".join(sgf_dirs), srank,
               ", ".join("%s (%d games)" % (nm, n) for n, nm in seen) or "none"))
    rows, warns = [], []
    for nm in sorted(names):
        if not nm.startswith(rank + "_v"):
            continue
        r = dt.pair_stats(totals, strong, nm)
        if r["decided"] <= 0:
            continue                       # a bucket from some other rung; nothing to say about it
        x, why = invert_bot_name(nm)
        if x is None:
            warns.append("SKIP %s (%d games): %s" % (nm, r["decided"], why))
            continue
        rows.append({"x": x, "name": nm, "w": r["weak_wins"] + 0.5 * r["draws"],
                     "n": float(r["decided"]), "noresult": int(r["noresult"]),
                     "draws": int(r["draws"]), "avg_moves": r["avg_moves"]})
    rows.sort(key=lambda r: r["x"])
    return rows, strong, rank, nfiles, warns


def load_json(path, rank=None):
    """[{"x":..,"w":..,"n":..,"name":..}, ...].  Rows WITHOUT a name get a unique synthetic one, so
    two rows at the same x are treated as two physically different buckets (which is what they are)
    rather than silently pooled."""
    rows = []
    for i, o in enumerate(json.load(open(path))):
        x = float(o["x"])
        rows.append({"x": x, "name": o.get("name", "bucket%d@x=%+.4f" % (i, x)), "w": float(o["w"]),
                     "n": float(o["n"]), "noresult": int(o.get("noresult", 0)),
                     "draws": int(o.get("draws", 0)), "avg_moves": float(o.get("avg_moves", 0.0))})
    rows.sort(key=lambda r: r["x"])
    return rows


# ---------------------------------------------------------------------------- 1b. x-grid points
def group_by_x(rows, tol=1e-9):
    """Buckets -> ANALYSIS POINTS with a strictly increasing x.

    A bucket is one SGF PB/PW bucket, i.e. one physical bot.  Two DIFFERENT bots can land on the
    same dial x (they differ in a field the dial does not carry: rootNumSymmetriesToSample,
    chosenMoveTemperatureOnlyBelowProb, rootPolicyTemperature, ...).  v1 pooled them silently and
    then credited one bucket's banked games to the other bot's name, and the tied x divided by zero
    inside the slope code.  Here they are pooled ONLY for the response fit -- which is all the
    monotone constraint can use them for -- with a loud warning, and the banked-games credit is
    taken from the LARGEST single bucket, never from the pooled sum.
    """
    pts, warns = [], []
    for r in rows:
        if pts and abs(r["x"] - pts[-1]["x"]) <= tol:
            pts[-1]["buckets"].append(r)
        else:
            pts.append({"x": float(r["x"]), "buckets": [r]})
    for p in pts:
        p["w"] = float(sum(b["w"] for b in p["buckets"]))
        p["n"] = float(sum(b["n"] for b in p["buckets"]))
        p["noresult"] = int(sum(b["noresult"] for b in p["buckets"]))
        big = max(p["buckets"], key=lambda b: b["n"])
        p["bank_w"], p["bank_n"], p["name"] = float(big["w"]), float(big["n"]), big["name"]
        p["ambiguous"] = len(p["buckets"]) > 1
        if p["ambiguous"]:
            warns.append(
                "AMBIGUOUS DIAL x=%+.4f carries %d physically different buckets (%s). They are "
                "pooled for the response fit only; banked-game credit is taken from %s (%d games) "
                "alone, because a certificate lives in ONE bucket."
                % (p["x"], len(p["buckets"]),
                   ", ".join("%s n=%d" % (b["name"], int(b["n"])) for b in p["buckets"]),
                   p["name"], int(p["bank_n"])))
    for a, b in zip(pts, pts[1:]):
        if not b["x"] > a["x"]:
            raise AssertionError("x grid is not strictly increasing: %r" % [q["x"] for q in pts])
    return pts, warns


# ---------------------------------------------------------------------------- 2. merge
def g2_stat(ws, ns):
    """Binomial deviance of a cluster against one pooled rate; df = len-1."""
    W, N = float(sum(ws)), float(sum(ns))
    pbar = min(max(W / N, 1e-12), 1 - 1e-12)
    t = 0.0
    for w, n in zip(ws, ns):
        if w > 0:
            t += w * math.log(w / (n * pbar))
        if n - w > 0:
            t += (n - w) * math.log((n - w) / (n * (1 - pbar)))
    return 2.0 * t


def _collapse(group):
    n = sum(g["n"] for g in group)
    return {"x": sum(g["x"] * g["n"] for g in group) / n, "w": sum(g["w"] for g in group),
            "n": n, "members": group}


def _split_while_heterogeneous(group, log):
    """Un-merge a cluster the data can actually resolve: split at the largest winrate step while
    the pooled deviance exceeds chi2_95.  Points (never buckets) are the atoms, so a split can
    never produce two merged points with the same x."""
    if len(group) == 1:
        return [_collapse(group)]
    g2 = g2_stat([g["w"] for g in group], [g["n"] for g in group])
    crit = chi2_95(len(group) - 1)
    xs = "{%s}" % ",".join("%.3f" % g["x"] for g in group)
    if g2 <= crit:
        log.append("  %-28s G2 = %5.2f on %d df (chi2.95 = %5.2f)  MERGED" %
                   (xs, g2, len(group) - 1, crit))
        return [_collapse(group)]
    log.append("  %-28s G2 = %5.2f on %d df (chi2.95 = %5.2f)  SPLIT" %
               (xs, g2, len(group) - 1, crit))
    ps = [g["w"] / g["n"] for g in group]
    k = max(range(len(group) - 1), key=lambda i: abs(ps[i] - ps[i + 1]))
    return _split_while_heterogeneous(group[:k + 1], log) + _split_while_heterogeneous(group[k + 1:], log)


def merge_dials(points, s_max=S_MAX, min_w=MIN_SLOPE_W):
    """Pool dials no measurement here can tell apart.

    (a1) STRUCTURAL: points spanning less than min_w of dial are one point.  0.03 of dial is far
         inside the noise, so such a cluster must be arithmetically unable to contribute a slope.
    (a2) PHYSICAL: further apart than that they are still one point while s_max*dx <= 0.5*min
         (sd_gap), i.e. while the largest possible true difference is at most half the noise.
    (b)  STATISTICAL: a G2 homogeneity test may only UN-merge what (a) proposed.

    The merged point is an ANALYSIS object: it has no config and no SGF bucket, so banked-game
    credit is always taken from a real bucket, never from the centroid.
    """
    log = []
    if not points:
        return [], log
    groups = [[points[0]]]
    for r in points[1:]:
        prev = groups[-1][-1]
        span = r["x"] - groups[-1][0]["x"]          # span, not step, so a chain cannot creep
        bias = s_max * (r["x"] - prev["x"])
        noise = 0.5 * min(sd_gap(prev["w"], prev["n"]), sd_gap(r["w"], r["n"]))
        if span < min_w or bias <= noise:
            groups[-1].append(r)
        else:
            groups.append([r])
    out = []
    for g in groups:
        if len(g) == 1:
            out.append(_collapse(g))
        else:
            out.extend(_split_while_heterogeneous(g, log))
    out.sort(key=lambda m: m["x"])
    for a, b in zip(out, out[1:]):
        if not b["x"] > a["x"]:
            raise AssertionError("merged x grid is not strictly increasing")
    return out, log


# ---------------------------------------------------------------------------- 3. isotonic fit
def pava_dec(Y, wt):
    """Weighted DECREASING isotonic regression of every row of Y, by the min-max formula

        yhat_i = min_{j<=i} max_{k>=i} avg(j..k)

    which for a one-parameter exponential family is the constrained MLE, not an approximation."""
    Y = np.atleast_2d(np.asarray(Y, float))
    B, K = Y.shape
    wt = np.asarray(wt, float)
    if K == 1:
        return Y.copy()
    cw = np.concatenate([[0.0], np.cumsum(wt)])
    cy = np.concatenate([np.zeros((B, 1)), np.cumsum(Y * wt, axis=1)], axis=1)
    num = cy[:, None, 1:] - cy[:, :-1, None]                 # (B, j, k) sum over j..k
    den = cw[None, None, 1:] - cw[None, :-1, None]
    with np.errstate(divide="ignore", invalid="ignore"):
        M = num / den
    j = np.arange(K)[:, None]; k = np.arange(K)[None, :]
    M = np.where(k >= j, M, -np.inf)
    A = np.maximum.accumulate(M[:, :, ::-1], axis=2)[:, :, ::-1]    # max over k>=i
    Cm = np.minimum.accumulate(A, axis=1)                           # min over j<=i
    idx = np.arange(K)
    return Cm[:, idx, idx]


def loglik_binom(w, n, p):
    """Binomial log-likelihood, rows of p.  w may be fractional (a draw counts 0.5)."""
    p = np.clip(p, 1e-12, 1 - 1e-12)
    return (w * np.log(p) + (n - w) * np.log(1 - p)).sum(axis=-1)


# ---------------------------------------------------------------------------- 4. LR interval on x*
def _constrained_rows(PH, n, k, p_T):
    """MLE of p under 'the T-crossing lies in bin k', i.e. p_j >= p_T for j < k and p_j <= p_T for
    j >= k, on top of the monotone cone.  With a CONSTANT one-sided bound the projection is the
    clipped isotonic fit, so this is exact."""
    K = PH.shape[1]
    out = np.empty_like(PH)
    if k > 0:
        out[:, :k] = np.maximum(pava_dec(PH[:, :k], n[:k]), p_T)
    if k < K:
        out[:, k:] = np.minimum(pava_dec(PH[:, k:], n[k:]), p_T)
    return out


def lr_interval(wm, nm, T, boot, seed=SEED_BOOT, level=0.95):
    """Confidence set for the crossing by INVERTING a likelihood-ratio test, one bin at a time.

    Not a bootstrap of x_hat: the isotonic estimator has a cube-root (Chernoff) limit at a fixed
    point and the percentile bootstrap is inconsistent for it (Sen, Banerjee & Woodroofe 2010).
    The cutoff is calibrated PER BIN under that bin's own constrained MLE.
    """
    K = len(wm)
    p_T = float(p_of_gap(T))
    PH = (wm / nm)[None, :]
    ll = np.array([loglik_binom(wm, nm, _constrained_rows(PH, nm, k, p_T))[0] for k in range(K + 1)])
    LR = 2.0 * (ll.max() - ll)
    rng = np.random.default_rng(seed)
    nb = np.maximum(np.rint(nm), 1).astype(int)
    cut = np.empty(K + 1)
    for k in range(K + 1):
        p0 = _constrained_rows(PH, nm, k, p_T)[0]
        Wb = rng.binomial(nb[None, :], p0[None, :], size=(boot, K)).astype(float)
        PHb = Wb / nb[None, :]
        llb = np.stack([loglik_binom(Wb, nb.astype(float), _constrained_rows(PHb, nm, j, p_T))
                        for j in range(K + 1)], axis=1)
        LRb = 2.0 * (llb.max(axis=1) - llb[:, k])
        cut[k] = np.quantile(LRb, level)
    return np.flatnonzero(LR <= cut), LR, cut, ll


def bins_to_interval(accept, xm):
    """Bin k is the open-closed dial interval (x_{k-1}, x_k]; bin 0 and bin K are unbounded."""
    if len(accept) == 0:
        return None
    lo = -np.inf if accept[0] == 0 else xm[accept[0] - 1]
    hi = np.inf if accept[-1] == len(xm) else xm[accept[-1]]
    gaps_in = [k for k in range(accept[0], accept[-1] + 1) if k not in set(accept.tolist())]
    return lo, hi, gaps_in


# ---------------------------------------------------------------------------- 5. posterior
def fit_posterior(xm, wm, nm, B, seed, sigma_warp=SIGMA_WARP):
    """Order-restricted PROJECTION posterior (Dunson & Neelon 2003): draw each dial's rate from its
    own exact Jeffreys posterior, then project the draw onto the monotone cone.  No smoothness is
    imposed between dials, so a plateau stays a plateau.

    TWO priors are needed to say anything at a dial that was never played, and both are explicit:
      * INSIDE a bracket: gap(x) = g_a + (g_b - g_a) * t**gamma, log gamma ~ N(0, sigma_warp^2).
        Monotone for every draw, and at sigma_warp = 0.8 it spans most of [g_a, g_b] at t = 0.5,
        which is the honest statement of what monotonicity alone allows there.
      * OUTSIDE the sampled hull: the gap continues at a random slope drawn lognormally around the
        draw's own in-hull slope, CLIPPED to [S_MIN, S_MAX].  It is never zero, so no root is ever
        obtained by dividing by a fitted zero, and never unbounded, so no dial is ever priced on an
        arbitrarily steep imaginary response.
    """
    xm = np.asarray(xm, float); wm = np.asarray(wm, float); nm = np.asarray(nm, float)
    K = len(xm)
    rng = np.random.default_rng(seed)
    PH = rng.beta(wm + 0.5, nm - wm + 0.5, size=(B, K))
    P = np.clip(pava_dec(PH, nm), 1e-6, 1 - 1e-6)
    G = gap_of_p(P)
    GAM = np.exp(rng.normal(0.0, 1.0, size=(B, max(K - 1, 1))) * sigma_warp)
    if K >= 2:
        s_ref = (G[:, -1] - G[:, 0]) / (xm[-1] - xm[0])
    else:
        s_ref = np.full(B, 200.0)         # no in-hull slope exists; campaign-scale prior median
    s_ref = np.clip(s_ref, S_MIN, S_MAX)
    SL_LO = np.clip(s_ref * np.exp(rng.normal(0.0, SIGMA_SLOPE, size=B)), S_MIN, S_MAX)
    SL_HI = np.clip(s_ref * np.exp(rng.normal(0.0, SIGMA_SLOPE, size=B)), S_MIN, S_MAX)
    iso = np.clip(pava_dec((wm / nm)[None, :], nm)[0], 1e-6, 1 - 1e-6)
    return {"xm": xm, "wm": wm, "nm": nm, "G": G, "GAM": GAM, "SL_LO": SL_LO, "SL_HI": SL_HI,
            "iso_p": iso, "iso_gap": gap_of_p(iso), "B": B, "sigma_warp": sigma_warp}


def curve_at(F, xs):
    """Posterior gap curves at dials xs -> (B, len(xs)).  Outside the hull the declared slope prior
    is used and the caller must flag it as extrapolation."""
    xm, G, GAM = F["xm"], F["G"], F["GAM"]
    xs = np.atleast_1d(np.asarray(xs, float))
    out = np.empty((G.shape[0], len(xs)))
    for i, x in enumerate(xs):
        if len(xm) == 1:
            out[:, i] = G[:, 0] + (x - xm[0]) * np.where(x >= xm[0], F["SL_HI"], F["SL_LO"])
        elif x <= xm[0]:
            out[:, i] = G[:, 0] - F["SL_LO"] * (xm[0] - x)
        elif x >= xm[-1]:
            out[:, i] = G[:, -1] + F["SL_HI"] * (x - xm[-1])
        else:
            a = int(np.searchsorted(xm, x, side="right") - 1)
            t = (x - xm[a]) / (xm[a + 1] - xm[a])
            out[:, i] = G[:, a] + (G[:, a + 1] - G[:, a]) * t ** GAM[:, a]
    return out


def roots_at(F, T):
    """Per-draw dial delivering gap T, computed ONLY where the draw crosses T inside the sampled
    hull.  A draw that never reaches T inside the hull, or is already past T at the first dial, is
    CENSORED: no number is manufactured for it by dividing by a near-zero fitted slope (that is how
    v1 printed x_hat = 3.4e7).  Returns (x for the crossing draws, n_left, n_right, B)."""
    xm, G, GAM = F["xm"], F["G"], F["GAM"]
    B, K = G.shape
    if K < 2:
        return np.empty(0), 0, B, B
    above = G >= T
    anyab = above.any(axis=1)
    first = np.argmax(above, axis=1)
    n_right = int(np.sum(~anyab))                    # never reaches T inside the hull
    n_left = int(np.sum(anyab & (first == 0)))       # already above T at the first dial
    ii = np.flatnonzero(anyab & (first > 0))
    if ii.size == 0:
        return np.empty(0), n_left, n_right, B
    a = first[ii] - 1
    ga = G[ii, a]; gb = G[ii, a + 1]
    t = np.clip((T - ga) / np.maximum(gb - ga, 1e-9), 0.0, 1.0) ** (1.0 / GAM[ii, a])
    return xm[a] + t * (xm[a + 1] - xm[a]), n_left, n_right, B


# ---------------------------------------------------------------------------- 6. cost engine
# Cost is measured in GAMES by simulating the rule that is actually in force -- deepkyu_tally's
# dual-Z stop rule, looked at every `check` games -- forward from the dial's own realised (w, n).
#
# There is no precomputed surface and no interpolation over "how off-centre the bank is": the bank
# is carried exactly, because P(certify) and E[games] depend on the realised (w, n) directly.
#
# deepkyu_tally.games_needed() is a 90%-POWER table (a fixed N), not an expected cost.  It is
# printed for comparison and never used to budget anything.
GAP_GRID = np.concatenate([np.arange(-150.0, 70.0, 15.0),
                           np.arange(70.0, 130.001, 2.5),
                           np.arange(135.0, 615.0, 15.0)])


def sim_forward(n0, w0, gaps, trials, check, cap, seed):
    """Forward simulation from a bank of w0 wins in n0 games, per true gap.

    Returns p_cert, e_cert (E[extra games | it certifies]), e_all (E[extra games], every branch),
    p_ref, p_cap.  e_all is the only one the decision uses; e_cert is reported separately because
    conflating P(cert)*E[games|cert] with E[games|cert] made v1's table read 15-20x too cheap.
    """
    gaps = np.asarray(gaps, float)
    G = len(gaps)
    p = p_of_gap(gaps)
    rng = np.random.default_rng(seed)
    w = np.full(G * trials, float(w0))
    n = np.full(G * trials, float(n0))
    pp = np.repeat(p, trials)
    add = np.zeros(G * trials)
    stt = np.zeros(G * trials, dtype=np.int8)       # 0 running, 1 certified, 2 refuted, 3 capped
    c, r = cert_state(w, n)
    stt[c] = 1
    stt[r & ~c] = 2
    act = np.flatnonzero(stt == 0)
    while act.size:
        w[act] += rng.binomial(check, pp[act])
        n[act] += check
        add[act] += check
        c, r = cert_state(w[act], n[act])
        stt[act[c]] = 1
        stt[act[r & ~c]] = 2
        still = stt[act] == 0
        capped = still & (add[act] >= cap)
        stt[act[capped]] = 3
        act = act[stt[act] == 0]
    stt = stt.reshape(G, trials); add = add.reshape(G, trials)
    mc = stt == 1
    cnt = mc.sum(axis=1)
    return {"p_cert": cnt / float(trials),
            "e_cert": np.where(cnt > 0, (add * mc).sum(axis=1) / np.maximum(cnt, 1), 0.0),
            "e_all": add.mean(axis=1),
            "p_ref": (stt == 2).sum(axis=1) / float(trials),
            "p_cap": (stt == 3).sum(axis=1) / float(trials)}


class CertCost:
    """P(certify) and E[games spent] at a dial, as a function of its TRUE gap and of the games it
    has already banked.  Memoised on the exact realised (w, n) -- no surface, no interpolation."""

    def __init__(self, trials=400, check=180, cap=CAP_GAMES, seed=SEED_SIM):
        self.trials, self.check, self.cap, self.seed = trials, check, cap, seed
        self._memo = {}
        self.calls = 0

    def full(self, n0=0.0, w0=0.0):
        key = (round(float(n0), 3), round(float(w0), 3))
        r = self._memo.get(key)
        if r is None:
            self.calls += 1
            h = (hash(key) ^ self.seed) & 0x7FFFFFFF
            r = sim_forward(key[0], key[1], GAP_GRID, self.trials, self.check, self.cap, h)
            self._memo[key] = r
        return r

    def components(self, n0=0.0, w0=0.0):
        """(P(certify), E[games spent]) over GAP_GRID."""
        r = self.full(n0, w0)
        return r["p_cert"], r["e_all"]


def solve_value(S, q, move, move_restart=MOVE_COST, q_min=Q_MIN):
    """Self-consistent continuation value with abandonment.

        V*   = min_x (S_x + MOVE_COST) / q_x            -- the restart value
        V(x) = S_x + move(x) + (1 - q_x) * V*

    V* is the EXACT fixed point of V = min_x (S_x + MOVE_COST + (1 - q_x) V):  at V = min A/q the
    minimising x gives q*(A/q) + (1-q)V = V, and every other x gives at least V, so f(V) = V; f is
    a contraction for q > 0, so the fixed point is unique.  --selftest checks it against value
    iteration.  If no candidate has q > q_min the fixed point does not exist: return None and say
    UNATTAINABLE rather than print a capped number as if it were a cost.
    """
    S = np.asarray(S, float); q = np.asarray(q, float); move = np.asarray(move, float)
    ok = q > q_min
    if not ok.any():
        return None, None, ok
    A = S + move_restart
    Vstar = float(np.min(A[ok] / q[ok]))
    V = np.where(ok, S + move + (1.0 - q) * Vstar, np.inf)
    return V, Vstar, ok


def value_iterate(S, q, move_restart=MOVE_COST, iters=2000, q_min=Q_MIN):
    """The same fixed point by value iteration -- used only to check solve_value()."""
    S = np.asarray(S, float); q = np.asarray(q, float)
    ok = q > q_min
    if not ok.any():
        return None
    V = 0.0
    for _ in range(iters):
        V = float(np.min((S + move_restart + (1.0 - q) * V)[ok]))
    return V


def norm_isf(tail):
    """z with P(|Z| > z) = tail, by bisection on math.erfc (scipy is not installed)."""
    lo, hi = 0.0, 10.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        if math.erfc(mid / math.sqrt(2.0)) > tail:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


# ---------------------------------------------------------------------------- 7. placement core
def legal(x):
    return X_MIN <= x <= X_MAX


def clip_dial(x):
    return float(min(max(float(x), X_MIN), X_MAX))


def bracket_of(xm, gap_iso, T, slope_hint, widen=True):
    """The identified set for the crossing: monotonicity says x* lies between the last dial fitted
    at or below T and the first fitted at or above it, and says nothing finer.  Outside the hull the
    bracket is extended by ONE declared step, sized by the slope prior, and clipped to the legal
    dial domain -- never by an unbounded extrapolation."""
    lo_ext = hi_ext = False
    s = max(float(slope_hint), S_MIN)
    if T <= gap_iso[0]:
        step = min(1.0, max(0.05, (gap_iso[0] - T) / s))
        x_b, x_a, lo_ext = float(xm[0]), clip_dial(xm[0] - step), True
    elif T >= gap_iso[-1]:
        step = min(1.0, max(0.05, (T - gap_iso[-1]) / s))
        x_a, x_b, hi_ext = float(xm[-1]), clip_dial(xm[-1] + step), True
    else:
        ia = int(np.max(np.flatnonzero(gap_iso <= T)))
        ib = int(np.min(np.flatnonzero(gap_iso >= T)))
        x_a, x_b = float(xm[min(ia, ib)]), float(xm[max(ia, ib)])
    # STRUCTURAL ANTI-SLOPE GUARD: a bracket narrower than MIN_SLOPE_W carries no slope information.
    if widen and x_b - x_a < MIN_SLOPE_W:
        c = 0.5 * (x_a + x_b)
        x_a, x_b = clip_dial(c - 0.5 * MIN_SLOPE_W), clip_dial(c + 0.5 * MIN_SLOPE_W)
    return float(x_a), float(x_b), lo_ext, hi_ext


def candidate_set(x_a, x_b, lat, points, x_cur, extra=(), raw_window=None):
    """Lattice over the bracket, plus every REAL dial in it (those carry banked games), plus the
    current dial.  Snapping to a lattice is load-bearing: a free grid makes the tool hop to a fresh
    SGF bucket after every chunk and never bank enough games to certify anything.  Everything is
    clipped to the legal dial domain: a dial the config cannot express is not a candidate."""
    cands = list(np.round(np.arange(x_a, x_b + 0.5 * lat, lat), 6))
    rlo, rhi = raw_window if raw_window else (x_a - lat, x_b + lat)
    for r in points:
        if min(rlo, x_a - lat) <= r["x"] <= max(rhi, x_b + lat):
            cands.append(round(r["x"], 6))
    for e in list(extra) + ([x_cur] if x_cur is not None else []):
        if e is not None and x_a - lat <= e <= x_b + lat:
            cands.append(round(float(e), 6))
    out = sorted(set(round(clip_dial(c), 6) for c in cands))
    return np.array(out, float)


def bank_of(points, x, tol=1e-6):
    """Banked games come from the LARGEST REAL bucket at this dial.  A merged centroid has no config
    and no SGF bucket, and two different bots at one x are two different certificates, so a bank is
    never a sum across buckets."""
    for r in points:
        if abs(r["x"] - x) <= tol:
            return float(r["bank_w"]), float(r["bank_n"]), r["name"]
    return 0.0, 0.0, None


def evaluate_candidates(F, cands, points, cm, x_cur):
    """V(x) at every candidate under the posterior, the banked games and the continuation value.

    The PER-DRAW cost is kept as well.  Every candidate is evaluated on the SAME posterior draws
    (common random numbers), so the Monte-Carlo error of a DIFFERENCE between two candidates is the
    paired sd over draws -- far smaller than the error of either level, and it is the only error bar
    the decision rule ever needs, because the only thing the rule compares is a difference of V.
    """
    GC = curve_at(F, cands)                                    # (B, ncand) delivered gap
    nc = len(cands)
    Q = np.empty(nc); S = np.empty(nc)
    QD = np.empty((F["B"], nc)); SD = np.empty((F["B"], nc))
    for i, xc in enumerate(cands):
        w0, n0, _nm = bank_of(points, xc)
        q_g, s_g = cm.components(n0, w0)
        g = GC[:, i]
        QD[:, i] = np.interp(g, GAP_GRID, q_g)
        SD[:, i] = np.interp(g, GAP_GRID, s_g)
        Q[i] = float(QD[:, i].mean())
        S[i] = float(SD[:, i].mean())
    move = MOVE_COST * (np.abs(cands - (x_cur if x_cur is not None else cands[0])) > 1e-6)
    V, Vstar, ok = solve_value(S, Q, move, MOVE_COST, Q_MIN)
    cost_d = None if V is None else SD + move[None, :] + (1.0 - QD) * Vstar
    return {"unattainable": V is None, "cands": cands, "GC": GC, "Q": Q, "S": S,
            "V": V, "Vstar": Vstar, "ok": ok, "move": move, "cost_d": cost_d}


def mcse_diff(ev, i, j):
    """Monte-Carlo standard error of V(i) - V(j) under common random numbers."""
    if ev["cost_d"] is None or i == j:
        return 0.0
    d = ev["cost_d"][:, i] - ev["cost_d"][:, j]
    return float(np.std(d, ddof=1) / math.sqrt(len(d)))


def pick_dial(ev, T, tol=TOL_T):
    """Ship dial x* = cheapest candidate whose MEDIAN delivered gap is within tol of the target.

    The constraint is not cosmetic: the certification cost depends only on the band [70,130] and not
    at all on T, so unconstrained cost minimisation returns the same dial whether T is 100, 87 or
    85, and every rung would certify while the ladder's span silently drifted.  When T is not
    reachable at all among the candidates the constraint is measured against the BEST ACHIEVABLE
    miss instead of being abandoned.
    """
    med = np.median(ev["GC"], axis=0)
    V = ev["V"]
    i_free = int(np.argmin(V))
    dmin = float(np.min(np.abs(med - T)[np.isfinite(V)])) if np.isfinite(V).any() else float("inf")
    feas = (np.abs(med - T) <= max(tol, dmin + tol)) & np.isfinite(V)
    idx = np.flatnonzero(feas)
    if idx.size == 0:
        idx = np.flatnonzero(np.isfinite(V))
    i_star = int(idx[np.argmin(V[idx])])
    return i_star, i_free, med, (dmin <= tol), feas


def iso_blocks(xm, iso_gap, nm):
    """Maximal runs of equal isotonic level: PAVA's own statement of where x is unidentified."""
    out = []
    i = 0
    while i < len(xm):
        j = i
        while j + 1 < len(xm) and abs(iso_gap[j + 1] - iso_gap[i]) < 1e-9:
            j += 1
        n = nm[i:j + 1].sum()
        out.append({"i": i, "j": j, "value": float(iso_gap[i]), "n": float(n),
                    "x_lo": float(xm[i]), "x_hi": float(xm[j]),
                    "centroid": float((xm[i:j + 1] * nm[i:j + 1]).sum() / n)})
        i = j + 1
    return out


class Opt(object):
    """Everything the decision layer is allowed to depend on, in one place."""
    draws = 8000
    boot = 1200
    tol = TOL_T
    s_max = S_MAX
    min_slope_w = MIN_SLOPE_W
    sigma_warp = SIGMA_WARP
    chunk = 540
    sticky = True                 # keep playing an unrefuted, on-target dial until the dual-Z
                                  # rule ends it or it hits the abandonment cap -- the same policy
                                  # sim_forward prices, which is what makes the loop terminate
    place_budget = None          # None -> 4 * games_floor(T)

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def core(points, T, cm, opt, x_cur, B=None, seed=SEED, sigma_warp=None, s_max=None,
         min_slope_w=None, extra_cands=()):
    """merge -> isotonic -> projected posterior -> bracket -> candidates -> value function -> x*."""
    sigma_warp = opt.sigma_warp if sigma_warp is None else sigma_warp
    s_max = opt.s_max if s_max is None else s_max
    min_slope_w = opt.min_slope_w if min_slope_w is None else min_slope_w
    merged, mlog = merge_dials(points, s_max, min_slope_w)
    xm = np.array([m["x"] for m in merged], float)
    wm = np.array([m["w"] for m in merged], float)
    nm = np.array([m["n"] for m in merged], float)
    F = fit_posterior(xm, wm, nm, B or opt.draws, seed, sigma_warp)
    blocks = iso_blocks(xm, F["iso_gap"], nm)
    s_hint = float(np.median(F["SL_HI"]))
    x_a, x_b, lo_ext, hi_ext = bracket_of(xm, F["iso_gap"], T, s_hint)
    med_ab = np.median(curve_at(F, [x_a, x_b]), axis=0)
    S_br = (med_ab[1] - med_ab[0]) / max(x_b - x_a, 1e-9)
    lat = float(np.clip(DGAP_LAT / max(50.0, S_br), LAT_MIN, LAT_MAX))
    # A plateau straddling T is the GOOD case: every dial in it ships, so offer the block's
    # n-weighted centroid, as far as possible from wherever the curve starts moving again.
    flat = None
    for b in blocks:
        if b["j"] > b["i"] and abs(b["value"] - T) <= 10.0:
            flat = b
    extra = list(extra_cands) + ([flat["centroid"]] if flat else [])

    def _block_members(xv):
        for m in merged:
            if abs(m["x"] - xv) < 1e-9:
                return min(g["x"] for g in m["members"]), max(g["x"] for g in m["members"])
        return xv, xv
    rwin = (min(_block_members(x_a)[0], x_a), max(_block_members(x_b)[1], x_b))
    cands = candidate_set(x_a, x_b, lat, points, x_cur, extra, rwin)
    ev = evaluate_candidates(F, cands, points, cm, x_cur)
    xr, n_left, n_right, nB = roots_at(F, T)
    res = {"merged": merged, "mlog": mlog, "F": F, "xm": xm, "wm": wm, "nm": nm, "blocks": blocks,
           "x_a": x_a, "x_b": x_b, "lo_ext": lo_ext, "hi_ext": hi_ext, "S_br": S_br, "lat": lat,
           "cands": cands, "ev": ev, "roots": xr, "flat": flat,
           "frac_left": n_left / float(nB), "frac_right": n_right / float(nB),
           "root_identified": (n_left + n_right) <= 0.20 * nB and len(xr) > 0}
    if ev["unattainable"]:
        res.update({"low_pwork": True, "i_star": None, "x_star": None, "med": None,
                    "feasible": False, "V_star": None, "V_free": None, "price_T": None,
                    "i_free": None})
        return res
    i_star, i_free, med, feasible, feas_mask = pick_dial(ev, T, opt.tol)
    res.update({"feas_mask": feas_mask, "low_pwork": False, "i_star": i_star, "i_free": i_free, "med": med,
                "feasible": feasible, "x_star": float(cands[i_star]),
                "V_star": float(ev["V"][i_star]), "V_free": float(ev["V"][i_free]),
                "price_T": float(ev["V"][i_star] - ev["V"][i_free])})
    return res


# ---------------------------------------------------------------------------- 8. the decision
# There is exactly ONE action: play the next chunk at a dial.  There is no separate "probe" action,
# because there is no such thing as a probe here -- deepkyu_cfg.bot_name puts every game played at a
# dial into that dial's own SGF bucket, so every game is a certificate game for whichever dial ends
# up being shipped.  v1 had a one-step lookahead that could recommend spending a chunk at a dial it
# would not ship; deepkyu_bakeoff.py measured it over 75 matched (truth, seed) runs and it cost
# +480 games per run on average (t = 2.1, more expensive in 39 runs against cheaper in 18), so it
# was deleted rather than tuned.
#
# The rule the cost model assumes and the rule the decision layer follows are now the SAME rule:
#   play at a dial until the dual-Z rule certifies it, refutes it, or it has swallowed `cap` games,
#   then re-place.
# That is what sim_forward simulates, so V(x) is the exact value of the policy actually followed,
# and it is what makes the loop terminate: every visit to a dial is bounded by `cap`, and V* < inf
# bounds the expected number of visits.


def _bank_state(points, x):
    """(w, n, certified, refuted) for the real bucket at this dial."""
    w0, n0, _nm = bank_of(points, x)
    if n0 <= 0:
        return 0.0, 0.0, False, False
    c, r = cert_state(np.array([w0]), np.array([n0]))
    return w0, n0, bool(c[0]), bool(r[0])


def decide(points, T, cm, opt, x_cur, seed=SEED, res=None):
    """Which dial gets the next chunk, and why.

    Two quantities are compared and they are the SAME functional evaluated on the SAME posterior
    draws: V(incumbent) and V(x*).  Both already carry the move cost and the continuation value, so
    the difference is a pure "does moving pay", and its Monte-Carlo error is the paired sd over the
    common draws.  Nothing else enters.
    """
    if res is None:
        res = core(points, T, cm, opt, x_cur, seed=seed)
    out = {"res": res, "x_star": None, "x_next": None, "n_next": 0, "reason": "",
           "dV": 0.0, "mcse": 0.0, "eps": 0.0, "i_cur": None, "stuck": False}
    if res["low_pwork"]:
        out["action"] = "UNATTAINABLE"
        return out
    ev, cands = res["ev"], res["cands"]
    i_star, x_star = res["i_star"], res["x_star"]
    out["x_star"] = x_star
    i_cur = None
    if x_cur is not None:
        hit = np.flatnonzero(np.abs(cands - x_cur) <= 1e-6)
        if hit.size:
            i_cur = int(hit[0])
    out["i_cur"] = i_cur
    # A bucket that already satisfies the dual-Z rule is the whole point of the exercise: stop.
    for pt in points:
        if pt["bank_n"] > 0:
            c, _r = cert_state(np.array([pt["bank_w"]]), np.array([pt["bank_n"]]))
            if bool(c[0]):
                out.update({"action": "CERTIFIED", "x_next": pt["x"], "n_next": 0,
                            "i_next": i_star, "cert_x": pt["x"], "cert_name": pt["name"],
                            "reason": "bucket %s (%d games) already satisfies the dual-Z rule"
                                      % (pt["name"], int(pt["bank_n"]))})
                return out
    _w, n_cur, cert_cur, ref_cur = _bank_state(points, x_cur) if x_cur is not None else (0, 0, 0, 0)
    chosen, reason = i_star, "no incumbent dial is set, so the cheapest candidate is chosen"
    if i_cur is not None:
        dV = float(ev["V"][i_cur] - ev["V"][i_star]) if np.isfinite(ev["V"][i_cur]) else float("inf")
        mcse = mcse_diff(ev, i_cur, i_star)
        eps = max(0.5 * opt.chunk, 2.0 * mcse)
        out.update({"dV": dV, "mcse": mcse, "eps": eps})
        on_target = bool(res["feas_mask"][i_cur])
        alive = (not ref_cur) and np.isfinite(ev["V"][i_cur]) and n_cur < cm.cap
        if ref_cur:
            chosen, reason = i_star, "the incumbent is REFUTED by the dual-Z rule: abandon it"
        elif n_cur >= cm.cap:
            chosen, reason = i_star, ("the incumbent has passed the %d-game abandonment cap without"
                                      " resolving: re-place" % cm.cap)
        elif not on_target:
            chosen = i_star
            reason = ("the incumbent's median delivered gap misses T by more than the %.0f ELO the "
                      "ladder step allows, so it is not a dial this rung may ship" % opt.tol)
        elif opt.sticky and alive and n_cur > 0:
            chosen = i_cur
            reason = ("committed: the incumbent is unrefuted, on target and below the %d-game "
                      "abandonment cap -- which is exactly the policy V prices, and is what makes "
                      "this loop terminate" % cm.cap)
            out["stuck"] = True
        elif dV > eps:
            chosen = i_star
            reason = ("moving pays: V(incumbent) - V(x*) = %.0f > %.0f = max(half a chunk, 2 MCSE)"
                      % (dV, eps))
        else:
            chosen = i_cur
            reason = ("staying: V(incumbent) - V(x*) = %.0f is inside %.0f = max(half a chunk, "
                      "2 MCSE), so the move does not pay" % (dV, eps))
    out.update({"action": "PLAY", "x_next": float(cands[chosen]), "n_next": int(opt.chunk),
                "i_next": chosen, "reason": reason})
    return out


# ---------------------------------------------------------------------------- 9. diagnostics
def phi_audit(points, F, nblocks):
    """Per-dial standardised residuals in WIN-COUNT space and the Pearson overdispersion estimate.
    phi = 1 is assumed here AND in the published Wilson certificate; nnRandomize=false exists to
    keep it true.  This is the cheap check that it still is."""
    xs = [p["x"] for p in points]
    med = np.median(curve_at(F, xs), axis=0)
    pr = p_of_gap(med)
    z = np.array([(p["w"] - p["n"] * pi) / math.sqrt(max(p["n"] * pi * (1 - pi), 1e-9))
                  for p, pi in zip(points, pr)])
    df = max(1, len(points) - nblocks)
    return z, float((z ** 2).sum() / df), df


def ppc_tail(points, F, seed=20260913):
    """Posterior-predictive tail probability of each dial's observed win count."""
    rng = np.random.default_rng(seed)
    P = p_of_gap(curve_at(F, [p["x"] for p in points]))
    out = []
    for i, p in enumerate(points):
        sim = rng.binomial(int(round(p["n"])), P[:, i])
        out.append(float((sim < p["w"]).mean() + 0.5 * (sim == p["w"]).mean()))
    return out


# ---------------------------------------------------------------------------- 10. report
def fmt_x(x):
    return "%+.4f" % x if abs(x) < 1e3 else "%.3g" % x


def need_summary(gaps):
    """Median of deepkyu_tally.games_needed over a gap posterior, and the mass outside the band.

    games_needed diverges at the band edge and is undefined outside it, so E[games_needed] over this
    posterior is INFINITE (measured ~7e8 by Monte Carlo at the live rung-1 dials).  Only medians and
    capped summaries are reported here; a plug-in games_needed(point gap) is neither the mean nor
    the median and is printed only as the number the rest of the campaign tooling used to use.
    """
    g = np.asarray(gaps, float)
    out = float(np.mean((g <= BAND_LO) | (g >= BAND_HI)))
    vals = np.array([dt.games_needed(float(v)) or np.inf for v in g])
    med = float(np.median(vals))
    return (None if not np.isfinite(med) else med), out


def run(args):
    t0 = time.time()
    st = dl.load()
    rung = args.rung
    if args.data:
        rows = load_json(args.data)
        strong, rank, nfiles, warns = args.strong, args.rank, 0, []
        x_cur = args.x_cur
    else:
        cache = args.cache or os.path.join(dl.RUN, "cache_ladder.json")
        rows, strong, rank, nfiles, warns = load_live(st, rung, cache, args.sgf_dir or [dl.sgf_dir()])
        x_cur = float(st["ranks"][rung - 1]["x"]) if rung - 1 < len(st["ranks"]) else None
        if args.x_cur is not None:
            x_cur = args.x_cur
    if not rows:
        raise SystemExit("no games for this rung")
    points, amb = group_by_x(rows)
    warns = list(warns) + amb
    T = args.target if args.target is not None else dl.target_gap_for(st, rung - 1)
    rate = args.rate if args.rate is not None else (56.0 if rung == 1 else 740.0)

    opt = Opt(draws=args.draws, boot=args.boot, tol=args.tol,
              s_max=args.s_max, min_slope_w=args.min_slope_w, sigma_warp=args.sigma_warp,
              chunk=args.chunk, sticky=not args.no_commit)
    cm = CertCost(trials=args.sim_trials, check=args.sim_check, cap=args.cap)

    print("=" * 100)
    print("deepkyu_place  rung %d:  %s   (weaker rank %s)" % (rung, strong, rank))
    print("target T = %+.1f   band [%g,%g]   rate %.0f games/h   %d SGF files   %d buckets, "
          "%d dials, %d games"
          % (T, BAND_LO, BAND_HI, rate, nfiles, len(rows), len(points),
             sum(r["n"] for r in rows)))
    print("seed %d   draws %d   bootstrap %d   sigma_warp %.2f   S_MAX %g ELO/unit   legal dial "
          "domain [%.2f, %.2f]" % (SEED, opt.draws, opt.boot, opt.sigma_warp, opt.s_max,
                                   X_MIN, X_MAX))
    print("cost MC: %d trials/state, look every %d games, cap %d games, dual-Z rule Z_STOP=%.2f"
          % (args.sim_trials, args.sim_check, args.cap, Z_STOP))
    for w in warns:
        print("  !! " + w)

    # -- 1. observations and the information floor --------------------------
    nfl = games_floor(T)
    print("\n-- 1. observations, and the information floor ------------------------------------")
    print("%-9s %-32s %8s %6s %9s %8s %7s %7s" %
          ("x", "bot", "w", "n", "obs gap", "sd_gap", "nores%", "vs floor"))
    below = 0
    for r in rows:
        sdg = sd_gap(r["w"], r["n"])
        nrp = 100.0 * r["noresult"] / max(1.0, r["n"] + r["noresult"])
        flag = "BELOW" if r["n"] < nfl else "ok"
        below += 1 if r["n"] < nfl else 0
        print("%-9s %-32s %8.1f %6d %+9.1f %8.1f %7.2f %7s" %
              (fmt_x(r["x"]), r["name"][:32], r["w"], int(r["n"]),
               gap_of_p(r["w"] / r["n"]), sdg, nrp, flag))
    print("information floor at T=%+.0f: %.0f games (1 sigma of the measured gap = half the band "
          "margin %.0f)" % (T, nfl, min(T - BAND_LO, BAND_HI - T)))
    print("%d of %d buckets are below it -- a dial below the floor cannot localise the crossing."
          % (below, len(rows)))
    nores_frac = max((r["noresult"] / max(1.0, r["n"] + r["noresult"])) for r in rows)

    # -- 2. merge diagnostic ------------------------------------------------
    res = core(points, T, cm, opt, x_cur)
    print("\n-- 2. merge diagnostic (Lipschitz S_MAX=%g + G2 homogeneity) ---------------------"
          % opt.s_max)
    for line in res["mlog"]:
        print(line)
    print("  %d dials -> %d resolvable points" % (len(points), len(res["merged"])))
    for m in res["merged"]:
        if len(m["members"]) > 1:
            print("    x=%.4f  w=%.1f n=%d  gap %+.1f +-%.1f   absorbs %s"
                  % (m["x"], m["w"], int(m["n"]), gap_of_p(m["w"] / m["n"]),
                     sd_gap(m["w"], m["n"]),
                     ",".join("%.3f" % g["x"] for g in m["members"])))

    # -- 3. isotonic fit ----------------------------------------------------
    F = res["F"]
    med_raw = np.median(curve_at(F, [p["x"] for p in points]), axis=0)
    z, phi, dfp = phi_audit(points, F, len(res["blocks"]))
    tails = ppc_tail(points, F)
    print("\n-- 3. isotonic fit (weighted PAVA = the exact monotone binomial MLE) -------------")
    print("%-9s %6s %9s %9s %9s %8s %9s" %
          ("x", "n", "obs gap", "iso gap", "post med", "resid z", "ppc tail"))
    for i, p in enumerate(points):
        j = int(np.argmin(np.abs(res["xm"] - p["x"])))
        warn = "  <-- WARN" if not (0.025 <= tails[i] <= 0.975) else ""
        print("%-9s %6d %+9.1f %+9.1f %+9.1f %8.2f %9.3f%s" %
              (fmt_x(p["x"]), int(p["n"]), gap_of_p(p["w"] / p["n"]), F["iso_gap"][j],
               med_raw[i], z[i], tails[i], warn))
    print("Pearson phi_hat = %.2f on %d df (phi=1 is assumed here AND by the published Wilson "
          "certificate)" % (phi, dfp))
    if phi > 1.5 and dfp >= 4:
        print("  !! OVERDISPERSED: refitting with n -> n/phi_hat. Both this placement and any "
              "certificate from these games are too narrow.")
        points = [dict(p, w=p["w"] / phi, n=p["n"] / phi, bank_w=p["bank_w"] / phi,
                       bank_n=p["bank_n"] / phi) for p in points]
        res = core(points, T, cm, opt, x_cur)
        F = res["F"]

    # -- 4. bracket, LR interval, x_hat -------------------------------------
    xm = res["xm"]
    raw_merged, _ = merge_dials(points, 1e12, 0.0)   # no merging: what a naive isotonic tool prints
    xr_raw = np.array([m["x"] for m in raw_merged])
    iso_raw = gap_of_p(pava_dec(np.array([[m["w"] / m["n"] for m in raw_merged]]),
                                np.array([m["n"] for m in raw_merged]))[0])
    ba_r, bb_r, _, _ = bracket_of(xr_raw, iso_raw, T, 200.0, widen=False)
    acc, LR, cut, _ll = lr_interval(res["wm"], res["nm"], T, opt.boot)
    iv = bins_to_interval(acc, xm)
    acc99, _, _, _ = lr_interval(res["wm"], res["nm"], T, opt.boot, level=0.99)
    iv99 = bins_to_interval(acc99, xm)
    print("\n-- 4. where the crossing is ------------------------------------------------------")
    print("bracket on UNMERGED dials : [%.4f, %.4f]   (what a naive isotonic fit would print)"
          % (ba_r, bb_r))
    print("bracket after merging     : [%.4f, %.4f]   slope %.0f ELO/unit   lattice %.4f%s"
          % (res["x_a"], res["x_b"], res["S_br"], res["lat"],
             "   (far end is an EXTRAPOLATION)" if (res["lo_ext"] or res["hi_ext"]) else ""))
    if iv:
        print("LR 95%% CI on x* (MONOTONICITY ALONE, no shape prior): (%s, %s]%s"
              % ("-inf" if iv[0] == -np.inf else "%.4f" % iv[0],
                 "+inf" if iv[1] == np.inf else "%.4f" % iv[1],
                 "   NON-CONTIGUOUS, hull shown" if iv[2] else ""))
    if iv99:
        print("LR 99%% CI on x*                                     : (%s, %s]"
              % ("-inf" if iv99[0] == -np.inf else "%.4f" % iv99[0],
                 "+inf" if iv99[1] == np.inf else "%.4f" % iv99[1]))
    xr = res["roots"]
    if res["root_identified"]:
        q = lambda a: float(np.quantile(xr, a))
        print("x_hat (PRIOR-DEPENDENT: warp prior inside the bracket) = %.4f   50%% [%.4f, %.4f]   "
              "90%% [%.4f, %.4f]" % (q(0.5), q(0.25), q(0.75), q(0.05), q(0.95)))
    else:
        print("x_hat = NOT IDENTIFIED. %.1f%% of posterior draws never reach T inside the sampled "
              "dials and %.1f%% are already past T at the first one, so the crossing is outside the"
              " data and any number here would come from the extrapolation prior, not the games."
              % (100 * res["frac_right"], 100 * res["frac_left"]))
        if res["frac_right"] > res["frac_left"]:
            print("        The one-sided statement the data DOES support: x* > %.4f." % xm[-1])
        else:
            print("        The one-sided statement the data DOES support: x* < %.4f." % xm[0])
    print("draws never reaching T inside the span: %.1f%%   draws crossing left of the data: %.1f%%"
          % (100 * res["frac_right"], 100 * res["frac_left"]))
    if res["flat"]:
        b = res["flat"]
        print("FLAT OPTIMUM: T sits in an isotonic block of width %.3f in x (%.4f..%.4f, n=%d) -- "
              "placement precision is not the binding constraint, spend on certification."
              % (b["x_hi"] - b["x_lo"], b["x_lo"], b["x_hi"], int(b["n"])))

    # -- 5. what certification actually costs --------------------------------
    ev = res["ev"]
    print("\n-- 5. what certification actually costs ------------------------------------------")
    show_g = (70, 75, 80, 85, 90, 100, 110, 120, 130)
    gi = [int(np.argmin(np.abs(GAP_GRID - g))) for g in show_g]
    fresh = cm.full(0.0, 0.0)
    print("simulating the rule in force (dual-Z, looked at every %d games, abandon at %d):"
          % (cm.check, cm.cap))
    print("   %-16s %s" % ("true gap", " ".join("%7.0f" % g for g in show_g)))
    print("   %-16s %s" % ("P(certify)", " ".join("%7.2f" % fresh["p_cert"][i] for i in gi)))
    print("   %-16s %s   <- CONDITIONAL on certifying"
          % ("E[games|cert]", " ".join("%7.0f" % fresh["e_cert"][i] for i in gi)))
    print("   %-16s %s   <- every branch: cert, refutation, cap"
          % ("E[games]", " ".join("%7.0f" % fresh["e_all"][i] for i in gi)))
    print("   %-16s %s   <- 90%%-POWER fixed N, not a cost"
          % ("POWER90 table", " ".join("%7s" % (dt.games_needed(g) or "-") for g in show_g)))
    ib = int(np.argmax([bank_of(points, c)[1] for c in res["cands"]]))
    wb, nb, nmb = bank_of(points, res["cands"][ib])
    print("NEVER plug a point estimate into a convex cost, and never credit a bank by subtraction.")
    if nb > 0:
        gobs = float(gap_of_p(wb / nb))
        gdb = ev["GC"][:, ib]
        nmed, pout = need_summary(gdb)
        print("   at x=%.4f (bucket %s), which already holds %d games reading %+.1f:"
              % (res["cands"][ib], nmb, int(nb), gobs))
        print("     plug-in games_needed(obs gap)                = %s games   (what "
              "deepkyu_ladder.cmd_plan and deepkyu_tally used to report)" % (dt.games_needed(gobs) or "-"))
        print("     MEDIAN games_needed over the gap posterior   = %s games   (%.1f%% of the "
              "posterior is OUTSIDE the band, where games_needed is undefined -- so the MEAN of "
              "games_needed does not exist)"
              % ("%.0f" % nmed if nmed else "NOT DEFINED (>50% outside the band)", 100 * pout))
        q_b, s_b = cm.components(nb, wb)
        print("     simulated forward from the realised (%.0f/%d) = %.0f games, P(certify) %.2f"
              "   <- the honest number: finite only because the policy may abandon"
              % (wb, int(nb), float(np.mean(np.interp(gdb, GAP_GRID, s_b))),
                 float(np.mean(np.interp(gdb, GAP_GRID, q_b)))))

    # -- 6. candidate dials --------------------------------------------------
    if res["low_pwork"]:
        print("\n!! NO CANDIDATE DIAL REACHES P(certify) > %.0f%%.  There is no finite continuation "
              "value to report, so none is printed." % (100 * Q_MIN))
        hole = (not res["hi_ext"] and not res["lo_ext"]
                and res["x_b"] - res["x_a"] <= MIN_SLOPE_W + 1e-9)
        if hole:
            print("   The bracket has collapsed with one end below the band and the other above it:"
                  " TARGET UNATTAINABLE ON THIS LEVER, no number of games fixes it. The escape "
                  "levers deepkyu_cfg documents are chosenMoveTemperatureOnlyBelowProb (flattens "
                  "only the tail, protecting the endgame pass) and nnPolicyTemperature past "
                  "X_HALFLIFE_CAP=%.1f; the alternative is to renegotiate T for this rung and let "
                  "a neighbour absorb the difference." % dc.X_HALFLIFE_CAP)
        edge = res["x_b"] if res["hi_ext"] else res["x_a"]
        at_edge = ((res["hi_ext"] and edge >= X_MAX - 1e-9)
                   or (res["lo_ext"] and edge <= X_MIN + 1e-9))
        if not hole and not at_edge:
            print("   The bracket's far end is still an EXTRAPOLATION (%s), i.e. T is beyond every "
                  "dial played so far. This is the normal early state of a rung, not saturation: "
                  "probe at the far edge and re-run." % ("right" if res["hi_ext"] else "left"))
        if at_edge:
            print("   The bracket has run into the end of the legal dial domain, so there is no "
                  "far edge left to probe.")
        if at_edge:
            print("\nACTION: STOP -- the bracket runs into the end of the legal dial domain "
                  "[%.2f, %.2f]. This lever cannot deliver T = %+.0f on this rung at all; change "
                  "lever (chosenMoveTemperatureOnlyBelowProb, nnPolicyTemperature) or renegotiate "
                  "T." % (X_MIN, X_MAX, T))
        else:
            print("\nACTION: EXTEND -- play %d games at x = %.4f (the far edge of the bracket) "
                  "and re-run." % (args.chunk, edge))
        print("  runtime %.1f s" % (time.time() - t0))
        print("=" * 100)
        return

    i_star = res["i_star"]; cands = res["cands"]; x_star = res["x_star"]; med = res["med"]
    print("\n-- 6. candidate dials (V = expected TOTAL forward games, abandonment priced) ------")
    print("%-9s %7s %9s %-17s %8s %8s %10s %s" %
          ("x", "n_have", "med gap", "90% CI", "P(band)", "P(cert)", "V", ""))
    lo90 = np.quantile(ev["GC"], 0.05, axis=0); hi90 = np.quantile(ev["GC"], 0.95, axis=0)
    pband = np.mean((ev["GC"] > BAND_LO) & (ev["GC"] < BAND_HI), axis=0)
    order = np.argsort(np.where(np.isfinite(ev["V"]), ev["V"], np.inf))
    show = sorted(set(list(order[:12]) + [i_star, res["i_free"]] +
                      [i for i, c in enumerate(cands) if bank_of(points, c)[1] > 0]))
    for i in show:
        _w0, _n0, _nm = bank_of(points, cands[i])
        tag = []
        if i == i_star: tag.append("<== SHIP")
        if i == res["i_free"]: tag.append("(cost optimum, T ignored)")
        if abs(cands[i] - (x_cur if x_cur is not None else 1e9)) < 1e-6: tag.append("(current dial)")
        if not ev["ok"][i]: tag.append("(P(cert) below %.0f%%: not a candidate)" % (100 * Q_MIN))
        print("%-9s %7d %+9.1f [%+7.1f,%+7.1f] %8.3f %8.3f %10s %s" %
              (fmt_x(cands[i]), int(_n0), med[i], lo90[i], hi90[i], pband[i], ev["Q"][i],
               ("%.0f" % ev["V"][i]) if np.isfinite(ev["V"][i]) else "-", " ".join(tag)))
    print("restart value V* (abandon and re-place optimally) = %.0f games; V(x*) = S + move + "
          "(1-P(cert))*V* = %.0f" % (ev["Vstar"], res["V_star"]))
    if res["root_identified"]:
        print("x_hat (root of gap(x)=T) = %.4f   vs   x* (argmin V) = %.4f   -- they differ on "
              "purpose: cost is convex, so a tightly-known dial beats a better-centred one."
              % (float(np.median(xr)), x_star))
    if not res["feasible"]:
        print("  !! T is NOT reachable among the candidates: the closest misses by %.1f ELO. "
              "Shipping the cheapest dial within %.0f ELO of that best achievable miss. This rung "
              "will come in short of its ladder step."
              % (float(np.min(np.abs(med - T))), opt.tol))
    print("price of the |median gap - T| <= %.0f constraint: %+.0f games (free optimum x=%.4f at "
          "%.0f). The certification cost depends on the BAND, never on T, so without this "
          "constraint every rung would certify while the ladder's span drifted."
          % (opt.tol, res["price_T"], cands[res["i_free"]], res["V_free"]))
    pband_star = float(pband[i_star])

    # -- 7. the comparison the decision actually makes -----------------------
    dec = decide(points, T, cm, opt, x_cur, res=res)
    print("\n-- 7. the comparison the decision makes ------------------------------------------")
    print("There is one action -- play the next chunk at a dial -- so the decision is one")
    print("comparison of the SAME functional on the SAME posterior draws: V(incumbent) vs V(x*).")
    print("Both already carry the move cost and the continuation value, and the error bar below is")
    print("the paired sd of their difference over the common draws, not the error of either level.")
    if dec["i_cur"] is None:
        print("   no incumbent dial is set (--x-cur), so there is nothing to compare: x* it is.")
    else:
        wC, nC, certC, refC = _bank_state(points, x_cur)
        gl, gh = np.array(wilson_np(np.array([wC]), np.array([max(nC, 1.0)]), Z_STOP))[:, 0]
        print("   incumbent x = %.4f   %d games   dual-Z gap interval [%+.0f, %+.0f]   %s"
              % (x_cur, int(nC), gap_of_p(gh), gap_of_p(gl),
                 "CERTIFIED" if certC else ("REFUTED" if refC else "still running")))
        print("   V(incumbent) = %10.0f" % ev["V"][dec["i_cur"]])
        print("   V(x* = %.4f) = %10.0f" % (x_star, ev["V"][i_star]))
        print("   difference   = %10.0f   MCSE %.0f   threshold max(half a chunk, 2 MCSE) = %.0f"
              % (dec["dV"], dec["mcse"], dec["eps"]))
    print("   -> %s" % dec["reason"])

    # -- 8. sensitivity and gates -------------------------------------------
    print("\n-- 8. sensitivity, and the gates -------------------------------------------------")
    sweep = []
    for sg in (0.40, 0.80, 1.50):
        for mw in (0.03, 0.05, 0.10):
            r2 = core(points, T, cm, opt, x_cur, B=max(1500, opt.draws // 5),
                      sigma_warp=sg, min_slope_w=mw)
            if not r2["low_pwork"]:
                sweep.append((sg, mw, r2["x_star"], r2["V_star"]))
    spread = (max(s[2] for s in sweep) - min(s[2] for s in sweep)) if sweep else 0.0
    print("prior sweep (sigma_warp x MIN_SLOPE_W -- both DO change the fit and the merge), x*:")
    print("   %s" % ", ".join("%.2f/%.2f:%.3f" % (a, b, c) for a, b, c, _ in sweep))
    prior_gate = spread > max(2 * res["lat"], DIAL_EPS)
    print("  x* spread across priors = %.4f (lattice %.4f) -> %s"
          % (spread, res["lat"], "DISAGREE" if prior_gate else "agree"))
    caps = []
    if not args.no_sensitivity:
        for mult in (0.5, 1.0, 2.0):
            cmx = cm if mult == 1.0 else CertCost(trials=args.sim_trials, check=args.sim_check,
                                                  cap=int(args.cap * mult))
            r3 = res if mult == 1.0 else core(points, T, cmx, opt, x_cur,
                                              B=max(1500, opt.draws // 5))
            caps.append((int(args.cap * mult), r3["x_star"], r3["V_star"]))
        print("abandonment-cap sensitivity: %s"
              % ", ".join(("cap %d -> x*=%.4f (%.0f games)" % c) if c[1] is not None
                          else ("cap %d -> UNATTAINABLE" % c[0]) for c in caps))
        flip = [c for c in caps if c[1] is not None and abs(c[1] - x_star) > res["lat"]]
        print("  %s" % (("recommendation FLIPS at cap %d -- the answer is riding on the economic "
                         "assumption, not on the statistics" % flip[0][0]) if flip else
                        "no flip across 0.5x..2x the cap: the recommendation is robust to it"))
    hull = (min(p["x"] for p in points), max(p["x"] for p in points))
    sl_lo = float(np.median((curve_at(F, [x_star]) - curve_at(F, [x_star - res["lat"] * 3]))[:, 0])
                  / (3 * res["lat"]))
    sl_hi = float(np.median((curve_at(F, [x_star + res["lat"] * 3]) - curve_at(F, [x_star]))[:, 0])
                  / (3 * res["lat"]))
    sharp = max(sl_lo, sl_hi) > 2.0 * max(min(sl_lo, sl_hi), 1e-9)
    gates = []
    if nores_frac > 0.02:
        gates.append(("HARD", "no-result rate %.1f%% > 2%%: high chosen-move temperature is filling"
                              " the board and the certificate's protocol assumes decided games"
                      % (100 * nores_frac)))
    if prior_gate:
        gates.append(("HARD", "the shape prior, not the data, is choosing the dial (x* moves %.4f "
                              "across the prior sweep)" % spread))
    if pband_star < 0.80:
        gates.append(("SOFT", "P(delivered gap in band) = %.2f < 0.80 at x* -- V averages over an "
                              "abandon branch the operator experiences as failure" % pband_star))
    if not res["root_identified"]:
        gates.append(("SOFT", "the crossing is not identified by the data (%.0f%% of draws never "
                              "reach T inside the sampled dials): the dial rests on the declared "
                              "extrapolation prior" % (100 * res["frac_right"])))
    if not (hull[0] <= x_star <= hull[1]):
        gates.append(("SOFT", "x* = %.4f is outside the sampled hull [%.3f, %.3f]"
                      % (x_star, hull[0], hull[1])))
    if sharp:
        gates.append(("SOFT", "sharp response: median slope %.0f -> %.0f ELO/unit across x*; the "
                              "delivered-gap interval below is POST-SELECTION (x* is chosen partly "
                              "because its interval is tight) and is not a 90%% interval"
                      % (sl_lo, sl_hi)))
    if phi > 1.5:
        gates.append(("SOFT", "phi_hat = %.2f: intervals here AND the published certificate are "
                              "too narrow" % phi))
    if not res["feasible"]:
        gates.append(("SOFT", "T is not reachable among the candidates (best miss %.1f ELO): the "
                              "rung will certify but the ladder's span will be short"
                      % float(np.min(np.abs(med - T)))))
    if any(p["ambiguous"] for p in points):
        gates.append(("SOFT", "at least one dial carries two physically different buckets; the "
                              "response fit pools them but only one of them can hold a certificate"))
    for kind, msg in gates:
        print("  [%s] %s" % (kind, msg))
    if not gates:
        print("  no gate fired")
    zsel = norm_isf(math.erfc(Z_STOP / math.sqrt(2.0)) / max(1, len(points)))
    marg = min(T - BAND_LO, BAND_HI - T)
    print("selection bias: the dial is chosen from %d candidates and the SAME games then certify "
          "it. Z_STOP=%.2f was validated at band margin 30; Bonferroni over %d dials would want "
          "z=%.2f, ~%.2fx the games. This rung's margin is %.0f -- %s"
          % (len(points), Z_STOP, len(points), zsel, (zsel / Z_STOP) ** 2, marg,
             "inside the validated regime." if marg >= 25 else
             "OUTSIDE it, so either raise Z_STOP or certify only on games played after the dial "
             "was fixed."))

    # -- 9. the action -------------------------------------------------------
    hard = [m for k, m in gates if k == "HARD"]
    kind = "HOLD" if hard else dec["action"]
    x_next, n_next = dec["x_next"], dec["n_next"]
    i_next = dec.get("i_next", i_star)
    _w0, n_have, nm_have = bank_of(points, x_next)
    print("\n" + "=" * 100)
    bot = (dc.resolve({"rank": rank, "maxVisits": 1, "x": x_next, "sym": 1})["name"]
           if rank else "(rank unknown)")
    if kind == "CERTIFIED":
        print("ACTION: DONE -- %s" % dec["reason"])
        w0, n0, nm0 = bank_of(points, dec["cert_x"])
        gl, gh = np.array(wilson_np(np.array([w0]), np.array([n0]), Z_STOP))[:, 0]
        g95l, g95h = np.array(wilson_np(np.array([w0]), np.array([n0]), 1.96))[:, 0]
        print("  bucket          %s at x = %.4f, %d games, %.1f%% to the weaker side"
              % (nm0, dec["cert_x"], int(n0), 100.0 * w0 / n0))
        print("  gap             %+.1f   Z=2.50 [%+.1f, %+.1f]   published Z=1.96 [%+.1f, %+.1f]"
              % (gap_of_p(w0 / n0), gap_of_p(gh), gap_of_p(gl), gap_of_p(g95h), gap_of_p(g95l)))
        print("  runtime %.1f s" % (time.time() - t0))
        print("=" * 100)
        return
    if kind == "PLAY":
        label = "CERTIFY" if n_have > 0 else "PLACE"
        print("ACTION: %s at x = %.4f -- play %d games there" % (label, x_next, n_next))
        print("  bot             %s" % bot)
        print("  banked here     %d games in bucket %s" % (int(n_have), nm_have or "(none yet)"))
        print("  delivered gap   %+.1f  90%% [%+.1f, %+.1f]   P(in band) %.3f  (POST-SELECTION)"
              % (med[i_next], np.quantile(ev["GC"][:, i_next], 0.05),
                 np.quantile(ev["GC"][:, i_next], 0.95), float(pband[i_next])))
        print("  expected total  V = %.0f games = %.1f h at %.0f games/h  (P(certify here) %.2f, "
              "restart value V* = %.0f)"
              % (ev["V"][i_next], ev["V"][i_next] / rate, rate, ev["Q"][i_next], ev["Vstar"]))
        print("  why             %s" % dec["reason"])
        if x_next != x_star:
            print("  note            the cheapest candidate on paper is x = %.4f (V = %.0f); the "
                  "rule above says the move does not pay" % (x_star, ev["V"][i_star]))
    else:
        print("ACTION: HOLD -- do not certify")
        for m in hard:
            print("  gate            %s" % m)
        print("  suggested       fix the gate, then re-run; the cheapest dial is x = %.4f" % x_star)
    cmdset = ("python3 deepkyu_ladder.py set %s=%.4f && " % (rank, x_next)
              if rank and (x_cur is None or abs(x_next - x_cur) > 1e-6) else "")
    print("  run             %sRUNGS=%d N=1 CHUNK=%d bash deepkyu_step.sh"
          % (cmdset, rung, int(n_next)))
    print("  abandon rule    move the dial when deepkyu_tally's stop_lo > %g or stop_hi < %g at "
          "this bucket, or when it passes %d games -- that is exactly the policy V prices"
          % (BAND_HI, BAND_LO, cm.cap))
    print("  runtime %.1f s   (%d distinct cost simulations)" % (time.time() - t0, cm.calls))
    print("=" * 100)

    if args.json_out:
        blob = {"rung": rung, "rank": rank, "strong": strong, "target": T, "rate": rate,
                "action": kind, "x_star": x_star, "x_next": x_next, "n_next": int(n_next),
                "x_hat": (float(np.median(xr)) if res["root_identified"] else None),
                "x_hat_90": ([float(np.quantile(xr, 0.05)), float(np.quantile(xr, 0.95))]
                             if res["root_identified"] else None),
                "root_identified": bool(res["root_identified"]),
                "lr95": None if not iv else [None if iv[0] == -np.inf else iv[0],
                                             None if iv[1] == np.inf else iv[1]],
                "bracket": [res["x_a"], res["x_b"]], "lattice": res["lat"],
                "delivered_gap": float(med[i_star]),
                "delivered_gap_90": [float(np.quantile(ev["GC"][:, i_star], 0.05)),
                                     float(np.quantile(ev["GC"][:, i_star], 0.95))],
                "p_band": pband_star, "V_star": res["V_star"], "V_restart": ev["Vstar"],
                "dV_incumbent_minus_xstar": dec["dV"], "eps": dec["eps"],
                "mcse": dec["mcse"], "reason": dec["reason"],
                "phi_hat": phi, "T_reachable": bool(res["feasible"]),
                "n_have": n_have, "frac_right": res["frac_right"], "frac_left": res["frac_left"],
                "price_of_T": res["price_T"], "gates": gates,
                "prior_sweep": [[a, b, c, d] for a, b, c, d in sweep], "cap_sweep": caps,
                "candidates": [{"x": float(cands[i]), "med_gap": float(med[i]),
                                "p_band": float(pband[i]), "p_cert": float(ev["Q"][i]),
                                "V": (float(ev["V"][i]) if np.isfinite(ev["V"][i]) else None),
                                "n_have": bank_of(points, cands[i])[1]} for i in range(len(cands))],
                "dials": [{"x": r["x"], "name": r["name"], "w": r["w"], "n": r["n"],
                           "noresult": r["noresult"]} for r in rows]}
        json.dump(blob, open(args.json_out, "w"), indent=1, default=float)
        print("wrote %s" % args.json_out, file=sys.stderr)


# ---------------------------------------------------------------------------- 11. self-test
# The real rung-1 design: the dials and sample sizes this campaign actually played.
SELFTEST_DESIGN = [(-0.650, 99), (0.000, 90), (0.350, 137), (0.520, 409), (0.545, 792),
                   (0.550, 122), (0.630, 240), (0.750, 51), (0.950, 50), (1.370, 26)]

TRUTHS = {
    # mimics the fitted rung-1 response: flat, steep rise through the band, plateau, then a climb
    "smooth": [(-1.0, 28.0), (0.30, 36.0), (0.50, 70.0), (0.62, 110.0), (0.95, 140.0),
               (1.20, 220.0), (1.60, 340.0)],
    # T sits INSIDE an exactly flat stretch: x is genuinely unidentified there and must say so
    "plateau": [(-1.0, 30.0), (0.30, 40.0), (0.60, 100.0), (0.95, 100.0), (1.20, 180.0),
                (1.60, 330.0)],
    # a corner: ~570 ELO/unit through the crossing
    "steep": [(-1.0, 30.0), (0.45, 40.0), (0.58, 114.0), (0.75, 130.0), (1.20, 200.0),
              (1.60, 320.0)],
    # the crossing sits beyond every dial the design plays: the honest answer is NOT IDENTIFIED
    "late": [(-1.0, 10.0), (0.60, 30.0), (1.00, 55.0), (1.50, 95.0), (2.00, 150.0), (2.60, 260.0)],
    # a staircase: the response jumps, so no smooth interpolation is right anywhere
    "step": [(-1.0, 25.0), (0.52, 30.0), (0.5201, 95.0), (0.90, 100.0), (0.9001, 175.0),
             (1.60, 300.0)],
}


def truth_gap(name, x):
    pts = TRUTHS[name]
    return float(np.interp(x, [p[0] for p in pts], [p[1] for p in pts]))


def truth_root(name, T):
    xs = np.linspace(-1.0, 2.6, 36001)
    gs = np.array([truth_gap(name, x) for x in xs])
    i = int(np.argmax(gs >= T))
    return float(xs[i]) if gs[i] >= T else float("nan")


class _Args(object):
    """A stand-in for the argparse namespace, so the report can be smoke-tested in-process."""
    rung = 1; target = 100.0; data = ""; rank = "15k"; strong = "(synthetic)"; x_cur = None
    rate = 56.0; sgf_dir = None; cache = ""; json_out = ""
    draws = 3000; boot = 200; s_max = S_MAX; min_slope_w = MIN_SLOPE_W
    sigma_warp = SIGMA_WARP; tol = TOL_T; cap = 20000; sim_trials = 250; sim_check = 180
    chunk = 400; no_sensitivity = True; no_commit = False

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def selftest(args):
    import io, contextlib
    T = args.target if args.target is not None else 100.0
    ok = True
    print("deepkyu_place self-test   T = %.0f" % T)

    # 1. the x axis is only meaningful if a bot NAME inverts back to the x that produced it.
    bad = []
    for x in np.round(np.arange(-0.65, 11.51, 0.01), 4):
        e, l, h, npt = dc.dial_params(float(x))
        nm = dc.bot_name("15k", 1, e, l, h, 1, 1.0, npt, 1.0)
        xb, why = invert_bot_name(nm)
        if xb is None or abs(xb - float(x)) > 2e-3:
            bad.append((float(x), nm, xb, why))
    print("\n-- 1. bot-name <-> dial round trip, all four dial_params branches ----------------")
    print("   1217 dials from -0.65 to 11.50: %d failures%s"
          % (len(bad), ("  e.g. " + str(bad[:2])) if bad else ""))
    ok = ok and not bad

    # 2. the value function: closed form vs value iteration, and the no-solution case.
    print("\n-- 2. continuation value: closed form vs value iteration -------------------------")
    rng = np.random.default_rng(7)
    worst = 0.0
    for _ in range(200):
        k = int(rng.integers(1, 9))
        S = rng.uniform(50, 8000, k); q = rng.uniform(0.01, 1.0, k)
        mv = MOVE_COST * (rng.random(k) < 0.5)
        V, Vs, okm = solve_value(S, q, mv)
        if V is None:
            continue
        Vi = value_iterate(S, q)
        worst = max(worst, abs(Vs - Vi) / max(Vs, 1.0))
    print("   max |closed form - value iteration| / V* over 200 random instances = %.2e" % worst)
    ok = ok and worst < 1e-6
    Vn, _, _ = solve_value(np.array([1000.0]), np.array([0.001]), np.array([0.0]))
    print("   a problem with no workable dial returns %s (never a capped number)" % Vn)
    ok = ok and Vn is None

    # 3. duplicate x, and the report's own format strings, exercised on every branch.
    print("\n-- 3. report smoke test: duplicate x, unattainable target, normal case -----------")
    cases = {
        "duplicate-x (two buckets on one dial)":
            [{"x": 0.545, "w": 306, "n": 792, "name": "15k_A"},
             {"x": 0.545, "w": 20, "n": 100, "name": "15k_B"},
             {"x": 0.63, "w": 82, "n": 240, "name": "15k_C"}],
        "hole: a gap the dials straddle but never visit":
            [{"x": 0.50, "w": 700, "n": 1000, "name": "h1"},
             {"x": 0.52, "w": 100, "n": 1000, "name": "h2"}],
        "unattainable: lever saturated at the domain edge":
            [{"x": 11.40, "w": 900, "n": 1000, "name": "u1"},
             {"x": 11.50, "w": 905, "n": 1000, "name": "u2"}],
        "normal": [{"x": 0.35, "w": 61, "n": 137, "name": "n1"},
                   {"x": 0.545, "w": 306, "n": 792, "name": "n2"},
                   {"x": 0.63, "w": 82, "n": 240, "name": "n3"}],
        "single dial": [{"x": 0.545, "w": 306, "n": 792, "name": "s1"}],
    }
    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".place_selftest.json")
    for label, data in cases.items():
        json.dump(data, open(tmp, "w"))
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                run(_Args(data=tmp, target=T, no_sensitivity=True))
            txt = buf.getvalue()
            hit = [k for k in ("ACTION:",) if k in txt]
            print("   %-38s OK  (%d lines, %s)" % (label, len(txt.splitlines()),
                                                   txt.split("ACTION: ")[1].split("\n")[0][:40]
                                                   if hit else "no ACTION line"))
            ok = ok and bool(hit)
        except Exception as e:
            print("   %-38s FAIL  %s: %s" % (label, type(e).__name__, e))
            ok = False
    if os.path.exists(tmp):
        os.remove(tmp)

    # 4. placement calibration at the REAL design points.
    print("\n-- 4. one-shot placement at the real rung-1 design (%d reps) ---------------------"
          % args.reps)
    cm = CertCost(trials=250, check=400, cap=20000)
    opt = Opt(draws=3000, boot=200, chunk=400)
    print("%-9s %9s %9s %9s %9s %9s %9s %9s" %
          ("truth", "x_true", "x_hat", "id'd", "cov LR", "cov gap", "in band", "med|gap-T|"))
    for name in TRUTHS:
        xt = truth_root(name, T)
        rng = np.random.default_rng(4242)
        xh, cl, inband, dg, idf, cg = [], [], [], [], [], []
        for _rep in range(args.reps):
            pts = []
            for x, n in SELFTEST_DESIGN:
                p = float(p_of_gap(truth_gap(name, x)))
                pts.append({"x": x, "name": "x=%.3f" % x, "w": float(rng.binomial(n, p)),
                            "n": float(n), "noresult": 0})
            pts, _ = group_by_x(pts)
            r = core(pts, T, cm, opt, None)
            idf.append(bool(r["root_identified"]))
            if r["root_identified"]:
                xh.append(float(np.median(r["roots"])))
            acc, _, _, _ = lr_interval(r["wm"], r["nm"], T, 200)
            iv = bins_to_interval(acc, r["xm"])
            cl.append(bool(iv) and (iv[0] <= xt <= iv[1] if xt == xt else iv[1] == np.inf))
            if r["low_pwork"]:
                inband.append(False); dg.append(np.nan); continue
            tg = truth_gap(name, r["x_star"])
            inband.append(BAND_LO < tg < BAND_HI)
            dg.append(abs(tg - T))
            gs = r["ev"]["GC"][:, r["i_star"]]
            cg.append(float(np.quantile(gs, 0.05)) <= tg <= float(np.quantile(gs, 0.95)))
        print("%-9s %9.3f %9s %8.0f%% %8.0f%% %8.0f%% %8.0f%% %9.1f"
              % (name, xt, ("%.3f" % np.median(xh)) if xh else "not id'd",
                 100 * np.mean(idf), 100 * np.mean(cl),
                 100 * np.mean(cg) if cg else float("nan"), 100 * np.mean(inband),
                 float(np.nanmedian(dg))))
    print("   'cov gap' is the nominal-90% delivered-gap interval's MEASURED coverage. It is a")
    print("   POST-SELECTION interval -- x* is chosen partly because its interval is tight -- so it")
    print("   is reported, never claimed. 'in band' is one-shot placement accuracy from a FIXED")
    print("   design, not the closed loop; deepkyu_bakeoff.py measures the thing that matters.")
    print("\nSELFTEST %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--rung", type=int, default=1)
    ap.add_argument("--target", type=float, default=None, help="default: ladder.json's per-rung target")
    ap.add_argument("--data", default="", help='JSON [{"x":..,"w":..,"n":..}, ...] instead of an SGF scan')
    ap.add_argument("--rank", default=None, help="weaker rank name when using --data")
    ap.add_argument("--strong", default="(from --data)")
    ap.add_argument("--x-cur", type=float, default=None, help="dial currently set (for the move cost)")
    ap.add_argument("--rate", type=float, default=None, help="games/h (default 56 for rung 1, else 740)")
    ap.add_argument("--sgf-dir", action="append", default=None)
    ap.add_argument("--cache", default="")
    ap.add_argument("--json-out", default="")
    ap.add_argument("--draws", type=int, default=8000)
    ap.add_argument("--boot", type=int, default=1200, help="bootstrap replicates for the LR cutoffs")
    ap.add_argument("--s-max", type=float, default=S_MAX, help="Lipschitz bound, ELO per unit x")
    ap.add_argument("--min-slope-w", type=float, default=MIN_SLOPE_W)
    ap.add_argument("--sigma-warp", type=float, default=SIGMA_WARP)
    ap.add_argument("--tol", type=float, default=TOL_T, help="|median delivered gap - T| allowed")
    ap.add_argument("--cap", type=int, default=CAP_GAMES, help="games past which you re-place instead")
    ap.add_argument("--sim-trials", type=int, default=400)
    ap.add_argument("--sim-check", type=int, default=180, help="games between looks at the stop rule")
    ap.add_argument("--chunk", type=int, default=540, help="deepkyu_step.sh chunk size")
    ap.add_argument("--no-commit", action="store_true",
                    help="re-optimise the dial every chunk instead of committing to an unrefuted "
                         "on-target dial until the dual-Z rule ends it")
    ap.add_argument("--no-sensitivity", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--reps", type=int, default=40, help="self-test replicates per truth")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest(a))
    run(a)


if __name__ == "__main__":
    main()
