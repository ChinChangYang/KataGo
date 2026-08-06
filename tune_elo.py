#!/usr/bin/env python3
"""
tune_elo.py — even-game ELO-gap decision brain for the Human-SL ladder re-tune.

Sibling of tune_fit.py, but the calibration target is an EVEN-GAME ELO GAP (not a 50%
handicap winrate). Each rung is tuned so the candidate (weaker) sits exactly G ELO below its
already-locked baseline in even games (komi 6.5, alternating colors): the candidate's target
winrate is w* = 1/(1+10^(G/400)) (< 0.5). The rung LOCKs only when a SINGLE concentrated
lambda's direct Wilson 95% winrate CI, converted to ELO, sits inside [G-ci, G+ci] — i.e. the
adjacent even-game gap is pinned to +-ci ELO. That direct, concentrated measurement (not the
fit's interpolated CI) is the acceptance metric; the Bayesian fit is used ONLY to LOCATE the
crossing lambda to concentrate on (the "concentration-gap" fix: pile games at ONE point).

LOCATE  reuses tune_fit.run_fit's (a,b) grid posterior; the target crossing is
        lambda* = exp(z0 + (logit(w*) - a)/b), weighted-median over the posterior.
CONCENTRATE  GRIND the sampled lambda nearest lambda* (snap to it so games accumulate at one
        point); open a fresh point at lambda* only when no sample is within +-CONC_WIN.
LOCK    a sampled lambda whose Wilson gap-CI is within [G-ci, G+ci] (needs ~525-590 games).
STOP    best-effort if the target is unreachable by lambda alone (saturation) or on budget.

Output: one ACTION line (ACTION=/LAMBDA=/WR=/GAP=/CI=/N=, CI in ELO) + one '# ELOFIT:' line.
Winrates/CI printed for the CANDIDATE (the weaker rung). PURE STDLIB; reuses tune_fit.py.

Usage: tune_elo.py '<samples-glob>' <gap-elo> [<ci-halfwidth=30>]
   e.g. tune_elo.py '~/.katago_tune/elo7d_L*.samples' 100
        tune_elo.py '~/.katago_tune/elo3k_L*.samples' 50 30
"""
import sys, math, os, re
import tune_fit as tf   # reuse load/parse, fit_grid/run_fit, weighted_quantiles, wilson, snap

# ---- constants ----
Z = 1.96                    # 95% normal z
GRID = tf.GRID              # lambda output grid (1e-4)
CONC_WIN = 0.10             # (legacy) window for the nearest-sample helper
CONC_GRID = 0.01            # concentrate on a 1% relative (log) grid AT the crossing, so successive
                            #   chunks re-hit the same lambda (auto-concentration) centered on gap=target.
                            #   1% (not 2%) keeps steep rungs centered within ~a few ELO of the crossing,
                            #   so the single-cell (phi=1) lock lands near target instead of off-center.
LOCK_MIN_G = 120            # a ship lambda needs at least this many games before a LOCK is considered
                            #   (the +-ci Wilson gate itself forces ~525-590; this is a sanity floor)
LOCK_WIN = 0.03             # pooled-window LOCK: pool all samples within +-3% of the crossing and lock on
                            #   their DIRECT Wilson gap-CI (uses games the migrating concentration spread
                            #   across nearby cells; the concentration-gap fix). Tight enough to bound the
                            #   winrate-gradient bias to a few ELO; phi-inflated for overdispersion.
MAXGAMES_PER_LAM = 4000     # per-lambda safety cap -> budget STOP. Also the cell_can_certify budget:
                            #   deep-kyu rungs land NEAR the band edge (e.g. 9k gap +115), where a
                            #   single-cell CI needs ~2500-3800 games to pin ⊂[70,130]. At 2000 a
                            #   perfectly-good in-band cell was judged "can't certify" and re-derived
                            #   forever (9k stuck at 3688g). 4000 lets a near-edge in-band cell simply
                            #   accumulate and lock. Normal rungs certify at ~600-1500g, unaffected.
BUDGET = 8000               # total games safety cap -> budget STOP (raised with MAXGAMES_PER_LAM so a
                            #   hard noisy+steep deep-kyu rung has room to pin one cell before giving up)
SAT_MARGIN = 0.02           # saturation slack (fraction) beyond the band edge


