#!/usr/bin/env python3
"""
tune_fit.py — Bayesian curve-fit decision brain for the Human-SL rank-ladder lambda calibration.

Replaces the local-interpolation logic of tune_decide.py with a PARAMETRIC monotone-decreasing
fit of winrate vs lambda, so EVERY game contributes to a global estimate of the 50%-crossing
lambda* and its uncertainty. This borrows strength across all data and lets a rung LOCK from far
fewer games than the old ~280g/lambda local read.

MODEL.    p(win|lambda) = sigmoid(a + b*z),  z = ln(lambda) - z0,  b < 0 (winrate decreasing).
          z0 = mean of ln(lambda) over distinct observed lambdas (centering decorrelates a,b).
          Crossing: z* = -a/b  =>  lambda* = exp(z0 - a/b).
FIT.      Exact normalized posterior over a 2D (a,b) grid with weak Gaussian priors and b<0
          enforced by the grid. Quasi-binomial overdispersion factor phi>=1 (Pearson) widens
          CIs when the net's per-lambda scatter exceeds binomial. One adaptive zoom-refit on the
          high-mass box for crossing-quantile precision. PAVA shelf-shape consistency guard.
DECIDE.   LOCK   when a shippable lambda's posterior-PREDICTIVE 95% winrate interval is in [40,60]%.
          GRIND  the most informative next lambda (active learning), snapped to a 1e-4 grid.
          STOP   on saturation (unbalanceable -> ship pure-human lambda=50), budget, or degeneracy.

Output is one decision line compatible with ladder_step.sh (ACTION=/LAMBDA=/WR=/CI=lo,hi/N=,
CI in PERCENT) plus one diagnostic line beginning '# FIT:'.

PURE PYTHON STDLIB ONLY (math, sys, glob, os, re) — no numpy, no scipy.

Usage: tune_fit.py '<samples-glob>'   e.g.  tune_fit.py '~/.katago_tune/jpn6d_ane_L*.samples'
"""
import sys, glob, os, re, math

# ---- constants (from the final design spec) ----
CI_LO, CI_HI = 0.40, 0.60      # LOCK target band for the predictive 95% CI (fraction)
GRID = 1e-4                     # lambda rounding grid for GRIND output
MAXGAMES = 900                 # best-single-lambda games before budget STOP
BUDGET = 2500                  # total games before budget STOP
Z = 1.96                       # normal 95% z for Wilson fallback
NA = 121                       # grid resolution for a
NB = 121                       # grid resolution for b
A_LO, A_HI = -8.0, 8.0         # grid range for a
B_LO, B_HI = -12.0, -0.02      # grid range for b (b<0 enforces monotone-decreasing)
PRIOR_A_SD = 4.0
PRIOR_B_MEAN = -1.5
PRIOR_B_SD = 4.0
PHI_MIN_G = 20                 # only groups with >= this many games contribute to Pearson chi2
PHI_CAP = 5.0                  # cap overdispersion to avoid a single outlier exploding it
LOCK_MIN_TOTAL = 60            # minimum total pooled games before a LOCK is allowed
LOCK_MIN_DISTINCT = 3          # min distinct sampled lambdas before a LOCK (>=3 => >=1 residual df)
WIDTH_RATIO_MAX = 3.0          # reject pathological fits whose crossing hi/lo exceeds this
SHAPE_GUARD_DELTA = 0.08       # logistic-vs-local disagreement (fraction) that blocks a LOCK
SHAPE_GUARD_MIN_G = 60         # (legacy PAVA-block guard) only a block with >= this many games blocks
# --- hardening gates (added after adversarial review: defend against model-misspecification false locks) ---
LACKFIT_Z = 3.5                # block LOCK if any g>=PHI_MIN_G group's standardized residual exceeds this
NEAR_FAC = 1.10                # local window (+-10%) for the interpolation + local-shape-agreement checks
NEAR_MIN_G = 20                # a candidate LOCK lambda needs >= this many games within +-10% (no gap ship)
BRACKET_FAC = 1.30            # candidate LOCK lambda must be bracketed by sampled points within +-30%
LOCK_MARGIN_PP = 1.0          # predictive CI must sit within [40+m, 60-m]% — bounds the OOB tail
                              # (a margin, not a fixed width cap: the latter over-restricts
                              #  legitimately-wider overdispersed rungs like 5d at phi~1.8)
