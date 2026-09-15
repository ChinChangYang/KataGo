#!/usr/bin/env python3
"""Head-to-head: deepkyu_place against naive bracket-and-interpolate baselines.

THE BAR. A placement tool only earns its complexity if it reaches a VALID certificate in fewer
total games than a naive baseline, on several independent monotone truths and several seeds.  This
script is the referee.  Three things here are deliberately independent of deepkyu_place:

  1. the certification rule is RE-IMPLEMENTED from its specification (Wilson Z = 2.50 interval on
     the weaker side's winrate, mapped through gap = 400*log10((1-p)/p), must lie inside [70,130]).
     Nothing in this file calls deepkyu_tally or deepkyu_place to decide whether a run has finished.
     --check-rule cross-checks the two implementations agree on random (w, n), as a smoke test --
     but the referee is the code below.
  2. the truths are defined here, not imported from deepkyu_place's self-test, and include shapes
     the tool's priors do not favour: a cliff, a long plateau, and a crossing far outside the cold
     start.
  3. every policy gets the SAME cold-start data from the SAME seed, and the same per-round chunk,
     budget and dial domain.

Usage:
  python3 deepkyu_bakeoff.py --truth rung1 --seeds 10 --out bake.jsonl
  python3 deepkyu_bakeoff.py --report bake.jsonl
  python3 deepkyu_bakeoff.py --check-rule
"""
import argparse, json, math, os, sys, time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deepkyu_place as dp

# ---------------------------------------------------------------------------- the referee
Z_CERT = 2.50
BAND = (70.0, 130.0)


def wilson_ci(w, n, z):
    """Wilson score interval for a binomial proportion."""
    if n <= 0:
        return 0.0, 1.0
    ph = float(w) / float(n)
    d = 1.0 + z * z / n
    c = (ph + z * z / (2.0 * n)) / d
    h = (z / d) * math.sqrt(ph * (1.0 - ph) / n + z * z / (4.0 * n * n))
    return max(0.0, c - h), min(1.0, c + h)


def gap_from_p(p):
    p = min(max(float(p), 1e-12), 1.0 - 1e-12)
    return 400.0 * math.log10((1.0 - p) / p)


def p_from_gap(g):
    return 1.0 / (1.0 + 10.0 ** (float(g) / 400.0))


def gap_interval(w, n, z=Z_CERT):
    """(lo, hi) of the ELO gap. gap is DECREASING in p, so the interval flips."""
    plo, phi = wilson_ci(w, n, z)
    return gap_from_p(phi), gap_from_p(plo)


def is_certified(w, n, band=BAND):
    lo, hi = gap_interval(w, n)
    return (lo >= band[0]) and (hi <= band[1])


def is_refuted(w, n, band=BAND):
    lo, hi = gap_interval(w, n)
    return (lo > band[1]) or (hi < band[0])


# ---------------------------------------------------------------------------- the truths
TRUTHS = {
    # shaped like the measured rung 1: flat below 0.30, a steep rise, a plateau at 130-140 from
    # 0.63 to 0.95, then steep again to 432 at 1.37
    "rung1":   [(-0.70, 26.0), (0.30, 36.0), (0.50, 72.0), (0.60, 112.0), (0.63, 130.0),
                (0.95, 140.0), (1.20, 250.0), (1.37, 432.0), (2.50, 600.0)],
    # a near-cliff through the band: ~900 ELO/unit at the crossing
    "cliff":   [(-0.70, 20.0), (0.55, 40.0), (0.62, 130.0), (0.90, 150.0), (1.50, 260.0),
                (2.50, 420.0)],
    # T sits inside a long exactly-flat stretch: the dial is genuinely unidentified there
    "plateau": [(-0.70, 22.0), (0.35, 45.0), (0.70, 100.0), (1.25, 100.0), (1.60, 190.0),
                (2.50, 350.0)],
    # the crossing is far outside the cold start: the policy has to walk a long way right
    "far":     [(-0.70, 8.0), (0.60, 25.0), (1.20, 48.0), (1.90, 82.0), (2.40, 118.0),
                (3.20, 200.0), (4.50, 330.0)],
    # nearly linear and well-conditioned: the case a naive interpolator should be good at
    "gentle":  [(-0.70, 10.0), (0.50, 80.0), (1.00, 140.0), (2.00, 250.0), (3.50, 420.0)],
}