def wfromgap(g):
    """Candidate winrate for an even-game gap of g ELO (baseline stronger by g)."""
    return 1.0 / (1.0 + 10.0 ** (g / 400.0))


def gapfromw(p):
    """Even-game ELO gap (baseline - candidate) from the candidate winrate p."""
    p = min(max(p, 1e-9), 1.0 - 1e-9)
    return 400.0 * math.log10((1.0 - p) / p)


# ---- sticky concentration (flat/noisy rungs) ----
# On a gently-sloped or noisy rung the crossing estimate wobbles chunk-to-chunk, so re-deriving the
# concentration lambda every chunk chases the wobble and spreads games across many lambda (the 2d
# saga: ~2700 games over ~14 lambda, none reaching the ~530-game single-cell lock). The fix: once a
# concentration lambda is picked, PERSIST it in a per-rung state file and keep piling games there;
# only re-derive when that cell is well-sampled AND its gap is clearly off-target (crossing mislocated).
STICKY_REDERIVE_G = LOCK_MIN_G     # only re-pick the sticky lambda once its cell has this many games


def sticky_path_for(glob):
    """Per-rung sticky-concentration state file, derived from the samples glob:
    '~/.katago_tune/elo7d_L*.samples' -> '~/.katago_tune/elo7d_conc.txt'. Returns None for a glob that
    isn't an elo<rank>_ samples glob, so ad-hoc/test callers (and report.py) get NO stickiness."""
    if not glob:
        return None
    m = re.match(r'(elo\d+[dk])_', os.path.basename(glob))
    if not m:
        return None
    return os.path.join(os.path.dirname(os.path.abspath(os.path.expanduser(glob))), m.group(1) + "_conc.txt")


def read_sticky(path):
    try:
        return float(open(path).read().strip())
    except (OSError, ValueError, TypeError):
        return None


def write_sticky(path, lam):
    try:
        with open(path, "w") as f:
            f.write("%.5f" % lam)
    except (OSError, TypeError):
        pass


def clear_sticky(path):
    try:
        os.remove(path)
    except (OSError, TypeError):
        pass


def cell_can_certify(w, g, G, ci, budget=None):
    """Can a single cell at this point estimate plausibly reach a Wilson gap-CI ⊂ [G-ci, G+ci] within
    `budget` games? False if the point is already out of band, OR so near a band EDGE that the games
    needed to shrink its CI inside the band exceed the budget — an off-CENTRE lodge that would grind to
    a budget STOP without ever certifying (e.g. gap +76 for a 100±30 target needs ~14k games because
    +76 is only 6 ELO above the +70 edge). Estimated via the normal-approx required-n in winrate space
    (Wilson-exact isn't needed for a feasibility gate). Used to move the sticky concentration off an
    off-centre lodge toward the fit crossing instead of stalling there."""
    if budget is None:
        budget = MAXGAMES_PER_LAM
    p = w / g
    w_lo, w_hi = wfromgap(G + ci), wfromgap(G - ci)     # winrate band (w_lo < w_hi)
    if not (w_lo < p < w_hi):
        return False
    margin = min(p - w_lo, w_hi - p)
    if margin <= 0:
        return False
    req_n = (Z * math.sqrt(p * (1.0 - p)) / margin) ** 2
    return req_n <= budget


def logit(p):
    return math.log(p / (1.0 - p))


def rgrid(lam, step=CONC_GRID):
    """Snap lam to a relative (multiplicative) log-grid of fractional spacing `step`.
    Stabilizes the concentration lambda against small crossing-estimate jitter."""
    g = math.log(1.0 + step)
    return math.exp(round(math.log(lam) / g) * g)


def wilson_gap_ci(w, g, phi=1.0):
    """Return (gap_point, gap_lo, gap_hi) from a candidate w/g via Wilson on the winrate, with the
    interval inflated by sqrt(phi) for quasi-binomial overdispersion. Lower winrate => larger gap,
    so gap_lo maps from the winrate hi-bound and vice versa."""
    p = w / g
    plo, phe = tf.wilson(w, g)
    if phi > 1.0:
        hw = 0.5 * (phe - plo) * math.sqrt(phi)
        plo, phe = max(1e-9, p - hw), min(1.0 - 1e-9, p + hw)
    return gapfromw(p), gapfromw(phe), gapfromw(plo)


