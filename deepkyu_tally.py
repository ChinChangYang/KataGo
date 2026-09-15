#!/usr/bin/env python3
"""Tally `katago match` SGFs into per-rung even-game gaps with Wilson 95% CIs.

The certification rule (lightvector/KataGo#1209, docs/HumanSL_Rank_Ladder.md) is TWO-SIDED: a
rung is certified when the Wilson 95% interval (binomial, phi=1) of its even-game gap BOTH lies
entirely inside [70,130] ELO AND CONTAINS 100. An interval like [70, 87.5] is invalid however
tight. Because `status` is recomputed after every chunk, the two halves are enforced with
opposite disciplines -- containment on the WIDER Z_STOP=2.50 interval, coverage on the NARROWER
Z_COVER=1.50 one -- so the published Z=1.96 certificate satisfies both a fortiori after
arbitrarily many looks. Formulas are the ones tune_elo.py / tune_fit.py use, verbatim.

WHAT THE SECOND HALF DOES TO "HOW MANY MORE GAMES". Under containment alone the answer was a
THRESHOLD: play until the interval is narrow enough. Under the two-sided rule the requirement is
a WINDOW in n -- the half-width must be small enough to stay inside the band and LARGE enough to
still reach 100 -- so for a true gap off centre there is no n that certifies, and for one near
centre the window eventually CLOSES. games_needed()/need_median() below answer the OLD one-sided
question and are kept only for that; the honest replacement for "need ~N games" is
cert_outlook(), which reports P(this bucket ever certifies) and, conditional on that, the games
it takes.

Games are bucketed by SGF PB/PW, i.e. by BOT NAME, and deepkyu_cfg.py encodes the dial in the
name -- so a dial change starts a fresh bucket and stale games can never be pooled.

Usage:
  python3 deepkyu_tally.py --sgf-dir DIR [--sgf-dir DIR2 ...] \
      [--rungs "strongA:weakA,strongB:weakB"] [--json-out out.json] [--all-pairs]
"""
import argparse, json, math, os, random, re, sys

Z = 1.96          # the PUBLISHED certificate interval (what the goal asks for)
Z_STOP = 2.50     # OUTER interval: must fit inside the band before a rung may be certified
Z_COVER = 1.50    # INNER interval: must COVER the band centre before a rung may be certified
BAND_LO, BAND_HI = 70.0, 130.0
BAND_MID = 100.0  # the published 95% CI must CONTAIN this, not merely lie inside the band

RE_PB = re.compile(r"PB\[([^\]]*)\]")
RE_PW = re.compile(r"PW\[([^\]]*)\]")
RE_RE = re.compile(r"RE\[([^\]]*)\]")
RE_MOVE = re.compile(r";[BW]\[")


def wilson(w, n, z=Z):
    """Wilson interval (fraction) at z. At z=Z it is identical to tune_fit.wilson."""
    if n == 0:
        return (0.0, 1.0)
    p = w / n
    den = 1 + z * z / n
    cen = (p + z * z / (2 * n)) / den
    mar = (z / den) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, cen - mar), min(1.0, cen + mar))


def gapfromw(p):
    """Even-game ELO gap (stronger - weaker) from the WEAKER side's winrate p."""
    p = min(max(p, 1e-9), 1.0 - 1e-9)
    return 400.0 * math.log10((1.0 - p) / p)


def wfromgap(g):
    return 1.0 / (1.0 + 10.0 ** (g / 400.0))


def wilson_gap_ci(w, g, z=Z):
    """(point, lo, hi) gap in ELO from the weaker side's w wins in g decided games."""
    p = w / g
    plo, phi_ = wilson(w, g, z)
    return gapfromw(p), gapfromw(phi_), gapfromw(plo)


# Simulation-calibrated certification cost, keyed by the band margin m = min(gap-70, 130-gap).
# The naive n = (Z*dgap/dp)^2*p(1-p)/m^2 sets the EXPECTED half-width equal to the margin, which
# certifies only if the point estimate lands centred -- measured by simulation at 0% success for a
# true gap of 100 and 42% at 92.
# These are the sample sizes at which a fixed-N run certifies 90% of the time under the rule
# ACTUALLY IN FORCE, which is the Z_STOP=2.50 stop rule, not the Z=1.96 publication interval
# (4000-trial binomial MC, seed 20260910). The Z=1.96 column of the same simulation reproduces the
# earlier table -- 1892 vs 1961 at gap 100, 4640 vs 4630 at 87.2 -- so both calibrations agree;
# the ~1.35x here is the price of certificates that survive being looked at after every chunk.
POWER90_Z196 = {30: 1892, 26: 2077, 22: 2770, 20: 3329, 17: 4640, 15: 5945}
POWER90 = {30: 2488, 26: 2762, 22: 3822, 20: 4582, 17: 6165, 15: 8178}