def truth_gap(name, x):
    pts = TRUTHS[name]
    return float(np.interp(x, [p[0] for p in pts], [p[1] for p in pts]))


def truth_root(name, T):
    xs = np.linspace(dp.X_MIN, 5.0, 60001)
    gs = np.array([truth_gap(name, float(x)) for x in xs])
    i = int(np.argmax(gs >= T))
    return float(xs[i]) if gs[i] >= T else float("nan")


# ---------------------------------------------------------------------------- the world
class World(object):
    """Buckets of games.  A dial is a bot, a bot is an SGF bucket, a bucket is a candidate
    certificate.  Every policy sees exactly this and nothing else."""

    def __init__(self, truth, seed, T, chunk, budget):
        self.truth, self.T, self.chunk, self.budget = truth, T, chunk, budget
        self.rng = np.random.default_rng(seed)
        self.data = {}          # rounded x -> [w, n]
        self.games = 0
        self.rounds = 0

    def play(self, x, n):
        x = round(float(min(max(x, dp.X_MIN), dp.X_MAX)), 4)
        n = int(min(n, self.budget - self.games))
        if n <= 0:
            return x
        p = p_from_gap(truth_gap(self.truth, x))
        w = float(self.rng.binomial(n, p))
        d = self.data.setdefault(x, [0.0, 0.0])
        d[0] += w; d[1] += n
        self.games += n
        self.rounds += 1
        return x

    def certificate(self):
        """The first bucket that satisfies the rule, or None."""
        for x in sorted(self.data):
            w, n = self.data[x]
            if is_certified(w, n):
                return x, w, n
        return None

    def rows(self):
        return [{"x": x, "name": "bot@%+.4f" % x, "w": self.data[x][0], "n": self.data[x][1],
                 "noresult": 0} for x in sorted(self.data)]


# The REAL rung-1 observations (14k anchor at 40 visits vs 15k at 1 visit), as of the campaign
# state this tool was repaired against.  Used by --cold-real to ask the one question that matters
# operationally: starting from where the campaign actually is, does the loop TERMINATE, and how
# many more games does each policy need?
REAL_RUNG1 = [(-0.650, 43, 99), (0.000, 42, 90), (0.350, 61, 137), (0.520, 153, 409),
              (0.545, 306, 792), (0.550, 42, 122), (0.630, 82, 240), (0.750, 16, 51),
              (0.950, 16, 50), (1.370, 2, 26)]


def real_compatible(truth, max_z=4.0):
    """--cold-real hands every policy the REAL rung-1 observations.  Those observations were
    produced by the real response, so pairing them with a synthetic truth that flatly contradicts
    them (say, a truth that puts gap 62 at x=1.37 where 2 wins in 26 games say 432) asks every
    policy to fit an impossibility and reports a meaningless 0% for all of them.  Truths are
    screened here instead: the largest standardised binomial residual of the real counts under the
    truth must be under max_z."""
    worst = 0.0
    for x, w, n in REAL_RUNG1:
        p = p_from_gap(truth_gap(truth, x))
        worst = max(worst, abs(w - n * p) / math.sqrt(max(n * p * (1 - p), 1e-9)))
    return worst <= max_z, worst


def cold_start(world, design):
    if design == "real":
        for x, w, n in REAL_RUNG1:
            world.data[round(x, 4)] = [float(w), float(n)]
    else:
        for x, n in design:
            world.play(x, n)
    world.games = 0
    world.rounds = 0


# ---------------------------------------------------------------------------- policies
def _obs_gaps(world):
    return sorted((x, gap_from_p(world.data[x][0] / world.data[x][1]), world.data[x][1])
                  for x in world.data)