def target_crossing(cells, z0, target_wr):
    """Weighted median + 95% CrI of lambda* where sigmoid(a+b*(ln lam - z0)) = target_wr.
    Solve a + b*z = logit(target) => z = (logit-a)/b => lam* = exp(z0 + z)."""
    lt = logit(target_wr)
    pairs = [(z0 + (lt - a) / b, wt) for (wt, a, b) in cells]   # (ln lambda*, weight); b<0 finite
    lo, med, hi = tf.weighted_quantiles(pairs, [0.025, 0.5, 0.975])
    return math.exp(med), math.exp(lo), math.exp(hi)


def nearest_sample(pts, lam):
    """(lambda, wins, games) of the sampled point closest to lam in log-space."""
    return min(pts, key=lambda p: abs(math.log(p[0]) - math.log(lam)))


def local_crossing(pts, G, lam_fit, min_g=40):
    """Refine the gap=G crossing by LINEAR interpolation (in log-lambda vs gap) of the two adjacent
    reliable (>=min_g games) sampled points that bracket G. The global logistic can be biased near the
    crossing when the true winrate-vs-ln(lambda) curve isn't exactly logistic (far/steep points pull its
    slope); the local bracket is unbiased there. Falls back to lam_fit if nothing brackets G."""
    rp = sorted((lam, gapfromw(w / g)) for (lam, w, g) in pts if g >= min_g)
    for i in range(len(rp) - 1):
        (l0, g0), (l1, g1) = rp[i], rp[i + 1]
        if (g0 - G) * (g1 - G) <= 0 and g1 != g0:
            t = (G - g0) / (g1 - g0)
            return math.exp(math.log(l0) + t * (math.log(l1) - math.log(l0)))
    return lam_fit


def coarse_crossing(pts, G, binfrac=0.07, min_g=80):
    """Robust gap=G crossing for OVERDISPERSED rungs: pool lambdas into ~binfrac-wide log bins (each
    averaging out the per-lambda noise), then linearly interpolate (game-weighted-mean-log-lambda vs
    pooled gap) between the two adjacent bins with >=min_g games that bracket G. On a noisy rung the
    individual-point local_crossing chases 28-game outliers and never concentrates; the coarse bins give
    a STABLE crossing so the concentration sticks. Returns None if no coarse bin brackets G."""
    if len(pts) < 2:
        return None
    lo = math.log(min(l for l, _, _ in pts))
    step = math.log(1.0 + binfrac)
    bins = {}
    for lam, w, g in pts:
        k = round((math.log(lam) - lo) / step)
        b = bins.setdefault(k, [0.0, 0, 0.0])
        b[0] += w; b[1] += g; b[2] += g * math.log(lam)
    bp = sorted((math.exp(sll / g), gapfromw(w / g)) for (w, g, sll) in bins.values() if g >= min_g)
    for i in range(len(bp) - 1):
        (l0, g0), (l1, g1) = bp[i], bp[i + 1]
        if (g0 - G) * (g1 - G) <= 0 and g1 != g0:
            t = (G - g0) / (g1 - g0)
            return math.exp(math.log(l0) + t * (math.log(l1) - math.log(l0)))
    return None


PHI_COARSE = 1.3            # above this overdispersion, trust the coarse-binned crossing over local points
WIDTH_RATIO_COARSE = 2.5    # crossing CI hi/lo above this = poorly-determined (FLAT/noisy) crossing ->
                            # also use the stable coarse crossing (the 2d failure: a shallow slope keeps
                            # phi~1 so the phi trigger alone misses it, and local_crossing then chases noise)


def refine_crossing(pts, G, lam_fit, phi, width_ratio=1.0):
    """Best crossing estimate. For a FLAT/NOISY rung — overdispersed (phi>PHI_COARSE) OR a poorly-
    determined crossing (width_ratio>WIDTH_RATIO_COARSE, i.e. a shallow slope whose fit crossing jitters
    and whose local bracket chases 24-game outliers; the 2d failure mode) — use the STABLE coarse-binned
    crossing. Otherwise prefer the precise LOCAL bracket from well-sampled (>=120 g) cells (so a clean
    steep rung centers exactly), then coarse, then any >=40 g bracket / lam_fit."""
    if phi > PHI_COARSE or width_ratio > WIDTH_RATIO_COARSE:
        c = coarse_crossing(pts, G)
        if c is not None:
            return c
    lc = local_crossing(pts, G, None, min_g=120)
    if lc is not None:
        return lc
    c = coarse_crossing(pts, G)
    if c is not None:
        return c
    return local_crossing(pts, G, lam_fit)