def games_needed(gap, band_lo=BAND_LO, band_hi=BAND_HI):
    """ONE-SIDED, AND KEPT ONLY FOR THE QUESTION IT ANSWERS. Games for a ~90% chance that the
    Z_STOP interval lands inside the band at this true gap -- the CONTAINMENT half alone.

    IT IS NOT "GAMES UNTIL CERTIFIED" AND MUST NOT BE PRINTED AS ONE. The rule in force also
    requires the interval to CONTAIN 100, which bounds the half-width BELOW as well as above, so
    the set of n that certify is a window, not a tail: at a true gap of 90 no n certifies with
    probability 1 (the honest answer is P = 0.71), and at a gap of 92.2 a certificate that stands
    at n = 1704 is DESTROYED by n = 4786. A "need ~N" built on this function therefore advises
    games that can take the rung away. cert_outlook() is the replacement; this stays because the
    containment half is still a real question (the power table it interpolates is a measurement)
    and because deepkyu_place2's docstrings cite it as the one-sided baseline."""
    m = min(gap - band_lo, band_hi - gap)
    if m <= 0:
        return None
    ks = sorted(POWER90)
    if m >= ks[-1]:
        return POWER90[ks[-1]]
    if m <= ks[0]:
        return int(POWER90[ks[0]] * (ks[0] / m) ** 2)      # extrapolate as 1/m^2
    for a, b in zip(ks, ks[1:]):
        if a <= m <= b:
            t = (m - a) / (b - a)
            return int(POWER90[a] + t * (POWER90[b] - POWER90[a]))
    return None