def _interpolate_dial(world, T):
    """The naive rule: bracket T with the two observed dials on either side of it and interpolate
    linearly for gap = T.  With no bracket, extrapolate along the slope of the two most extreme
    dials.  Clipped to the legal dial domain."""
    g = _obs_gaps(world)
    below = [q for q in g if q[1] <= T]
    above = [q for q in g if q[1] >= T]
    if below and above:
        a = max(below, key=lambda q: q[1])
        b = min(above, key=lambda q: q[1])
        if abs(b[1] - a[1]) < 1e-9 or abs(b[0] - a[0]) < 1e-9:
            return 0.5 * (a[0] + b[0])
        return a[0] + (b[0] - a[0]) * (T - a[1]) / (b[1] - a[1])
    if len(g) >= 2:
        (x0, g0, _), (x1, g1, _) = (g[-2], g[-1]) if not above else (g[0], g[1])
        s = (g1 - g0) / (x1 - x0) if abs(x1 - x0) > 1e-9 else 0.0
        s = s if abs(s) > 20.0 else (20.0 if not above else -20.0)
        base = g[-1] if not above else g[0]
        step = (T - base[1]) / s
        return base[0] + max(-1.0, min(1.0, step))
    return g[0][0] + (0.2 if not above else -0.2)


def policy_interp(world, T, opt):
    """BASELINE 1: play a chunk at the interpolated dial, re-interpolate, repeat."""
    while world.games < world.budget:
        if world.certificate():
            return
        world.play(_interpolate_dial(world, T), world.chunk)


def policy_grind(world, T, opt):
    """BASELINE 2 (the stronger one): interpolate, move there, and GRIND at that dial until the
    rule certifies it, refutes it, or it has swallowed `max_dial` games without doing either --
    then re-interpolate from everything known so far.  This is the baseline that actually banks
    games in one bucket, which is what a certificate needs, and the games-budget abandonment is
    what stops it dying on a dial sitting exactly on the band edge."""
    cur = None
    max_dial = opt.get("max_dial", 6000)
    while world.games < world.budget:
        if world.certificate():
            return
        if cur is None or is_refuted(*world.data[cur]) or world.data[cur][1] >= max_dial:
            nxt = round(float(min(max(_interpolate_dial(world, T), dp.X_MIN), dp.X_MAX)), 4)
            if cur is not None and nxt == cur and world.data[cur][1] >= max_dial:
                # the interpolation wants the dial we just gave up on: step off it by one lattice
                nxt = round(min(dp.X_MAX, max(dp.X_MIN, cur + (0.02 if world.data[cur][0] /
                                                               world.data[cur][1] >
                                                               p_from_gap(T) else -0.02))), 4)
            cur = nxt
        cur = world.play(cur, world.chunk)


def _tool_opt(chunk, sticky, fast):
    return dp.Opt(draws=2500 if fast else 6000, chunk=chunk, sticky=sticky)


def policy_tool(world, T, opt):
    """deepkyu_place's own decision, run every round exactly as the operator would."""
    cm = dp.CertCost(trials=opt["trials"], check=world.chunk, cap=opt["cap"])
    o = _tool_opt(world.chunk, opt["sticky"], opt["fast"])
    x_cur = None
    while world.games < world.budget:
        if world.certificate():
            return
        points, _w = dp.group_by_x(world.rows())
        try:
            dec = dp.decide(points, T, cm, o, x_cur, seed=dp.SEED + world.rounds)
        except Exception as e:                       # a crash is a loss, not an exception
            world.note = "%s: %s" % (type(e).__name__, e)
            return
        if dec["action"] == "CERTIFIED":
            return
        if dec["action"] == "UNATTAINABLE":
            r = dec["res"]
            edge = r["x_b"] if r["hi_ext"] else r["x_a"]
            if (r["hi_ext"] and edge >= dp.X_MAX - 1e-9) or (r["lo_ext"] and edge <= dp.X_MIN + 1e-9):
                world.note = "tool stopped: lever saturated"
                return
            x_cur = world.play(edge, world.chunk)
            continue
        x_cur = world.play(dec["x_next"], dec["n_next"])