def pooled_estimate(pts, G):
    """Current gap estimate at the (refined) gap=G crossing, for the status report / ETA. Reports the
    SINGLE concentration cell (the sampled lambda nearest the crossing with the most games) on its
    BINOMIAL (phi=1) Wilson gap-CI — the same quantity the primary LOCK tests — so the report matches
    what will lock. Returns (lam, gap, gap_lo, gap_hi, n, phi=1), or None if no data."""
    if not pts:
        return None
    if len(pts) < 2:
        lam, w, g = pts[0]
        gp, glo, ghi = wilson_gap_ci(w, g)
        return (lam, gp, glo, ghi, g, 1.0)
    fit = tf.run_fit(pts)
    z0 = fit['z0']
    lam_star, lam_lo, lam_hi = target_crossing(fit['cells'], z0, wfromgap(G))
    wr = lam_hi / lam_lo if lam_lo > 0 else 1e9
    lam_star = refine_crossing(pts, G, lam_star, fit['phi'], wr)
    lo_w, hi_w = lam_star / (1.0 + LOCK_WIN), lam_star * (1.0 + LOCK_WIN)
    near = [(lam, w, g) for (lam, w, g) in pts if lo_w <= lam <= hi_w]
    if not near:                                   # crossing between cells: report the nearest sample
        near = [nearest_sample(pts, lam_star)]
    # Report the ACTIVE concentration cell = the reliable (>=40 g) cell NEAREST the crossing — the one the
    # grind is building and that will lock — not merely the cell with the most games (which may be a stale
    # off-center cell from before the crossing was refined).
    reliable = [p for p in near if p[2] >= 40]
    lam, w, g = (min(reliable, key=lambda p: abs(math.log(p[0]) - math.log(lam_star)))
                 if reliable else max(near, key=lambda p: p[2]))
    gp, glo, ghi = wilson_gap_ci(w, g)             # phi=1
    return (lam, gp, glo, ghi, g, 1.0)


def emit(action, fit):
    sys.stdout.write(fit + "\n")
    sys.stdout.write(action + "\n")


def lock_line(L, w, g, phi=1.0):
    gp, glo, ghi = wilson_gap_ci(w, g, phi)
    return "ACTION=LOCK LAMBDA=%.5f WR=%.1f GAP=%+.0f CI=%.0f,%.0f N=%d" % (
        L, 100 * w / g, gp, glo, ghi, g)