DEGEN_TOTAL = 600             # total games before a still-unresolved crossing -> degenerate STOP
DEGEN_DISTINCT = 6            # distinct lambdas before degenerate STOP
SUPPORT_CLAMP = 1.3           # never ship a lambda outside [min/1.3, max*1.3] of the sampled range
FLAT_B_THRESH = -0.05        # posterior mass with b < this must exceed 0.95 (non-flat slope)
FLAT_B_MASS = 0.95
EDGE_MASS = 0.01             # posterior mass on a grid boundary that triggers a widen+refit


# ---------- numerically stable primitives ----------
def log_sigmoid(x):
    """log(sigmoid(x)) computed stably."""
    if x >= 0.0:
        return -math.log1p(math.exp(-x))
    return x - math.log1p(math.exp(x))


def sigmoid(x):
    if x >= 0.0:
        z = math.exp(-x)
        return 1.0 / (1.0 + z)
    z = math.exp(x)
    return z / (1.0 + z)


def wilson(w, n):
    """Wilson 95% interval (fraction) — used only in <2-lambda fallback and saturation proxy."""
    if n == 0:
        return (0.0, 1.0)
    p = w / n
    den = 1 + Z * Z / n
    cen = (p + Z * Z / (2 * n)) / den
    mar = (Z / den) * math.sqrt(p * (1 - p) / n + Z * Z / (4 * n * n))
    return (max(0.0, cen - mar), min(1.0, cen + mar))


# ---------- parse / aggregate (verbatim semantics from tune_decide.py) ----------
def parse(path):
    """Return (lambda, wins, games) for one fixed-lambda samples file."""
    lam = None
    w = 0.0
    g = 0
    with open(path) as f:
        for i, line in enumerate(f):
            if i == 0:
                m = re.search(r'piklFloor=(\S+)', line)  # \S+ handles scientific notation (1e+08)
                if m:
                    try:
                        lam = float(m.group(1))
                    except ValueError:
                        lam = None
                continue
            if line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) >= 3:
                try:
                    w += float(parts[1])
                    g += int(parts[2])
                except ValueError:
                    pass
    return (lam, w, g)


def load(pattern):
    """Aggregate by lambda (pool files sharing a lambda). Returns sorted [(lam, wins, games)]."""
    files = sorted(glob.glob(os.path.expanduser(pattern)))
    agg = {}
    for f in files:
        lam, w, g = parse(f)
        if lam is None or g == 0 or lam <= 0.0:
            continue
        a = agg.setdefault(round(lam, 6), [0.0, 0])
        a[0] += w
        a[1] += g
    return sorted((lam, w, g) for lam, (w, g) in agg.items())


# ---------- isotonic PAVA (shape guard / sanity check) ----------
def pava_decreasing(pts):
    """Weighted pool-adjacent-violators for a NON-INCREASING fit.
    Returns blocks (lambda_min, lambda_max, pooled_winrate, games)."""
    blocks = [[lam, lam, w, g] for (lam, w, g) in pts]
    i = 0
    while i < len(blocks) - 1:
        r_i = blocks[i][2] / blocks[i][3]
        r_j = blocks[i + 1][2] / blocks[i + 1][3]
        if r_i < r_j:
            blocks[i][1] = blocks[i + 1][1]
            blocks[i][2] += blocks[i + 1][2]
            blocks[i][3] += blocks[i + 1][3]
            del blocks[i + 1]
            if i > 0:
                i -= 1
        else:
            i += 1
    return [(b[0], b[1], b[2] / b[3], b[3]) for b in blocks]