def _norm_ppf(u):
    """Standard normal quantile by bisection on math.erfc (scipy is not installed)."""
    if u <= 0.0:
        return -12.0
    if u >= 1.0:
        return 12.0
    lo, hi = -12.0, 12.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        cdf = 0.5 * math.erfc(-mid / math.sqrt(2.0))
        if cdf < u:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def need_median(w, n, band_lo=BAND_LO, band_hi=BAND_HI, nodes=401):
    """MEDIAN of games_needed over the gap posterior, plus the posterior mass outside the band.

    ONE-SIDED, LIKE THE FUNCTION IT SUMMARISES: it fixes the plug-in bug in games_needed() and
    inherits its question. Do not print it as "games until this rung certifies" -- see
    games_needed()'s docstring and cert_outlook(), which is what the status lines now use.

    games_needed(point gap) is a PLUG-IN into a function that is convex, non-monotone and DIVERGENT
    at both band edges, so it is neither the mean nor the median of what it is meant to summarise.
    At the live rung-1 dial x=0.63 (82/240) the plug-in says 7108 games and the posterior median is
    14799 -- a factor of two, in the direction that matters.  (At 306/792 the two happen to agree:
    that dial sits where the posterior is nearly symmetric about the plug-in, which is exactly why
    a plug-in cannot be trusted without checking.)  The MEAN does not exist at all: 20.7% of that
    posterior lies outside [70,130], where games_needed is undefined, so E[games_needed] is
    infinite.  Every consumer must summarise over the posterior, and the only finite summaries are
    medians and capped quantiles.

    The posterior for the gap is taken as normal on the ELO scale with the delta-method sd, which is
    the same approximation the Wilson interval already makes.  Returns (median or None, p_outside).
    """
    if n <= 0:
        return None, 1.0
    p = min(max(w / n, 0.5 / n), 1.0 - 0.5 / n)
    sd = (400.0 / math.log(10.0)) / math.sqrt(n * p * (1.0 - p))
    g0 = gapfromw(p)
    vals = []
    out = 0
    for k in range(nodes):
        g = g0 + sd * _norm_ppf((k + 0.5) / nodes)
        v = games_needed(g, band_lo, band_hi)
        if v is None:
            out += 1
            vals.append(float("inf"))
        else:
            vals.append(float(v))
    vals.sort()
    med = vals[nodes // 2]
    return (None if med == float("inf") else int(round(med))), out / float(nodes)

# ---------------------------------------------------------------------------------------------
# THE HONEST REPLACEMENT FOR `need~N`.
#
# Under the one-sided rule "how many more games?" had an answer, so the status line could print
# one. Under the two-sided rule it does not, and the question is ill-posed in a way that is not a
# rounding error: for a TRUE gap of 90 there is no n at which the rule certifies with certainty
# -- the whole truth is a probability, 0.71 at 540-game looks and 0.77 at 60 (deepkyu_place2's
# LOOK table, which is why the look cadence is an input here) -- and for a bucket off centre more
# make a certificate LESS likely, not more. Printing a game count there is worse than printing
# nothing: on the live rung 4 the dial at 1807/4668 read `need~19066` while its actual
# probability of EVER certifying, from its own bank, was 0.001.
#
# What is true under the rule in force is a pair:
#     P(certify)          the chance this bucket ever satisfies BOTH halves if you keep playing
#                         at this dial, over the bucket's own gap posterior; and
#     games | certify     the games it takes IN THE WORLDS WHERE IT DOES -- a conditional median,
#                         reported only when the condition is not vanishingly rare.
# Both come from simulating the rule ACTUALLY IN FORCE forward from the realised (w, n), which is
# the same construction deepkyu_place2.forward_summary uses; that file's selftest cross-checks
# the two implementations, which are deliberately separate so a bug cannot hide in both.
LOOK_FINE = 60        # games between looks while the window is open. The rule is re-tested after
                      # every chunk in the live loop, so the number of looks inside the window is
                      # the number of chances; 60 mirrors deepkyu_place2.LOOK.
LOOK_DENSE = 5000     # ...past which the look schedule coarsens (99% of a bucket's certification
LOOK_COARSE = 540     # probability has arrived by n ~ 5000, so the tail is not worth the time).
CAP_GAMES = 12000     # additional games simulated at one dial before giving up. P(certify) is
                      # monotone in this and has converged well before it: past the window's
                      # close only a return of the estimate to centre can certify, and that is
                      # what the tail of the simulation is measuring.
OUTLOOK_TRIALS = 800  # stratified posterior draws, one forward play each; MC sd of P at most
                      # 0.018 (the i.i.d. bound -- stratifying beats it), which is the resolution
                      # of the two decimals the status line prints.
OUTLOOK_SEED = 20260913
PCERT_LIVE = 0.05     # BELOW THIS, "how many more games" IS REPORTED AS NOT APPLICABLE, not as a
                      # number: a conditional median over a handful of lucky trials answers "how
                      # long, in the worlds where a 2% event happens", which no operator reading
                      # a status line wants handed to them as a plan. It is a REPORTING
                      # threshold. The one thing keyed on it is deepkyu_ladder `plan`'s advisory
                      # GRIND/CORRECT label, which took the same branch on the old `need is
                      # None`; ACTIVE (the only machine-read output) is identical either way.
_OUTLOOK_CACHE = {}


def _cert_state(w, n):
    """(certified, refuted) for one bucket under the rule in force. The same two halves
    pair_stats applies, in one place, so the forward simulation cannot drift away from the
    status line it is printed beside."""
    slo, shi = wilson_gap_ci(w, n, Z_STOP)[1:]
    clo, chi = wilson_gap_ci(w, n, Z_COVER)[1:]
    cert = (slo >= BAND_LO and shi <= BAND_HI and clo <= BAND_MID <= chi)
    ref = (shi < BAND_LO or slo > BAND_HI)
    return cert, (ref and not cert)


P_HI_W = wfromgap(BAND_LO)      # 0.4008: the weaker side's winrate at a gap of  70
P_LO_W = wfromgap(BAND_HI)      # 0.3231: ...and at a gap of 130
P_MID_W = wfromgap(BAND_MID)    # 0.3599: ...and at the band centre


def _cert_bounds(n):
    """(w_cert_lo, w_cert_hi, w_ref_lo, w_ref_hi): the SAME rule as _cert_state, in closed form.

    The Wilson score interval at level z contains p0 exactly when |w - n*p0| <= z*sqrt(p0*q0*n),
    so each half of the rule is a linear inequality in the win count and the whole rule is an
    interval of w at every n. That turns the inner loop of cert_outlook() from four Wilson
    evaluations into two comparisons -- worth about 10x on a bucket whose every trial runs to the
    cap, which is exactly the bucket an operator is most likely to be staring at.

    CERTIFIED is w in [w_cert_lo, w_cert_hi]; REFUTED is w < w_ref_lo or w > w_ref_hi. The
    The equivalence is not assumed: deepkyu_place2's selftest [3b] checks the two forms against
    each other on a (w, n) grid, and its [2c] checks the same identity against pair_stats over
    ~85,000 pairs."""
    s = lambda p, z: z * math.sqrt(p * (1.0 - p) * n)
    return (max(P_LO_W * n + s(P_LO_W, Z_STOP), P_MID_W * n - s(P_MID_W, Z_COVER)),
            min(P_HI_W * n - s(P_HI_W, Z_STOP), P_MID_W * n + s(P_MID_W, Z_COVER)),
            P_LO_W * n - s(P_LO_W, Z_STOP),
            P_HI_W * n + s(P_HI_W, Z_STOP))


def cert_outlook(w, n, trials=OUTLOOK_TRIALS, look=LOOK_FINE, cap=CAP_GAMES,
                 seed=OUTLOOK_SEED, pcert_live=PCERT_LIVE):
    """P(this bucket ever certifies) and, conditional on that, the games it takes.

    Returns {"p_cert", "med_more", "mean_more", "q90_more", "state", "cap", "trials"}, with
    med_more/mean_more/q90_more None when p_cert < pcert_live (see PCERT_LIVE) or nothing
    certified.

    METHOD. Draw a true gap from the bucket's own posterior -- normal on the ELO scale with the
    delta-method sd, the same approximation the Wilson interval already makes -- and play the
    two-sided rule forward from (w, n) at that gap, looking every `look` games, until it
    CERTIFIES, is REFUTED, or `cap` further games are spent. The draws are STRATIFIED over the
    posterior quantiles rather than sampled i.i.d., which is what keeps 800 trials enough.

    WHAT IT DOES NOT MODEL, deliberately: the OVERSHOT abandon exit of deepkyu_place2, which is a
    POLICY ("this dial is no longer worth paying for"), not part of the rule. So this is the
    GENEROUS reading -- if P is ~0 here it is ~0 even for an operator willing to keep grinding --
    and it reads slightly higher than deepkyu_place2's residual P(certify), which prices the
    policy as well.

    Deterministic: the same (w, n) gives the same numbers on every run, and results are memoised.
    """
    key = (round(float(w), 1), round(float(n), 1), int(trials), int(look), int(cap), int(seed))
    if key in _OUTLOOK_CACHE:
        return _OUTLOOK_CACHE[key]
    out = {"p_cert": 0.0, "med_more": None, "mean_more": None, "q90_more": None,
           "state": "no games", "cap": int(cap), "trials": int(trials)}
    n = float(n)
    if n <= 0:
        _OUTLOOK_CACHE[key] = out
        return out
    cert0, ref0 = _cert_state(w, n)
    if cert0:
        out.update({"p_cert": 1.0, "med_more": 0, "mean_more": 0.0, "q90_more": 0,
                    "state": "CERTIFIED"})
        _OUTLOOK_CACHE[key] = out
        return out
    rng = random.Random(seed)
    p0 = min(max(float(w) / n, 0.5 / n), 1.0 - 0.5 / n)
    sd = (400.0 / math.log(10.0)) / math.sqrt(n * p0 * (1.0 - p0))
    g0 = gapfromw(p0)
    # the look schedule is deterministic and shared by every trial, so the rule's win-count
    # bounds are evaluated once per reachable n rather than once per trial per look
    sched, spent_at, sp = [], [], 0
    while sp < cap:
        step = look if sp < LOOK_DENSE else LOOK_COARSE
        sp += step
        sched.append(step)
        spent_at.append(sp)
    bounds = [_cert_bounds(n + sp) for sp in spent_at]
    got = []
    for t in range(trials):
        p = wfromgap(g0 + sd * _norm_ppf((t + 0.5) / trials))
        ww = float(w)
        for k, step in enumerate(sched):
            ww += rng.binomialvariate(step, p)
            clo_w, chi_w, rlo_w, rhi_w = bounds[k]
            if clo_w <= ww <= chi_w:
                got.append(spent_at[k])
                break
            if ww < rlo_w or ww > rhi_w:
                break
    pc = len(got) / float(trials)
    out["p_cert"] = pc
    out["state"] = "REFUTED" if ref0 else ("dead" if pc < pcert_live else "live")
    if got and pc >= pcert_live:
        got.sort()
        out["med_more"] = int(got[len(got) // 2])
        out["mean_more"] = sum(got) / float(len(got))
        out["q90_more"] = int(got[min(len(got) - 1, int(0.9 * len(got)))])
    _OUTLOOK_CACHE[key] = out
    return out


def outlook_str(o):
    """The status-line rendering of cert_outlook(), so every caller says the same true thing.

    NEVER a bare game count: a count is meaningless without the probability it is conditional on,
    and that pairing is the whole reason `need~N` had to go."""
    if o is None or o.get("state") == "no games":
        return "no games"
    if o.get("state") == "CERTIFIED":
        return "CERTIFIED"
    pc = o["p_cert"]
    if o.get("med_more") is None:
        return "P(cert)=%.2f (%s)" % (pc, "REFUTED" if o.get("state") == "REFUTED"
                                      else "no n certifies")
    return "P(cert)=%.2f +%d games if it does" % (pc, o["med_more"])



def parse_file(path):
    """-> {(pb,pw): [pb_wins, pw_wins, draws, noresults, moves_total, decided]}"""
    out = {}
    with open(path, "rb") as f:
        data = f.read().decode("utf-8", "replace")
    for line in data.split("\n"):
        if "PB[" not in line:
            continue
        mb, mw, mr = RE_PB.search(line), RE_PW.search(line), RE_RE.search(line)
        if not mb or not mw:
            continue
        key = (mb.group(1), mw.group(1))
        rec = out.setdefault(key, [0, 0, 0, 0, 0, 0])
        res = mr.group(1) if mr else ""
        nmoves = len(RE_MOVE.findall(line))
        rec[4] += nmoves
        if res.startswith("B+"):
            rec[0] += 1; rec[5] += 1
        elif res.startswith("W+"):
            rec[1] += 1; rec[5] += 1
        elif res == "0":
            rec[2] += 1; rec[5] += 1
        else:
            rec[3] += 1
    return out


def scan(dirs, cache_path):
    cache = {}
    if cache_path and os.path.exists(cache_path):
        try:
            cache = json.load(open(cache_path))
        except Exception:
            cache = {}
    new_cache = {}
    totals = {}
    nfiles = 0
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for root, _dirs, files in os.walk(d):
            for fn in sorted(files):
                if not (fn.endswith(".sgf") or fn.endswith(".sgfs")):
                    continue
                p = os.path.join(root, fn)
                st = os.stat(p)
                sig = "%d:%d" % (st.st_size, int(st.st_mtime))
                ent = cache.get(p)
                if ent and ent.get("sig") == sig:
                    per = {tuple(k.split("\x1f")): v for k, v in ent["per"].items()}
                else:
                    per = parse_file(p)
                    ent = {"sig": sig, "per": {"\x1f".join(k): v for k, v in per.items()}}
                new_cache[p] = ent
                nfiles += 1
                for k, v in per.items():
                    t = totals.setdefault(k, [0, 0, 0, 0, 0, 0])
                    for i in range(6):
                        t[i] += v[i]
    if cache_path:
        try:
            json.dump(new_cache, open(cache_path, "w"))
        except Exception:
            pass
    return totals, nfiles


def pair_stats(totals, strong, weak):
    """Merge both color orders for one rung. Returns dict with the weaker side's record."""
    wwins = 0.0; swins = 0.0; draws = 0; nores = 0; moves = 0; games = 0
    for (pb, pw), v in totals.items():
        if pb == weak and pw == strong:
            wwins += v[0]; swins += v[1]
        elif pb == strong and pw == weak:
            swins += v[0]; wwins += v[1]
        else:
            continue
        draws += v[2]; nores += v[3]; moves += v[4]; games += v[5] + v[3]
    decided = wwins + swins + draws
    d = {"strong": strong, "weak": weak, "weak_wins": wwins, "strong_wins": swins,
         "draws": draws, "noresult": nores, "decided": int(decided),
         "avg_moves": (moves / games) if games else 0.0}
    if decided > 0:
        w = wwins + 0.5 * draws
        pt, lo, hi = wilson_gap_ci(w, decided)
        # DUAL-Z STOP RULE. `status` is run after every chunk, so certifying the first time the
        # 95% interval happens to fit is optional stopping: with a hundred looks the reported
        # "95% CI" is not a 95% interval at all. A rung may only be declared certified once the
        # WIDER Z_STOP interval fits the band; the published Z=1.96 interval is nested inside it,
        # so it is still a valid 95% certificate after arbitrarily many looks.
        slo, shi = wilson_gap_ci(w, decided, Z_STOP)[1:]
        # TWO-SIDED RULE. The goal now requires the published 95% interval BOTH to lie inside
        # [70,130] AND to CONTAIN 100, so an interval like [70,87.5] is invalid however tight.
        # That makes the width bounded BELOW as well as above -- more games can DESTROY a rung
        # whose point estimate is off centre -- so the two conditions need opposite disciplines
        # against the repeated looks:
        #   containment: the WIDER Z_STOP interval must fit the band. Published (narrower) then
        #                fits a fortiori.
        #   coverage:    the NARROWER Z_COVER interval must contain 100. Published (wider) then
        #                contains it a fortiori.
        # Both are conservative, so the published certificate is valid after arbitrarily many looks.
        clo, chi = wilson_gap_ci(w, decided, Z_COVER)[1:]
        _nm = need_median(w, decided)
        contains = lo <= BAND_MID <= hi
        d.update({"winrate": w / decided, "gap": pt, "lo": lo, "hi": hi,
                  "stop_lo": slo, "stop_hi": shi, "cover_lo": clo, "cover_hi": chi,
                  "certified": (slo >= BAND_LO and shi <= BAND_HI
                                and clo <= BAND_MID <= chi),
                  "ci95_fits": lo >= BAND_LO and hi <= BAND_HI and contains,
                  "ci95_inside": lo >= BAND_LO and hi <= BAND_HI,
                  "ci95_covers": contains,
                  # ONE-SIDED LEGACY KEYS. `need`/`need_plugin` answer "games until the
                  # interval fits the band", which the two-sided rule does not ask; nothing
                  # prints them any more (cert_outlook() is what the status lines use) and they
                  # are kept only so an existing --json-out consumer does not lose a field.
                  "need": _nm[0], "need_plugin": games_needed(pt), "p_out_band": _nm[1]})
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sgf-dir", action="append", required=True)
    ap.add_argument("--rungs", default="", help="comma-separated strongBot:weakBot")
    ap.add_argument("--json-out", default="")
    ap.add_argument("--all-pairs", action="store_true", help="list every observed (PB,PW) bucket")
    ap.add_argument("--cache", default="", help="path for the parse cache (default: <first dir>/../tally_cache.json)")
    a = ap.parse_args()

    cache_path = a.cache or os.path.join(os.path.dirname(os.path.abspath(a.sgf_dir[0].rstrip("/"))), "tally_cache.json")
    totals, nfiles = scan(a.sgf_dir, cache_path)

    if a.all_pairs or not a.rungs:
        print("== observed buckets (PB vs PW) from %d files ==" % nfiles)
        for (pb, pw), v in sorted(totals.items()):
            print("  %-22s (B) vs %-22s (W): B+%d W+%d draw %d nores %d avg_moves %.0f"
                  % (pb, pw, v[0], v[1], v[2], v[3], (v[4] / max(1, v[0] + v[1] + v[2] + v[3]))))
        if not a.rungs:
            return

    rows = []
    for tok in a.rungs.split(","):
        tok = tok.strip()
        if not tok:
            continue
        s, w = tok.split(":")
        rows.append(pair_stats(totals, s, w))

    print()
    print("%-24s %-24s %6s %7s %8s %-16s %4s %6s %s"
          % ("stronger", "weaker", "N", "wr%", "gap", "95% CI", "nores", "avgmv", "status"))
    for r in rows:
        if r["decided"] == 0:
            print("%-24s %-24s %6d %7s %8s %-16s %4d %6s %s"
                  % (r["strong"], r["weak"], 0, "-", "-", "-", r["noresult"], "-", "no games"))
            continue
        # NOT `need~N`: under the two-sided rule there is no such N (see games_needed()).
        status = outlook_str(cert_outlook(r["weak_wins"] + 0.5 * r["draws"], r["decided"]))
        print("%-24s %-24s %6d %7.1f %+8.1f [%+6.1f,%+6.1f] %4d %6.0f %s"
              % (r["strong"], r["weak"], r["decided"], 100 * r["winrate"], r["gap"],
                 r["lo"], r["hi"], r["noresult"], r["avg_moves"], status))
    ncert = sum(1 for r in rows if r.get("certified"))
    print("\nCERTIFIED %d/%d   (band [%g,%g])" % (ncert, len(rows), BAND_LO, BAND_HI))
    if a.json_out:
        json.dump({"rungs": rows, "files": nfiles}, open(a.json_out, "w"), indent=1)
    print("GOAL_MET=%d" % (1 if rows and ncert == len(rows) else 0))


if __name__ == "__main__":
    main()