def decide(pts, G, ci, sticky_path=None):
    w_star = wfromgap(G)
    band_lo, band_hi = G - ci, G + ci          # gap band (ELO)
    if not pts:
        return ("ACTION=GRIND LAMBDA=NA NOTE=no-data",
                "# ELOFIT: no-data target=%dELO(w*=%.1f%%)" % (G, 100 * w_star))

    total = sum(g for _, _, g in pts)
    lams = [p[0] for p in pts]
    lo_lam, hi_lam = min(lams), max(lams)

    # ---- single lambda: Wilson gate or step toward the crossing ----
    if len(pts) < 2:
        lam, w, g = pts[0]
        gp, glo, ghi = wilson_gap_ci(w, g)
        fl = "# ELOFIT: single lam=%.5f wr=%.1f%% gap=%+.0f CI[%.0f,%.0f] n=%d target=%d" % (
            lam, 100 * w / g, gp, glo, ghi, g, G)
        if g >= LOCK_MIN_G and glo >= band_lo and ghi <= band_hi:
            return (lock_line(lam, w, g), fl)
        wr = w / g
        # winrate below target => candidate too weak => go stronger (lower lambda); else higher
        if wr < w_star:
            nxt = tf.snap(max(GRID, lam / (1.0 + 4.0 * abs(wr - w_star))))
            note = "single-too-weak(%.0f%%<%.0f%%)-lower-lambda" % (100 * wr, 100 * w_star)
        else:
            nxt = tf.snap(lam * (1.0 + 4.0 * abs(wr - w_star)) + 0.004)
            note = "single-too-strong(%.0f%%>%.0f%%)-raise-lambda" % (100 * wr, 100 * w_star)
        return ("ACTION=GRIND LAMBDA=%.5f NOTE=%s-total%dg" % (nxt, note, total), fl)

    # ---- multi lambda: fit for the crossing location ----
    fit = tf.run_fit(pts)
    z0 = fit['z0']
    lam_star, lam_lo, lam_hi = target_crossing(fit['cells'], z0, w_star)
    wr = lam_hi / lam_lo if lam_lo > 0 else 1e9
    lam_star = refine_crossing(pts, G, lam_star, fit['phi'], wr)   # coarse-binned when overdispersed/flat
    predfn = lambda L: tf.pred_wr(fit['cells'], z0, L)[0]
    fl = ("# ELOFIT: target=%dELO w*=%.1f%% lam*=%.5f CI[%.5f,%.5f] phi=%.2f "
          "b<%.2f=%.3f total=%d" % (
              G, 100 * w_star, lam_star, lam_lo, lam_hi, fit['phi'],
              tf.FLAT_B_THRESH, fit['b_below'], total))

    wrs = [p[1] / p[2] for p in pts]

    phi = fit['phi']
    # ---- LOCK (primary): a single concentrated lambda whose BINOMIAL (phi=1) Wilson gap-CI fits the
    #      band. Within a fixed lambda the games are iid Bernoulli, so phi=1 is EXACT; the cross-cell
    #      fit-phi (>1 from logistic MISFIT — a steep local slope + noisy far points, NOT within-cell
    #      overdispersion) must not inflate a single-cell measurement. The completed 17k-game eval hit
    #      +-30 ELO at ~530 games/pair (phi=1), confirming this. Prefer the qualifier nearest the crossing. ----
    lockable = []
    for (lam, w, g) in pts:
        if g < LOCK_MIN_G:
            continue
        gp, glo, ghi = wilson_gap_ci(w, g)   # phi=1: iid within a single lambda
        if glo >= band_lo and ghi <= band_hi:
            lockable.append((abs(math.log(lam) - math.log(lam_star)), lam, w, g))
    if lockable:
        lockable.sort()
        _, lam, w, g = lockable[0]
        return (lock_line(lam, w, g), fl)
    # NOTE: the former pooled-window fallback (pool +-LOCK_WIN of lam_star, fit-phi-inflated) was
    # REMOVED 2026-07-18. It pooled a lambda-GRADIENT, so on the steeper dan rungs it reported an
    # optimistically-tight, biased CI and locked rungs whose single-cell gap AT the shipped lambda was
    # actually out of band (6d/5d/4d/3d locked +87..+108, single-cell CI reaching 142 — see doc). Its
    # premise ("concentration migrates, so no single cell accumulates enough") is now obsolete: the
    # STICKY concentration above pins games at ONE lambda, so the honest single-cell phi=1 gate always
    # gets enough games at the shipped lambda. LOCK now requires that single-cell gate, nothing looser.

    # ---- saturation STOP (best-effort): crossing unreachable by lambda alone ----
    #      too-weak-everywhere: even the strongest sampled lambda wins < band's weak edge and
    #      lambda already tiny; too-strong-everywhere: weakest sampled play still > band and
    #      lambda already huge (pure human) -> ship the closest-to-target sampled lambda.
    pm_lo = predfn(max(GRID, lo_lam / 2.0))     # extrapolate stronger
    pm_hi = predfn(hi_lam * 2.0)                # extrapolate weaker
    too_weak_floor = (pm_lo < w_star - SAT_MARGIN) and (lo_lam <= 0.02)
    too_strong_ceil = (pm_hi > w_star + SAT_MARGIN) and (hi_lam >= 50.0)
    if too_weak_floor or too_strong_ceil:
        best = min(pts, key=lambda p: abs(p[1] / p[2] - w_star))
        gp, glo, ghi = wilson_gap_ci(best[1], best[2])
        why = "cannot-strengthen(lambda-floor)" if too_weak_floor else "cannot-weaken(pure-human)"
        return ("ACTION=STOP LAMBDA=%.5f WR=%.1f GAP=%+.0f CI=%.0f,%.0f N=%d "
                "NOTE=saturated-%s-best-effort" % (
                    best[0], 100 * best[1] / best[2], gp, glo, ghi, best[2], why), fl)

    # ---- budget STOP ----
    best_g = max(g for _, _, g in pts)
    if total > BUDGET or best_g > MAXGAMES_PER_LAM:
        best = min(pts, key=lambda p: abs(gapfromw(p[1] / p[2]) - G))
        gp, glo, ghi = wilson_gap_ci(best[1], best[2])
        return ("ACTION=STOP LAMBDA=%.5f WR=%.1f GAP=%+.0f CI=%.0f,%.0f N=%d "
                "NOTE=budget-cannot-pin" % (
                    best[0], 100 * best[1] / best[2], gp, glo, ghi, best[2]), fl)

    # ---- cold start: all samples one side of the target -> geometric expand ----
    if all(wr < w_star for wr in wrs):          # all too weak -> go stronger (lower lambda)
        nxt = tf.snap(max(GRID, lo_lam / (1.0 + 4.0 * abs(max(wrs) - w_star))))
        return ("ACTION=GRIND LAMBDA=%.5f NOTE=all-too-weak(%.0f%%)-expand-stronger-total%dg" % (
            nxt, 100 * max(wrs), total), fl)
    if all(wr > w_star for wr in wrs):          # all too strong -> go weaker (raise lambda)
        nxt = tf.snap(hi_lam * (1.0 + 4.0 * abs(min(wrs) - w_star)) + 0.004)
        return ("ACTION=GRIND LAMBDA=%.5f NOTE=all-too-strong(%.0f%%)-expand-weaker-total%dg" % (
            nxt, 100 * min(wrs), total), fl)

    # ---- CONCENTRATE: crossing is bracketed. Pile games AT the crossing (gap=target), snapped to a
    #      stable 1% relative grid so successive chunks re-hit the same lambda (centered, not at an
    #      off-center existing sample). Reuse an existing sample only if it sits in the SAME cell.
    #      STICKY (flat/noisy rungs): the crossing estimate wobbles chunk-to-chunk on a gently-sloped
    #      or noisy rung, so re-deriving `conc` every chunk chases the wobble and spreads games across
    #      many lambda (the 2d saga) — none ever reaching the ~530 games a single-cell lock needs. Once
    #      a concentration lambda is picked, PERSIST it and keep piling games there; only re-derive when
    #      that cell is well-sampled AND its gap is clearly off-target (>ci ELO), i.e. mislocated. ----
    conc = tf.snap(rgrid(lam_star))
    conc = tf.snap(max(GRID, min(max(conc, lo_lam / tf.SUPPORT_CLAMP), hi_lam * tf.SUPPORT_CLAMP)))
    if sticky_path is not None:
        s = read_sticky(sticky_path)
        if s is not None:
            sc = nearest_sample(pts, s)          # sampled cell nearest the sticky lambda
            in_cell = abs(math.log(sc[0]) - math.log(s)) <= math.log(1.0 + CONC_GRID)
            # Re-derive a WELL-SAMPLED sticky cell that CANNOT plausibly certify — either its point gap
            # is outside the band (crossing mislocated), OR it sits so far off-CENTRE (near a band edge)
            # that shrinking its CI inside the band would exceed the per-lambda budget (e.g. gap +76 for
            # a 100±30 target: ~14k games because it's only 6 ELO above the +70 edge). Without the
            # off-centre test the sticky lodges at an un-certifiable edge and grinds to a budget STOP
            # instead of moving to the crossing (the 1k +76 case, 2026-07-19). A "CI wholly excludes
            # band" trigger was tried and is far too slow; the point + feasibility test is prompt, and a
            # rare noise-driven re-derive is cheap (it re-sticks near the fit crossing and converges).
            off_target = (in_cell and sc[2] >= STICKY_REDERIVE_G
                          and not cell_can_certify(sc[1], sc[2], G, ci))
            if not off_target:                   # keep concentrating at the sticky lambda
                tgt = sc[0] if in_cell else s
                nn = nearest_sample(pts, tgt)
                return ("ACTION=GRIND LAMBDA=%.5f NOTE=concentrate-sticky@%.5f(near-n=%d,gap%+.0f)-total%dg" % (
                    tgt, tgt, nn[2], gapfromw(nn[1] / nn[2]), total), fl)
            clear_sticky(sticky_path)
            # Re-derive placement depends on the rung's noise (phi), so a CLEAN steep rung isn't stuck by
            # the coarse grid while a NOISY rung isn't scattered by fine chasing:
            #  - CLEAN rung (phi <= PHI_COARSE): the fit crossing is reliable/stable. Place the new sticky
            #    at the FINE interpolated crossing and pin it DIRECTLY (skip the coarse reuse loop). On a
            #    STEEP clean rung the coarse rgrid snaps re-derives back to the SAME un-certifiable cell
            #    and oscillates (9k, 2026-07-28: 0.306->gap+73, 0.309->+120, crossing 0.3078 between them,
            #    phi=1.00); the fine placement walks games into the certifiable centre between coarse cells.
            #  - NOISY rung (phi > PHI_COARSE): the crossing estimate wobbles, so a fine re-derive chases
            #    the noise to ever-new fine cells and SPREADS games (1k, phi=1.41). Fall through to the
            #    STABLE coarse rgrid so games stick to one cell and average the noise.
            if phi <= PHI_COARSE:
                fine = tf.snap(max(GRID, min(max(lam_star, lo_lam / tf.SUPPORT_CLAMP), hi_lam * tf.SUPPORT_CLAMP)))
                write_sticky(sticky_path, fine)
                nn = nearest_sample(pts, fine)
                return ("ACTION=GRIND LAMBDA=%.5f NOTE=concentrate-finerederive@%.5f(near-n=%d,gap%+.0f)-total%dg" % (
                    fine, fine, nn[2], gapfromw(nn[1] / nn[2]), total), fl)
        write_sticky(sticky_path, conc)          # (re-)persist the freshly derived concentration lambda
    for (lam, w, g) in pts:
        if abs(math.log(lam) - math.log(conc)) <= math.log(1.0 + CONC_GRID * 0.5):  # ~half a cell -> reuse
            conc = lam
            break
    ns = nearest_sample(pts, conc)
    return ("ACTION=GRIND LAMBDA=%.5f NOTE=concentrate-crossing@%.5f(near-n=%d,gap%+.0f)-total%dg" % (
        conc, conc, ns[2], gapfromw(ns[1] / ns[2]), total), fl)