def pava_block_wr(fit, lam):
    """Pooled winrate (and games) of the PAVA block whose lambda-span contains lam (nearest if none)."""
    for lmn, lmx, wr, g in fit:
        if lmn <= lam <= lmx:
            return wr, g
    # nearest block by midpoint
    best = min(fit, key=lambda b: abs(0.5 * (b[0] + b[1]) - lam))
    return best[2], best[3]


def local_pooled_wr(pts, L, fac):
    """Pooled (winrate, games) of all sampled lambdas within a multiplicative window [L/fac, L*fac].
    Non-disable-able local shape check: uses every nearby game, not a single (possibly-singleton)
    PAVA block — so the active-learning loop cannot create a sub-threshold block that skips the guard."""
    lo, hi = L / fac, L * fac
    w = 0.0
    g = 0
    for (lam, ww, gg) in pts:
        if lo <= lam <= hi:
            w += ww
            g += gg
    return (w / g if g > 0 else None), g


def max_lackfit_z(pts, predfn):
    """Largest standardized residual |obs - pred| / sqrt(pred*(1-pred)/g) over groups with g>=PHI_MIN_G.
    A well-fitting logistic has small residuals everywhere; a misspecified fit (real cliff/step the
    2-param logistic cannot represent) leaves at least one group badly mispredicted -> large z."""
    mx = 0.0
    for (lam, w, g) in pts:
        if g < PHI_MIN_G:
            continue
        mu = min(max(predfn(lam), 1e-6), 1 - 1e-6)
        se = math.sqrt(mu * (1 - mu) / g)
        if se > 0:
            zres = abs(w / g - mu) / se
            if zres > mx:
                mx = zres
    return mx


def bracketed(pts, L, fac):
    """True iff there is a sampled lambda < L within [L/fac, L) AND one > L within (L, L*fac]."""
    lo, hi = L / fac, L * fac
    has_below = any(lo <= lam < L for (lam, _, _) in pts)
    has_above = any(L < lam <= hi for (lam, _, _) in pts)
    return has_below and has_above


# ---------- the 2D grid posterior ----------
def axis(lo, hi, n):
    if n == 1:
        return [0.5 * (lo + hi)]
    step = (hi - lo) / (n - 1)
    return [lo + step * i for i in range(n)]


def fit_grid(pts, z0, a_lo, a_hi, b_lo, b_hi, phi):
    """Return a list of cells (wt, a, b) normalized to sum(wt)=1, plus the axes used.

    Each cell's unnormalized log-posterior is
        lp_a(a) + lp_b(b) + (1/phi) * sum_pts[ w*log_sigmoid(eta) + (g-w)*log_sigmoid(-eta) ]
    with eta = a + b*z, z = ln(lambda) - z0.
    """
    As = axis(a_lo, a_hi, NA)
    Bs = axis(b_lo, b_hi, NB)
    # precompute per-point (z, w, gmw)
    zz = [(math.log(max(lam, 1e-12)) - z0, w, g - w) for (lam, w, g) in pts]
    inv_phi = 1.0 / phi
    cells = []
    maxlp = -float('inf')
    for a in As:
        lp_a = -0.5 * (a / PRIOR_A_SD) ** 2
        for b in Bs:
            lp_b = -0.5 * ((b - PRIOR_B_MEAN) / PRIOR_B_SD) ** 2
            ll = 0.0
            for (z, w, gmw) in zz:
                eta = a + b * z
                if w != 0.0:
                    ll += w * log_sigmoid(eta)
                if gmw != 0.0:
                    ll += gmw * log_sigmoid(-eta)
            lp = lp_a + lp_b + inv_phi * ll
            cells.append((lp, a, b))
            if lp > maxlp:
                maxlp = lp
    # normalize
    s = 0.0
    out = []
    for (lp, a, b) in cells:
        wt = math.exp(lp - maxlp)
        out.append([wt, a, b])
        s += wt
    if s <= 0.0:
        # degenerate; uniform
        n = len(out)
        for c in out:
            c[0] = 1.0 / n
    else:
        for c in out:
            c[0] /= s
    return out, As, Bs