POLICIES = {"interp": policy_interp, "grind": policy_grind,
            "tool": policy_tool, "tool_nocommit": policy_tool}
POLICY_OPTS = {"tool": {"sticky": True}, "tool_nocommit": {"sticky": False}}


# ---------------------------------------------------------------------------- driver
def run_one(policy, truth, seed, T, chunk, budget, design, trials, cap, fast):
    w = World(truth, seed, T, chunk, budget)
    w.note = ""
    cold_start(w, design)
    opt = dict({"trials": trials, "cap": cap, "fast": fast, "sticky": True,
                "max_dial": 6000}, **POLICY_OPTS.get(policy, {}))
    t0 = time.time()
    POLICIES[policy](w, T, opt)
    cert = w.certificate()
    tg = truth_gap(truth, cert[0]) if cert else None
    return {"policy": policy, "truth": truth, "seed": seed, "T": T, "chunk": chunk,
            "games": w.games, "rounds": w.rounds, "certified": bool(cert),
            "cert_x": (cert[0] if cert else None), "cert_true_gap": tg,
            "cert_valid": (bool(cert) and BAND[0] < tg < BAND[1]),
            "secs": round(time.time() - t0, 2), "note": w.note,
            "dials": len(w.data)}


def report(path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    if not rows:
        print("no rows"); return
    truths = sorted(set(r["truth"] for r in rows))
    pols = [p for p in ("interp", "grind", "tool_nocommit", "tool")
            if any(r["policy"] == p for r in rows)]
    print("=" * 104)
    print("BAKE-OFF: total games to a VALID certificate, judged by this file's own dual-Z "
          "implementation")
    print("budget %d games/run, chunk %d, cold start %s"
          % (rows[0].get("budget", 0) or max(r["games"] for r in rows), rows[0]["chunk"],
             rows[0].get("design", "(0.00,90) (0.35,137)")))
    print("=" * 104)
    hdr = "%-9s %-13s %5s %8s %8s %8s %8s %8s %9s" % (
        "truth", "policy", "runs", "cert%", "valid%", "med.gms", "mean.gms", "gms/cert", "|gap-T|")
    print(hdr)
    tot = {}
    for t in truths:
        for p in pols:
            rs = [r for r in rows if r["truth"] == t and r["policy"] == p]
            if not rs:
                continue
            nc = [r for r in rs if r["cert_valid"]]
            g = sorted(r["games"] for r in nc)
            gpc = sum(r["games"] for r in rs) / max(1, len(nc))
            dev = [abs(r["cert_true_gap"] - r["T"]) for r in nc]
            print("%-9s %-13s %5d %7.0f%% %7.0f%% %8s %8s %8.0f %9s"
                  % (t, p, len(rs), 100.0 * sum(r["certified"] for r in rs) / len(rs),
                     100.0 * len(nc) / len(rs),
                     ("%.0f" % np.median(g)) if g else "-",
                     ("%.0f" % np.mean(g)) if g else "-",
                     gpc, ("%.1f" % np.median(dev)) if dev else "-"))
            a = tot.setdefault(p, [0, 0, 0.0, []])
            a[0] += len(rs); a[1] += len(nc); a[2] += sum(r["games"] for r in rs)
            a[3] += [r["games"] for r in nc]
        print("-" * 104)
    print("%-9s %-13s %5s %8s %8s %8s %8s %8s %9s" % ("ALL", "", "", "", "", "", "", "", ""))
    for p in pols:
        if p not in tot:
            continue
        n, nc, gsum, g = tot[p]
        print("%-9s %-13s %5d %7.0f%% %7.0f%% %8s %8s %8.0f %9s"
              % ("", p, n, 100.0 * nc / n, 100.0 * nc / n,
                 ("%.0f" % np.median(g)) if g else "-", ("%.0f" % np.mean(g)) if g else "-",
                 gsum / max(1, nc), ""))
    print("=" * 104)
    print("gms/cert = total games spent by that policy divided by its number of VALID certificates.")
    print("It is the only column that handles censoring honestly: a run that never certifies still")
    print("spent its whole budget.  Lower is better.")
    best = min(((tot[p][2] / max(1, tot[p][1]), p) for p in tot))
    print("\nBEST OVERALL: %s at %.0f games per valid certificate." % (best[1], best[0]))
    for p in tot:
        if p != best[1]:
            print("   %-13s %.0f  (%.2fx)" % (p, tot[p][2] / max(1, tot[p][1]),
                                              (tot[p][2] / max(1, tot[p][1])) / best[0]))


def check_rule():
    """Cross-check this file's independent rule against deepkyu_tally's, which deepkyu_place uses."""
    import deepkyu_tally as dt
    rng = np.random.default_rng(11)
    bad = 0
    for _ in range(20000):
        n = int(rng.integers(1, 6000)); w = int(rng.binomial(n, rng.uniform(0.2, 0.55)))
        mine = is_certified(w, n)
        slo, shi = dt.wilson_gap_ci(w, n, dt.Z_STOP)[1:]
        theirs = slo >= dt.BAND_LO and shi <= dt.BAND_HI
        bad += int(mine != theirs)
    print("independent dual-Z rule vs deepkyu_tally on 20000 random (w, n): %d disagreements" % bad)
    rng = np.random.default_rng(12)
    bad2 = 0
    for _ in range(20000):
        n = int(rng.integers(1, 6000)); w = int(rng.binomial(n, rng.uniform(0.05, 0.9)))
        a, b = dp.cert_state(np.array([float(w)]), np.array([float(n)]))
        bad2 += int(bool(a[0]) != is_certified(w, n) or bool(b[0]) != is_refuted(w, n))
    print("independent dual-Z rule vs deepkyu_place.cert_state on 20000 random (w, n): %d "
          "disagreements" % bad2)
    return 0 if (bad == 0 and bad2 == 0) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--truth", default="", help="comma list, default all")
    ap.add_argument("--policies", default="interp,grind,tool_nocommit,tool")
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--seed0", type=int, default=1000)
    ap.add_argument("--target", type=float, default=100.0)
    ap.add_argument("--chunk", type=int, default=500)
    ap.add_argument("--budget", type=int, default=30000)
    ap.add_argument("--trials", type=int, default=200)
    ap.add_argument("--cap", type=int, default=20000)
    ap.add_argument("--fast", action="store_true", default=True)
    ap.add_argument("--out", default="")
    ap.add_argument("--report", default="")
    ap.add_argument("--check-rule", action="store_true")
    ap.add_argument("--cold-real", action="store_true",
                    help="start every policy from the REAL rung-1 observations instead of a "
                         "two-dial synthetic cold start; games counted are the EXTRA games needed")
    a = ap.parse_args()
    if a.check_rule:
        sys.exit(check_rule())
    if a.report:
        report(a.report); return
    design = "real" if a.cold_real else [(0.00, 90), (0.35, 137)]
    truths = [t.strip() for t in a.truth.split(",") if t.strip()] or sorted(TRUTHS)
    pols = [p.strip() for p in a.policies.split(",") if p.strip()]
    done = set()
    if a.out and os.path.exists(a.out):
        for l in open(a.out):
            if l.strip():
                r = json.loads(l)
                done.add((r["policy"], r["truth"], r["seed"]))
    fh = open(a.out, "a") if a.out else None
    for t in truths:
        if a.cold_real:
            okc, z = real_compatible(t)
            if not okc:
                print("# skipping truth %r under --cold-real: it contradicts the real rung-1 "
                      "counts at %.1f sigma, so no policy could certify and the comparison would "
                      "be vacuous" % (t, z), file=sys.stderr)
                continue
        for s in range(a.seed0, a.seed0 + a.seeds):
            for p in pols:
                if (p, t, s) in done:
                    continue
                r = run_one(p, t, s, a.target, a.chunk, a.budget, design, a.trials, a.cap, a.fast)
                r["budget"] = a.budget
                r["design"] = str(design)
                line = json.dumps(r)
                print(line, flush=True)
                if fh:
                    fh.write(line + "\n"); fh.flush()
    if fh:
        fh.close()


if __name__ == "__main__":
    main()