def seed_slope_prior(glob, max_rungs=5, sd=1.5):
    """Tighten tune_fit's logistic-slope (b) prior using the b already measured on the last few LOCKED
    sibling rungs (same nets/40v → similar slope), so a fresh rung locates its crossing with less
    deliberate spread (~41% exploration overhead). Moderate SD (1.5, vs the default 4) so the rung's own
    data still dominates and the prior can't force a wrong crossing. No-op if <2 usable locked rungs.
    Reads the lock log next to the samples glob. Mutates tf module globals (safe: fresh subprocess/run)."""
    tune_dir = os.path.dirname(os.path.abspath(os.path.expanduser(glob)))
    locklog = os.path.join(tune_dir, "elo_ladder_locks.txt")
    if not os.path.exists(locklog):
        return
    ranks = []
    with open(locklog) as f:
        for line in f:
            m = re.search(r'\s(\d+[dk])\s.*\bLOCK\b', line)
            if m:
                ranks.append(m.group(1))
    ranks = list(dict.fromkeys(ranks))[-max_rungs:]   # dedup (keep ladder order), take the nearest few
    bs = []
    for r in ranks:
        pts = tf.load(os.path.join(tune_dir, f"elo{r}_L*.samples"))
        if len(pts) < 3:
            continue
        fit = tf.run_fit(pts)                          # weak default prior => ~data-driven slope
        bs.append(sum(wt * b for (wt, a, b) in fit['cells']))   # posterior-mean b
    if len(bs) >= 2:
        bs.sort()
        tf.PRIOR_B_MEAN = bs[len(bs) // 2]             # median neighbour slope
        tf.PRIOR_B_SD = sd


def main():
    if len(sys.argv) < 3:
        sys.stdout.write("# ELOFIT: usage: tune_elo.py '<glob>' <gap-elo> [ci]\n"
                         "ACTION=GRIND LAMBDA=NA NOTE=no-args\n")
        return
    seed_slope_prior(sys.argv[1])   # nudge tf's slope prior toward locked neighbours before fitting
    pts = tf.load(sys.argv[1])
    G = float(sys.argv[2])
    ci = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
    action, fit = decide(pts, G, ci, sticky_path=sticky_path_for(sys.argv[1]))
    emit(action, fit)


if __name__ == "__main__":
    main()