def edge_mass(cells, As, Bs):
    """Fraction of posterior mass on the outermost a or b grid lines (low and high separately)."""
    a_lo, a_hi = As[0], As[-1]
    b_lo, b_hi = Bs[0], Bs[-1]
    m = {'a_lo': 0.0, 'a_hi': 0.0, 'b_lo': 0.0, 'b_hi': 0.0}
    for (wt, a, b) in cells:
        if a == a_lo:
            m['a_lo'] += wt
        if a == a_hi:
            m['a_hi'] += wt
        if b == b_lo:
            m['b_lo'] += wt
        if b == b_hi:
            m['b_hi'] += wt
    return m


def weighted_quantiles(pairs, qs):
    """pairs: list of (value, weight). Returns value at each cumulative quantile in qs."""
    pairs = sorted(pairs, key=lambda t: t[0])
    tot = sum(w for _, w in pairs)
    if tot <= 0.0:
        v = pairs[len(pairs) // 2][0] if pairs else 0.0
        return [v for _ in qs]
    out = []
    for q in qs:
        target = q * tot
        cum = 0.0
        val = pairs[-1][0]
        for v, w in pairs:
            cum += w
            if cum >= target:
                val = v
                break
        out.append(val)
    return out


def crossing_stats(cells, z0):
    """Weighted median + 95% CrI of lambda* = exp(z0 - a/b) over the posterior."""
    pairs = []  # (ln lambda*, wt)
    for (wt, a, b) in cells:
        ls = z0 - a / b  # b<0 always finite
        pairs.append((ls, wt))
    lo, med, hi = weighted_quantiles(pairs, [0.025, 0.5, 0.975])
    return math.exp(med), math.exp(lo), math.exp(hi)


def pred_wr(cells, z0, lam):
    """Posterior-predictive mean + 95% CI of the TRUE winrate at lambda (fractions).

    The CI is an EPISTEMIC credible interval of the latent MEAN winrate p(lambda)=sigmoid(a+b*z) under
    the (a,b) posterior — binomial/finite-sample noise is intentionally EXCLUDED (correct: the shipped
    config's strength is p(lambda), not an observed win count). Verified correct (object, sqrt(phi)
    propagation, grid, quantile convention) by the winrate-CI review. CAVEAT: it is mildly ANTI-
    conservative under genuine overdispersion at the ladder's low residual df (covers the true mean
    ~0.91-0.94, not 0.95), so do NOT quote it as a standalone calibrated 95% interval — the
    [40,60]%+LOCK_MARGIN_PP gate (not this number) is the calibration/safety boundary, and it holds."""
    z = math.log(max(lam, 1e-12)) - z0
    mean = 0.0
    pairs = []
    for (wt, a, b) in cells:
        p = sigmoid(a + b * z)
        mean += wt * p
        pairs.append((p, wt))
    lo, hi = weighted_quantiles(pairs, [0.025, 0.975])
    return mean, lo, hi


def b_mass_below(cells, thresh):
    return sum(wt for (wt, a, b) in cells if b < thresh)


def compute_phi(pts, predfn):
    """Quasi-binomial Pearson overdispersion factor phi>=1 from groups with g>=PHI_MIN_G."""
    chi2 = 0.0
    df = 0
    for (lam, w, g) in pts:
        if g < PHI_MIN_G:
            continue
        mu = min(max(predfn(lam), 1e-6), 1 - 1e-6)
        chi2 += (w - g * mu) ** 2 / (g * mu * (1 - mu))
        df += 1
    df -= 2
    if df < 1:
        return 1.0
    phi = chi2 / df
    if phi < 1.0:
        phi = 1.0
    # NOTE (winrate-CI review): the old df<4 shrink-toward-1 only ever fired on a SPARSE rung that was
    # genuinely overdispersed, and it narrowed the CI the WRONG way (hurting coverage). Removed — leave
    # phi un-shrunk so sparse overdispersed rungs get an honestly-wider CI. PHI_CAP still guards a
    # single outlier group from exploding phi.
    if phi > PHI_CAP:
        phi = PHI_CAP
    return phi


def run_fit(pts):
    """Full fit pipeline: center, phi-refit, optional edge-widen, zoom. Returns a dict of results."""
    lams = [p[0] for p in pts]
    z0 = sum(math.log(l) for l in lams) / len(lams)

    a_lo, a_hi, b_lo, b_hi = A_LO, A_HI, B_LO, B_HI

    # initial fit, phi=1
    cells, As, Bs = fit_grid(pts, z0, a_lo, a_hi, b_lo, b_hi, 1.0)

    # widen any boundary that holds too much mass, refit once (key-risk mitigation)
    em = edge_mass(cells, As, Bs)
    widened = False
    if em['a_lo'] > EDGE_MASS:
        a_lo -= 6.0; widened = True
    if em['a_hi'] > EDGE_MASS:
        a_hi += 6.0; widened = True
    if em['b_lo'] > EDGE_MASS:
        b_lo -= 12.0; widened = True
    # do NOT widen b_hi past -0.02 (monotone constraint); piling there means flat -> handled later
    if widened:
        cells, As, Bs = fit_grid(pts, z0, a_lo, a_hi, b_lo, b_hi, 1.0)

    # overdispersion phi from the phi=1 predictive mean
    predfn0 = lambda L: pred_wr(cells, z0, L)[0]
    phi = compute_phi(pts, predfn0)

    # refit with phi
    if phi != 1.0:
        cells, As, Bs = fit_grid(pts, z0, a_lo, a_hi, b_lo, b_hi, phi)

    # adaptive zoom on the 99.9% marginal mass box, padded 20%, b clamped <= -0.02
    a_pairs = [(a, wt) for (wt, a, b) in cells]
    b_pairs = [(b, wt) for (wt, a, b) in cells]
    a_q = weighted_quantiles(a_pairs, [0.0005, 0.9995])
    b_q = weighted_quantiles(b_pairs, [0.0005, 0.9995])
    a_pad = 0.2 * (a_q[1] - a_q[0]) + 1e-6
    b_pad = 0.2 * (b_q[1] - b_q[0]) + 1e-6
    za_lo, za_hi = a_q[0] - a_pad, a_q[1] + a_pad
    zb_lo, zb_hi = b_q[0] - b_pad, min(-0.02, b_q[1] + b_pad)
    if zb_hi <= zb_lo:
        zb_hi = zb_lo + 0.01
    zcells, zAs, zBs = fit_grid(pts, z0, za_lo, za_hi, zb_lo, zb_hi, phi)

    use = zcells
    cross_med, cross_lo, cross_hi = crossing_stats(use, z0)
    width_ratio = cross_hi / cross_lo if cross_lo > 0 else float('inf')
    b_below = b_mass_below(use, FLAT_B_THRESH)

    return {
        'z0': z0, 'phi': phi, 'cells': use, 'widened': widened,
        'cross_med': cross_med, 'cross_lo': cross_lo, 'cross_hi': cross_hi,
        'width_ratio': width_ratio, 'b_below': b_below,
        'a_box': (za_lo, za_hi), 'b_box': (zb_lo, zb_hi),
    }


# ---------- decision logic ----------
def snap(lam):
    return round(round(lam / GRID) * GRID, 5)


def emit(action_line, fit_line):
    sys.stdout.write(fit_line + "\n")
    sys.stdout.write(action_line + "\n")


def fit_diag(fit, lam_show, lackfit=None):
    z0 = fit['z0']
    pm, plo, phi_ci = pred_wr(fit['cells'], z0, lam_show)
    # report dominant-cell a,b as a representative point estimate
    best = max(fit['cells'], key=lambda c: c[0])
    s = ("# FIT: a=%.3f b=%.3f z0=%.4f phi=%.2f lam*=%.5f CI[%.5f,%.5f] wr@%.5f=%.1f%% "
         "CI[%.1f,%.1f] widthratio=%.2f Pb<%.2f=%.3f" % (
             best[1], best[2], z0, fit['phi'],
             fit['cross_med'], fit['cross_lo'], fit['cross_hi'],
             lam_show, 100 * pm, 100 * plo, 100 * phi_ci,
             fit['width_ratio'], FLAT_B_THRESH, fit['b_below']))
    if lackfit is not None:
        s += " lackfit=%.2f" % lackfit
    return s


def decide(pts):
    """Return (action_line, fit_line)."""
    if not pts:
        return ("ACTION=GRIND LAMBDA=NA NOTE=no-data", "# FIT: no-data")

    total = sum(g for _, _, g in pts)
    lams = [p[0] for p in pts]
    lo_lam, hi_lam = min(lams), max(lams)
    distinct = len(pts)

    # ---- branch 1: <2 distinct lambdas — slope unidentified, fall back to single-point logic ----
    if distinct < 2:
        lam, w, g = pts[0]
        lo, hi = wilson(w, g)
        wr = w / g
        fl = "# FIT: single-lambda lam=%.5f wr=%.1f%% Wilson[%.1f,%.1f] n=%d" % (
            lam, 100 * wr, 100 * lo, 100 * hi, g)
        if lo >= CI_LO and hi <= CI_HI:
            return ("ACTION=LOCK LAMBDA=%.5f WR=%.1f CI=%.1f,%.1f N=%d" % (
                lam, 100 * wr, 100 * lo, 100 * hi, g), fl)
        if wr < 0.5:
            nxt = snap(max(GRID, lam / (1.0 + 6.0 * abs(wr - 0.5))))
            return ("ACTION=GRIND LAMBDA=%.5f NOTE=single-too-weak(%.0f%%)-go-lower-total%dg" % (
                nxt, 100 * wr, total), fl)
        excess = wr - 0.5
        add = min(0.05, max(0.01, excess * 0.30 + 0.006))
        nxt = snap(max(lam + add, lam * (1.0 + 6.0 * excess)))
        return ("ACTION=GRIND LAMBDA=%.5f NOTE=single-too-strong(%.0f%%)-go-higher-total%dg" % (
            nxt, 100 * wr, total), fl)

    # ---- fit ----
    fit = run_fit(pts)
    z0 = fit['z0']
    cross_med = fit['cross_med']
    width_ratio = fit['width_ratio']
    predfn = lambda L: pred_wr(fit['cells'], z0, L)[0]
    lackfit = max_lackfit_z(pts, predfn)  # global lack-of-fit: large => logistic mis-fits the shape

    # representative diagnostic lambda for the # FIT line = the proposed action lambda (set later);
    # default to cross_med snapped into support
    lam_default = snap(min(max(cross_med, lo_lam / SUPPORT_CLAMP), hi_lam * SUPPORT_CLAMP))

    # ---- branch 3: saturation / unbalanceable STOP (must precede LOCK) ----
    pm5 = pred_wr(fit['cells'], z0, 5.0)[0]
    best = min(pts, key=lambda t: abs(t[1] / t[2] - 0.5))
    bp = best[1] / best[2]
    saturated = (cross_med > 1e6) or (pm5 > 0.53) or (hi_lam >= 5.0 and bp > 0.53)
    if saturated:
        hp = pts[-1]  # highest sampled lambda — pure-human proxy
        rwr = hp[1] / hp[2]
        rlo, rhi = wilson(hp[1], hp[2])
        fl = fit_diag(fit, hi_lam, lackfit)
        return ("ACTION=STOP LAMBDA=%.5f WR=%.1f CI=%.1f,%.1f N=%d "
                "NOTE=saturated-best-effort-pure-human-lam50-CI-NOT-in-[40,60]" % (
                    50.0, 100 * rwr, 100 * rlo, 100 * rhi, hp[2]), fl)

    # PAVA fit for shape guard
    pava = pava_decreasing(pts)

    # ---- branch 4: LOCK (hardened conjunctive gate; see adversarial-review fixes) ----
    flat_ok = fit['b_below'] >= FLAT_B_MASS
    guards_ok = (distinct >= LOCK_MIN_DISTINCT and total >= LOCK_MIN_TOTAL
                 and width_ratio <= WIDTH_RATIO_MAX and flat_ok and lackfit <= LACKFIT_Z)
    if guards_ok:
        lo_clamp = lo_lam / SUPPORT_CLAMP
        hi_clamp = hi_lam * SUPPORT_CLAMP
        cands = set()
        if lo_clamp <= cross_med <= hi_clamp:
            cands.add(snap(cross_med))
        for l in lams:
            if lo_clamp <= l <= hi_clamp:
                cands.add(round(l, 5))
        shippable = []
        for L in cands:
            pm, plo, phi_ci = pred_wr(fit['cells'], z0, L)
            # (a) predictive 95% winrate CI within the target band WITH a small margin, so the
            #     out-of-band tail stays well under 2.5%/side (replaces a fixed width cap that
            #     over-restricted legitimately-wider overdispersed rungs)
            if not (100 * plo >= 100 * CI_LO + LOCK_MARGIN_PP and 100 * phi_ci <= 100 * CI_HI - LOCK_MARGIN_PP):
                continue
            # (c) interpolation, not extrapolation: real games right at L, and L bracketed by samples
            lwr, near_g = local_pooled_wr(pts, L, NEAR_FAC)
            if near_g < NEAR_MIN_G or not bracketed(pts, L, BRACKET_FAC):
                continue
            # (d) local shape agreement (non-disable-able): model pred vs pooled LOCAL winrate
            if lwr is not None and abs(pm - lwr) > SHAPE_GUARD_DELTA:
                continue
            # (e) legacy PAVA-block shape guard (belt-and-suspenders)
            bwr, bg = pava_block_wr(pava, L)
            if bg >= SHAPE_GUARD_MIN_G and abs(pm - bwr) > SHAPE_GUARD_DELTA:
                continue
            shippable.append((abs(pm - 0.5), abs(L - cross_med), L, pm, plo, phi_ci))
        if shippable:
            shippable.sort()
            _, _, L, pm, plo, phi_ci = shippable[0]
            fl = fit_diag(fit, L, lackfit)
            return ("ACTION=LOCK LAMBDA=%.5f WR=%.1f CI=%.1f,%.1f N=%d" % (
                L, 100 * pm, 100 * plo, 100 * phi_ci, total), fl)

    fl = fit_diag(fit, lam_default, lackfit)

    # ---- branch 5: budget STOP ----
    best_g = max(g for _, _, g in pts)
    if total > BUDGET or best_g > MAXGAMES:
        # ship the sampled lambda whose predictive mean is closest to 50% (or cross_med if interior)
        cand = []
        for l in lams:
            pm = pred_wr(fit['cells'], z0, l)[0]
            cand.append((abs(pm - 0.5), l, pm))
        cand.sort()
        _, L, pm = cand[0]
        plo, phi_ci = pred_wr(fit['cells'], z0, L)[1:]
        return ("ACTION=STOP LAMBDA=%.5f WR=%.1f CI=%.1f,%.1f N=%d NOTE=budget-cannot-pin" % (
            L, 100 * pm, 100 * plo, 100 * phi_ci, total), fl)

    # ---- branch 6: degenerate STOP ----
    if width_ratio > WIDTH_RATIO_MAX and total > DEGEN_TOTAL and distinct >= DEGEN_DISTINCT:
        cand = sorted((abs(p[1] / p[2] - 0.5), p[0]) for p in pts)
        L = cand[0][1]
        pm, plo, phi_ci = pred_wr(fit['cells'], z0, L)
        return ("ACTION=STOP LAMBDA=%.5f WR=%.1f CI=%.1f,%.1f N=%d NOTE=degenerate-flat" % (
            L, 100 * pm, 100 * plo, 100 * phi_ci, total), fl)

    # ---- branch 7: GRIND (active learning) ----
    # cold-start: all points one side of 50% -> geometric expand toward the crossing
    wrs = [p[1] / p[2] for p in pts]
    all_weak = all(wr < 0.5 for wr in wrs)
    all_strong = all(wr > 0.5 for wr in wrs)
    if all_weak:
        ext = pts[0]
        ewr = ext[1] / ext[2]
        nxt = snap(max(GRID, ext[0] / (1.0 + 6.0 * abs(ewr - 0.5))))
        return ("ACTION=GRIND LAMBDA=%.5f NOTE=all-too-weak(%.0f%%)-expand-stronger-total%dg" % (
            nxt, 100 * max(wrs), total), fl)
    if all_strong:
        ext = pts[-1]
        ewr = ext[1] / ext[2]
        excess = ewr - 0.5
        factor = 1.0 + 6.0 * excess
        add = min(0.05, max(0.01, excess * 0.30 + 0.006))
        nxt = snap(max(ext[0] + add, ext[0] * factor))
        return ("ACTION=GRIND LAMBDA=%.5f NOTE=all-too-strong(%.0f%%)-expand-weaker-x%.1f-total%dg" % (
            nxt, 100 * min(wrs), factor, total), fl)

    # bracketed but not lockable yet. If the crossing is poorly resolved, EXPLORE the geometric
    # midpoint toward whichever CrI bound has fewer neighboring games — this adds spread that pins
    # the SLOPE (which crossing-grinding cannot). Trigger when distinct<3 (cold) OR width_ratio is
    # very high (a noisy/overdispersed rung whose slope stays unidentified even with >=3 lambdas).
    if width_ratio > WIDTH_RATIO_MAX and (distinct < 3 or width_ratio > 8.0):
        def neighbors(bound):
            return sum(g for (l, w, g) in pts if min(bound, cross_med) <= l <= max(bound, cross_med))
        lo_n = neighbors(fit['cross_lo'])
        hi_n = neighbors(fit['cross_hi'])
        target = fit['cross_lo'] if lo_n <= hi_n else fit['cross_hi']
        mid = math.sqrt(max(cross_med, 1e-12) * max(target, 1e-12))
        nxt = snap(max(GRID, mid))
        return ("ACTION=GRIND LAMBDA=%.5f NOTE=explore-wide-crossing-total%dg" % (nxt, total), fl)

    # default active-learning step: grind the crossing estimate (snapped, clamped to support+margin)
    nxt = snap(max(GRID, min(max(cross_med, lo_lam / SUPPORT_CLAMP), hi_lam * SUPPORT_CLAMP)))
    return ("ACTION=GRIND LAMBDA=%.5f NOTE=grind-crossing~%.5f-total%dg" % (nxt, cross_med, total), fl)


def main():
    if len(sys.argv) < 2:
        sys.stdout.write("# FIT: no-data\nACTION=GRIND LAMBDA=NA NOTE=no-data\n")
        return
    pts = load(sys.argv[1])
    action_line, fit_line = decide(pts)
    emit(action_line, fit_line)


if __name__ == "__main__":
    main()
