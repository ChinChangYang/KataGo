#!/usr/bin/env python3
"""Decide the NEXT ACTION for one rung of the deep-kyu ladder: which dial to play games at, and
how many, so that the rung reaches a valid certificate for the fewest total games.

THE PROBLEM. A rung pits a stronger bot against a weaker one in even games; one scalar dial x on
the weaker bot (deepkyu_cfg.dial_params) makes it monotonically weaker. Games are bucketed by BOT
NAME, so games played at two different dials never pool: a certificate is earned at ONE dial, out
of that dial's own games.

THE RULE IS TWO-SIDED, AND THAT IS THE SHAPE OF THE WHOLE PROBLEM (deepkyu_tally.pair_stats, which
this file must agree with and must never change). A rung is CERTIFIED when the published Wilson
95% interval of its even-game gap BOTH lies inside [70,130] AND CONTAINS 100. An interval like
[70, 87.5] is invalid however tight. Because the status is recomputed after every look, the two
halves are enforced with opposite disciplines -- containment on the WIDER Z=2.50 interval,
coverage on the NARROWER Z=1.50 one -- so the published Z=1.96 certificate satisfies both a
fortiori after arbitrarily many looks.

WHAT THAT DOES TO THE SAMPLE SIZE, and it is the fact every line below is built on. Feasibility
needs the half-width w to satisfy BOTH |pt - 100| <= w (reach the centre) and w <= min(pt-70,
130-pt) (stay in the band), so w is bounded BELOW as well as above and certification is a WINDOW
in n, not a threshold:

    it is EMPTY below n = 914; it is widest at n = 2372, where the observed gap may be anywhere
    in [+88.9, +111.3]; and it closes like 543/sqrt(n) forever after.

Three consequences, and they are why this file was rewritten:
  * MORE GAMES CAN DESTROY A RUNG. A bucket certified at an observed gap of +92.2 stops
    certifying at n = 4786. Continuing to play against a certified bot name is not thrift, it is
    a way to lose a rung that is already published. DONE therefore prints the lifetime.
  * [88.7, 111.3] BOUNDS THE PUBLISHED POINT ESTIMATE, NOT THE TRUE GAP. No certificate can ever
    carry a point estimate outside it. That is NOT a statement about truth: the coverage gate is
    a selection ON the estimate, so a rung whose TRUE gap is 85 certifies 0.49 of the time and
    one at 80 still 0.25, and each publishes a number inside the window. The old viability filter
    asked whether a dial's gap was inside [70,130]; p_centre asks about this window instead,
    which is the right question for PLACEMENT and is not a guarantee about what certifies.
  * A DIAL CAN DIE OF SUCCESS. OVERSHOT (see rule_state) is the exit the one-sided rule had no
    use for: a dial still nominally alive, whose own games have carried its estimate so far off
    centre that coverage can no longer be recovered. Under the old rule more games could only
    ever help, so the cost model had no reason to stop paying at a dial. It does now.

WHAT THIS FILE IS. A rewrite of the decision layer of deepkyu_place.py, which three adversarial
verifiers rejected. The old tool separated "probe" from "certify", priced the probe with a
one-step lookahead whose stop rule compared two different baselines, and consequently recommended
the same probe round after round without ever playing a game at the dial it said it would ship.
The rewrite deletes that split. The single fact it is built on:

    AT THIS RUNG, INFORMATION AND PROGRESS ARE THE SAME GAMES.
    Every game played at dial x both (a) tells you what gap x delivers and (b) counts toward the
    certificate at x. So there is never a reason to play at a dial you would not ship, and the
    only decision left is WHICH dial to stand on. That decision is made by pricing each candidate
    dial in expected total games and taking the argmin -- and because the recommendation is always
    "play n > 0 games somewhere", the loop cannot fail to terminate.

    QUALIFIED BY THE TWO-SIDED RULE: it is true only while the dial is alive. Past n_kill(g_hat)
    a dial's games are information only -- they can no longer buy that dial a certificate -- and
    past the OVERSHOT boundary they are not even that. The premise survives as a statement about
    a LIVE dial, which is why "stop playing a dial that is still nominally alive" had to become
    an exit rather than a judgement call.

COST IS ONLY FINITE BECAUSE YOU MAY WALK AWAY. games_needed(gap) diverges at the band edge, and a
real fraction of the posterior sits outside the band entirely, so E[games_needed] is infinite and
any plug-in or plain expectation built on it is meaningless (at the live rung-1 dials the plug-in
reads 17124 while the posterior median is 10004). Here the cost of a dial is measured by
SIMULATING THE RULE IN FORCE forward from that dial's realised (w, n), with FOUR exits --
certified, refuted, OVERSHOT, or the abandon cap -- so every expectation is a bounded quantity. Abandoning
returns you to the same problem, so the continuation value is solved as a fixed point

    V(x) = E_g[ spend(x, g) ] + (1 - E_g[ P(certify | x, g) ]) * (MOVE + V*),   V* = min_x V(x)

rather than asserted as a constant.

WHY THERE IS NO LONGER A FIDELITY PRICE (p_fid = 0). The 11 rungs' delivered gaps sum to the
ladder's span, so a rung that certifies far from its target used to move the whole ladder, and
that damage was priced at p_fid games per ELO -- an exchange rate derived as
|d games_needed/d target|. Two things killed it on the day the goal changed. (1) Every target is
now exactly 100, so there is no span budget to allocate and nothing to trade; and the function it
differentiated, deepkyu_tally.games_needed, is the ONE-SIDED cost, which under the two-sided rule
is not the number of games needed for anything (the requirement is an interval in n). (2) It is
subsumed by something steeper: P(certify) is now .99 at a true gap of 100, .94 at 95, .78 at 90,
.51 at 85 and .25 at 80, so the games term ALREADY charges roughly 400 games per ELO near the
target, and charging P_FID = 3200 on top of it was an 8x double-count. The constant survives under
the name P_EXPLORE in the one place it was never a fidelity price: the branch where NOTHING can
certify, where it is the exploration gradient that walks a stuck lever toward the target. The
recursion below is kept verbatim and is simply evaluated at p_fid = 0, where it reduces to the
games-only iteration (selftest [11] pins that reduction). What no price could ever buy is reported
instead: `p_centre`, the posterior probability that a dial's TRUE gap is inside the feasible set,
and the bench's `lottery` column, the share of certificates bought at a dial that was wrong.

THE ARITHMETIC THAT REMAINS, for the record. The 11 rungs' delivered gaps sum to the span, and The damage of STANDING on a dial is NOT the miss it makes when
it certifies: a dial that certifies 2% of the time almost never delivers a certificate at all,
and the miss is then made by whatever dial we certify at AFTER abandoning it. Both branches, and
only both, are the damage:

    M(x) = W(x) * miss(x) + (1 - W(x)) * M*,   miss(x) = E[ |gap-T| | THIS DIAL CERTIFIES ]

with W(x) = P(certify at x) and M* the damage of the continuation -- a fixed point for exactly
the reason V* is, and the SAME one: pricing ELO in games at p_fid collapses the pair into one
scalar recursion whose immediate cost carries the certifying branch,

    U(x) = [S(x) + p_fid*W(x)*miss(x)] + (1-W(x))*(MOVE + U*),  U* = min_x U(x) = V* + p_fid*M*

so ONE value iteration is solved, not two, and V* and M* fall out of the dial it lands on
(M* = miss(x*), V* = (S(x*) + (1-W(x*))*MOVE)/W(x*)). The version before this one charged
p_fid * (miss(x) - min_x miss(x)) with no second branch at all, and because miss() is
CONDITIONED on certifying it charged the LEAST to the dials that certify least -- in the rare
world where a hopeless dial certifies, the gap is necessarily in band. On the live rung 2 that
inversion stood the tool on a dial 39 ELO below target which certifies 2% of the time, and
charged it nothing. joint_value_iterate() is the recursion that removes it.

BEYOND THE LAST DIAL PLAYED THE SLOPE IS CONTINUED FLAT -- THE GEOMETRIC CONTINUATION BELOW WAS
BUILT, MEASURED, AND THEN REJECTED, AND IT IS OFF IN THE DRIVER (deepkyu_auto.sh passes --acc-k 1).
READ THE REJECTION FIRST; the paragraph after it is the case that was made FOR the mechanism and is
kept only so the measurement that killed it is legible.

  WHAT KILLED IT (independent adversarial verification, workflow w4a1rs5jd, on fresh seeds
  disjoint from every seed this file tunes on; all three numbers are that verifier's, paired
  bootstrap or Wilson 95%):
    (a) "OFF IS EXACT" IS CONDITIONAL, AND THE CONDITION FAILS HALF THE TIME. The identity holds
        when the fit does not accelerate -- but on an EXACTLY LINEAR truth the fit accelerates
        from binomial noise on 46-53% of designs, and the clamp is one-sided, so the noise only
        ever steepens. Measured harm where that happens: P(certify) -0.046 [-0.072, -0.020] at
        600-game arms and -0.094 [-0.118, -0.070] at 2400. Selftest [13b]'s "122 non-accelerating
        designs, 0 differ" is a true statement about the 122, not about the 178 that did.
    (b) IT LOSES ON THE TRUTH IT WAS BUILT FOR. On `compound` it costs a RESOLVED +419 [+102,
        +786] and +549 [+188, +953] games -- the claim below that games cannot resolve `compound`
        does not survive fresh seeds.
    (c) ITS HEADLINE COST DOES NOT REPRODUCE EITHER. `far`'s +916 [+440, +1415] below comes out
        +102 [-375, +603] and +288 [-250, +818] on fresh seeds -- not resolved, in the opposite
        direction. And the rung-9 fixture that certifies the whole change is mis-specified: the
        change reverses on it one round deeper.
  So sentences (b) and (c) in the paragraph below, and its claim that "the shallow regime is
  untouched", are WRONG AS WRITTEN. The shallow regime is untouched IN THE BENCH STATES; it is not
  untouched on a near-linear response, which is exactly where (a) measures the harm.
  ACC_K is NOT set to 1.0 in this source on purpose: selftest [13] asserts that the geometric
  branch MUST differ from the flat one, so a source revert has to relax [13] in the same commit.
  The driver flag is the honest switch and it is on.

WHAT THE MECHANISM WAS FOR (the superseded case). The extrapolant used
to be gap(x) = G_top + S*(x - x_top) with S drawn around a reference that is a max() of three
terms -- the last secant, half the global secant, and a 20 ELO/unit floor. A floor is not a second
derivative, so the extrapolant could not see acceleration at all, and every bench truth here is a
broken line whose secants wander, so nothing could see that it could not. THE LEVER IS NOT LIKE
THAT. Past x = 4.30 both temperature caps are pinned and the dial weakens through
halflife = 30 * 2**(x - 4.30): equal steps in x are equal DOUBLINGS of the noisy phase, so the ELO
response COMPOUNDS -- 39, 78, 209, 440 ELO/unit on the campaign's own 600-game arms, a secant that
roughly doubles every segment. IT COST RUNG 9 3,706 GAMES: from arms at 3.52/4.12/4.72 reading
-3.5/+19.7/+66.8 the tool read s_ref ~ 78, proposed x = 5.04, and 5.04 measured +133.7 -- 34 ELO
past the centre, P(certify) = 0.00. The reference slope is now multiplied by
clamp(s_last/s_prev, 1, ACC_K) whenever the last two segments accelerate and by exactly 1.0
whenever they do not, so on a fit that does not accelerate the extrapolation draws are
variate-for-variate the ones the pre-fix tool drew and the shallow regime -- where eight of the
ten certificates were earned -- is untouched. ACC_K = 2.0 and the widened spread SIG_SLOPE_ACC are
CALIBRATED, with intervals, in the comments beside them; selftest [13] pins the whole of it,
including the rung-9 fixture and a COMPOUNDING bench truth the file did not have. What the change
is NOT is a games win. At the 48-seed --bench default (never fewer) it is a WASH on nine of the
ten truths and bit-identical on three of them, it costs +120 games a rung [+52, +193] pooled over
all 480 paired runs, and all of that is ONE truth: it costs 916 games [+440, +1415] on `far` --
the truth that accelerates once and then runs straight, where a slope continued geometrically
reads the lever as twice as steep as it is and walks to the target in extra rounds. What it buys
is 12 to 53 ELO of placement error removed wherever the response keeps compounding, for 1 to 3
ELO paid where it does not, and the rung-9 dial moved from 5.04 (true gap +133.7, 34 ELO past the
centre, dead after 3,706 games) to 4.83 (+89.8, inside the feasible set). Both halves of that are
measured with intervals beside ACC_K; neither is asserted.

NOTHING UNIDENTIFIED IS EVER PRINTED AS A NUMBER. Monotonicity alone identifies a BRACKET for the
crossing, never a point; inside the bracket the position of the crossing is set by an
interpolation prior, so no x_hat is printed. What IS printed prior-free is the statement that
matters for the decision: for every dial in the bracket, the delivered gap lies between the two
bracketing block levels -- and when that whole range is inside [70,130], the dial is safe to ship
no matter where in the bracket the crossing actually is.

THE ACTION CONTRACT, because a driver obeys it literally. Three actions, and the game count is
part of the action, not a suggestion beside it:

    PLAY  x_next is a legal dial and n_next > 0. Play them there and call again.
    DONE  the rung is certified at x_next. n_next == 0.
    STOP  the target is unattainable on this lever. n_next == 0, and stop_reason is a statement
          about DATA -- a dial at its ceiling, or a bracket closed onto refuted dials -- never
          about the absence of data.

STOP used to be emitted whenever the continuation value V* hit its ceiling, which is what a rung
looks like at round 0 with two dials 50 ELO below the band and everything still to explore; it
came with n_next = 540, so the action and the game count contradicted each other, and the
acceptance harness discarded the action field entirely and could not see any of it. Now STOP
requires BOTH V* at its ceiling AND lever_room() reporting that no legal dial is left,
check_contract() enforces the whole contract on every return, and --bench runs the tool
FAITHFULLY -- obeying the action -- with the charitable mode kept alongside so the difference
between them is a printed number rather than an assumption.

WHAT POOLING COSTS. Dials closer than MIN_SEP may be one analysis point, but proximity alone
never pools them: a G^2 homogeneity test has to fail to reject one common winrate first, a group
that fails is cut where the deviance is, a block that only just passes is credited n/phi games
rather than n, and the response the merge assumed away inside a block (its width times the slope
beside it) is charged as uncertainty on the dial you will actually stand on. The report prints
what the merge is worth at the chosen dial, merged against that dial's own games, because the
certificate is earned at ONE dial out of ONE bucket and no test can confirm an assumption -- only
fail to reject it.

WHAT THE VARIANCE MODEL ASSUMES, AND WHAT IT MEASURES (W2). Every interval in this file --
Wilson, the cost simulation, the acceptance bar -- treats the games at one dial as independent
Bernoulli trials, i.e. phi = 1. That is no longer a silent assumption: `--dispersion` MEASURES it
on the campaign's own SGFs, at the only unit a set of games actually shares, the `katago match`
PROCESS (one nnRandSeed, one NN cache, one shuffled pairing round carrying both colour orders):

    phi = 1.00, 95% [0.85, 1.18], ~4000 decided games over ~290 df  (the ladder SGFs)
    phi = 0.98, 95% [0.85, 1.16], ~5000 decided games over ~313 df  (every deepkyu SGF dir)

(the campaign is still running, so --dispersion recomputes these rather than quoting them)

so phi = 1 stands, is CONSERVATIVE by at most about 2%, and that 2% is NOT banked -- it is inside
its own interval. The mechanisms that could have bent it are all measured and all worth nothing:
draws and no-results, which is what would bend it upward, do not occur at all at komi 6.5 with
maxMovesPerGame = 1200 (0 of each in 7840 games); the colour-order design is balanced to within
0.5% of games, and EXACT balancing would save 0.5-0.8% of variance -- measured from the games, as
delta^2/(p(1-p)) with delta the side's own black-minus-white winrate; the process-shared NN cache
and seed bound the intra-wave correlation to rho = -0.002, 95% [-0.015, +0.014]. The phi_hat = 0.43 that
prompted the question was a Bradley-Terry RESIDUAL dispersion on 7 df (55 free ratings, 61 edges),
95% CI [0.19, 1.78]: it never excluded 1, and it is the statistic that falls as parameters are
added. The COST model now carries a stated planning dispersion, plan_phi(), instead of a silent 1
-- clamped to >= 1 and allowed to react only above DISP_MIN_DF degrees of freedom, so on today's
data it is exactly 1.0 and every number this file prints is unchanged, while a genuinely
overdispersed future rung buys more GAMES rather than a narrower interval it has not earned.

WHAT --bench CAN AND CANNOT RESOLVE (W1). The acceptance table is a MEASUREMENT and it carries
measurement error, which at small --seeds is larger than every effect anyone has tried to read
out of it. Two independent diagnoses of the reported "steep-response weakness" found the same
thing: at 12 seeds the paired difference between the tool and its best baseline on a 1200 ELO/unit
truth has a per-seed sd of ~5030 games (the baseline's runs at the 40000 cap are the tail), so the
95% half-width on the mean difference is +/-2846 games and the sd of the quoted MEDIAN difference
is 423 games; at 240 seeds the sign reverses and the tool wins by a paired mean of 745 games
[175, 1447] while certifying 240/240 against 235/240. The |delivered gap - T| criterion is worse:
on a steep truth one lattice step IS 12 ELO, so that statistic takes the values {0, 12, 24} and
its 12-run median flips on one seed. Therefore --bench now (a) resamples the paired bootstrap over
CLUSTERS, (b) prints a 95% interval beside EVERY criterion, per-truth rows included, and refuses
to let a bare median be read as a win or a loss, (c) prints a censoring column and a winsorised
mean, because that is where a baseline's real cost lives, and (d) can average the tool over K
internal Monte-Carlo seeds (--tool-seeds), whose own scatter is sd 601 games per run. Nothing in
the DECISION layer was changed for W1: the lattice, MIN_SEP, SIG_SLOPE, S_MAX, propose()'s reach
and P_FID were each ablated at 288-480 runs and every proposed change was neutral or harmful
(finer lattice +261 to +546 games, slope-aware MIN_SEP fidelity +0.08 ELO, a churn brake +0.31 ELO
of delivered gap). What IS load-bearing on a steep lever is the HET_K resolution gate, worth +326
games [+197, +458]; selftest [8] now pins it.

EVERY ONE OF THOSE ABLATIONS WAS MEASURED IN EXPECTED GAMES AGAINST THE ONE-SIDED RULE, and
none has been re-measured against the two-sided one. TIE_FLOOR, HET_K, EXTRAP_MULT, MIN_SEP,
S_MAX, CAP_GAMES and the 0.01 lattice are therefore inherited constants, not re-validated ones.
The one where the goal change clearly bears is CAP_GAMES = 12000: a dial collects ~99% of its
certification probability by n ~ 5000 and E[games | it certifies] is 1500-2100 at EVERY true
gap, so the cap is nearly inert and probably wants to fall. That is an ablation (--bench at 48
seeds against the new truths), not an assertion, and it has not been run. Nothing in this file
claims otherwise.

SHOULD THE TOOL DECLINE A VALID CERTIFICATE THAT IS PROBABLY OFF CENTRE? MEASURED: IT CANNOT,
AND NEITHER PROPOSED DESIGN GETS NEAR IT (G1, section 5b). Both were built and measured against
the shipped tool on an independent harness -- a COMMIT GATE that refuses to stand on a dial whose
posterior says P(|true gap - 100| <= K) is too small (--commit-gate/--commit-k), and the same
preference written into the OPTIMAND, minimising expected games to a certificate that is also
near 100 (--obj-k). Both are OFF by default and neither is recommended. They change 4-30% of the
tool's moves and almost none of its certificates, because certification is a SELECTION ON THE
POINT ESTIMATE and the posterior a gate reads is centred on that same estimate: at the moment a
dial certifies its own posterior says "near 100" whatever the truth is. The numbers, the reason,
and the one thing that DOES move the quality axis (the acceptance, not the placement) are in 5b.

Usage:
  python3 deepkyu_place2.py --data obs.json --target 100     # [{"x":..,"w":..,"n":..}, ...]
  python3 deepkyu_place2.py --rung 1                         # live, from the ladder SGFs
  python3 deepkyu_place2.py --rung 1 --json-out act.json     # the contract, as strict JSON
  python3 deepkyu_place2.py --need-json obs.json --at 0.545  # honest replacement for games_needed
  python3 deepkyu_place2.py --rung 4 --rank 18k --target 100 --x-cur 1.36 --rate 740
  python3 deepkyu_place2.py --dispersion                     # measure phi on the campaign SGFs
  python3 deepkyu_place2.py --selftest                       # unit tests + calibration
  python3 deepkyu_place2.py --bench                          # beat-the-baseline acceptance run
"""
import argparse, json, math, os, re, sys, time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deepkyu_cfg as dc

# ---------------------------------------------------------------------------- 1. the rule
# Written here from the specification, not imported, so that the tool and the acceptance harness
# do not share a bug. selftest() checks it agrees with deepkyu_tally.pair_stats on a grid.
BAND_LO, BAND_HI = 70.0, 130.0
BAND_MID = 100.0         # THE TWO-SIDED RULE. The published interval must BOTH lie inside the
                         # band AND contain this centre: [70, 87.5] is invalid however tight.
Z_STOP = 2.50            # OUTER interval: must fit inside the band  (containment half)
Z_COVER = 1.50           # INNER interval: must contain BAND_MID     (coverage half)
Z_PUB = 1.96             # the published certificate, nested between the two
Z_KILL = 3.50            # OVERSHOT boundary, in sd of the dial's OWN observed gap. CALIBRATED,
                         # not derived -- see overshot(). 20000-trial binomial MC at the live
                         # 12-game look cadence, P(certify)/E[games at the dial]:
                         #   true gap   no kill      K=3.0      K=3.5      K=4.0
                         #      100   .985/ 1566  .954/1452  .979/1522  .983/1560
                         #       95   .943/ 2066  .913/1582  .935/1829  .943/1953
                         #       90   .778/ 3770  .740/1848  .768/2546  .776/3102
                         #       85   .507/ 6524  .491/1965  .502/2793  .506/3744
                         #       80   .253/ 9053  .244/1768  .250/2501  .257/3331
                         #      115   .509/ 6564  .490/2076  .504/2972  .509/3932
                         # K=3.5 costs 0.6 points of P(certify) at a centred dial and cuts the
                         # spend at a dial 15 ELO low by 57%. K=3.0 costs 3.1 points at the
                         # centre -- too eager; K=4.0 leaves 800-1200 games/dial on the table.
C_ELO = 400.0 / math.log(10.0)          # 173.7178 ELO per logit


def gap_of_p(p):
    """Even-game ELO gap (stronger - weaker) from the WEAKER side's winrate p."""
    p = np.clip(np.asarray(p, float), 1e-12, 1.0 - 1e-12)
    return 400.0 * np.log10((1.0 - p) / p)


def p_of_gap(g):
    return 1.0 / (1.0 + 10.0 ** (np.asarray(g, float) / 400.0))


def wilson(w, n, z=Z_STOP):
    """Wilson interval on the winrate, vectorised."""
    n = np.maximum(np.asarray(n, float), 1e-12)
    p = np.asarray(w, float) / n
    den = 1.0 + z * z / n
    cen = (p + z * z / (2.0 * n)) / den
    mar = (z / den) * np.sqrt(np.maximum(p * (1.0 - p) / n + z * z / (4.0 * n * n), 0.0))
    return np.clip(cen - mar, 0.0, 1.0), np.clip(cen + mar, 0.0, 1.0)


P_HI = float(p_of_gap(BAND_LO))         # 0.4008: the winrate at gap 70, the UPPER p of the band
P_LO = float(p_of_gap(BAND_HI))         # 0.3231: the winrate at gap 130


P_MID = float(p_of_gap(BAND_MID))       # 0.3599: the winrate at gap 100, the band CENTRE


def overshot(w, n, z_kill=Z_KILL):
    """The dial's own games say the CENTRE is out of reach, at this n and at every larger one.

    Coverage at a future look n' needs |gap_hat' - BAND_MID| <= Z_COVER * sigma', and sigma'
    <= sigma because n only ever grows at a dial (games are bucketed by bot name, so a dial's
    bank is monotone). Granting the estimate a full Z_COVER sigma of future fluctuation, a dial
    whose estimate is Z_KILL sigma off centre would still need the truth to be
    (Z_KILL - Z_COVER) = 2 sigma away, which coverage cannot absorb.

    THIS IS ABSORBING BY ASSUMPTION, NOT BY LOGIC -- exactly as `refuted` already is. A long
    enough losing streak moves p_hat anywhere, so no (w, n) makes a future certificate strictly
    impossible; both predicates are right under the Bernoulli law this whole file plans with, and
    neither may be described as more than that. What makes OVERSHOT necessary rather than
    optional is that the certification window CLOSES as n grows (see cert_window): a dial 15 ELO
    low is not merely slow, it spends 6500 games to buy a 50% lottery ticket, and the cost model
    must be allowed to stop paying."""
    n = np.asarray(n, float)
    w = np.asarray(w, float)
    ph = np.clip(np.divide(w, np.maximum(n, 1e-12)), 1e-9, 1.0 - 1e-9)
    g = 400.0 * np.log10((1.0 - ph) / ph)
    sg = C_ELO / np.sqrt(np.maximum(n, 1e-12) * ph * (1.0 - ph))
    return (np.abs(g - BAND_MID) > float(z_kill) * sg) & (n > 0)


def rule_state(w, n, z=Z_STOP, z_kill=Z_KILL, cover=True):
    """(certified, dead) under the TWO-SIDED rule deepkyu_tally.pair_stats implements.

    CERTIFIED requires BOTH halves, and they are deliberately opposite disciplines because the
    status is recomputed after every look:
        containment  the WIDER Z_STOP interval lies inside [70,130]; the published Z=1.96
                     interval is nested inside it and fits a fortiori;
        coverage     the NARROWER Z_COVER interval contains 100; the published interval is wider
                     and contains it a fortiori.
    Both are conservative, so the published 95% certificate is valid after arbitrarily many looks.

    DEAD is the union of the two exits at which this dial stops being worth a game:
        REFUTED   the Z_STOP interval lies entirely outside the band;
        OVERSHOT  the sample has grown past what coverage can tolerate (W2) -- the exit that did
                  not exist under the one-sided rule, where more games could only ever help.

    `cover` and `z_kill` exist ONLY so that --bench can price the two halves of this change
    against the shipped one-sided rule; nothing on a live path passes anything but the defaults.
    cover = False switches OVERSHOT off with it, because under containment alone drifting off
    centre is not fatal and the exit would be incoherent -- so cover=False is exactly the tool
    as it shipped, and z_kill=inf is the two-sided rule with no abandon exit.
    """
    lo, hi = wilson(w, n, z)
    nn = np.asarray(n, float)
    contain = (hi <= P_HI) & (lo >= P_LO)
    if cover:
        clo, chi = wilson(w, n, Z_COVER)
        cov = (clo <= P_MID) & (chi >= P_MID)
        ov = overshot(w, n, z_kill)
    else:
        cov = np.ones(np.shape(contain), bool)
        ov = np.zeros(np.shape(contain), bool)
    cert = contain & cov & (nn > 0)
    dead = ((hi < P_LO) | (lo > P_HI) | ov) & ~cert
    return cert, dead


def dead_kind(w, n, z_kill=Z_KILL):
    """"" if the dial is alive, else which exit killed it. REFUTED is tested on the interval, not
    on the point estimate: a dial can sit outside the band on p_hat and still overlap it at
    Z=2.50, in which case it is OVERSHOT and not refuted, and the report must not confuse the
    two -- they mean different things about what the games bought."""
    if float(n) <= 0:
        return ""
    lo, hi = wilson(w, n, Z_STOP)
    if bool(hi < P_LO) or bool(lo > P_HI):
        return "REFUTED"
    if bool(overshot(w, n, z_kill)):
        return "OVERSHOT"
    return ""


# ---- the rule IN CLOSED FORM. Wilson_z(w,n) contains p0 exactly when |w/n - p0| <= z*sqrt(p0
# q0/n) -- it is the score interval -- so certification is an INTERVAL OF WIN COUNTS at each n.
# selftest [2c] checks this against deepkyu_tally on a (w,n) grid: 0 mismatches in 85,497 pairs.
def cert_window(n):
    """[w_lo, w_hi], the win counts that CERTIFY at exactly n decided games. hi < lo means n
    cannot certify at any w at all. Pass n/phi for a planning dispersion above 1."""
    n = float(n)
    s = lambda p, z: z * math.sqrt(p * (1.0 - p) * n)
    lo = max(P_LO * n + s(P_LO, Z_STOP), P_MID * n - s(P_MID, Z_COVER))
    hi = min(P_HI * n - s(P_HI, Z_STOP), P_MID * n + s(P_MID, Z_COVER))
    return lo, hi


def gap_window(n):
    """The same window in point-gap ELO: (lo, hi) of observed gaps that certify at n, or None.

    This is the whole goal change in one object. It is EMPTY below N_OPEN, opens, widens to
    +-MAX_MISS at N_PEAK, and then closes like Z_COVER*sd forever after -- so a dial off centre
    is not merely slow, it has a LAST n at which it can still certify (n_kill)."""
    lo, hi = cert_window(n)
    if lo > hi:
        return None
    return float(gap_of_p(hi / n)), float(gap_of_p(lo / n))     # low w = big gap


def window_note(gap):
    """One line describing what the certification window does at an observed/believed gap."""
    nk = n_kill(gap)
    if not math.isfinite(nk):
        return "opens at n = %d and never closes (the estimate is exactly the centre)" % N_OPEN
    if nk < N_OPEN:
        return ("is EMPTY: coverage would already be lost by n = %.0f, before the window opens "
                "at n = %d, so no sample size certifies this gap" % (nk, N_OPEN))
    return "opens at n = %d and the coverage half dies at n = %.0f" % (N_OPEN, nk)


def n_kill(gap):
    """The largest n at which an observed gap of `gap` still satisfies the coverage half, i.e.
    the number of games past which a certificate standing at that point estimate is DESTROYED by
    collecting more games into the same bucket. (Z_COVER*s/|g-100|)^2, within 0.1% of the exact
    rule over the whole band. Infinite only exactly at the centre."""
    d = abs(float(gap) - BAND_MID)
    if d < 1e-9:
        return float("inf")
    p = float(p_of_gap(gap))
    return (Z_COVER * (C_ELO / math.sqrt(p * (1.0 - p))) / d) ** 2


def _window_geometry(nmax=8000):
    n_open, best = None, (0.0, 0)
    for n in range(100, nmax):
        lo, hi = cert_window(n)
        if lo > hi:
            continue
        if n_open is None and math.ceil(lo) <= math.floor(hi):
            n_open = n
        g = gap_window(n)
        m = max(abs(g[0] - BAND_MID), abs(g[1] - BAND_MID))
        if m > best[0]:
            best = (m, n)
    return n_open, best[1], best[0]


N_OPEN, N_PEAK, MAX_MISS = _window_geometry()
# N_OPEN = 914 (the smallest n at which an INTEGER win count certifies; 908 in real w), the peak
# is at N_PEAK = 2372 and MAX_MISS = 11.25 ELO is the largest |published point - 100| any
# certificate can ever carry. [100-MAX_MISS, 100+MAX_MISS] is therefore the set of PUBLISHED
# POINT ESTIMATES, and the tool uses it as the placement target (p_centre, Fit.p_safe). It is NOT
# the set of true gaps that can certify: the coverage gate selects on the estimate, so a dial
# whose TRUE gap is 85 certifies about half the time and publishes an estimate inside the window
# anyway. Cost.lottery_share is the share of P(certify) that is NOT that.


def gap_ci(w, n, z=Z_STOP):
    lo, hi = wilson(w, n, z)
    return float(gap_of_p(hi)), float(gap_of_p(lo))        # gap is DECREASING in p


def sd_gap(w, n):
    """1 sigma of the observed gap at a dial -- the number that explains the burned budget."""
    n = max(float(n), 1.0)
    p = min(max(float(w) / n, 1.0 / (2.0 * n)), 1.0 - 1.0 / (2.0 * n))
    return C_ELO / math.sqrt(n * p * (1.0 - p))


# SHOULD A CERTIFICATE THIS CLOSE TO ITS CONTAINMENT EDGE BE FLAGGED? MEASURED: NO.
# The obvious design is a warning when the binding margin is small -- a quarter of the dial's own
# sd, say. It was built, and then measured on the certificates the stop rule actually produces:
# cold dial, 60-game looks, the rule run forward to its FIRST crossing, 1200 trials at each true
# gap in 80..115, 400 certificates scored per gap (3082 pooled).
#
#     true gap        80    85    90    95   100   105   110   115
#     binding margin under 0.25 sd
#                   0.93  0.91  0.91  0.89  0.87  0.90  0.90  0.89
#     median containment margin, ELO
#                   0.79  0.95  0.95  0.97  0.98  0.98  0.95  1.04
#     swing <= 1 game
#                   0.39  0.34  0.34  0.33  0.31  0.34  0.36  0.35
#     median swing  2     2     2     2     2     2     2     2
#
# A flag that fires on ~90% of certificates is not information, and neither is one at 34%. The
# thinness is not an anomaly to warn about -- it is what a FIRST-CROSSING stop rule produces by
# construction: the campaign stops the first look at which both halves hold, and while a rung is
# grinding it is containment that is still open, so containment is the half that has only just
# crossed when it stops. So the report carries no alarm. It carries the two margins, the binder,
# and the SWING (this certificate's own distance from failing, in games), plus these numbers for
# scale, so that 0.6 ELO is read as "normal for this stop rule" rather than as either a crisis or
# -- the defect this replaces -- 10.7 ELO of room that is not there.
CERT_TYPICAL_CONTAIN = 0.95   # ELO, the MEASURED median above (pooled)
CERT_TYPICAL_SWING = 2        # games, the MEASURED median above (pooled)
CERT_TYPICAL_UNDER_QSD = 0.90 # ...and the share under a quarter sd, which is why there is no flag


def cert_margins(w, n, z_stop=Z_STOP, z_cover=Z_COVER):
    """THE TWO MARGINS OF A CERTIFICATE, EACH MEASURED ON THE INTERVAL THAT ENFORCES IT.

    The rule has two halves and they are enforced on DIFFERENT intervals, so a certificate has
    two margins and they are not interchangeable:

        containment   min(lo_2.50 - 70, 130 - hi_2.50)    slack of the WIDER interval in the band
        coverage      min(100 - lo_1.50, hi_1.50 - 100)   slack of the NARROWER interval about 100

    THEY MOVE IN OPPOSITE DIRECTIONS IN n. More games at the same winrate narrow both intervals,
    which pushes the containment margin UP and the coverage margin DOWN. Coverage is therefore
    the half with a LIFETIME -- n_kill() is exactly the n at which its margin reaches zero, and
    `survives_to`/`headroom` are that lifetime in games -- while containment is the half that had
    to be BOUGHT at the look where the rule first fired, and can only get safer afterwards.

    WHICH IS WHY REPORTING ONLY THE LIFETIME WAS WRONG. survives_to/headroom describe the
    coverage half alone. On every live certificate that is the NON-BINDING half:

        rung        n      gap     coverage   containment
        14k-15k   1296   + 95.6     10.66         0.61
        15k-16k   1644   + 97.6     10.95         5.33
        16k-17k   1704   + 92.2      5.30         0.46
        17k-18k   1967   + 91.6      3.78         1.36

    so the tool reported 10.7 ELO of safety on a rung standing 0.6 ELO from the band edge. Both
    are reported now, and the smaller is named.

    THE BINDING MARGIN IS THIN BY CONSTRUCTION, NOT BY ACCIDENT. The status is re-tested after
    every chunk and the campaign stops the FIRST time both halves hold, so a certificate is
    sampled from the states that have only just crossed -- and while the rung is grinding it is
    containment that is still open (the interval is shrinking into the band), so containment is
    the half that first crosses and the half that is thin when it does. The dual-Z discipline is
    what makes that valid after arbitrarily many looks; the margin is what it cost. That is also
    why there is no warning attached to it: see the measurement above CERT_TYPICAL_CONTAIN.

    `swing` is the same fact with no model in it at all: the smallest change in the WIN COUNT, at
    this same n, that leaves the state uncertified. A fact about the realised games, and the one
    number here an operator can check by hand.

    NO ALARM IS RAISED on a thin margin: see the measurement above CERT_TYPICAL_CONTAIN, where a
    quarter-sd flag fires on ~90% of the certificates this stop rule produces. `margin_sd` is
    reported so the reader can place the number against that base rate themselves.

    Returns a dict; margins are in ELO and may be negative for a state that does not certify.
    """
    n = float(n)
    slo, shi = gap_ci(w, n, z_stop)
    clo, chi = gap_ci(w, n, z_cover)
    m_con = min(slo - BAND_LO, BAND_HI - shi)
    m_cov = min(BAND_MID - clo, chi - BAND_MID)
    binds = "containment" if m_con <= m_cov else "coverage"
    cert = bool(rule_state(np.array([float(w)]), np.array([n]))[0][0])
    swing, swing_dir = None, ""
    if cert:
        # vectorised: the certification window is an interval of win counts at fixed n, so the
        # first k that leaves it in either direction is the answer and it is bounded by the
        # window's own half-width (~80 wins at the largest n this campaign reaches).
        K = int(min(float(w), n - float(w))) + 1
        ks = np.arange(1, max(K, 2), dtype=float)
        nn = np.full(ks.shape, n)
        dn = ~rule_state(float(w) - ks, nn)[0]
        up = ~rule_state(float(w) + ks, nn)[0]
        hit = np.flatnonzero(dn | up)
        if hit.size:
            j = int(hit[0])
            swing, swing_dir = int(ks[j]), ("fewer" if bool(dn[j]) else "more")
    sd = sd_gap(w, n)
    return {"contain": float(m_con), "cover": float(m_cov),
            "margin": float(min(m_con, m_cov)), "binds": binds,
            "margin_sd": float(min(m_con, m_cov) / sd) if sd > 0 else float("inf"),
            "swing": swing, "swing_dir": swing_dir, "sd": float(sd),
            "stop_ci": (float(slo), float(shi)), "cover_ci": (float(clo), float(chi))}


# ---------------------------------------------------------------------------- 2. legal domain
# deepkyu_cfg.dial_params: early = 0.70 + x (capped at 5.0), then the halflife branch, then
# nnPolicyTemperature. The early temperature must stay positive, and 0.05 is the lowest value the
# campaign has ever run (x = -0.650, the sharpest end of the dial; deepkyu_ladder.X_FLOOR agrees).
X_LO = round(0.05 - dc.TEMP_BASE_EARLY, 6)                           # -0.65
X_HI = round(dc.X_HALFLIFE_CAP + (dc.NNPT_MAX - 1.0) * 3.0 / 4.0, 6)  # 11.50
LATTICE = 0.01        # dials are proposed on this lattice: a free grid opens a fresh SGF bucket
                      # after every chunk and never banks enough games to certify anything


def in_domain(x):
    return X_LO - 1e-9 <= float(x) <= X_HI + 1e-9


def clamp_x(x):
    return float(min(max(float(x), X_LO), X_HI))


def snap(x):
    """Nearest legal lattice dial."""
    return clamp_x(round(round(float(x) / LATTICE) * LATTICE, 6))


# ---------------------------------------------------------------------------- 3. data
RE_NAME = re.compile(r"^(?P<rank>\d+[kd])_v(?P<v>\d+)_e(?P<e>[-\d.]+)_l(?P<l>[-\d.]+)"
                     r"(?:_h(?P<h>[-\d.]+))?(?:_s(?P<s>\d+))?(?:_q(?P<q>[-\d.]+))?"
                     r"(?:_p(?P<p>[-\d.]+))?(?:_r(?P<r>[-\d.]+))?_(?P<tag>[A-Za-z0-9]+)$")


def parse_bot(nm):
    """Bot NAME -> (x, signature, ""), or (None, None, reason).

    The signature is everything about the bot that is NOT the dial: (rank, maxVisits, symmetries,
    onlyBelowProb, rootPolicyTemperature, protocol tag). Two bots with different signatures are
    physically different players even at the same x, and pooling them credits one bucket's banked
    games to another bot -- so the caller refuses instead. The x inverse is verified both ways:
    dial_params(x) must reproduce every field and deepkyu_cfg.bot_name must rebuild the string.
    """
    m = RE_NAME.match(nm)
    if not m:
        return None, None, "name does not parse"
    e = float(m.group("e")); late = float(m.group("l"))
    hl = float(m.group("h")) if m.group("h") else dc.HALFLIFE_BASE
    sym = int(m.group("s")) if m.group("s") else 2
    q = float(m.group("q")) if m.group("q") else 1.0
    nnpt = float(m.group("p")) if m.group("p") else 1.0
    rootpt = float(m.group("r")) if m.group("r") else 1.0
    if nnpt > 1.0 + 1e-9:
        x = dc.X_HALFLIFE_CAP + (nnpt - 1.0) * 3.0 / 4.0
    elif hl > dc.HALFLIFE_BASE + 1e-9:
        x = dc.X_EARLY_CAP + math.log2(hl / dc.HALFLIFE_BASE)
    else:
        x = e - dc.TEMP_BASE_EARLY
    x = round(x, 6)
    # The name carries halflife rounded to 4 decimals, so inverting it lands a hair off the 0.010
    # dial lattice (4.88 comes back as 4.880001). A DONE action then reports that x_next and
    # deepkyu_auto.sh's read_contract refuses it as off-lattice. Snap -- but only when the snapped
    # dial rebuilds the IDENTICAL name, which proves it is the same bot and not a nearby one; a
    # genuinely off-lattice historical bucket fails that test and keeps its exact x.
    xl = snap(x)
    if xl != x:
        pe, pl, ph, pn = dc.dial_params(xl)
        if dc.bot_name(m.group("rank"), int(m.group("v")), pe, pl, ph, sym, q, pn, rootpt) == nm:
            x = xl
    de, dlate, dhl, dnnpt = dc.dial_params(x)
    for got, want, what in ((de, e, "early"), (dlate, late, "late"),
                            (dhl, hl, "halflife"), (dnnpt, nnpt, "nnpt")):
        if abs(got - want) > 2e-4 * max(1.0, abs(want)):
            return None, None, "dial_params(%.6f).%s = %.5f != %.5f in the name" % (x, what, got, want)
    rebuilt = dc.bot_name(m.group("rank"), int(m.group("v")), de, dlate, dhl, sym, q, dnnpt, rootpt)
    if rebuilt != nm:
        return None, None, "bot_name round-trip gives %s" % rebuilt
    return x, (m.group("rank"), int(m.group("v")), sym, round(q, 6), round(rootpt, 6),
               m.group("tag")), ""


def check_rows(rows):
    """Refuse any row set in which one dial carries two physically different bots, or in which the
    same bot appears twice. Either one silently pools games that must not be pooled."""
    by_x, by_name = {}, {}
    for r in rows:
        if not in_domain(r["x"]):
            raise SystemExit("dial x = %.4f is outside the legal domain [%.3f, %.3f]"
                             % (r["x"], X_LO, X_HI))
        if r["n"] <= 0:
            raise SystemExit("dial x = %.4f has n = %g games" % (r["x"], r["n"]))
        if r["w"] < 0 or r["w"] > r["n"]:
            raise SystemExit("dial x = %.4f has w = %g out of n = %g" % (r["x"], r["w"], r["n"]))
        key = round(float(r["x"]), 6)
        sig = r.get("sig")
        if key in by_x and by_x[key][0] != sig:
            raise SystemExit(
                "two physically different bots share the dial x = %.6f:\n  %s  (%s)\n  %s  (%s)\n"
                "Their games are in different SGF buckets and must not be pooled. Restrict the "
                "scan (--visits / --sig) or remove the stale bot." %
                (key, by_x[key][1], by_x[key][0], r["name"], sig))
        if key in by_x:
            raise SystemExit("dial x = %.6f appears twice (%s and %s): merge the two buckets "
                             "upstream, they are the same bot" % (key, by_x[key][1], r["name"]))
        if r["name"] in by_name:
            raise SystemExit("bot %s appears at two dials, %.6f and %.6f"
                             % (r["name"], by_name[r["name"]], key))
        by_x[key] = (sig, r["name"])
        by_name[r["name"]] = key
    sigs = set(r.get("sig") for r in rows if r.get("sig") is not None)
    if len(sigs) > 1:
        raise SystemExit("the rows mix %d physically different bots (differing in rank, visits, "
                         "symmetries, onlyBelowProb, rootPolicyTemperature or protocol tag):\n  %s\n"
                         "Only one of them is this rung's weaker side. Pick it with --sig."
                         % (len(sigs), "\n  ".join(repr(s) for s in sorted(map(str, sigs)))))
    return rows


def load_json(path):
    rows = []
    for o in json.load(open(path)):
        x = float(o["x"])
        nm = o.get("name")
        sig = None
        if nm:
            xb, sig, why = parse_bot(nm)
            if xb is not None and abs(xb - x) > 1e-4:
                raise SystemExit("row %s carries x = %.6f but its name inverts to %.6f" % (nm, x, xb))
        rows.append({"x": x, "name": nm or "x=%+.4f" % x, "sig": sig,
                     "w": float(o["w"]), "n": float(o["n"])})
    rows.sort(key=lambda r: r["x"])
    return check_rows(rows)


def load_live(rung, sgf_dirs, cache_path, sig_filter=None):
    """Every dial this rung's weaker rank has ever been played at against its stronger bot."""
    import deepkyu_tally as dt
    import deepkyu_ladder as dl
    st = dl.load()
    rg = dl.rungs(st)
    if not (1 <= rung <= len(rg)):
        raise SystemExit("rung %d out of range 1..%d" % (rung, len(rg)))
    strong, _weak_now, rank = rg[rung - 1]
    totals, nfiles = dt.scan(sgf_dirs, cache_path)
    names = set()
    for (pb, pw) in totals:
        names.add(pb); names.add(pw)
    if strong not in names:
        raise SystemExit(
            "the rung's stronger bot %s has no games in %s. Its dial has moved since those games "
            "were played, so every banked-game credit below would be a lie. Refusing."
            % (strong, ", ".join(sgf_dirs)))
    rows, warns = [], []
    for nm in sorted(names):
        if not nm.startswith(rank + "_v"):
            continue
        r = dt.pair_stats(totals, strong, nm)
        if r["decided"] <= 0:
            continue
        x, sig, why = parse_bot(nm)
        if x is None:
            warns.append("SKIP %s (%d games): %s" % (nm, r["decided"], why))
            continue
        if sig_filter and str(sig) != sig_filter:
            warns.append("SKIP %s (%d games): signature %s filtered out" % (nm, r["decided"], sig))
            continue
        rows.append({"x": x, "name": nm, "sig": sig,
                     "w": r["weak_wins"] + 0.5 * r["draws"], "n": float(r["decided"])})
    rows.sort(key=lambda r: r["x"])
    return check_rows(rows), strong, rank, nfiles, warns


# ---------------------------------------------------------------------------- 4. fit
MIN_SEP = 0.05        # dials closer together than this are CANDIDATES to be pooled into one
                      # analysis point. The operator's own measurement is that dials closer than
                      # ~0.1 in x carry no slope information; 0.05 is the conservative half of
                      # that. This is the structural anti-slope guard: it is what stops
                      # x = 0.520/0.545/0.550 from reading a 5400 ELO/unit slope out of binomial
                      # noise. Proximity ALONE is not enough to pool, though -- see merge_rows().
HET_K = 1.0           # RESOLUTION GATE. Pooling buys precision and pays for it in bias: the
                      # response the block hides between its own member dials. Pool only while
                      # that hidden response, width x the slope beside the block, is no larger
                      # than HET_K times the sd the POOLED games would achieve -- i.e. only while
                      # the bias bought is smaller than the precision it buys. On the live rung-1
                      # triple that is 8.4 ELO of hidden response against a 9.8 ELO pooled sd, so
                      # they pool; on a 1200 ELO/unit response two dials 0.01 apart hide 12 ELO
                      # against a 6.9 ELO pooled sd, so they do not. This is the gate the
                      # homogeneity test cannot supply: G^2 only sees response the GAMES already
                      # resolve, and two 500-game dials 12 ELO apart look identical to it.
MERGE_ALPHA = 0.01    # G^2 homogeneity test level. Two dials close enough to pool are pooled only
                      # if their winrates are statistically indistinguishable at this level; the
                      # structural guard decides which dials MAY pool, the test decides which DO.
                      # Without it the merge is a silent assumption and the costs it advertises
                      # are optimistic by whatever within-block response it assumed away.
S_MAX = 1500.0        # ELO per unit x, the Lipschitz ceiling. The steepest slope this dial has
                      # ever shown is ~545 ELO/unit, so this is ~2.7x headroom. Used ONLY to bound
                      # extrapolation; nothing inside the data depends on it.
S_REF_FLOOR = 20.0    # slope floor for extrapolation proposals, so a flat top block cannot ask for
                      # an infinite step. A floor, never a divisor: see propose_beyond().
SIG_WARP = (0.40, 0.70, 1.00)      # interpolation prior, MIXED over (not fixed at) these
W_WARP = (0.30, 0.40, 0.30)
SIG_SLOPE = 0.80      # lognormal spread of the extrapolation slope prior
# THE EXTRAPOLANT IS CURVATURE-AWARE. Past the last dial played, gap(x) used to be continued
# LINEARLY IN x at a slope whose reference was a FLOOR (max of the last secant, half the global
# secant and S_REF_FLOOR), which cannot see acceleration at all. On this lever it must: past
# x = 4.30 both temperature caps are pinned and the dial weakens through
# halflife = 30 * 2**(x - 4.30), so equal steps in x are equal DOUBLINGS of the noisy phase and
# the ELO response COMPOUNDS. Measured on the campaign, each from a 600-game arm or better:
#     3.52 -> 4.12   ~39 ELO/unit   (temperature regime)
#     4.12 -> 4.72   ~78 ELO/unit   (crossing x = 4.30)
#     4.72 -> 5.04  ~209 ELO/unit   (halflife 40 -> 50)
#     5.03 -> 5.18  ~440 ELO/unit   (halflife 50 -> 55)
# i.e. the secant roughly DOUBLES every segment. Continuing the last secant flat cost rung 9
# 3,706 games: from arms at 3.52/4.12/4.72 the tool read s_ref ~ 78, proposed x = 5.04, and
# measured +133.7 -- 34 ELO past the band centre, P(certify) = 0.00.
ACC_K = 2.0           # THE ACCELERATION CLAMP, AND IT IS MEASURED. The extrapolation slope is
                      # continued GEOMETRICALLY, s_ext = s_last * clamp(s_last/s_prev, 1, ACC_K),
                      # and the clamp is what stops two noisy secants buying an unbounded leap.
                      #
                      # CALIBRATED ON THE QUESTION THE DEFECT IS ABOUT: from three arms inside a
                      # stretch whose secant is multiplied by rho every 0.35 of dial, the tool's
                      # posterior median puts gap = 100 at some x -- what is the TRUE gap there?
                      # (That is rung 9 exactly: arms at 3.52/4.12/4.72, the tool said 5.04, and
                      # 5.04 was +133.7.) 300 Monte-Carlo designs per cell, PAIRED on the same
                      # designs, 95% bootstrap intervals, rho = 1.0 the LINEAR control the clamp
                      # must not damage. E|true gap - 100| in ELO, each K against K = 1 (flat):
                      #
                      #  arms  rho  flat    K=1.5            K=2.0            K=2.5           K=3.0
                      #   600  1.0  24.1  +1.1[+0.5,+1.7]  +1.7[+0.8,+2.4]  +2.0[+1.1,+2.8]  +2.2
                      #   600  1.5  71.7  -2.6[-4.6,-0.8]  -2.4[-5.0,-0.2]  -2.1[-4.9,+0.3]  -1.7
                      #   600  2.0 157.1 -11.9[-17.5,-7.2]-13.1[-19.8,-7.3]-12.6[-19.5,-6.7] -11.7
                      #   600  3.0 495.0 -46.8[-67,-29]   -52.6[-75,-33]   -52.9[-76,-33]   -52.3
                      #  2400  1.0  14.5  +1.5[+1.1,+1.9]  +2.2[+1.7,+2.7]  +2.5[+2.0,+3.1]  +2.6
                      #  2400  2.0  82.8 -13.2[-16.1,-11] -13.5[-17.0,-10] -12.7[-16.3,-9.3] -11.8
                      #  2400  3.0 214.7 -40.1[-49,-33]   -47.4[-57,-38]   -47.7[-58,-38]   -46.9
                      #
                      # So it COSTS 1-3 ELO on a linear response -- every one of those intervals
                      # is above zero, a real cost and not noise -- and is worth 12-53 ELO
                      # wherever the response compounds. K is chosen by WORST-CASE EXCESS over the
                      # best K in each row, in ELO, because the certification band is an absolute
                      # +-11.25 window and not a relative one:
                      #     K=1.0  52.9 | K=1.5  7.6 | K=2.0  2.2 | K=2.5  2.5 | K=3.0  2.6  ELO
                      # K = 2.0 is the minimum and the curve is flat from 2.0 to 3.0. It is also
                      # the smallest doubling the campaign actually measured (its three ratios are
                      # 2.03, 2.66, 2.10), so the clamp truncates the lever's own curvature rather
                      # than chasing it -- the conservative direction for a PRIOR, and a prior is
                      # what this is: at 600-game arms one segment carries ~14 ELO of signal
                      # against a ~14 ELO per-arm sd, so a secant has a ~57 ELO/unit standard
                      # error and the ratio of two of them is a weak measurement, not a fit.
                      # ACC_K = 1.0 switches the whole mechanism off (the pre-fix tool exactly).
                      # AND WHAT IT COSTS IN GAMES, WHICH IS THE ONE PLACE IT MEASURABLY LOSES.
                      # Run FAITHFULLY at the 48-seed --bench default against the same tool with
                      # acc_k = 1, paired on the same table seeds, mean games:
                      #   rung1 +0 | steep +0 | cliff +0 (bit-identical: those fits never
                      #       accelerate, so the draws are variate-for-variate the old ones)
                      #   tilt +5 [+0,+15]   | c1200 +38 [+0,+112]  | off90   +44 [-118,+215]
                      #   shallow +48 [-139,+281] | plateau +49 [-72,+196]
                      #   compound +102 [-234,+414] | far +916 [+440,+1415]
                      #   ALL ten pooled, 480 paired runs: +120 games [+52,+193] a rung, and
                      #       E|delivered gap - 100| -0.19 ELO [-0.48,+0.11]
                      # `far` is the cost, and it is REAL -- that interval excludes zero. Its
                      # shape is why: gap accelerates once (15.8 -> 84.2 ELO/unit, a ratio of 5)
                      # and then runs STRAIGHT to the crossing at x = 1.30. The clamp reads the
                      # acceleration, believes the slope is ~2x what it is, proposes a step half
                      # the length needed, and walks to the target in extra 540-game rounds. That
                      # is the honest shape of the trade: a slope continued geometrically wins
                      # where the response KEEPS compounding and loses where it accelerates once
                      # and stops. The cost is 370-920 games at every K >= 1.5 and the K's cannot
                      # be separated from each other in games (K=1.5 - K=2.0 on `far` is -335
                      # [-791,+110], on `compound` -118 [-355,+126]), which is why K is chosen on
                      # the placement table above and not here. Against it: rung 9 lost 3,706
                      # games to the flat continuation on a lever that really does compound.
                      # NOT MEASURED, AND THE OBVIOUS NEXT THING: letting the acceleration DECAY
                      # with distance past the data (a ratio read off one segment says little
                      # three segments out) would keep the rung-9 fix and should remove most of
                      # the `far` cost. It is a second mechanism, it needs its own calibration,
                      # and nothing here has measured it.
SIG_SLOPE_ACC = 1.20  # lognormal spread of the extrapolation slope prior IN THE ACCELERATING
                      # BRANCH ONLY, floored at SIG_SLOPE so this branch is never NARROWER than
                      # the flat one. The clamp deliberately UNDER-corrects on a steeply
                      # compounding lever, so the posterior has to admit a truth its median does
                      # not reach. Calibrated on COVERAGE -- a nominal 90% interval should contain
                      # the truth 90% of the time -- over the same rho family, 300 designs a cell,
                      # Wilson 95% intervals, at 2400-game arms, one segment out / two:
                      #     sigma   rho 1.0    rho 2.0    rho 2.5    rho 3.0   mean |cover - 90|
                      #      0.80   91 / 92    88 / 77    83 / 67    82 / 63       8.4 points
                      #      1.00   94 / 96    88 / 80    83 / 74    84 / 71       7.4
                      #      1.20   96 / 99    89 / 80    84 / 77    84 / 79       6.7
                      #      1.50   98 /100    89 / 80    84 / 78    85 / 81       6.6
                      # 1.20 is where the gain stops: two segments out on the steepest truth it
                      # lifts coverage from 63% [57,68] to 79% [74,83], and 1.50 buys two more
                      # points at the price of covering 100% on a LINEAR response. AND THE HONEST
                      # CAVEAT, because it cuts the other way: on the rung-9 fixture itself the
                      # NARROW prior does better -- sigma 0.80 lands on 4.88, true gap +100.2,
                      # and the widened one on 4.83, +89.8. That is ONE case, the two dials are
                      # 2% apart in total cost (inside the tool's own tie band), and the coverage
                      # table is the resolved measurement; so the widening ships with this note
                      # standing beside it rather than without it.


def pava_dec(Y, wt):
    """Weighted DECREASING isotonic regression of every row of Y, by the min-max formula
        yhat_i = min_{j<=i} max_{k>=i} avg(j..k)
    which for a one-parameter exponential family is the order-restricted MLE, not an
    approximation (Robertson-Wright-Dykstra Thm 1.5.1). Checked against a brute-force
    implementation in selftest()."""
    Y = np.atleast_2d(np.asarray(Y, float))
    B, K = Y.shape
    wt = np.asarray(wt, float)
    if K == 1:
        return Y.copy()
    cw = np.concatenate([[0.0], np.cumsum(wt)])
    cy = np.concatenate([np.zeros((B, 1)), np.cumsum(Y * wt, axis=1)], axis=1)
    num = cy[:, None, 1:] - cy[:, :-1, None]
    den = cw[None, None, 1:] - cw[None, :-1, None]
    with np.errstate(divide="ignore", invalid="ignore"):
        M = num / den
    j = np.arange(K)[:, None]; k = np.arange(K)[None, :]
    M = np.where(k >= j, M, -np.inf)
    A = np.maximum.accumulate(M[:, :, ::-1], axis=2)[:, :, ::-1]
    Cm = np.minimum.accumulate(A, axis=1)
    idx = np.arange(K)
    return Cm[:, idx, idx]


def _gammainc_q(a, x):
    """Regularised UPPER incomplete gamma Q(a,x) = Gamma(a,x)/Gamma(a), to machine precision.
    Series below the crossover, Lentz continued fraction above (Numerical Recipes 6.2). scipy is
    not installed in this environment and a chi-square tail is the whole of what is needed."""
    a = float(a); x = float(x)
    if a <= 0.0:
        raise ValueError("a must be positive")
    if x <= 0.0:
        return 1.0
    lead = math.exp(-x + a * math.log(x) - math.lgamma(a))
    if x < a + 1.0:
        ap, s, d = a, 1.0 / a, 1.0 / a
        for _ in range(10000):
            ap += 1.0
            d *= x / ap
            s += d
            if abs(d) < abs(s) * 1e-16:
                break
        return max(0.0, min(1.0, 1.0 - s * lead))
    tiny = 1e-300
    b = x + 1.0 - a
    c = 1.0 / tiny
    d = 1.0 / b if abs(b) > tiny else 1.0 / tiny
    h = d
    for i in range(1, 10000):
        an = -i * (i - a)
        b += 2.0
        d = an * d + b
        if abs(d) < tiny:
            d = tiny
        c = b + an / c
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        de = d * c
        h *= de
        if abs(de - 1.0) < 1e-16:
            break
    return max(0.0, min(1.0, h * lead))


def chi2_sf(stat, df):
    """P(chi^2_df >= stat)."""
    if df <= 0:
        return 1.0
    if stat <= 0.0:
        return 1.0
    return _gammainc_q(0.5 * df, 0.5 * stat)


def g2_homog(members):
    """Likelihood-ratio G^2 test that several dials share ONE binomial winrate.

        G^2 = 2 * sum_i [ w_i log(w_i / (n_i p)) + (n_i-w_i) log((n_i-w_i) / (n_i (1-p))) ]

    on df = (#members - 1), where p is the pooled rate. Returns (G2, df, p_value, phi) with
    phi = max(1, G2/df) the quasi-binomial overdispersion factor: if the members really do share a
    rate, phi is 1 and pooling is free; if they do not, phi > 1 and the pooled block's effective
    sample size is n/phi, which is the honest precision of a pooled heterogeneous block.
    Draws count as half a win, so w may be fractional; the statistic is unchanged by that."""
    ms = [m for m in members]
    df = len(ms) - 1
    if df <= 0:
        return 0.0, 0, 1.0, 1.0
    N = float(sum(m["n"] for m in ms))
    W = float(sum(m["w"] for m in ms))
    p = min(max(W / N, 1e-12), 1.0 - 1e-12)
    G2 = 0.0
    for m in ms:
        n, w = float(m["n"]), float(m["w"])
        l = n - w
        if w > 0:
            G2 += 2.0 * w * math.log(w / (n * p))
        if l > 0:
            G2 += 2.0 * l * math.log(l / (n * (1.0 - p)))
    G2 = max(G2, 0.0)
    return G2, df, chi2_sf(G2, df), max(1.0, G2 / df)


def _split_homog(group, alpha):
    """Recursively cut a proximity group wherever its members are NOT one winrate. The cut is
    placed at the boundary that explains the most deviance, which for an ordered, monotone
    response is the boundary the response actually steps at. Terminates: every cut is strict."""
    if len(group) <= 1:
        return [group]
    G2, df, pval, _phi = g2_homog(group)
    if pval >= alpha:
        return [group]
    best, bi = -1.0, None
    for i in range(1, len(group)):
        a, b = group[:i], group[i:]
        wa = sum(m["w"] for m in a); na = sum(m["n"] for m in a)
        wb = sum(m["w"] for m in b); nb = sum(m["n"] for m in b)
        # between-group deviance of this cut, the 2x2 G^2
        tot_w, tot_n = wa + wb, na + nb
        pp = min(max(tot_w / tot_n, 1e-12), 1.0 - 1e-12)
        d = 0.0
        for ww, nn in ((wa, na), (wb, nb)):
            ll = nn - ww
            if ww > 0:
                d += 2.0 * ww * math.log(ww / (nn * pp))
            if ll > 0:
                d += 2.0 * ll * math.log(ll / (nn * (1.0 - pp)))
        if d > best:
            best, bi = d, i
    return _split_homog(group[:bi], alpha) + _split_homog(group[bi:], alpha)


def _iso_levels(blocks):
    """Point isotonic (decreasing-in-winrate) gap level of each block. Used inside the merge to
    size the response beside a block, before any Fit exists."""
    w = np.array([b["w"] for b in blocks], float)
    n = np.array([b["n"] for b in blocks], float)
    if len(blocks) == 1:
        return gap_of_p(np.clip(w / n, 1e-9, 1 - 1e-9))
    pp = np.clip(pava_dec((w / n)[None, :], n)[0], 1e-9, 1 - 1e-9)
    return gap_of_p(pp)


def block_het(blocks, k, levels=None):
    """ELO of response a block hides between its own member dials: its width times the slope of
    the segments beside it. Zero for a single-dial block, which hides nothing."""
    b = blocks[k]
    d = float(b["hi"] - b["lo"])
    if d <= 0 or len(blocks) < 2:
        return 0.0
    g = _iso_levels(blocks) if levels is None else levels
    slopes = []
    for j in (k - 1, k):
        if 0 <= j < len(blocks) - 1:
            dx = blocks[j + 1]["lo"] - blocks[j]["hi"]
            if dx > 1e-12:
                slopes.append(max((g[j + 1] - g[j]) / dx, 0.0))
    s = max(slopes) if slopes else 0.0
    return float(min(d * s, d * S_MAX))


def _resolution_pass(blocks, het_k):
    """Split any block whose hidden response is bigger than the precision pooling bought it. The
    cut goes at the block's widest internal dial separation, which on a monotone response is where
    most of the hidden response is. -> (blocks, changed)."""
    levels = _iso_levels(blocks)
    out, changed = [], False
    for k, b in enumerate(blocks):
        if len(b["members"]) < 2 or b["hi"] <= b["lo"]:
            out.append(b)
            continue
        if block_het(blocks, k, levels) <= het_k * sd_gap(b["w"], b["n"]):
            out.append(b)
            continue
        changed = True
        ms = sorted(b["members"], key=lambda m: m["x"])
        i = max(range(1, len(ms)), key=lambda j: ms[j]["x"] - ms[j - 1]["x"])
        out.append(_block(ms[:i]))
        out.append(_block(ms[i:]))
    return out, changed


def _block(members):
    n = float(sum(m["n"] for m in members))
    G2, df, pval, phi = g2_homog(members)
    return {"lo": float(min(m["x"] for m in members)), "hi": float(max(m["x"] for m in members)),
            "xc": float(sum(m["x"] * m["n"] for m in members) / n),
            "w": float(sum(m["w"] for m in members)), "n": n, "members": list(members),
            "G2": float(G2), "df": int(df), "pval": float(pval), "phi": float(phi),
            "n_eff": float(n / phi), "w_eff": float(sum(m["w"] for m in members) / phi)}


def merge_rows(rows, min_sep=MIN_SEP, alpha=MERGE_ALPHA, het_k=HET_K):
    """Pool dials no measurement on this rung can separate. THREE gates, all required:

      STRUCTURAL   a run of dials spanning less than min_sep of dial MAY be one block, because
                   this rung cannot read slope over a span that short;
      HOMOGENEITY  they are pooled only if a G^2 test cannot reject one common winrate at alpha.
                   A group that fails is cut at the boundary carrying the most deviance, and the
                   halves are re-tested, so a real step inside a proximity group survives it;
      RESOLUTION   and only while the response the block hides (its width times the slope beside
                   it) is no larger than het_k times the sd the pooled games buy. G^2 cannot see
                   response its games do not resolve, which on a steep lever is exactly the
                   response that matters; this gate is sized in ELO, not in dial, and it is what
                   stops two dials 0.01 apart being declared one point on a 1200 ELO/unit lever.

    Pooling that passes the test is still an assumption, and its residual price is charged: the
    block carries phi = max(1, G^2/df) and an effective sample size n/phi, so a block that is only
    just homogeneous does not advertise the precision of a block that truly is. The block is an
    ANALYSIS object -- it has no config and no SGF bucket, so banked games are always taken from
    the member dials by name.

    min_sep = 0 disables the structural gate entirely and gives every dial its own block; that is
    the sensitivity knob that separates dials 0.01 apart, which a merge width of 0.025 cannot."""
    if not rows:
        return []
    groups = [[rows[0]]]
    for r in rows[1:]:
        if min_sep > 0 and r["x"] - groups[-1][0]["x"] < min_sep:   # span from the group's first
            groups[-1].append(r)                                    # member, never a chain
        else:
            groups.append([r])
    split = []
    for g in groups:
        split.extend(_split_homog(g, alpha))
    out = [_block(g) for g in split]
    if het_k is not None and math.isfinite(het_k):
        for _ in range(len(rows) + 1):          # each pass strictly increases the block count
            out, changed = _resolution_pass(out, het_k)
            if not changed:
                break
    for a, b in zip(out, out[1:]):
        if not b["lo"] > a["hi"]:                      # cannot happen; raised, never divided by
            raise SystemExit("internal: merged blocks overlap (%.6f..%.6f, %.6f..%.6f)"
                             % (a["lo"], a["hi"], b["lo"], b["hi"]))
    return out


class Fit:
    """Monotone fit of gap(x) plus a posterior over it.

    Block levels: each merged block's rate is drawn from its own exact Jeffreys posterior and the
    whole draw is projected onto the monotone cone (Dunson & Neelon 2003). No smoothness is
    imposed between blocks, so a plateau stays a plateau.

    Between blocks: monotonicity identifies only the INTERVAL [G_k, G_{k+1}]. The position inside
    it is a prior -- gap = G_k + (G_{k+1}-G_k) * t**gamma with log gamma ~ N(0, sigma^2), sigma
    mixed over SIG_WARP -- and is labelled PRIOR everywhere it is used.

    Beyond the ends: monotonicity identifies only a half-line, so a slope prior is required and is
    stated: S ~ S_ref * LogNormal(0, SIG_SLOPE), clipped to [0, S_MAX].
    """

    def __init__(self, rows, B=8000, seed=20260911, min_sep=MIN_SEP, sig_warp=SIG_WARP,
                 w_warp=W_WARP, merge_alpha=MERGE_ALPHA, het_mult=1.0, het_k=HET_K,
                 acc_k=ACC_K, sig_acc=SIG_SLOPE_ACC):
        self.rows = rows
        self.min_sep, self.merge_alpha, self.het_mult = float(min_sep), float(merge_alpha), float(het_mult)
        self.het_k = het_k
        # acc_k = 1.0 is the pre-fix tool exactly: _accel() returns 1.0 unconditionally, the
        # lognormal spread stays at SIG_SLOPE, and propose() emits the same candidate set.
        self.acc_k = max(1.0, float(acc_k))
        self.sig_acc = max(SIG_SLOPE, float(sig_acc))
        self.blocks = merge_rows(rows, min_sep, merge_alpha, het_k)
        self.K = len(self.blocks)
        self.B = int(B)
        self.lo = np.array([b["lo"] for b in self.blocks])
        self.hi = np.array([b["hi"] for b in self.blocks])
        self.xc = np.array([b["xc"] for b in self.blocks])
        self.wm = np.array([b["w"] for b in self.blocks])
        self.nm = np.array([b["n"] for b in self.blocks])
        self.phi = np.array([b["phi"] for b in self.blocks])
        self.we = np.array([b["w_eff"] for b in self.blocks])      # quasi-binomial: a block that
        self.ne = np.array([b["n_eff"] for b in self.blocks])      # is only just homogeneous does
        rng = np.random.default_rng(seed)                          # not get full-precision credit
        PH = rng.beta(self.we + 0.5, self.ne - self.we + 0.5, size=(self.B, self.K))
        self.P = np.clip(pava_dec(PH, self.ne), 1e-9, 1 - 1e-9)
        self.G = gap_of_p(self.P)                                  # (B, K) posterior block gaps
        self.iso_p = np.clip(pava_dec((self.wm / self.nm)[None, :], self.nm)[0], 1e-9, 1 - 1e-9)
        self.iso_gap = gap_of_p(self.iso_p)                        # point estimate
        self.het = self._het()                                     # within-block response, in ELO
        self.HET = rng.uniform(-0.5, 0.5, size=(self.B, self.K))
        self.NRM = rng.normal(0.0, 1.0, size=(self.B, self.K))
        # Per MEMBER dial of a multi-dial block: its OWN gap estimate and variance. The certificate
        # is earned at one dial out of that dial's own games, so once a dial has games of its own
        # they must be allowed to disagree with the block -- see gap_draws().
        self.own = {}
        for k, b in enumerate(self.blocks):
            if len(b["members"]) < 2:
                continue
            for m in b["members"]:
                n, w = float(m["n"]), float(m["w"])
                if n <= 0:
                    continue
                pp = min(max(w / n, 0.5 / n), 1.0 - 0.5 / n)
                self.own[round(float(m["x"]), 6)] = (k, float(gap_of_p(pp)),
                                                     float(sd_gap(w, n)) ** 2)
        nseg = max(self.K - 1, 1)
        sig = rng.choice(np.asarray(sig_warp, float), size=self.B,
                         p=np.asarray(w_warp, float) / np.sum(w_warp))
        self.GAM = np.exp(rng.normal(0.0, 1.0, size=(self.B, nseg)) * sig[:, None])
        s_hi, s_lo, a_hi, a_lo = self._edge_slopes()
        self.s_ref_hi, self.s_ref_lo = s_hi, s_lo
        self.acc_hi, self.acc_lo = a_hi, a_lo          # 1.0 unless the last two segments accelerate
        # THE WIDENING IS IN THE ACCELERATING BRANCH ONLY. Where the fit does not accelerate both
        # a_* are exactly 1.0 and both lines below are character-for-character the old ones, in
        # the same order, drawing the same variates from the same stream -- so the shallow regime,
        # where eight of the ten certificates were earned, is bit-identical.
        sg_hi = self.sig_acc if a_hi > 1.0 else SIG_SLOPE
        sg_lo = self.sig_acc if a_lo > 1.0 else SIG_SLOPE
        self.S_hi = np.clip(s_hi * a_hi * np.exp(rng.normal(0.0, sg_hi, self.B)), 0.0, S_MAX)
        self.S_lo = np.clip(s_lo * a_lo * np.exp(rng.normal(0.0, sg_lo, self.B)), 0.0, S_MAX)

    # -- structure ----------------------------------------------------------
    def _het(self):
        """Per block: how much delivered-gap response the MERGE assumed away, in ELO.

        A block of width d, sitting beside segments of slope s, hides up to d*s of real response
        between its own member dials -- and the certificate is earned at ONE of those dials, out
        of that dial's own games, so that hidden response is uncertainty about the dial you will
        actually stand on. It is charged here as a uniform window of width d*s around the block
        level, which is zero for a single-dial block and is exactly what a homogeneity test cannot
        see: the test only rejects response the GAMES already resolve, and the games at a 51-game
        dial resolve nothing. Without this the pooled posterior advertises 1323 games of precision
        for a dial that has 792 of its own."""
        return np.array([block_het(self.blocks, k, self.iso_gap) * self.het_mult
                         for k in range(self.K)])

    def _segment(self, i):
        """The point fit's secant ACROSS THE GAP between block i and block i+1, as
        (slope, width, midpoint), or None where no slope is identified there.

        The width and the midpoint are carried because _accel() divides two of these and a ratio
        of secants over windows of different widths is not a growth rate. Same identification rule
        local_slope() uses: below MIN_SEP of separation the two blocks carry no slope information
        at all (that is the structural anti-slope guard, and it is what stops three dials 0.01
        apart reading a 5400 ELO/unit response out of binomial noise), so None rather than a
        number."""
        if i < 0 or i + 1 >= self.K:
            return None
        xa, xb = float(self.hi[i]), float(self.lo[i + 1])
        if xb - xa < MIN_SEP - 1e-12:
            return None
        return (max((self.iso_gap[i + 1] - self.iso_gap[i]) / (xb - xa), 0.0),
                xb - xa, 0.5 * (xa + xb))

    def _accel(self, prev, last):
        """GEOMETRIC SLOPE CONTINUATION: the factor the last measured secant is multiplied by to
        extrapolate past the data. 1.0 -- exactly, identically -- unless the last two segments
        ACCELERATE, so the shallow regime is untouched.

        WHY A FACTOR AND NOT A CURVATURE MODEL. Past the end of the data monotonicity identifies
        only a half-line; a second derivative there is a prior like any other, and the cheapest
        honest one is "the next segment does to this one what this one did to the last". Where
        the response really compounds that is the right shape, and where it does not the test
        below never fires.

        WIDTH NORMALISATION, AND WHY IT IS ONE-SIDED. s_last/s_prev is a growth PER SEGMENT, and
        the two segments need not be the same width. Under an exponential response the growth per
        unit x is ratio ** (1 / (m_last - m_prev)) with m the window midpoints, so continuing one
        more segment of the last segment's own width is ratio ** (w_last / (m_last - m_prev)).
        That exponent is 1 exactly when the two widths are equal -- which is the campaign (0.60,
        0.60) and both live extrapolations (0.15, 0.15) -- is BELOW 1 when the last segment is the
        narrower, and is ABOVE 1 when the previous segment is. The exponent is capped at 1: a
        narrow, noisy PREVIOUS segment is the one case where the ratio is least trustworthy, and
        amplifying it there is the failure mode the clamp exists to prevent. So the normalisation
        only ever DAMPS.

        THE DENOMINATOR IS FLOORED, NEVER BARE. s_prev is floored at S_REF_FLOOR, so a flat
        stretch followed by a take-off asks for the clamp rather than for infinity.

        MEASURED, BOTH WAYS. The clamp is calibrated on placement error over a family of
        compounding truths and the cost is measured in games at the 48-seed --bench default
        (never fewer -- a 12-seed run of this bench once manufactured a phantom defect that cost
        a whole improvement cycle). Both tables, with intervals, are beside ACC_K; selftest [13]
        pins the behaviour, including the rung-9 fixture that is the reason this exists."""
        if prev is None or last is None or self.acc_k <= 1.0:
            return 1.0
        s0, w0, m0 = prev
        s1, w1, m1 = last
        dm = abs(m1 - m0)
        if not (s1 > 0.0) or dm < 1e-9:
            return 1.0
        ratio = s1 / max(s0, S_REF_FLOOR)
        if ratio <= 1.0:
            return 1.0                    # not accelerating -> identity, and nothing below runs
        return float(min(ratio ** min(1.0, w1 / dm), self.acc_k))

    def _edge_slopes(self):
        """Reference slopes AND acceleration factors for EXTRAPOLATION only, from the point
        isotonic fit. A flat end block falls back to the global secant, and everything is floored
        at S_REF_FLOOR so that a step proposal is always a finite length. Never used as a divisor
        without that floor.

        -> (s_hi, s_lo, a_hi, a_lo). The extrapolant beyond either end is s * a, drawn around that
        median with the lognormal spread SIG_SLOPE (a == 1) or SIG_SLOPE_ACC (a > 1). WAS
        _slope_refs(), which returned the two slopes alone and could not see curvature: `s_hi` is
        a max() of three terms, i.e. a FLOOR, and a floor is not a second derivative."""
        g, xcl, xch = self.iso_gap, self.lo, self.hi
        glob = 0.0
        if self.K >= 2 and xch[-1] > xcl[0]:
            glob = max((g[-1] - g[0]) / (xch[-1] - xcl[0]), 0.0)
        def local(i, j, xa, xb):
            if self.K < 2 or xb <= xa:
                return 0.0
            return max((g[j] - g[i]) / (xb - xa), 0.0)
        s_hi = local(self.K - 2, self.K - 1, self.hi[-2], self.lo[-1]) if self.K >= 2 else 0.0
        s_lo = local(0, 1, self.hi[0], self.lo[1]) if self.K >= 2 else 0.0
        # The HIGH end continues rightward off the last segment, with the one before it as the
        # comparison; the LOW end continues leftward off the FIRST segment, with the one after it
        # as the comparison. Accelerating to the left means the response steepens as x falls.
        self.seg_hi = (self._segment(self.K - 3), self._segment(self.K - 2))
        self.seg_lo = (self._segment(1), self._segment(0))
        a_hi = self._accel(*self.seg_hi)
        a_lo = self._accel(*self.seg_lo)
        s_hi = max(s_hi, 0.5 * glob, S_REF_FLOOR)
        s_lo = max(s_lo, 0.5 * glob, S_REF_FLOOR)
        return min(s_hi, S_MAX), min(s_lo, S_MAX), a_hi, a_lo

    def local_slope(self, x):
        """Point-estimate slope of the fit at x, or None where none is identified (inside a block,
        or outside the data). Returned as None, never as a number divided by an epsilon."""
        if self.K < 2:
            return None
        if x < self.lo[0] or x > self.hi[-1]:
            return None
        for k in range(self.K - 1):
            if self.hi[k] <= x <= self.lo[k + 1]:
                dx = self.lo[k + 1] - self.hi[k]
                if dx < MIN_SEP - 1e-12:
                    return None
                return (self.iso_gap[k + 1] - self.iso_gap[k]) / dx
        return None

    def where(self, x):
        """('block', k) | ('seg', k) | ('left', None) | ('right', None)."""
        x = float(x)
        if x < self.lo[0]:
            return "left", None
        if x > self.hi[-1]:
            return "right", None
        for k in range(self.K):
            if self.lo[k] - 1e-12 <= x <= self.hi[k] + 1e-12:
                return "block", k
        for k in range(self.K - 1):
            if self.hi[k] < x < self.lo[k + 1]:
                return "seg", k
        return "block", self.K - 1

    # -- the posterior ------------------------------------------------------
    def _block_gap(self, x, k):
        """Posterior draws of the gap AT ONE DIAL inside block k.

        A merged block asserts one level for several dials. That assertion buys precision -- 1323
        games behind a dial that has 792 of its own -- and the price of it is `het`, the response
        the merge assumed away. Once `het` is on the table the right object is the obvious
        hierarchical one: the block level is a PRIOR for the dial, with between-dial spread
        tau = het/sqrt(12), and the dial's OWN games are the likelihood. Precision-weighted,

            mean = G_k + lambda * (own_gap - G_k),   lambda = tau^2 / (tau^2 + var_own)

        so a dial with few games of its own is told what the block believes, and a dial with many
        is allowed to disagree with it by as much as the merge could be hiding. With het = 0 (a
        single-dial block, or a flat neighbourhood) lambda = 0 and this is exactly the block level,
        which is what it was before. This is the line that stopped the tool certifying at a dial
        whose 2160 own games said +88 while the block it was pooled into said +100: on a 1200
        ELO/unit response a 0.05 merge window spans 60 ELO, and no amount of target-miss penalty
        can fix a belief that is wrong by half the band."""
        h = float(self.het[k])
        if h <= 0.0:
            return self.G[:, k]
        o = self.own.get(round(float(x), 6))
        if o is None or o[0] != k:
            return self.G[:, k] + self.HET[:, k] * h      # unplayed dial: the whole window is open
        _k, g_own, v_own = o
        tau2 = h * h / 12.0
        lam = tau2 / (tau2 + max(v_own, 1e-9))
        sd = math.sqrt(tau2 * max(v_own, 1e-9) / (tau2 + max(v_own, 1e-9)))
        return self.G[:, k] + lam * (g_own - self.G[:, k]) + self.NRM[:, k] * sd

    def gap_draws(self, xs):
        """(B, len(xs)) posterior draws of the delivered gap."""
        xs = np.atleast_1d(np.asarray(xs, float))
        out = np.empty((self.B, len(xs)))
        for i, x in enumerate(xs):
            kind, k = self.where(x)
            if kind == "block":
                out[:, i] = self._block_gap(x, k)
            elif kind == "seg":
                t = (x - self.hi[k]) / (self.lo[k + 1] - self.hi[k])
                out[:, i] = self.G[:, k] + (self.G[:, k + 1] - self.G[:, k]) * t ** self.GAM[:, k]
            elif kind == "right":
                out[:, i] = self.G[:, -1] + self.S_hi * (x - self.hi[-1])
            else:
                out[:, i] = self.G[:, 0] - self.S_lo * (self.lo[0] - x)
        return out

    def identified_range(self, x):
        """(B,2) per-draw [lo, hi] gap range that MONOTONICITY ALONE allows at x, given the block
        levels. No interpolation prior enters. Outside the data one side is +-inf."""
        kind, k = self.where(x)
        if kind == "block":
            o = self.own.get(round(float(x), 6))
            if o is not None and self.het[k] > 0:
                g = self._block_gap(x, k)      # its own games identify it; no window is left over
                return g, g
            h = 0.5 * self.het[k]
            return self.G[:, k] - h, self.G[:, k] + h
        if kind == "seg":
            return self.G[:, k], self.G[:, k + 1]
        if kind == "right":
            return self.G[:, -1], np.full(self.B, np.inf)
        return np.full(self.B, -np.inf), self.G[:, 0]

    def p_safe(self, x):
        """P(the WHOLE monotone-identified gap range at x lies inside the FEASIBLE SET). Prior-
        free: if this is high, the dial ships no matter where inside the bracket the crossing
        really is.

        THE TARGET SET IS NO LONGER THE BAND. Under the two-sided rule a certificate must
        contain 100 as well as fit [70,130], so the PUBLISHED POINT ESTIMATE of any certificate
        lies in 100 +- MAX_MISS = [88.7, 111.3]. That is a bound on the ESTIMATE, never on the
        TRUE gap: the coverage gate selects on the estimate, so a true gap of 85 still certifies
        about half the time and one of 80 about a quarter, reading near +95 when it does.
        Testing against [70,130] here called a dial delivering +79 `safe to ship`, which is
        wrong for the purpose: such a dial certifies rarely and off centre when it does."""
        a, b = self.identified_range(x)
        return float(np.mean((a >= BAND_MID - MAX_MISS) & (b <= BAND_MID + MAX_MISS)))

    def prior_free(self, x):
        return self.where(x)[0] in ("block", "seg")

    # -- the crossing -------------------------------------------------------
    def bracket(self, T):
        """The identified bracket for gap(x) = T from the point isotonic fit.
        Returns (lo, hi, kind) with kind in 'interior' / 'right-open' / 'left-open'.
        lo/hi may be None on the open side. NO point estimate is returned: monotonicity does not
        identify one, and the whole failure mode being fixed here is printing one anyway."""
        g = self.iso_gap
        if T > g[-1]:
            return self.hi[-1], None, "right-open"
        if T < g[0]:
            return None, self.lo[0], "left-open"
        ia = int(np.max(np.flatnonzero(g <= T)))
        ib = int(np.min(np.flatnonzero(g >= T)))
        if ia >= ib:                                   # T sits exactly on a block level
            return float(self.lo[ib]), float(self.hi[ia]), "interior"
        return float(self.hi[ia]), float(self.lo[ib]), "interior"


# ------------------------------------------------------------------ 4b. dispersion, MEASURED
# W2. Every interval in this file assumes the games at one dial are independent Bernoulli trials.
# That assumption is worth exactly one number -- the dispersion phi -- and it is measured here
# rather than asserted, because if phi > 1 the certificates are earned on intervals that are too
# narrow, and if phi < 1 the budget is conservative and the operator should know by how much.
#
# THE UNIT MATTERS MORE THAN THE ESTIMATOR. Games in this campaign are written one SGF file per
# game THREAD per `katago match` PROCESS, and a process is the only thing a set of games shares:
# one nnRandSeed, one NN cache (nnRandomize = false), one shuffled pairing round that carries BOTH
# colour orders. So the Pearson dispersion has to be computed over PROCESSES -- called waves here.
# Per FILE it is vacuous (one game per file makes X^2 = K identically, zero power); per BOT GRAPH
# it is a Bradley-Terry goodness-of-fit statistic on a near-saturated graph, which is what the
# phi_hat = 0.43 that prompted this actually was: 7 df for 55 fitted ratings, 95% CI [0.19, 1.78],
# a reading that never excluded 1 and that falls as parameters are added.
#
# MEASURED (see --dispersion, which recomputes all of it):
#   ladder SGFs   phi = 1.00, 95% [0.85, 1.18], N ~ 4000 decided games, df ~ 290
#   every dir     phi = 0.98, 95% [0.85, 1.16], N ~ 5000 decided games, df ~ 313
#   draws 0 and no-results 0 in 7840 games (komi 6.5, maxMovesPerGame 1200): the two mechanisms
#     that could push phi the other way do not occur in this protocol at all;
#   colour balance exact to within 0.5% of games, variance saving capped at 0.5-0.8% (phi 0.995);
#   intra-wave correlation rho = -0.002, 95% [-0.015, +0.014].
# phi = 1 therefore stands. The ~2% of conservatism is inside its own interval and is NOT banked.
WAVE_GAP_S = 240.0    # seconds of quiet between two SGF writes that separate two match processes.
                      # A 12-thread / 12-game wave writes its files within seconds of each other
                      # and the next wave starts ~700 s later (median wave 719 s, p90 1184 s), so
                      # the clustering is not delicate: at 240 s it recovers waves of median size
                      # exactly 12 = cfg/ladder.cfg numGamesTotal, and --dispersion prints that
                      # size distribution so a protocol change shows up instead of being absorbed.
DISP_MIN_N = 40       # decided games a matchup needs before it may contribute to the pooled phi
DISP_MIN_DF = 200     # pooled degrees of freedom before the PLAN is allowed to react at all: the
                      # per-dial phi has 13-66 waves and no power (one live dial reads 0.74 and
                      # another 1.13 on the same lever), the pooled one has ~300 df
PHI_PLAN_CAP = 1.30   # and the most dispersion the plan will ever price, so a mis-measured phi
                      # cannot make the tool demand an unbounded budget
PHI_PLAN = 1.0        # what the cost model uses unless the caller measures otherwise. Stated,
                      # not silent: clamp(0.98, 1, 1.3) = 1.0 exactly, so today this is inert.


def chi2_ppf(q, df):
    """Chi-square quantile by bisection on chi2_sf, so the dispersion CI needs no scipy either.
    Round-tripped against the published critical values in selftest [8]."""
    df = max(int(df), 1)
    lo, hi = 0.0, max(10.0, 4.0 * df + 40.0)
    for _ in range(60):
        if chi2_sf(hi, df) <= 1.0 - q:
            break
        hi *= 2.0
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if chi2_sf(mid, df) > 1.0 - q:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def plan_phi(phi_hat=None, df=0):
    """The dispersion the COST model plans with. NEVER below 1, never above PHI_PLAN_CAP, and
    never allowed to move at all on fewer than DISP_MIN_DF degrees of freedom.

    Asymmetric on purpose. Overdispersion is a RISK -- the certificate would be earned on an
    interval that is too narrow -- so it is priced as soon as it is credibly measured. Under-
    dispersion is only conservatism, and banking it would buy a 2% smaller budget out of a
    measurement whose own 95% interval is +/-15%: the published +100 rung (213/592) survives only
    to phi = 1.05 as it is, so there is nothing here to spend. On today's data phi_hat = 0.98 and
    this returns exactly 1.0, which makes every benchmark number in this file bit-identical."""
    if phi_hat is None or not math.isfinite(float(phi_hat)) or int(df) < DISP_MIN_DF:
        return 1.0
    return float(min(max(float(phi_hat), 1.0), PHI_PLAN_CAP))


def _eff(w, n, phi):
    """Quasi-binomial effective counts: phi real games are worth one independent game. The
    IDENTITY at phi == 1.0 -- the branch below is taken on every shipped run -- which is what
    makes the guard free. Same n/phi rule the merge already charges a heterogeneous block."""
    if phi == 1.0:
        return w, n
    return w / phi, n / phi


def _sgf_files(dirs):
    """Every SGF file under dirs, as (mtime, path), oldest first. The mtime is when the file's
    last game was written, which is what places it in a wave."""
    out = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for root, _dirs, files in os.walk(d):
            for fn in files:
                if fn.endswith(".sgf") or fn.endswith(".sgfs"):
                    p = os.path.join(root, fn)
                    try:
                        out.append((os.stat(p).st_mtime, p))
                    except OSError:
                        pass
    out.sort()
    return out


def waves_of(files, gap_s=WAVE_GAP_S):
    """Single-linkage clustering of SGF files into match PROCESSES by write time. -> [[path,...]]"""
    waves, cur, prev = [], [], None
    for mt, p in files:
        if prev is not None and mt - prev > gap_s:
            waves.append(cur)
            cur = []
        cur.append(p)
        prev = mt
    if cur:
        waves.append(cur)
    return waves


def measure_dispersion(dirs, gap_s=WAVE_GAP_S, min_n=DISP_MIN_N):
    """Pearson dispersion of the campaign's own games about each matchup's pooled winrate, with
    the games grouped by WAVE. Pooled over every matchup with at least min_n decided games and at
    least two waves, so the estimate has the df the per-dial ones do not.

    Returns a dict, or None when there is nothing to measure. Every quantity is a measurement of
    the data on disk: no model of the response, no dependence on the fit or on the target."""
    import deepkyu_tally as dt
    files = _sgf_files(dirs)
    if not files:
        return None
    waves = waves_of(files, gap_s)
    per, order = {}, {}
    tot = {"decided": 0.0, "games": 0.0, "draws": 0, "noresult": 0, "black": 0.0, "moves": 0}
    for i, wv in enumerate(waves):
        for p in wv:
            try:
                rec = dt.parse_file(p)
            except Exception:
                continue
            for (pb, pw), v in rec.items():
                if pb == pw:
                    continue
                key = tuple(sorted((pb, pw)))
                dec = v[0] + v[1] + v[2]
                if dec <= 0:
                    tot["noresult"] += v[3]
                    tot["games"] += v[3]
                    continue
                aw = (v[0] if pb == key[0] else v[1]) + 0.5 * v[2]
                r = per.setdefault(key, {}).setdefault(i, [0.0, 0.0])
                r[0] += aw
                r[1] += dec
                o = order.setdefault(key, [0.0, 0.0, 0.0, 0.0])
                o[0 if pb == key[0] else 1] += dec          # games in each colour order
                o[2 if pb == key[0] else 3] += aw           # and the same side's wins in each
                tot["decided"] += dec
                tot["games"] += dec + v[3]
                tot["draws"] += v[2]
                tot["noresult"] += v[3]
                tot["black"] += v[0] + 0.5 * v[2]
                tot["moves"] += v[4]
    rows, X, DF, N = [], 0.0, 0, 0.0
    for key, d in sorted(per.items()):
        n = sum(r[1] for r in d.values())
        w = sum(r[0] for r in d.values())
        ks = [k for k, r in d.items() if r[1] > 0]
        if n < min_n or len(ks) < 2 or w <= 0 or w >= n:
            continue
        p = w / n
        x = sum((d[k][0] - d[k][1] * p) ** 2 / (d[k][1] * p * (1.0 - p)) for k in ks)
        o = order[key]
        # WHAT THE COLOUR PAIRING IS WORTH. The design plays both orders in one shuffled round, so
        # it is paired, not iid -- and a paired design genuinely lowers the variance. By how much
        # is not a matter of opinion: if this side wins at p+delta as black and p-delta as white,
        # exact balancing removes delta^2 of the per-game variance, i.e. bounds phi below by
        # 1 - delta^2/(p(1-p)). delta is measured here, per matchup, from the games themselves.
        dlt = 0.0
        if o[0] > 0 and o[1] > 0:
            dlt = 0.5 * (o[2] / o[0] - o[3] / o[1])
        rows.append({"pair": key, "n": float(n), "w": float(w), "waves": len(ks), "X2": float(x),
                     "phi": float(x / (len(ks) - 1)), "black": o[0], "white": o[1],
                     "delta": float(dlt), "var": float(n * p * (1.0 - p)),
                     "cvar": float(n * dlt * dlt)})
        X += x
        DF += len(ks) - 1
        N += n
    out = {"nfiles": len(files), "nwaves": len(waves),
           "wave_sizes": sorted(len(w) for w in waves), "rows": rows,
           "N": float(N), "df": int(DF), "X2": float(X), "tot": tot, "gap_s": float(gap_s),
           "phi": float(X / DF) if DF > 0 else float("nan")}
    if DF > 0:
        out["ci"] = (X / chi2_ppf(0.975, DF), X / chi2_ppf(0.025, DF))
        out["lo95_1s"] = X / chi2_ppf(0.95, DF)      # one-sided: above 1 means REAL overdispersion
        out["hi95_1s"] = X / chi2_ppf(0.05, DF)
    else:
        out["ci"] = (float("nan"), float("nan"))
        out["lo95_1s"] = out["hi95_1s"] = float("nan")
    out["phi_plan"] = plan_phi(out["phi"], out["df"])
    return out


def cert_phi_headroom(w, n, z=Z_PUB, hi=2.0):
    """The largest dispersion at which the certificate (w, n) still fits the band once its games
    are discounted to n/phi. A certificate with no headroom is one a modest overdispersion would
    take away, which is the whole reason to keep measuring phi."""
    lo, cur = 1.0, 1.0
    a, b = lo, hi
    for _ in range(60):
        mid = 0.5 * (a + b)
        glo, ghi = gap_ci(w / mid, n / mid, z)
        if glo >= BAND_LO and ghi <= BAND_HI:
            cur = mid
            a = mid
        else:
            b = mid
    return cur


def dispersion_report(m, out=sys.stdout):
    """Print the measurement, and what it does and does not license."""
    P = lambda s="": print(s, file=out)
    if not m:
        P("no SGF files found: nothing to measure.")
        return 1
    sz = np.array(m["wave_sizes"], float)
    P("== dispersion of the campaign's own games (W2) ==")
    P("%d SGF files -> %d waves (a wave = one `katago match` process = one nnRandSeed, one NN"
      % (m["nfiles"], m["nwaves"]))
    P("cache, one shuffled pairing round with both colour orders), split at %.0f s of quiet."
      % m["gap_s"])
    P("wave size: median %.0f, 10-90%% %.0f-%.0f, max %.0f  -- compare cfg/ladder.cfg "
      "numGamesTotal;" % (np.median(sz), np.quantile(sz, 0.1), np.quantile(sz, 0.9), sz.max()))
    P("a median that is not the configured wave size means the clustering, not the dispersion,")
    P("is what this is measuring, and the number below must not be used.")
    # A SHORT WAVE IS A BIAS, NOT A VARIANCE. The wave is bounded by GAME COUNT (numGamesTotal),
    # so on a healthy campaign every wave is the same size and nothing is selected. But the run
    # scripts also carry a wall-clock backstop, and a wave cut by the clock keeps only the games
    # that had already FINISHED -- the short ones. Game length predicts the winner strongly on
    # this campaign: the weak side wins 47.3% of the shortest quintile and 30.7% of the longest
    # (+19 ELO against +142), and its wins are 17.5 +- 7.6 moves shorter than its losses. So
    # truncation biases a rung LOW, invisibly: dropping the longest 16% of the real games moves
    # the measured gap from +87.2 to +79.3, and the longest 30% takes it to +59.2. The wave-size
    # distribution is the only place that shows up, so it is checked here.
    mode = int(np.bincount(np.asarray(sz, int)).argmax())
    short = [x for x in sz if x < mode]
    lost = sum(mode - x for x in short)
    P("full waves are %d games (the modal size); %d wave%s came up short, %.0f games in total "
      "(%.1f%%)" % (mode, len(short), "" if len(short) == 1 else "s", lost,
                    100.0 * lost / max(sz.sum(), 1.0)))
    P("-- an UPPER bound: a wave the %.0f s clustering split in two also reads as two short ones."
      % m["gap_s"])
    if lost > 0.05 * sz.sum():
        P("!! MORE THAN 5%% OF THE GAMES ARE MISSING FROM CUT WAVES. A wave cut by a wall-clock")
        P("   backstop keeps only the games that had already finished, i.e. the SHORT ones, and")
        P("   short games are the weak bot's wins (+19 ELO in the shortest quintile of this")
        P("   campaign against +142 in the longest). That is a BIAS on the delivered gap, not a")
        P("   variance: check deepkyu_step.sh's CHUNK and the `timeout` around the match, and")
        P("   make the wave's stopping rule its GAME COUNT, never the clock.")
    P()
    if m["df"] <= 0:
        P("no matchup has %d decided games in at least two waves: nothing to pool." % DISP_MIN_N)
        return 1
    P("PEARSON DISPERSION about each matchup's own pooled winrate, games grouped by wave,")
    P("pooled over %d matchups with n >= %d:" % (len(m["rows"]), DISP_MIN_N))
    P("    phi = %.3f   95%% CI [%.3f, %.3f]   N = %.0f decided games, df = %d"
      % (m["phi"], m["ci"][0], m["ci"][1], m["N"], m["df"]))
    P("    one-sided 95%%: phi >= %.3f, phi <= %.3f" % (m["lo95_1s"], m["hi95_1s"]))
    P()
    P("%-58s %7s %6s %7s %7s" % ("matchup", "n", "waves", "phi", "as B/W"))
    for r in sorted(m["rows"], key=lambda r: -r["n"])[:12]:
        P("%-58s %7.0f %6d %7.3f %3.0f/%3.0f"
          % ((" vs ".join(r["pair"]))[:58], r["n"], r["waves"], r["phi"], r["black"], r["white"]))
    if len(m["rows"]) > 12:
        P("(%d further matchups pooled, not shown)" % (len(m["rows"]) - 12))
    P("a per-matchup phi has 2-70 waves and no power -- read the POOLED line, not this table.")
    P()
    t = m["tot"]
    imb = sum(abs(r["black"] - r["white"]) for r in m["rows"])
    d2 = (t["black"] / t["decided"] - 0.5) if t["decided"] else 0.0
    pq = 0.25 - d2 * d2
    P("the mechanisms that could make phi differ from 1, each measured:")
    P("  draws                 %6d of %.0f games  (0.5 of a win each in the tally)"
      % (t["draws"], t["games"]))
    P("  no-results            %6d of %.0f games  (excluded from the decided count, so a "
      "selection)" % (t["noresult"], t["games"]))
    cvar = sum(r["cvar"] for r in m["rows"])
    vvar = sum(r["var"] for r in m["rows"])
    bound = 1.0 - (cvar / vvar if vvar > 0 else 0.0)
    P("  colour balance        %6.0f games of imbalance over %d matchups (%.2f%% of games);"
      % (imb, len(m["rows"]), 100.0 * imb / max(m["N"], 1.0)))
    P("                        black wins %.1f%% overall. The design IS paired, and a paired"
      % (100.0 * t["black"] / max(t["decided"], 1.0)))
    P("                        design really does lower the variance -- but by the measured")
    P("                        colour effect only: EXACT balancing bounds phi below by %.4f,"
      % bound)
    P("                        i.e. saves %.2f%% of variance. It cannot explain a phi far from 1."
      % (100.0 * (1.0 - bound)))
    P("  shared seed / cache   intra-wave correlation rho = (phi-1)/(n_bar-1) = %+.4f at the"
      % ((m["phi"] - 1.0) / max(m["N"] / max(m["df"] + len(m["rows"]), 1) - 1.0, 1e-9)))
    P("                        mean wave size, with the CI above carried through.")
    P()
    P("WHAT THIS LICENSES:")
    P("  plan_phi = %.2f for the COST model (clamp(phi_hat, 1, %.2f), and only above %d df)."
      % (m["phi_plan"], PHI_PLAN_CAP, DISP_MIN_DF))
    if m["lo95_1s"] > 1.0:
        P("  !! the one-sided 95%% LOWER bound is %.3f > 1: this campaign is GENUINELY "
          "OVERDISPERSED." % m["lo95_1s"])
        P("     Every Wilson interval here is too narrow by ~sqrt(phi). Re-run the rung's")
        P("     certificate with n/phi, and check nnRandomize / the match protocol for the cause.")
    elif m["hi95_1s"] < 1.0:
        P("  the one-sided 95%% UPPER bound is %.3f < 1: the games are measurably UNDER-dispersed,"
          % m["hi95_1s"])
        P("  so the certificates are conservative. Not banked: see plan_phi()'s docstring.")
    else:
        P("  phi = 1 is inside the interval, so the binomial variance model stands. The tool is")
        P("  conservative by at most %.1f%% of variance, which is inside the measurement's own"
          % (100.0 * max(0.0, 1.0 - m["phi"])))
        P("  error (+/-%.0f%%), so it is reported and NOT banked."
          % (100.0 * 0.5 * (m["ci"][1] - m["ci"][0])))
    for label, w, n in (("+100 rung (213/592)", 213.0, 592.0),
                        ("+29 rung (242/528)", 242.0, 528.0)):
        glo, ghi = gap_ci(w, n, Z_PUB)
        if not (glo >= BAND_LO and ghi <= BAND_HI):
            P("  the published %-19s is a MEASURED gap [%+.1f,%+.1f], not a [%g,%g] "
              "certification:" % (label, glo, ghi, BAND_LO, BAND_HI))
            P("  %-21s there is no band headroom to lose, only the interval, which widens as"
              % "")
            P("  %-21s sqrt(phi)." % "")
            continue
        h = cert_phi_headroom(w, n)
        P("  headroom of the published %-19s certificate: it survives to phi = %.2f%s"
          % (label, h, "" if h < 1.999 else " (unbounded: its CI is well inside the band)"))
        P("  %-21s i.e. a dispersion of %.0f%% would take the published rung away, against a"
          % ("", 100.0 * (h - 1.0)))
        P("  %-21s measured one-sided 95%% upper bound of %.2f. That is the whole reason this"
          % ("", m["hi95_1s"]))
        P("  %-21s is measured every time rather than assumed once." % "")
    return 0


# ---------------------------------------------------------------------------- 5. cost, in games
# Cost is measured by simulating the rule that is actually in force -- the TWO-SIDED rule, looked
# at on the same schedule the driver looks at it -- forward from the dial's REALISED (w, n). FOUR
# exits now, and the fourth is the goal change (W2):
#   CERTIFY   the Z_STOP interval fits [70,130] AND the Z_COVER interval contains 100;
#   REFUTE    the Z_STOP interval lies entirely outside the band;
#   OVERSHOT  the sample has grown past what coverage can tolerate at this point estimate --
#             the dial is still nominally alive and the policy stops playing it anyway;
#   CAP       none of those happened within `cap` further games, and you re-place instead.
# Every expectation below is therefore a bounded quantity. This is the whole reason the cost is
# finite: deepkyu_tally.games_needed(gap) diverges at the band edge and a real part of the
# posterior sits outside the band, so E[games_needed] is infinite and must never be used.
#
# WHAT THE GOAL CHANGE DID TO THIS SIMULATION. games_needed(gap) is the ONE-SIDED quantity -- the
# n at which the CI fits the band -- and under the two-sided rule no such n exists for a gap of
# 90: the answer is a probability (0.77 at the live cadence), not a sample size, and the function
# is ill-posed rather than merely mis-calibrated. Nothing on the decision path calls it any more.
# What replaces it is this simulation run against the real rule, and the two facts it prices:
#   (a) P(certify) collapses off centre -- .985 at a true gap of 100, .943 at 95, .778 at 90,
#       .507 at 85, .253 at 80, .509 at 115 (20000 trials, 12-game looks, cap 12000) -- so the
#       games objective now contains the fidelity preference the old rule made it blind to;
#   (b) E[games | it certifies] is 1500-2100 at EVERY one of those gaps. An off-centre dial is
#       not slow. It is a lottery ticket that costs the same as a certificate.
GAP_GRID = np.concatenate([np.array([0.0, 20.0, 40.0, 52.0]),
                           np.arange(58.0, 142.1, 2.5),
                           np.array([150.0, 165.0, 185.0, 215.0, 260.0, 330.0, 450.0])])
CAP_GAMES = 12000     # games past which you would re-place rather than keep paying at one dial
MOVE_COST = 150.0     # games-equivalent price of leaving the current dial (cfg regen + restart)
CHUNK = 540           # deepkyu_step.sh chunk: the BUDGET a driver is handed at one dial
LOOK = 60             # ...which is NOT the interval between looks at the stop rule. deepkyu_auto.sh
                      # plays in completion WAVES of 12 games and re-runs this tool after every one
                      # ("a campaign whose chunk is a wave", its own docstring), so the rule is
                      # looked at every 12 games while the cost model priced it every 540. Under
                      # the one-sided rule that mismatch only made the model conservative. Under
                      # the two-sided rule the certification window is FINITE in n, so the number
                      # of looks inside it is the number of chances, and the mismatch is a first-
                      # order error. Measured P(certify) (8000 trials, Z_KILL on):
                      #   true gap    look 540   look 60   look 12
                      #      100        .991      .988      .980
                      #       95        .932      .945      .939
                      #       90        .709      .765      .769
                      #       85        .405      .489      .505
                      #       80        .171      .233      .249
                      # i.e. finer looks are a Pareto gain OFF CENTRE (+8 points of P at 85) and
                      # cost ~1 point at the centre. 60 rather than 12 is a RUNTIME choice, and it
                      # is conservative in the right direction: it under-states P by <= 0.02
                      # against the cadence the driver actually runs. --look exposes it.
LOOK_DENSE = 5000     # games at a dial for which the fine look interval is simulated; past it the
                      # schedule coarsens to LOOK_COARSE. The window is widest at n = 2372 and
                      # 99% of a dial's certification probability has arrived by n ~ 5000, so the
                      # tail is worth <= 0.003 of P (measured) and costs 4x the simulation time.
LOOK_COARSE = 540


def look_steps(look=LOOK, cap=CAP_GAMES, dense=LOOK_DENSE, coarse=LOOK_COARSE):
    """The look schedule at one dial, as a list of game increments. Deterministic, so
    Cost.max_spend is exact rather than a ceiling."""
    look = max(int(look), 1)
    steps, spent = [], 0
    while spent < cap:
        step = look if spent < dense else max(look, int(coarse))
        steps.append(step)
        spent += step
    return steps


P_EXPLORE = 3200.0    # games per ELO, and NOT a fidelity price -- see the p_fid note in decide().
                      # It is the EXPLORATION gradient on a lever where nothing can certify: the
                      # only term that walks a stuck rung toward the target. Selftest [11e] pins
                      # that it must be non-zero or the lever never moves. The value is the one
                      # the old --calibrate sweep set for P_FID and it is unchanged; what changed
                      # is that it is no longer charged when a dial CAN certify.
P_FID = P_EXPLORE     # kept as a name only, for --calibrate's sweep and the old bench rows.
TOL_T = 0.0           # ELO free either side of the target before the exploration charge bites.
V_CAP_MULT = 5.0      # ceiling on the continuation value, so a hopeless lever is reported, not NaN
TIE_FLOOR = 60.0      # games: below this, two dials are the same dial whatever the arithmetic says
TIE_PCEN = 0.02       # P(centre): the resolution of the first tie-break key. p_centre is a mean
                      # over `draws` posterior draws, so at the default 8000 its own Monte-Carlo
                      # sd is about 0.006; 0.02 is ~3.5 of those, i.e. the smallest difference
                      # that is a difference. Bucketed by FLOOR, never by round(), because
                      # Python rounds half to even and that put two dials 0.03 apart in the same
                      # bucket on the live rung-4 rows.
TIE_PCEN_HOLD = 0.05  # ...and the WIDER band that decides whether to LEAVE the dial already set.
                      # Deliberately asymmetric: ranking two dials is free, but abandoning a
                      # bucket strands its games, and that harm is not in the cost model. A move
                      # off the current dial on fidelity grounds needs a clearer edge than a
                      # choice between two fresh dials does.
TIE_ELO = 2.0         # ELO: the indifference band inside a games tie. Was tie_tol/p_fid, which at
                      # the new p_fid = 0 is 6e10 -- i.e. "stand still" would win every tie, and
                      # standing still now burns the certification window. Fixed, and small
                      # against the +-11.25 ELO the rule itself allows.


# ---------------------------------------------------------------------------- 5b. G1: the two
# ways of preferring a NEAR-100 certificate, both OFF by default, both measurable.
#
# THE FACT THEY BOTH ANSWER. The rule certifies on the PUBLISHED POINT ESTIMATE, so a rung whose
# TRUE gap is 85 certifies about half the time and one at 80 a quarter of the time, and each
# publishes an estimate inside [88.7, 111.3] because that is the only place an estimate can be
# when it certifies. Those certificates satisfy the goal as written. The question G1 asks is
# whether the tool should decline to CHASE them.
#
# (a) THE COMMIT GATE, a filter: never stand on a dial whose own posterior says
#     P(|true gap - 100| <= GATE_K) < GATE_P. gate_p = 0 is off. A gated dial is priced exactly
#     as a dead one -- W = 0, S = the ceiling -- so the machinery that already exists for "this
#     dial cannot deliver" carries it, and no new branch enters the value iteration.
# (b) THE FIDELITY-WEIGHTED OBJECTIVE: minimise expected games to a certificate that is ALSO
#     near 100, i.e. run the same fixed point on W_k(x) = P(certify AND |true gap-100| <= k)
#     (Cost.w_good) instead of W(x) = P(certify). obj_k = None is off.
#
# WHAT NEITHER OF THEM CAN DO, and it is the first thing to say about both: the DONE branch is
# the RULE, and a certificate that has landed in a bucket is a certificate. Both designs act on
# PLACEMENT only -- where the next games go -- so neither improves the certificate the tool is
# standing on, and neither can decline one that arrives. Their whole effect is to move games off
# dials whose certification probability is bought off centre, and the price is that those games
# buy nothing at all on a lever where no dial is near 100.
#
# BOTH ARE ROUND-0 SAFE BY CONSTRUCTION. At round 0 every posterior is wide, so no dial passes
# the gate and W_k is tiny everywhere: the lever reads `hopeless`, which is the EXPLORATION
# branch (P_EXPLORE walks the lever toward the target), NOT the STOP branch -- STOP additionally
# requires lever_room() to report no legal dial left, and neither of these touches lever_room.
# Selftest [12] pins that: 0 round-0 STOPs under either design.
#
# WHAT THE TRADE IS, MEASURED -- AND WHY NEITHER IS SHIPPED (G1, 2026-09-13).
#
# An INDEPENDENT harness: its own judge (agrees with rule_state, indep_certified and
# deepkyu_tally on 35,186 (w,n) states), its own tables, its own truths. 19 truths x 48 seeds =
# 912 runs per design, 5,472 runs, 0 action-contract violations. The truths are 8 levers whose
# bracket is a WIDE PLATEAU at a true gap of 80, 85, ... 115 with a near-100 dial elsewhere on
# the lever (family A, deliberately hostile), the 9 shipped --bench shapes (B, the closest thing
# to the live lever), and 2 levers with no dial near 100 at all (C).
#
#   design                        mean|true gap-100|  >10 ELO  >15   pub hw  P(cert)   games
#   base (shipped)                        8.2          .35     .11    20.5    .998     3492
#   gate K=15 p>=.25 (the proposal)       8.3          .35     .11    20.5    .996     3611
#   gate K=15 p>=.50                      8.2          .36     .10    20.4    .993     3747
#   gate K=10 p>=.50                      7.9          .34     .09    20.5    .996     4366
#   objective W_k, k=15                   8.0          .33     .10    20.5    .998     3558
#   objective W_k, k=10                   8.0          .34     .10    20.5    .998     3584
#
#   paired against base over the same Bernoulli streams, 95% cluster bootstrap:
#     gate K=15 p>=.25   +120 games [ +46, +202]   d mean|err| +0.06 [-0.04,+0.17]   2/912 lost
#     gate K=15 p>=.50   +255 games [+123, +401]               +0.05 [-0.18,+0.27]   4/912 lost
#     gate K=10 p>=.50   +875 games [+704,+1048]               -0.35 [-0.63,-0.05]   3/912 lost
#     objective k=15      +67 games [ +13, +118]               -0.17 [-0.32,-0.03]   0/912 lost
#     objective k=10      +93 games [ +24, +160]               -0.21 [-0.38,-0.03]   0/912 lost
#
# AND WHERE THE ONE REAL GAIN LIVES. Split by family, the objective's whole effect is family A,
# the one built to make it work; on the shipped shapes -- the closest thing here to the live
# temperature lever -- its cost interval excludes zero and its benefit interval does not:
#     family A (384): d mean|err| -0.28 [-0.56,-0.02]   d>10 -0.034 [-0.055,-0.013]  +39 games [-44,+128]
#     family B (432):            -0.11 [-0.30,+0.05]         -0.002 [-0.019,+0.014]  +56 games [ +4,+110]
#   (the objective arms were re-measured after the `hopeless` fix below; the gate arms cannot
#    move under it, since a gated dial has W_cert = 0 as well as W = 0)
#     family C  (96): every certificate is >10 ELO out under every design; nothing to win
# Failures to certify are the same story: they all sit on `step28`, the lever where one lattice
# step spans 86 -> 114, where the gate raises them from 2/48 to 4-5/48.
#
# THE PROPOSAL AS WRITTEN IS A NO-OP WITH A BILL. Its quality interval covers zero and its point
# estimate has the wrong sign. That is not bad luck, it is arithmetic: p_gate at K = 15 for a
# posterior centred at mu is Phi((115-mu)/sd) - Phi((85-mu)/sd), which at mu = 85 rises to 0.5
# and never leaves the interval [0.38, 0.50] at any n (0.38 at n = 200, 0.496 at n = 1,000,
# 0.500 thereafter): the interval [85,115] is split exactly in half by its own centre. A gate at
# p >= 0.25 can therefore NEVER refuse a dial whose own games say +85 -- the exact case the
# complaint is about -- and at mu = 80 it first fires at n = 2,390 games AT THAT DIAL, while the
# median certificate at a true gap of 80 arrives at n = 1,440. It is late by construction.
#
# AND THE DEEPER REASON, WHICH IS WHY THE STRONGER GATES BUY SO LITTLE. Certification is a
# SELECTION ON THE POINT ESTIMATE: to certify at all, a dial's observed gap must be inside
# [88.7, 111.3]. The dial's posterior sits on that same estimate. So at the moment a dial
# certifies its posterior says "near 100" whatever the truth is. Measured on 254 certificates
# the shipped tool actually produced over 16 truths -- p_gate AT THE DIAL THAT CERTIFIED, and
# the share each gate would have refused there:
#     K=15  min 0.44  1st pct 0.60  median 0.84
#     K=10  min 0.14  1st pct 0.28  median 0.65
#     refused by K=15 p>=0.25 (THE PROPOSAL):    0 of 254   -- and 0 of the 96 that are
#                                                              actually more than 10 ELO off
#     refused by K=15 p>=0.50:                   1 of 254   (1 of those 96)
#     refused by K=10 p>=0.50 (the strongest):  12 of 254   (8 of those 96)
# That last 4.7% is the entire quality the strongest gate buys, at +875 games a rung. The
# proposal cannot touch a single one of these certificates. Selftest [12] pins the measurement.
#
# THEY ARE NOT INERT -- THEY ARE AIMED AT THE WRONG THING. Over the 383 states the shipped tool
# actually visits on 8 truths, the gate changes the MOVE in 6.0% (K=15 p>=.25), 14.1% (K=15
# p>=.50) and 29.8% (K=10 p>=.50) of them, and the objective in 4.4% (k=15) and 11.5% (k=10).
# They act on 4-30% of the decisions and move almost none of the certificates, because which of
# several similar dials the tool stands on is not what sets the certificate's quality: the rule's
# own selection at n ~ 1,500 is.
#
# NEITHER DESIGN TOUCHES WHAT THE CERTIFICATE SAYS. The published half-width is 20.5 ELO in
# every row above, to three figures. Both act on PLACEMENT only; the DONE branch is the rule.
#
# THE QUALITY AXIS IS REACHABLE, BUT AT THE ACCEPTANCE, NOT THE OPTIMAND. Same placement, same
# tool, and the only change is that the driver declines to publish a certificate taken before
# n = 3,000 (measured on the same 912 clusters, and NOT shipped here):
#     mean |true gap-100|  8.2 -> 6.9      d -1.21 [-1.47, -0.95]
#     >10 ELO             .35 -> .26       d -0.081 [-0.101, -0.062]
#     >15 ELO             .11 -> .05       d -0.057 [-0.074, -0.041]
#     published half-width 20.5 -> 12.9 ELO;  P(certify) .998 -> .980 (16/912 rungs lost)
#     cost                 +3,161 games a rung [+2,927, +3,418]
# i.e. the best placement design buys 0.35 ELO and cannot buy more at any price, while the
# acceptance floor buys 1.21 ELO and the interval width with it, at a comparable exchange rate
# (~2,400 games per ELO) but a far higher ceiling. That is a change to the campaign's stopping
# discipline, it invalidates nothing already published but would not have accepted the four live
# certificates (n = 1,296..2,099), and it is recorded here only so that "the quality axis cannot
# be moved" is not believed. It is the operator's decision, not this file's.
GATE_K = 15.0         # ELO. The half-width of "near enough to 100 to be worth grinding". 15 is
                      # the number both designs in the previous round proposed, and it is wider
                      # than MAX_MISS = 11.25 on purpose: 11.25 is a statement about ESTIMATES.
GATE_P = 0.0          # OFF. The previous round's proposal was 0.25.
OBJ_K = None          # OFF. The previous round's implicit K is the same 15 ELO.


def sim_dial(gaps, w0, n0, chunk=LOOK, cap=CAP_GAMES, trials=300, seed=0, phi=PHI_PLAN,
             z_kill=Z_KILL, cover=True):
    """Per true gap: P(certify), E[additional games spent before stopping]. Both bounded by cap.

    `chunk` is the LOOK INTERVAL, not the driver's budget: it is how often the stop rule is
    evaluated, which under the two-sided rule is a first-order input (see LOOK). All trials at a
    dial advance in lockstep from the same n0, so the schedule may coarsen with n at no cost to
    correctness -- look_steps() is that schedule.

    phi is the PLANNING dispersion (W2, plan_phi): the rule is looked at with n/phi effective
    games while the spend counts real ones, so an overdispersed rung is BUDGETED more games
    instead of certifying on an interval it has not earned. phi = 1.0 -- what the measurement
    supports, and what every benchmark in this file runs at -- takes the identity branch of
    _eff(), so this argument changes nothing until someone measures a phi above 1."""
    gaps = np.asarray(gaps, float)
    p = p_of_gap(gaps)
    G = len(gaps)
    rng = np.random.default_rng(seed)
    w = np.full(G * trials, float(w0))
    n = np.full(G * trials, float(n0))
    pp = np.repeat(p, trials)
    spent = np.zeros(G * trials)
    state = np.zeros(G * trials, np.int8)          # 0 running, 1 certified, 2 stopped
    if n0 > 0:
        c, r = rule_state(*_eff(w, n, phi), z_kill=z_kill, cover=cover)
        state[c] = 1
        state[r & ~c] = 2
    act = np.flatnonzero(state == 0)
    for step in look_steps(chunk, cap):
        if not act.size:
            break
        w[act] += rng.binomial(int(step), pp[act])
        n[act] += step
        spent[act] += step
        c, r = rule_state(*_eff(w[act], n[act], phi), z_kill=z_kill, cover=cover)
        state[act[c]] = 1
        state[act[r & ~c]] = 2
        run = state[act] == 0
        state[act[run & (spent[act] >= cap)]] = 2
        act = act[state[act] == 0]
    state = state.reshape(G, trials)
    spent = spent.reshape(G, trials)
    return (state == 1).mean(axis=1), spent.mean(axis=1), spent.std(axis=1)


class Cost:
    """sim_dial over the gap grid, memoised on the realised bank."""

    def __init__(self, chunk=LOOK, cap=CAP_GAMES, trials=300, seed=20260910, phi=PHI_PLAN,
                 z_kill=Z_KILL, cover=True):
        self.chunk, self.cap, self.trials, self.seed = chunk, cap, trials, seed
        self.phi = float(phi)          # planning dispersion (W2); 1.0 on today's measurement
        self.z_kill, self.cover = float(z_kill), bool(cover)
        self._c = {}
        self.max_spend = float(sum(look_steps(chunk, cap)))

    def curves(self, w0, n0):
        key = (round(float(w0), 1), round(float(n0), 1))
        if key not in self._c:
            h = (abs(hash(key)) % 100000)
            self._c[key] = sim_dial(GAP_GRID, key[0], key[1], self.chunk, self.cap,
                                    self.trials, self.seed + h, self.phi,
                                    z_kill=self.z_kill, cover=self.cover)
        return self._c[key]

    def state(self, w, n):
        """(certified, dead) under the rule THIS cost model is pricing, so an ablated bench row
        and its own cost simulation can never disagree about what a dial is worth."""
        return rule_state(w, n, z_kill=self.z_kill, cover=self.cover)

    def miss(self, gap_draws, w0, n0, T, tol):
        """E[ max(0, |gap - T| - tol) | THIS DIAL CERTIFIES ]. ONE BRANCH, NOT A PRICE.

        The ladder is only moved by a gap that gets a certificate, so the loss is weighted by
        P(certify | gap) and normalised by P(certify): what comes back is the miss the ladder
        suffers IN THE WORLD WHERE THIS DIAL IS THE ONE THAT CERTIFIES. That is a conditional
        quantity and it must never be charged on its own -- conditioning on a 2%-probability
        event makes it small precisely because the event is rare (if a dial 39 ELO below target
        ever certifies, the gap was in band all along). The other branch -- the miss made by the
        dial we certify at after abandoning this one -- is supplied by joint_value_iterate(),
        which combines the two into M(x) = W*miss(x) + (1-W)*M*. Falls back to the unconditional
        expectation when the dial cannot certify at all, where the conditional one is 0/0."""
        pw, _es, _sd = self.curves(w0, n0)
        g = np.asarray(gap_draws, float)
        pc = np.interp(g, GAP_GRID, pw)
        loss = np.maximum(0.0, np.abs(g - T) - tol)
        den = float(np.mean(pc))
        if den < 1e-6:
            return float(np.mean(loss))
        return float(np.mean(pc * loss) / den)

    @staticmethod
    def miss_uncond(gap_draws, T, tol):
        """E[ max(0, |gap - T| - tol) ], UNCONDITIONAL: how far from the target this dial is
        believed to land, whether or not it could ever certify. It is not a ladder cost -- a gap
        that never gets a certificate delivers nothing -- and it is never used as one while any
        candidate can certify. It is what is left when NONE can: there the one-epoch model is
        exhausted (every dial costs the ceiling and M(x) collapses to M* at all of them), the
        next games are exploration, and the only thing that still varies is where the target is
        believed to be. See decide()."""
        g = np.asarray(gap_draws, float)
        return float(np.mean(np.maximum(0.0, np.abs(g - T) - tol)))

    def w_good(self, gap_draws, w0, n0, k):
        """P(CERTIFY AND |true gap - 100| <= k) at this dial -- the FIDELITY-WEIGHTED OBJECTIVE
        (G1b), the same preference the commit gate expresses as a filter, written into the
        optimand instead:

            W_k(x) = E_g[ P(certify | x, g) * 1{|g - 100| <= k} ]

        It is W(x) times lottery_share(x, k), so it is not a new simulation -- it is the SAME
        forward simulation with the indicator moved inside the posterior expectation. Used only
        when decide(obj_k=...) is set; at obj_k = None the objective is P(certify), which is what
        the goal as written asks for and what ships.

        WHAT IT DOES AND DOES NOT DO. It changes WHERE the tool stands, never WHAT IT ACCEPTS: a
        certificate that lands at a dial is still a certificate (the DONE branch is the rule, and
        the rule is not this tool's to change). So it cannot make a landed certificate better --
        it can only stop the tool from standing where the certificates would be bought off
        centre."""
        pw, _es, _sd = self.curves(w0, n0)
        g = np.asarray(gap_draws, float)
        pc = np.interp(g, GAP_GRID, pw)
        return float(np.mean(pc * (np.abs(g - BAND_MID) <= float(k))))

    def lottery_share(self, gap_draws, w0, n0, k=None):
        """THE SHARE OF THIS DIAL'S CERTIFICATION PROBABILITY THAT COMES FROM WORLDS WHERE THE
        DIAL IS ACTUALLY RIGHT:

            E_g[ P(certify | g) * 1{|g - 100| <= MAX_MISS} ] / E_g[ P(certify | g) ]

        The two-sided rule lets a dial that is KNOWN to be wrong buy a certificate with a lucky
        sample -- a true gap of 85 certifies 0.49 of the time and a true gap of 80 still 0.25 --
        and that certificate is then not merely off target, it is WRONG, because the coverage
        gate is itself a selection on the point estimate. No pricing inside this tool can close
        that: it is a property of the goal. What the tool CAN do is say out loud what share of
        the probability it is standing on is the honest kind. Reported, never charged."""
        pw, _es, _sd = self.curves(w0, n0)
        g = np.asarray(gap_draws, float)
        pc = np.interp(g, GAP_GRID, pw)
        den = float(np.mean(pc))
        if den < 1e-9:
            return float("nan")
        kk = MAX_MISS if k is None else float(k)
        return float(np.mean(pc * (np.abs(g - BAND_MID) <= kk)) / den)

    def on(self, gap_draws, w0, n0):
        """(P(certify), E[spend], MC standard error of E[spend]) averaged over a posterior of the
        true gap at one dial. The standard error is what stops the decision from chasing noise in
        its own objective: two dials whose costs differ by less than it are not distinguishable."""
        pw, es, sd = self.curves(w0, n0)
        g = np.asarray(gap_draws, float)
        return (float(np.mean(np.interp(g, GAP_GRID, pw))),
                float(np.mean(np.interp(g, GAP_GRID, es))),
                float(np.mean(np.interp(g, GAP_GRID, sd))) / math.sqrt(self.trials))


def forward_summary(gap_draws, w0, n0, chunk=LOOK, cap=CAP_GAMES, seed=7717, nsim=3000,
                    phi=PHI_PLAN, z_kill=Z_KILL, cover=True):
    """Posterior-predictive summary of a dial: draw a true gap from the posterior, play the rule
    forward once, repeat. Returns P(certify) and MEDIANS/quantiles of the games spent -- never a
    plain expectation of games_needed(point gap), which is neither the mean nor the median of the
    posterior (at the live rung-1 dial the plug-in reads 17124 against a posterior median 10004).
    """
    g = np.asarray(gap_draws, float)
    rng = np.random.default_rng(seed)
    g = rng.choice(g, size=nsim, replace=True)
    p = p_of_gap(g)
    w = np.full(nsim, float(w0)); n = np.full(nsim, float(n0))
    spent = np.zeros(nsim); state = np.zeros(nsim, np.int8)
    if n0 > 0:
        c, r = rule_state(*_eff(w, n, phi), z_kill=z_kill, cover=cover)
        state[c] = 1; state[r & ~c] = 2
    act = np.flatnonzero(state == 0)
    for step in look_steps(chunk, cap):
        if not act.size:
            break
        w[act] += rng.binomial(int(step), p[act])
        n[act] += step; spent[act] += step
        c, r = rule_state(*_eff(w[act], n[act], phi), z_kill=z_kill, cover=cover)
        state[act[c]] = 1; state[act[r & ~c]] = 2
        run = state[act] == 0
        state[act[run & (spent[act] >= cap)]] = 2
        act = act[state[act] == 0]
    ok = state == 1
    q = (lambda u: float(np.quantile(spent[ok], u))) if ok.any() else (lambda u: float("nan"))
    return {"p_cert": float(ok.mean()), "med": q(0.5), "q10": q(0.1), "q90": q(0.9),
            "e_spend": float(spent.mean()), "p_refute_or_cap": float((state == 2).mean())}


def value_iterate(S, W, V_cap, iters=500):
    """Self-consistent continuation value. Abandoning a dial puts you back in front of the same
    problem, so the price of an unreliable dial is a fixed point, not a free constant:

        V(x) = E[spend at x] + (1 - P(certify at x)) * (MOVE + V*),   V* = min_x V(x)

    V(x) is the cost of STANDING on x; the move to get there is added by the caller, and the move
    away after a failure is the MOVE inside the bracket. The map V -> min_x[S+(1-W)(MOVE+V)] is a
    contraction with factor min_x(1-W(x)) < 1 whenever some dial can certify at all; when none
    can, it walks into the ceiling and `hopeless` is returned -- a REPORT, never a number."""
    S = np.asarray(S, float); W = np.asarray(W, float)
    V = 0.0
    for _ in range(iters):
        Vn = min(float(np.min(S + (1.0 - W) * (MOVE_COST + V))), V_cap)
        if abs(Vn - V) < 1e-7:
            V = Vn
            break
        V = Vn
    return S + (1.0 - W) * (MOVE_COST + V), V, bool(V >= V_cap * (1.0 - 1e-6))


def joint_value_iterate(S, W, miss, p_fid, V_cap, iters=500, tiny_w=1e-9):
    """The games fixed point and the LADDER-MISS fixed point, solved together.

    THE TWO ACCUMULATORS. Standing on a dial x costs S(x) games and certifies with probability
    W(x); if it does not certify you pay MOVE and are back in front of the same problem (the
    model's standing approximation, the same one V* has always used). Two things accumulate along
    that trajectory: the GAMES, and -- exactly once, when a certificate finally lands -- the
    ladder's TARGET MISS. Write V(x) for the expected games from x and M(x) for the expected miss
    of the certificate the rung eventually ships, and let x* be the dial the policy re-places on:

        V(x) = S(x)           + (1 - W(x)) * (MOVE + V(x*))
        M(x) = W(x) * miss(x) + (1 - W(x)) * M(x*)

    miss(x) = E[|gap - T| | it certifies HERE] (Cost.miss) is the conditional miss, and it enters
    only through the branch that actually collects the certificate. THE SECOND LINE IS THE WHOLE
    FIX: without its (1-W)*M* term a dial that certifies 2% of the time is charged 2% of a miss
    it hardly ever makes and nothing at all for the 98% of worlds where the ladder's miss is made
    somewhere else, so the charge is smallest exactly where the certificate is least likely.

    ONE OBJECTIVE, NOT TWO FIXED POINTS. p_fid is an exchange rate -- games per ELO of ladder miss
    -- so the thing to minimise is U(x) = V(x) + p_fid * M(x), and the continuation dial is
    x* = argmin_x U(x) (it is NOT argmin V and NOT argmin M; those two disagree, which is why the
    continuation cannot be solved one accumulator at a time). Adding the two lines above gives a
    SINGLE scalar recursion, with the fidelity of the certifying branch folded into the immediate
    cost:

        U(x) = [S(x) + p_fid*W(x)*miss(x)] + (1 - W(x)) * (MOVE + U*),   U* = min_x U(x)

    which is the operator value_iterate() already solves, on a different immediate cost. The
    constrained form (minimise games subject to E[miss] <= eps) is the same family: p_fid is its
    Lagrange multiplier, and --calibrate is the sweep over it.

    CONVERGENCE. Let a_x = S(x) + p_fid*W(x)*miss(x) + (1-W(x))*MOVE >= 0 and
    F(u) = min(min_x [a_x + (1-W(x))*u], U_cap) on [0, U_cap].
      (i)   F is monotone non-decreasing and non-expansive (a min of affine maps with slopes
            1-W(x) in [0,1]), and maps [0, U_cap] into itself.
      (ii)  u_0 = 0 gives F(u_0) >= u_0, so by monotonicity the iterates are non-decreasing and
            bounded by U_cap: they converge, and the limit is the LEAST fixed point -- the right
            one, being the cost of a policy that is always free to walk away.
      (iii) If u < u' are both fixed points below the cap and x'' is the argmin at u, then
            u = a_x'' + (1-W(x''))u while u' <= a_x'' + (1-W(x''))u', so W(x'')*(u'-u) <= 0 and
            hence W(x'') = 0 -- but a fixed point whose argmin has W = 0 reads u = a_x'' + u,
            i.e. S(x'') + MOVE = 0, which MOVE > 0 forbids. So the fixed point below the cap is
            UNIQUE, and near it the map contracts with factor 1 - W(x*) < 1: the iteration is
            geometric, and the 1e-7 break is reached in a handful of passes at any W(x*) that a
            dial anyone would stand on.
      (iv)  When no dial can certify the iterates walk into U_cap; that branch is REPORTED
            (`sat`), never read as a number, exactly as the games-only ceiling always has been.
    U_cap = V_cap + p_fid * max_x miss(x) keeps the ceiling on the joint objective consistent with
    the games ceiling: saturating the joint one implies saturating the games one.

    THE GAMES CEILING STILL BINDS ON THE GAMES HALF. V_CAP_MULT exists so that a hopeless lever
    is REPORTED rather than priced, and p_fid*max(miss) can be many times V_cap, so the joint
    ceiling alone would let the games half run far past its own. V* is clamped to V_cap and `sat`
    is raised when it is. Returns (V, M, V*, M*, i_star, sat); while `sat` is false the
    decomposition is exact by construction -- V(x) + p_fid*M(x) = U(x) at every candidate and
    V* + p_fid*M* = U* -- and once it is true every number here is a ceiling, exactly as the
    games-only V* has always been at its own."""
    S = np.asarray(S, float); W = np.asarray(W, float); miss = np.asarray(miss, float)
    p_fid = max(float(p_fid), 0.0)
    m_max = float(np.max(miss)) if miss.size else 0.0
    U_cap = float(V_cap) + p_fid * m_max
    A = S + p_fid * W * miss                      # immediate cost: games here + the damage this
                                                  # dial does IN THE BRANCH WHERE IT CERTIFIES
    U = 0.0
    for _ in range(iters):
        Un = min(float(np.min(A + (1.0 - W) * (MOVE_COST + U))), U_cap)
        if abs(Un - U) < 1e-7:
            U = Un
            break
        U = Un
    i_star = int(np.argmin(A + (1.0 - W) * (MOVE_COST + U)))
    sat = bool(U >= U_cap * (1.0 - 1e-6))
    if W[i_star] > tiny_w and not sat:
        M_star = float(miss[i_star])              # M(x*) = W*miss* + (1-W*)M(x*) => M* = miss*:
                                                  # a stationary continuation certifies AT x*
        V_star = float((S[i_star] + (1.0 - W[i_star]) * MOVE_COST) / W[i_star])   # eventually, wp1
    else:
        M_star = m_max                            # nothing certifies: the miss is not identified,
        V_star = float(U - p_fid * M_star)        # so report the ceiling and keep U = V + p_fid*M
    if V_star > V_cap:                            # a lever can be hopeless in GAMES while the
        V_star, sat = float(V_cap), True          # joint ceiling is still far away: report it
    return (S + (1.0 - W) * (MOVE_COST + V_star), W * miss + (1.0 - W) * M_star,
            V_star, M_star, i_star, sat)


# ---------------------------------------------------------------------------- 6. candidates
EXTRAP_MULT = (0.25, 0.5, 0.75, 1.0, 1.5, 2.0)   # bounded ladder of steps beyond the data
MAX_LATTICE = 25


def propose(fit, rows, T, x_cur=None):
    """Candidate dials, all legal and all on the lattice or on a dial that already has games.

    Inside the data: the lattice over every block and segment whose identified gap range overlaps
    the band -- those are the only dials that can ever certify.
    Beyond it: a bounded geometric ladder of steps sized by the reference slope, which is FLOORED
    at S_REF_FLOOR so the step is always a finite length. This is the one place the old tool
    printed x_hat = 34483406 by dividing by a flat slope; here there is no division by an
    unfloored quantity anywhere.

    THE LADDER IS ANCHORED ON BOTH SLOPES WHERE THEY DIFFER. Where the fit accelerates the
    posterior continues at s_ref * acc (Fit._accel), so a ladder sized only by s_ref puts its
    fine end beyond where the crossing now is; where it does not, acc is exactly 1.0 and the two
    anchors coincide, so on a non-accelerating fit this emits the SAME candidate set as before,
    dial for dial. Both are kept rather than the accelerated one alone because the accelerated
    ladder is SHORTER -- its reach is 2*d_star/acc -- and the ratio is a prior: losing reach on a
    genuinely far target would trade one extrapolation defect for another.
    """
    cands = [round(float(r["x"]), 6) for r in rows]
    lo_b, hi_b, kind = fit.bracket(T)
    g = fit.iso_gap
    if kind == "interior":
        spans = []
        for k in range(fit.K):
            if BAND_LO <= g[k] <= BAND_HI:
                spans.append((fit.lo[k], fit.hi[k]))
        for k in range(fit.K - 1):
            if g[k] < BAND_HI and g[k + 1] > BAND_LO:
                spans.append((fit.hi[k], fit.lo[k + 1]))
        if not spans:
            spans = [(lo_b, hi_b)]
        a = float(min(s[0] for s in spans)); b = float(max(s[1] for s in spans))
        step = LATTICE
        while (b - a) / step > MAX_LATTICE:
            step *= 2.0
        k0 = int(math.ceil((a - 1e-9) / step)); k1 = int(math.floor((b + 1e-9) / step))
        cands += [clamp_x(round(k * step, 6)) for k in range(k0, k1 + 1)]
        # SNAPPED. An off-lattice dial is a fresh SGF bucket that no later chunk can ever add to,
        # which is precisely the thrash the lattice exists to prevent; the docstring above promises
        # every candidate is on it, and this line used to be the one exception.
        cands += [snap(0.5 * (lo_b + hi_b))] if hi_b - lo_b < LATTICE else []
    # The ladder BEYOND the data is offered on whichever side could still hold the band, whatever
    # the bracket says, because the block levels that decide the bracket are themselves noisy: a
    # top block reading 105 on 137 games closes the bracket, and without this the tool creeps
    # around inside a 0.13-wide interval for five chunks waiting for that block to be corrected.
    for side in ("right", "left"):
        if side == "right":
            if g[-1] >= BAND_HI:
                continue
            edge, s_ref, sgn, g_edge, room = fit.hi[-1], fit.s_ref_hi, +1.0, g[-1], X_HI - fit.hi[-1]
            acc = float(getattr(fit, "acc_hi", 1.0))
        else:
            if g[0] <= BAND_LO:
                continue
            edge, s_ref, sgn, g_edge, room = fit.lo[0], fit.s_ref_lo, -1.0, g[0], fit.lo[0] - X_LO
            acc = float(getattr(fit, "acc_lo", 1.0))
        # THE STEP IS BOUNDED BY THE WIDTH OF THE DATA, not by the slope estimate. Beyond the data
        # the slope is unmeasured -- from two dials 0.35 apart at n ~ 100 its standard error is
        # ~145 ELO/unit -- so a small reading of it must not buy a long confident leap. Doubling
        # the explored span reaches a far target in a handful of probes and never lands at gap 600.
        span = max(fit.hi[-1] - fit.lo[0], 4 * LATTICE)
        d_max = min(span, max(room, 0.0))
        if d_max < LATTICE * 0.5:
            continue
        for s_use in sorted({round(max(s_ref, S_REF_FLOOR), 9),
                             round(max(s_ref * acc, S_REF_FLOOR), 9)}):
            d_star = min(max(abs(T - g_edge) / s_use, LATTICE), d_max)
            for m in EXTRAP_MULT:
                d = min(m * d_star, d_max)
                if d >= LATTICE * 0.5:
                    cands.append(snap(edge + sgn * d))
    if x_cur is not None and in_domain(x_cur):
        cands.append(round(float(x_cur), 6))
    out = sorted(set(c for c in cands if in_domain(c)))
    if not out:
        out = [snap(x_cur if x_cur is not None else fit.xc[-1])]
    return out


# ---------------------------------------------------------------------------- 7. the decision
# THE ACTION CONTRACT. An automated driver obeys this literally and has no judgement to fall back
# on, so it is stated once, enforced by check_contract() on every return, and honoured by the
# acceptance harness (run_policy) exactly as a driver would honour it.
#
#   action = "PLAY"   x_next is a legal dial, n_next > 0 games. Play them there, then call again.
#   action = "DONE"   the rung is certified AT x_next; n_next == 0. Play nothing. Stop the loop.
#   action = "STOP"   the target is unattainable on this lever; n_next == 0. Play nothing.
#                     stop_reason says why, and it is always a statement about DATA, never about
#                     the absence of data.
#
# n_suggest is always > 0 and is the chunk the tool WOULD play if it were told to play; it exists
# so that --bench can measure exactly what obeying the contract costs against ignoring it. A
# driver must never use it: n_next is the field with the authority.
#
# STOP IS NOT THE SAME AS 'nothing looks promising'. The continuation value V* running into its
# ceiling means no candidate has a good chance of certifying FROM WHERE IT STANDS NOW, which is
# the ordinary state of a rung at round 0 with two dials 50 ELO below the band and everything
# still to explore. STOP additionally requires lever_room() to report that there is no legal dial
# left to try -- see there.
ACTIONS = ("PLAY", "DONE", "STOP")


def _dead(r, cap, rule=rule_state):
    """A dial that can never contribute a certificate: REFUTED or OVERSHOT under the rule in
    force, or already played past the abandon cap without the rule resolving (a dial sitting
    exactly on a band edge certifies never and refutes never, and the cap is what stops it
    hanging the loop)."""
    c, dd = rule(r["w"], r["n"])
    return bool(dd) or (float(r["n"]) >= cap and not bool(c))


def lever_room(fit, rows, T, cap, rule=rule_state):
    """Is there any legal dial left that could still deliver the target? -> (room, why).

    Prior-free and DATA-driven; this is the predicate that separates a genuinely saturated lever
    from the normal early state of a rung. Room exists when either

      OPEN BRACKET  the target is beyond every dial played and the legal domain still has at least
                    one lattice step of dial on that side -- there is more lever to push; or
      INTERIOR      the identified bracket still contains a legal lattice dial that has not been
                    refuted (an unplayed dial is never refuted, so any unexplored dial inside the
                    bracket counts).

    When neither holds, every dial that monotonicity allows to deliver T has been played and
    refuted, or the dial is against its own stop, and STOP is the correct action. Note this is
    about the DIAL, not about the cost: a lever with room is never STOPped however expensive it
    looks, because 'expensive' at round 0 is just 'unmeasured'."""
    dead = set()
    for r in rows:
        if _dead(r, cap, rule):
            dead.add(round(float(r["x"]), 6))
    lo_b, hi_b, kind = fit.bracket(T)
    if kind == "right-open":
        room = X_HI - float(fit.hi[-1])
        if room >= LATTICE - 1e-9:
            return True, ("the bracket is OPEN above x = %.4f and the legal domain has %.3f of "
                          "dial left below its ceiling %.2f" % (fit.hi[-1], room, X_HI))
        return False, ("SATURATED: the dial is at its ceiling %.2f and the top block still "
                       "delivers only %+.1f, below the band" % (X_HI, fit.iso_gap[-1]))
    if kind == "left-open":
        room = float(fit.lo[0]) - X_LO
        if room >= LATTICE - 1e-9:
            return True, ("the bracket is OPEN below x = %.4f and the legal domain has %.3f of "
                          "dial left above its floor %.2f" % (fit.lo[0], room, X_LO))
        return False, ("SATURATED: the dial is at its floor %.2f and the first block still "
                       "delivers %+.1f, above the band" % (X_LO, fit.iso_gap[0]))
    a, b = float(lo_b), float(hi_b)
    k0 = int(math.ceil((a - 1e-9) / LATTICE))
    k1 = int(math.floor((b + 1e-9) / LATTICE))
    for k in range(k0, k1 + 1):
        x = snap(k * LATTICE)
        if in_domain(x) and round(x, 6) not in dead:
            return True, ("the bracket [%.4f, %.4f] is closed but the legal dial %.4f inside it "
                          "has not been refuted" % (a, b, x))
    return False, ("EXHAUSTED: the bracket [%.4f, %.4f] is closed and every legal dial in it has "
                   "been refuted by its own games -- no dial on this lever delivers %.0f"
                   % (a, b, T))


def check_contract(d):
    """Enforce the contract above on every return. Raised, never asserted, so that running under
    -O cannot hand a driver an action it will obey and a game count that contradicts it."""
    a = d.get("action")
    if a not in ACTIONS:
        raise SystemExit("internal: action %r is not one of %s" % (a, ACTIONS))
    n, x = d.get("n_next"), d.get("x_next")
    if not isinstance(n, int):
        raise SystemExit("internal: n_next must be an int, got %r" % (n,))
    if a == "PLAY":
        if n <= 0:
            raise SystemExit("internal: action PLAY with n_next = %d (the loop would not "
                             "terminate)" % n)
        if x is None or not in_domain(x):
            raise SystemExit("internal: action PLAY at the illegal dial %r" % (x,))
    else:
        if n != 0:
            raise SystemExit("internal: action %s with n_next = %d -- a driver that obeys the "
                             "action would play those games nowhere" % (a, n))
    if a == "STOP" and not d.get("stop_reason"):
        raise SystemExit("internal: action STOP with no stop_reason")
    if a == "DONE" and not d.get("row"):
        raise SystemExit("internal: action DONE with no certifying row")
    ns = d.get("n_suggest")
    if not isinstance(ns, int) or ns <= 0:
        raise SystemExit("internal: n_suggest must be a positive int, got %r" % (ns,))
    return d


def decide(rows, T, cost, fit=None, x_cur=None, draws=8000, seed=20260911,
           p_fid=None, tol_t=TOL_T, chunk=CHUNK, legacy_stop=False, het_k=HET_K,
           gate_p=GATE_P, gate_k=GATE_K, obj_k=OBJ_K, acc_k=ACC_K, sig_acc=SIG_SLOPE_ACC):
    """One action, obeying the contract above. Never 'think again': the answer is always PLAY
    n>0 games at a legal dial, or DONE, or STOP -- which is what makes the loop terminate."""
    # WHY THE FIDELITY PRICE IS NOW ZERO (W3). p_fid was an exchange rate -- games spent here
    # against games FORCED on the remaining rungs by overshooting this one's target. Two
    # independent things killed it on the same day:
    #  (1) THE DERIVATION IS VOID. p_fid = |d games_needed/d target| priced SPAN DRIFT, which
    #      only exists when the 11 targets are spread over a ladder budget and an overshoot here
    #      can be absorbed there. Every target is now exactly 100, so there is no allocation
    #      problem and nothing to reallocate. The quantity it differentiated,
    #      deepkyu_tally.games_needed, is the ONE-SIDED cost and is not the number of games
    #      needed for anything under the two-sided rule (the requirement is an INTERVAL in n).
    #      p_fid_auto() is deleted rather than re-fitted, and with it the tool's last
    #      decision-path dependence on that one-sided power table.
    #  (2) IT IS SUBSUMED, BY SOMETHING STEEPER. Under the one-sided rule W(x) was nearly flat in
    #      |gap - 100| -- any in-band gap certified -- so a separate price was the only thing
    #      pulling toward the target. The two-sided rule makes W(x) itself the preference:
    #      P(certify) = .985 at a true gap of 100, .943 at 95, .778 at 90, .507 at 85, .253 at
    #      80. Standing on a dial priced at V = S + (1-W)(MOVE+V*) already charges ~400 games per
    #      ELO between two dials 2 ELO apart near the target, which is the middle of the range
    #      the old --calibrate sweep chose; charging P_FID = 3200 on top of it is an 8x
    #      double-count. What no price can buy is reported instead, as `p_centre`.
    # The constant survives in ONE place, where it was never a fidelity price: the `hopeless`
    # branch, where nothing can certify, there is no certificate to drift, and the charge is the
    # exploration gradient that walks a stuck lever toward the target. See p_fid_ch below.
    if p_fid is None:
        p_fid = 0.0
    rows = check_rows(sorted(rows, key=lambda r: r["x"]))
    # het_k is exposed only so the RESOLUTION GATE can be ablated end-to-end from the CLI
    # (--het-k inf switches it off). It is the one structure measured to carry the steep regime --
    # +326 games [+197, +458] and +0.12 of P(optimal dial) on the c1200 truth over 288 paired runs
    # -- and nothing else in this file would notice if it stopped firing. The default is HET_K,
    # so every shipped path is unchanged.
    # acc_k/sig_acc are exposed for the same reason het_k is: so the EXTRAPOLANT'S CURVATURE can
    # be ablated end to end from the CLI (--acc-k 1 is the pre-fix tool, slope continued flat).
    fit = fit or Fit(rows, B=draws, seed=seed, het_k=het_k, acc_k=acc_k, sig_acc=sig_acc)
    by_x = {round(r["x"], 6): r for r in rows}

    rule = getattr(cost, "state", rule_state)
    cert_rows = [r for r in rows if bool(rule(r["w"], r["n"])[0])]
    if cert_rows:
        r = max(cert_rows, key=lambda q: q["n"])
        glo, ghi = gap_ci(r["w"], r["n"], Z_STOP)
        plo, phi = gap_ci(r["w"], r["n"], Z_PUB)
        g_hat = float(gap_of_p(r["w"] / r["n"]))
        # FREEZE. The certificate lives on the SGF bucket, so every game that lands there
        # afterwards re-evaluates it at a NARROWER coverage window: a certificate at observed gap
        # g is destroyed once the bucket passes n_kill(g) games. That is not thrift, it is
        # correctness, and it is why DONE carries the number.
        return check_contract(
            {"action": "DONE", "fit": fit, "row": r, "x_next": float(r["x"]), "n_next": 0,
             "n_suggest": int(chunk), "gap": g_hat,
             "stop_ci": (glo, ghi), "pub_ci": (plo, phi), "cands": [], "T": T,
             "survives_to": float(n_kill(g_hat)), "headroom": float(n_kill(g_hat) - r["n"]),
             # BOTH MARGINS, AND WHICH ONE BINDS. survives_to/headroom above are the COVERAGE
             # half's lifetime and nothing else; on every live certificate so far the binding
             # half is CONTAINMENT, whose margin is 10x smaller. cert_margins() carries both.
             "margins": cert_margins(r["w"], r["n"]),
             "x_cur": x_cur, "stop_reason": "", "hopeless": False,
             "gate_p": float(gate_p), "gate_k": float(gate_k),
             "obj_k": (None if obj_k is None else float(obj_k)), "n_gated": 0})

    cands = propose(fit, rows, T, x_cur)
    V_cap = V_CAP_MULT * cost.max_spend
    rec = []
    for x in cands:
        r = by_x.get(round(x, 6))
        w0, n0 = (float(r["w"]), float(r["n"])) if r else (0.0, 0.0)
        gd = fit.gap_draws([x])[:, 0]
        med = float(np.median(gd))
        p_band = float(np.mean((gd >= BAND_LO) & (gd <= BAND_HI)))
        # THE VIABILITY FILTER IS ABOUT THE CENTRE NOW, NOT THE BAND. Under the two-sided rule a
        # certificate's POINT ESTIMATE must land in [100-MAX_MISS, 100+MAX_MISS] = [88.7, 111.3].
        # That is NOT the set of true gaps that can certify -- no such set exists, the rule is
        # probabilistic in the truth: 85 certifies ~0.49 of the time and 80 ~0.25. p_centre is the
        # posterior mass on the estimate landing feasibly; p_band is still reported because it is
        # what the old rule asked, but it no longer decides anything.
        p_centre = float(np.mean(np.abs(gd - BAND_MID) <= MAX_MISS))
        # DEAD, and the third clause is not decoration. A dial is dead if it is REFUTED or
        # OVERSHOT, and ALSO if it has already been played past the per-dial abandon cap without
        # resolving -- which is what CAP_GAMES has always meant ("games past which you would
        # re-place rather than keep paying at one dial") and what lever_room()/_dead() have
        # always enforced. decide() did not, and under the ONE-SIDED rule that was harmless:
        # more games at a dial could only bring the certificate closer. Under the two-sided rule
        # it is a trap. Measured, on --bench truth `cliff` (1400 ELO/unit, feasible dial set 1.5
        # lattice steps wide) seed 42: the tool put 27,293 games into x = +0.59, whose TRUE gap
        # is +96 and whose observed gap settled at +92.9. Its window closed at n = 5,290; from
        # n = 12,000 on, P(certify) read 0.00-0.13 and the tool STILL stood there, because every
        # other dial on the lever was worse and nothing said the bank itself was spent. The cap
        # says it.
        dead = bool(rule(w0, n0)[1]) if n0 > 0 else False
        if n0 >= cost.cap and not bool(rule(w0, n0)[0]):
            dead = True
        # G1a, THE COMMIT GATE (off unless gate_p > 0). p_gate is a statement about the TRUE gap,
        # not about the estimate: P(|true gap - 100| <= gate_k) under this dial's own posterior.
        # A gated dial is priced as a dead one, which is the existing "cannot deliver" path.
        p_gate = float(np.mean(np.abs(gd - BAND_MID) <= float(gate_k)))
        gated = bool(float(gate_p) > 0.0 and p_gate < float(gate_p) and not dead)
        if dead or p_centre < 0.01 or gated:
            W, S, se = 0.0, float(cost.max_spend), 0.0   # cannot certify here; bound the spend
            W_cert = 0.0
        else:
            W, S, se = cost.on(gd, w0, n0)
            W_cert = W
            # G1b, THE FIDELITY-WEIGHTED OBJECTIVE (off unless obj_k is set). The value iteration
            # below is run on W_k = P(certify AND |true gap - 100| <= k) instead of P(certify),
            # so V(x) = S(x) + (1 - W_k(x))(MOVE + V*) reads "expected games until a certificate
            # I would be happy to publish", with an off-centre certificate charged as if the dial
            # had failed. That is an APPROXIMATION and it is the honest one to state: in the real
            # world an off-centre certificate ENDS the rung (the rule accepts it), it does not
            # hand the tool another turn. So V under obj_k is a planning objective, not a
            # prediction of games; only the ARGMIN is used.
            if obj_k is not None:
                W = cost.w_good(gd, w0, n0, float(obj_k))
        miss = cost.miss(gd, w0, n0, T, tol_t)
        miss_u = cost.miss_uncond(gd, T, tol_t)
        # the honest-share report is about P(certify), so it is gated on P(certify) -- not on the
        # objective weight, which --obj-k can drive to 0 at a dial that certifies perfectly well
        lot = (cost.lottery_share(gd, w0, n0) if W_cert > 0 else float("nan"))
        g_obs = float(gap_of_p(w0 / n0)) if n0 > 0 else float("nan")
        rec.append({"x": float(x), "row": r, "w0": w0, "n0": n0, "med": med, "miss_u": miss_u,
                    "gd_q":
                    (float(np.quantile(gd, 0.05)), float(np.quantile(gd, 0.95))),
                    "gd_sd": float(np.std(gd)),      # reported only: the ELO resolution at this
                                                     # dial, which is what says whether a finer
                                                     # lattice could buy anything (W1)
                    "p_band": p_band, "p_centre": p_centre,
                    "p_safe": fit.p_safe(x), "prior_free": fit.prior_free(x),
                    "dead": dead, "refuted": dead,   # `refuted` kept as an alias for one release
                    "dead_why": ((dead_kind(w0, n0, getattr(cost, "z_kill", Z_KILL))
                                  or "PAST CAP") if dead else ""),
                    "n_kill": (float(n_kill(g_obs)) if n0 > 0 else float("inf")),
                    "g_obs": g_obs, "lot_share": lot,
                    "p_gate": p_gate, "gated": gated, "W_cert": float(W_cert),
                    "W": W, "S": S, "se": se, "miss": miss})
    S = np.array([c["S"] for c in rec]); W = np.array([c["W"] for c in rec])
    W_cert = np.array([c["W_cert"] for c in rec])
    _miss = np.array([c["miss"] for c in rec])
    # THE GAMES-ONLY FIXED POINT, kept for one purpose: `hopeless`. "No candidate dial has a real
    # chance of certifying from where it stands" is a statement about GAMES, and the STOP gate it
    # feeds must not move because a price was attached to target fidelity.
    # SO IT IS RUN ON P(certify), NOT ON THE OBJECTIVE (G1b). With --obj-k the value iteration
    # below optimises W_k = P(certify AND near 100); reading `hopeless` off THAT would make a
    # lever where every dial certifies reliably but off centre report "nothing can certify",
    # which is false and is exactly the fidelity leak this line exists to prevent. W_cert == W
    # whenever --obj-k is unset, so no shipped path moves.
    _Vg, Vstar_g, hopeless = value_iterate(S, W_cert, V_cap)
    # THE JOINT FIXED POINT prices the dials: expected games AND the expected miss of the
    # certificate the rung eventually ships, solved together because the continuation dial
    # (argmin of the total) is the one that sets both. Derivation in joint_value_iterate().
    V, M, Vstar, Mstar, i_star, sat = joint_value_iterate(S, W, _miss, p_fid, V_cap)
    move = np.array([0.0 if (x_cur is not None and abs(c["x"] - x_cur) < 1e-9) else MOVE_COST
                     for c in rec])
    # TARGET FIDELITY. Four properties, the last of which is the one that was missing.
    # (1) The loss is an EXPECTATION over the gap posterior, not a hinge on its median: a hinge on
    #     the median is blind to a dial whose median sits on T but whose posterior is wide, which
    #     delivers a gap far from T about as often as it delivers one near it.
    # (2) Cost.miss is conditioned on THE CERTIFICATE HAPPENING AT THIS DIAL. A draw of the true
    #     gap that would never certify here delivers nothing to the ladder and must not be charged
    #     as a miss; a dial that certifies only at gaps far from T must be.
    # (3) THE CONDITIONAL MISS IS NOT THE CHARGE. Conditioning divides by P(certify here), so on
    #     its own it charges the least to the dials that certify least -- in the rare world where
    #     a dial 39 ELO below target certifies, its gap was in band all along. The charge is the
    #     expected miss of the certificate THE RUNG ACTUALLY SHIPS from here,
    #         M(x) = W(x)*miss(x) + (1 - W(x))*M*,
    #     whose second branch is the miss made at the dial we certify at after abandoning x. M* is
    #     a fixed point solved jointly with V*, not a constant.
    # (4) It is charged as the EXCESS over the best M any candidate offers, which is an affine
    #     shift -- it changes no decision -- so that TOTAL stays a number in games.
    # (5) WHEN NOTHING CAN CERTIFY, M HAS NO OPINION AND SAYS SO. M(x) -> M* at every dial as
    #     W -> 0, so on a saturated lever the charge is flat and the only thing left in TOTAL is
    #     the 150-game move cost, which says "stand still" -- and the tool stood still for 74
    #     rounds and 40000 games on truth `far` seed 5 without ever certifying. That branch is
    #     not a pricing problem, it is the one-epoch model being exhausted: no dial ships a
    #     certificate, the next games are exploration, and the quantity that still varies is the
    #     UNCONDITIONAL distance to the target. So the basis of the charge switches, once, on the
    #     same `hopeless` flag the report already prints -- and only there. Nothing is conditioned
    #     on a rare event in this branch, so the inversion cannot come back through it.
    miss_u = np.array([c["miss_u"] for c in rec])
    fid_basis = "distance" if hopeless else "ladder-miss"
    Mch = miss_u if hopeless else M
    # THE TWO BRANCHES ARE DIFFERENT QUANTITIES, AND ONLY ONE OF THEM IS STILL PRICED. In the
    # normal branch p_fid was the span-drift exchange rate; it is 0 now (see the note at the top
    # of decide()), and the target preference lives inside W(x) instead. The hopeless branch was
    # never pricing span drift at all: nothing certifies, so there is no certificate to drift.
    # Its charge is EXPLORATION pricing, the only thing pushing a stuck lever toward the target,
    # and at p_fid = 0 it would have no gradient -- the lever would then sit on whatever dial it
    # already has games at, forever. (Selftest [11e] catches exactly this: "the charge is flat on
    # a saturated lever: nothing can move it off a dial".) So exploration keeps the calibrated
    # constant, under the name it should always have had.
    p_fid_ch = max(float(p_fid), P_EXPLORE) if hopeless else float(p_fid)
    pen = p_fid_ch * (Mch - float(np.min(Mch)))      # EXCESS over the best fidelity on offer, so
                                                     # the charge is 0 at the dial that serves
                                                     # the target best and TOTAL stays readable as
                                                     # games. An affine shift: it moves no argmin.
    J = V + move
    tot = J + pen
    for c, v, mm, ch, mv, pn, jj in zip(rec, V, M, Mch, move, pen, J):
        c.update({"V": float(v), "M": float(mm), "fid": float(ch), "move": float(mv),
                  "pen": float(pn), "J": float(jj), "total": float(jj + pn)})
    # TIE-BREAK, and it is load-bearing. S is a Monte-Carlo estimate, and on a shallow rung a
    # whole range of dials is genuinely near-equivalent: a bare argmin then flips between them
    # every chunk and splits the games over five SGF buckets, none of which ever accumulates
    # enough to certify. Candidates whose cost differs by less than the simulation's own standard
    # error are declared indistinguishable, and among those the tool stands still -- on the
    # current dial if it is one of them, else where the games already are.
    # The tie tolerance is an indifference band in GAMES, and it is there because the games term
    # is Monte-Carlo noisy. The fidelity term is not noisy -- it is a posterior expectation over
    # `draws` draws -- so inside the band it is the term that decides, and standing still wins only
    # when it does not give up more fidelity than the same band is worth. Letting "stand still"
    # win the tie unconditionally is what made the tool certify at +0.63 (true gap 114) while the
    # baselines certified at +0.60 (true gap 105): it was never the cost that chose the dial, it
    # was the fact that the dial already had games on it.
    # A DEAD DIAL IS NEVER PLAYED AT, NOT EVEN FOR EXPLORATION. Pricing it high is not enough:
    # on a saturated lever every dial's V is at the ceiling, so the only term left in TOTAL is
    # the exploration charge P_EXPLORE * (E|gap-T| - best), and that charge PREFERS the dial
    # whose posterior sits nearest the target -- which, after a long grind, is exactly the dial
    # that was ground. Measured on --bench truth `cliff` seed 42: x = +0.59 (true gap +96, window
    # closed at n = 5,290) collected 21,360 games at P(certify) = 0.00 because its E|gap-100| was
    # the smallest on the lever. Those games bought nothing and could not have. An unplayed
    # lattice dial is never dead, so this restriction can only fail to leave a candidate when
    # every legal dial has been played and killed -- which is the state STOP exists for.
    pool = [j for j in range(len(rec)) if not rec[j]["dead"]] or list(range(len(rec)))
    i0 = min(pool, key=lambda j: tot[j])
    tie_tol = max(TIE_FLOOR, 2.0 * rec[i0]["se"])
    ties = [j for j in pool if tot[j] <= tot[i0] + tie_tol]
    # WHAT BREAKS A TIE IN GAMES, in two levels and in this order.
    #   M first: inside a tie the dial that serves the ladder best is the one with the smallest
    #     EXPECTED miss of the certificate the rung ships. Ranking by the CONDITIONAL miss here
    #     would re-introduce the very inversion the charge above removes.
    #   The UNCONDITIONAL distance second, and only among candidates the first cannot tell apart
    #     -- never the conditional miss, which is inverted by construction and enters the
    #     decision only through M, where W multiplies it. Two dials that are indistinguishable in
    #     games and in expected ladder miss are separated by which one is believed to land nearer
    #     the target.
    # THE TIE BAND IS AN ELO BAND AND MUST NOT BE DERIVED FROM p_fid. It used to be
    # tie_tol / p_fid, which at the new default p_fid = 0 is 6e10: every candidate is then
    # "near", and the `cur` branch below makes STANDING STILL win every tie unconditionally.
    # Under the one-sided rule that was merely lazy. Under the two-sided rule standing still
    # BURNS THE WINDOW -- the certification window closes as n grows -- so it is now a way to
    # lose a rung. A fixed indifference band in ELO, independent of any price.
    tol_elo = TIE_ELO
    m_best = min(Mch[j] for j in ties)
    near = [j for j in ties if Mch[j] <= m_best + tol_elo]
    # WHAT BREAKS THE TIE UNDER THE TWO-SIDED RULE. It used to be the unconditional E|gap - T|,
    # an L1 distance over the gap posterior. That is the wrong proxy now: being 10 ELO LOW and
    # being 3 ELO HIGH are not exchangeable when the rule can only certify inside 100 +- 11.25,
    # and on the live rung-4 rows the L1 tie-break picked a dial with median +91.8 over a
    # cost-equivalent one at +102.9 whose certification probability was identical and whose
    # honest share was higher (0.73 against 0.66). The first key is now p_centre -- the
    # posterior probability that this dial's TRUE gap is in the set the rule can certify at all
    # -- which is the same quantity the viability filter uses and is derived from the rule
    # rather than guessed. E|gap - T| stays as the SECOND key, because on a saturated lever
    # p_centre is 0 at every dial and has no gradient, and there the distance to the target is
    # the only thing left that varies (selftest [11e]).
    p_cen = np.array([c["p_centre"] for c in rec])
    _pc_bin = lambda j: -int(float(p_cen[j]) / TIE_PCEN)
    best_u = min(miss_u[j] for j in near)
    best_pc = max(p_cen[j] for j in near)
    cur = [j for j in near if x_cur is not None and abs(rec[j]["x"] - x_cur) < 1e-9
           and p_cen[j] >= best_pc - TIE_PCEN_HOLD and miss_u[j] <= best_u + tol_elo]
    if cur:
        i = cur[0]
    else:
        i = min(near, key=lambda j: (_pc_bin(j), miss_u[j], -rec[j]["n0"], tot[j]))
    i_free = int(np.argmin(J))
    best = rec[i]
    fs = forward_summary(fit.gap_draws([best["x"]])[:, 0], best["w0"], best["n0"],
                         chunk=cost.chunk, cap=cost.cap, seed=seed + 31,
                         phi=getattr(cost, "phi", 1.0))
    n_suggest = int(chunk)
    if fs["p_cert"] > 0.5 and fs["med"] == fs["med"] and fs["med"] < chunk:
        n_suggest = int(max(60, math.ceil(fs["med"] / 60.0) * 60))
    # W4: THE BUDGET MUST NOT STEP OVER THE WINDOW. A dial's certification window is an interval
    # in n, bounded ABOVE as well as below: at a point estimate of +90 it is [2020, 2900], 880
    # games wide -- less than two 540-game chunks. Handing a driver a flat 540 there is handing
    # it the games that destroy the certificate. n_kill(g_hat) is the last n at which the
    # coverage half can still hold, so the budget is clipped to what is left of it.
    if best["n0"] > 0 and math.isfinite(best["n_kill"]):
        room_n = best["n_kill"] - best["n0"]
        if room_n > 0:
            n_suggest = int(max(LOOK, min(n_suggest, math.ceil(room_n / float(LOOK)) * LOOK)))
    # THE STOP GATE. Both halves are required and neither is sufficient:
    #   hopeless   no candidate has a real chance of certifying from where it stands -- which at
    #              round 0, with two dials 50 ELO below the band, is simply what "unmeasured"
    #              looks like, and is why this was never allowed to decide alone;
    #   no room    there is no legal dial left on this lever that has not been refuted.
    room, why_room = lever_room(fit, rows, T, cost.cap, rule)
    # legacy_stop reinstates the rule this file shipped with -- STOP whenever V* hit its ceiling,
    # room or no room -- so that --bench can price D1 instead of asserting it. Nothing else uses it.
    stop = bool(hopeless) if legacy_stop else bool(hopeless and not room)
    act = "STOP" if stop else "PLAY"
    _cur_dead = False
    if x_cur is not None:
        _r = by_x.get(round(float(x_cur), 6))
        _cur_dead = bool(rule(_r["w"], _r["n"])[1]) if _r else False
    # THE ABANDONED DIALS, NAMED, with what is left in them. A dial does not become dead by
    # judgement here: `resid_P` is the same P(certify) the objective is already built on, run
    # forward from that dial's own bank, and a dead dial reads 0.00 because the cost simulation
    # absorbs it at the OVERSHOT exit on its first look.
    _dead_list = [{"x": c["x"], "w": c["w0"], "n": c["n0"], "gap": c["g_obs"],
                   "why": c["dead_why"], "n_kill": c["n_kill"], "resid_P": c["W"]}
                  for c in rec if c["dead"] and c["n0"] > 0]
    return check_contract(
        {"action": act, "fit": fit, "rec": rec, "i": i, "i_free": i_free, "best": best,
         "Vstar": float(Vstar), "Mstar": float(Mstar), "Vstar_games": float(Vstar_g),
         "joint_sat": bool(sat), "i_star": int(i_star),
         "hopeless": hopeless, "x_next": float(best["x"]),
         "n_next": (0 if stop else n_suggest), "n_suggest": n_suggest,
         "room": room, "why_room": why_room,
         "stop_reason": (why_room if stop else ""),
         "fwd": fs, "cands": cands, "T": T, "x_cur": x_cur, "ties": len(ties),
         "tie_tol": float(tie_tol), "i_cheapest": i0, "p_fid": float(p_fid),
         "p_fid_ch": float(p_fid_ch), "tol_t": float(tol_t),
         "fid_basis": fid_basis,
         # x_cur_dead is for the DRIVER, not for the report: deepkyu_auto.sh has an anti-thrash
         # hold that plays the wave at the dial ALREADY SET when a move is requested too soon.
         # If that dial is OVERSHOT those waves are pure waste and deepen the overshoot, so the
         # hold must never block a move OFF a dead dial.
         "x_cur_dead": bool(_cur_dead), "dead_dials": _dead_list,
         "gate_p": float(gate_p), "gate_k": float(gate_k),
         "obj_k": (None if obj_k is None else float(obj_k)),
         "n_gated": int(sum(1 for c in rec if c["gated"])),
         "fid_bound": bool(pen[i] > 0 or i != i_free), "V_cap": V_cap})


# ---------------------------------------------------------------------------- 8. report
def fmt_gap_ci(w, n, z):
    lo, hi = gap_ci(w, n, z)
    return "[%+6.1f,%+6.1f]" % (lo, hi)


def bot_for(x, rank, visits=1, sym=1):
    e, l, h, npt = dc.dial_params(float(x))
    return dc.bot_name(rank, visits, e, l, h, sym, 1.0, npt, 1.0)


def report(rows, T, d, cost, rank=None, strong=None, rate=None, out=sys.stdout):
    P = lambda s="": print(s, file=out)
    fit = d["fit"]
    who = ("%s vs %s" % (strong, rank)) if (rank and strong) else (
        ("weaker side %s" % rank) if rank else "one rung")
    P("== deepkyu_place2 ==  %s  target %.1f ELO   band [%g,%g]   TWO-SIDED rule"
      % (who, T, BAND_LO, BAND_HI))
    P("CERTIFIED = the Wilson Z=%.2f interval lies inside [%g,%g] AND the Z=%.2f interval contains"
      % (Z_STOP, BAND_LO, BAND_HI, Z_COVER))
    P("%.0f. The published Z=%.2f certificate is nested between them, so it both fits and covers"
      % (BAND_MID, Z_PUB))
    P("after arbitrarily many looks. THE CONSEQUENCE, and it is the whole shape of the problem:")
    gw = gap_window(N_PEAK)
    P("  the rule is a WINDOW in n, bounded ABOVE as well as below. It is EMPTY below n = %d,"
      % N_OPEN)
    P("  widest at n = %d (observed gap in [%+.1f,%+.1f]), and closes like %.0f/sqrt(n) forever"
      % (N_PEAK, gw[0], gw[1], Z_COVER * C_ELO / math.sqrt(P_MID * (1 - P_MID))))
    P("  after. MORE GAMES CAN DESTROY A RUNG: a certificate at an observed gap of %+.1f dies at"
      % 92.2)
    P("  n = %.0f games. The +-%.2f ELO bounds the PUBLISHED POINT ESTIMATE, not the true gap: a"
      % (n_kill(92.2), MAX_MISS))
    P("  rung whose TRUE gap is 85 still certifies 0.51 of the time and one at 80 still 0.25,")
    P("  because the coverage gate selects on the ESTIMATE, so what gets published reads near")
    P("  +95 either way. The feasible set bounds what a certificate SAYS, never what it IS.")
    if abs(T - BAND_MID) > 1e-6:
        P("  !! the target %.1f is NOT the band centre %.0f, and the rule certifies only around the"
          % (T, BAND_MID))
        P("  centre. Placement below aims at %.1f; certification still requires covering %.0f."
          % (T, BAND_MID))
    P()
    # -- 1. data ------------------------------------------------------------
    P("-- 1. the games ------------------------------------------------------------------")
    P("%-9s %-26s %6s %6s %8s %-16s %6s %8s  %s" %
      ("x", "bot", "w", "n", "gap", "95% CI (Z=1.96)", "1 sd", "survives", "state"))
    for r in rows:
        c, dd = rule_state(r["w"], r["n"])
        g_obs = float(gap_of_p(r["w"] / r["n"]))
        nk = n_kill(g_obs)
        st = ("CERTIFIED" if c else
              (dead_kind(r["w"], r["n"]) if dd else
               ("below n=%d" % N_OPEN if r["n"] < N_OPEN else "alive")))
        P("%-9.4f %-26s %6.0f %6.0f %+8.1f %-16s %6.1f %8s  %s" %
          (r["x"], (r["name"] or "")[:26], r["w"], r["n"], g_obs,
           fmt_gap_ci(r["w"], r["n"], Z_PUB), sd_gap(r["w"], r["n"]),
           "inf" if not math.isfinite(nk) else "%.0f" % nk, st))
    P("`survives` = n_kill(observed gap): the last n at which this bucket's coverage half can")
    P("still hold. Past it the certificate is gone and no game at this dial brings it back.")
    ntot = sum(r["n"] for r in rows)
    m = min(T - BAND_LO, BAND_HI - T)
    floor_n = (C_ELO / (0.5 * m)) ** 2 / (float(p_of_gap(T)) * (1 - float(p_of_gap(T)))) if m > 0 else float("inf")
    weak = sum(1 for r in rows if r["n"] < floor_n)
    P("%d dials, %d games. A dial needs n >= %d before its own 1 sd is under half the band margin;"
      % (len(rows), ntot, int(floor_n)))
    P("%d of %d dials are below that line and cannot localise anything on their own." % (weak, len(rows)))
    if rate:
        P("at %.0f games/h that bank is %.0f h." % (rate, ntot / rate))
    P()
    # -- 2. fit -------------------------------------------------------------
    P("-- 2. monotone fit: which dials are ONE analysis point, and what pooling them costs ---")
    P("dials within %.3f of dial MAY pool (this rung cannot read slope over a shorter span); they"
      % fit.min_sep)
    P("DO pool only if a G^2 test cannot reject one common winrate at alpha = %.3g. A group that"
      % fit.merge_alpha)
    P("fails is cut where the deviance is and the halves re-tested, so a real step survives it.")
    P("%-16s %6s %9s %-18s %6s %5s %6s  %s"
      % ("x range", "n", "gap", "90% posterior", "G2 p", "phi", "het", "members"))
    for k, b in enumerate(fit.blocks):
        q = np.quantile(fit.G[:, k], [0.05, 0.95])
        P("%-16s %6.0f %+9.1f [%+7.1f,%+7.1f] %6s %5.2f %6.1f  %s"
          % ("%.4f..%.4f" % (b["lo"], b["hi"]), b["n"], fit.iso_gap[k], q[0], q[1],
             "-" if b["df"] == 0 else "%.3f" % b["pval"], b["phi"], fit.het[k],
             ", ".join("%.3f" % mm["x"] for mm in b["members"])))
    P("phi = max(1, G2/df): a block that is only just homogeneous is credited n/phi games, not n.")
    P("het = the within-block response the merge assumed away (block width x the slope of the")
    P("segments beside it), charged as a uniform window on that block's gap -- the certificate is")
    P("earned at ONE member dial out of that dial's own games, so it is real uncertainty.")
    ksplit = [b for b in fit.blocks if b["df"] == 0 and len(b["members"]) == 1]
    forced = [b for b in fit.blocks if b["df"] > 0 and b["pval"] < 10 * fit.merge_alpha]
    if forced:
        P("MARGINAL: %s pooled at p = %s -- close to the cut; check the NO MERGE row of section 6."
          % (", ".join("%.3f..%.3f" % (b["lo"], b["hi"]) for b in forced),
             ", ".join("%.3f" % b["pval"] for b in forced)))
    # THE PRICE OF THE MERGE, in the only currency that matters: what it changes about the dial
    # the tool is about to stand on. A merge that pools 1323 games behind one dial's 792 makes
    # every forward cost at that dial look cheaper than it is, and no homogeneity test can rule
    # that out -- the test only rejects response the GAMES already resolve.
    if d["action"] != "DONE" and d.get("best"):
        xb = d["best"]["x"]
        try:
            f0 = Fit(rows, B=min(fit.B, 4000), seed=20260911, min_sep=0.0,
                     merge_alpha=fit.merge_alpha)
            g1 = fit.gap_draws([xb])[:, 0]
            g0 = f0.gap_draws([xb])[:, 0]
            s1 = forward_summary(g1, d["best"]["w0"], d["best"]["n0"], chunk=cost.chunk,
                                 cap=cost.cap, seed=4242, nsim=2000)
            s0 = forward_summary(g0, d["best"]["w0"], d["best"]["n0"], chunk=cost.chunk,
                                 cap=cost.cap, seed=4242, nsim=2000)
            blk = [b for b in fit.blocks if b["lo"] - 1e-12 <= xb <= b["hi"] + 1e-12]
            nown = sum(m["n"] for m in blk[0]["members"] if abs(m["x"] - xb) < 1e-9) if blk else 0.0
            P("PRICE OF THE MERGE at the dial chosen below, x = %+.4f:" % xb)
            P("  %-28s %14s %14s" % ("", "as merged", "no merge"))
            P("  %-28s %14.0f %14.0f" % ("games behind the posterior",
                                         blk[0]["n"] if blk else 0.0, nown))
            P("  %-28s %14.3f %14.3f"
              % ("P(gap outside [%.1f,%.1f])" % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS),
                 float(np.mean(np.abs(g1 - BAND_MID) > MAX_MISS)),
                 float(np.mean(np.abs(g0 - BAND_MID) > MAX_MISS))))
            P("  %-28s %14.2f %14.2f" % ("P(certify before the cap)", s1["p_cert"], s0["p_cert"]))
            P("  %-28s %14.0f %14.0f" % ("E[games spent here]", s1["e_spend"], s0["e_spend"]))
            if s0["e_spend"] > 1.05 * max(s1["e_spend"], 1.0):
                P("  the merge advertises this dial %.2fx cheaper than its OWN games do. That"
                  % (s0["e_spend"] / max(s1["e_spend"], 1.0)))
                P("  discount is real only if the pooled dials truly deliver the same gap -- an")
                P("  assumption the G2 test above could not reject, NOT one it confirmed.")
        except Exception as e:                     # a diagnostic must never take the report down
            P("PRICE OF THE MERGE: not computable (%s: %s)" % (type(e).__name__, e))
    P()
    # -- 3. what is identified ----------------------------------------------
    P("-- 3. where gap = %.0f is, and what is NOT identified -----------------------------" % T)
    lo_b, hi_b, kind = fit.bracket(T)
    if kind == "interior":
        sl = fit.local_slope(0.5 * (lo_b + hi_b))
        ka, kb = fit.where(lo_b)[1], fit.where(hi_b)[1]
        ga, gb = float(fit.iso_gap[ka]), float(fit.iso_gap[kb])
        P("identified bracket (monotonicity alone): x in [%.4f, %.4f], width %.4f"
          % (lo_b, hi_b, hi_b - lo_b))
        if abs(gb - ga) < 1e-9:
            P("FLAT: the fit is level at %+.1f across the whole bracket, so x* is not identified"
              % ga)
            P("   ANYWHERE in it -- and it does not need to be: every dial in it delivers %+.1f."
              % ga)
        else:
            P("slope across it: %s"
              % ("%.0f ELO/unit" % sl if sl is not None else
                 "NOT IDENTIFIED (the bracket is inside one merged block)"))
            P("x* is NOT printed as a number: inside the bracket the position of the crossing is")
            P("   set by the interpolation prior, not by the data. What IS identified, prior-free:")
            P("   every dial in [%.4f, %.4f] delivers a gap between %+.1f and %+.1f."
              % (lo_b, hi_b, ga, gb))
    elif kind == "right-open":
        P("x* > %.4f  -- UNIDENTIFIED ABOVE: gap %.0f is above every dial played (top block %+.1f)."
          % (hi_b if hi_b is not None else lo_b, T, fit.iso_gap[-1]))
        P("   No upper bound on x* exists in this data. The step proposed below is sized by the")
        _a = float(getattr(fit, "acc_hi", 1.0))
        P("   extrapolation slope PRIOR (%.0f ELO/unit, lognormal sd %.1f), not by a measurement."
          % (fit.s_ref_hi * _a, SIG_SLOPE_ACC if _a > 1.0 else SIG_SLOPE))
        if _a > 1.0:
            _p, _l = getattr(fit, "seg_hi", (None, None))
            P("   ACCELERATING: the last two segments read %.0f then %.0f ELO/unit over %.2f and"
              % (_p[0], _l[0], _p[1]))
            P("   %.2f of dial, so the slope is continued GEOMETRICALLY at %.0f x %.2f = %.0f"
              % (_l[1], fit.s_ref_hi, _a, fit.s_ref_hi * _a))
            P("   ELO/unit (clamp %.2f), and the prior is widened to sd %.2f because the ratio is"
              % (fit.acc_k, fit.sig_acc))
            P("   itself two noisy secants divided by each other.")
        else:
            P("   NOT accelerating (or fewer than three separated blocks): the slope is continued")
            P("   FLAT, which is the shipped behaviour and is exact where the response is linear.")
    else:
        P("x* < %.4f  -- UNIDENTIFIED BELOW: gap %.0f is below every dial played (first block %+.1f)."
          % (hi_b, T, fit.iso_gap[0]))
        _a = float(getattr(fit, "acc_lo", 1.0))
        P("   The step proposed below is sized by the extrapolation slope PRIOR (%.0f ELO/unit%s)."
          % (fit.s_ref_lo * _a,
             "" if _a <= 1.0 else ", geometric x %.2f off %.0f" % (_a, fit.s_ref_lo)))
    if d["action"] != "DONE":
        safe = [c["x"] for c in d["rec"] if c["p_safe"] >= 0.90]
        if safe:
            holes = [c["x"] for c in d["rec"]
                     if min(safe) < c["x"] < max(safe) and c["p_safe"] < 0.90]
            P("SAFE DIALS (P >= 0.90 that the WHOLE identified gap range at that dial is inside")
            P("   [%.1f,%.1f], where a certificate's POINT ESTIMATE must land, so they ship"
              % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
            P("   wherever the crossing really is): x in [%.4f, %.4f]%s"
              % (min(safe), max(safe),
                 "  -- NOT CONTIGUOUS, %d priced dial%s inside it %s not safe"
                 % (len(holes), "" if len(holes) == 1 else "s",
                    "is" if len(holes) == 1 else "are") if holes else ""))
        else:
            P("NO dial has P >= 0.90 that its whole identified gap range is inside the feasible")
            P("   set: every")
            P("   candidate below is a bet on the interpolation or slope prior to some degree.")
    P()
    if d["action"] == "DONE":
        r = d["row"]
        P("-- 4. ACTION ---------------------------------------------------------------------")
        P("DONE. %s certifies: %d games, gap %+.1f, Z=2.50 interval [%+.1f,%+.1f] inside [%g,%g]"
          % (r["name"], int(r["n"]), d["gap"], d["stop_ci"][0], d["stop_ci"][1], BAND_LO, BAND_HI))
        P("      AND the Z=%.2f interval [%+.1f,%+.1f] contains %.0f."
          % (Z_COVER, gap_ci(r["w"], r["n"], Z_COVER)[0], gap_ci(r["w"], r["n"], Z_COVER)[1],
             BAND_MID))
        P("      published Z=1.96 certificate: [%+.1f, %+.1f]  (n = %d)"
          % (d["pub_ci"][0], d["pub_ci"][1], int(r["n"])))
        hd = d.get("headroom", float("inf"))
        m = d.get("margins") or cert_margins(r["w"], r["n"])
        P()
        P("      HOW MUCH ROOM THIS CERTIFICATE HAS, ON BOTH HALVES OF THE RULE. They are")
        P("      enforced on different intervals, so they are different numbers, and the smaller")
        P("      one is the one that describes the certificate:")
        P("        containment  %+6.2f ELO   (Z=%.2f interval [%+.1f,%+.1f] inside [%g,%g])%s"
          % (m["contain"], Z_STOP, m["stop_ci"][0], m["stop_ci"][1], BAND_LO, BAND_HI,
             "   <-- BINDS" if m["binds"] == "containment" else ""))
        P("        coverage     %+6.2f ELO   (Z=%.2f interval [%+.1f,%+.1f] contains %g)%s"
          % (m["cover"], Z_COVER, m["cover_ci"][0], m["cover_ci"][1], BAND_MID,
             "   <-- BINDS" if m["binds"] == "coverage" else ""))
        P("      BINDING MARGIN %.2f ELO, on %s. That is %.2f of this dial's own"
          % (m["margin"], m["binds"], m["margin_sd"]))
        P("      1 sd (%.1f ELO)%s." % (m["sd"],
          "; %d %s win%s by the weaker side would have broken it"
          % (m["swing"], m["swing_dir"], "" if m["swing"] == 1 else "s")
          if m.get("swing") is not None else ""))
        P("      FOR SCALE, AND IT IS A MEASUREMENT, NOT A REASSURANCE: a first-crossing stop")
        P("      rule produces a median containment margin of %.2f ELO and a median swing of %d"
          % (CERT_TYPICAL_CONTAIN, CERT_TYPICAL_SWING))
        P("      games (3082 certificates, true gaps 80..115), with %.0f%% of them under a"
          % (100.0 * CERT_TYPICAL_UNDER_QSD))
        P("      quarter sd. Thinness here is the RULE's shape, not this rung's defect, which is")
        P("      why no alarm is raised -- but it is also why the %s lifetime below is not"
          % ("coverage" if m["binds"] == "containment" else "containment"))
        P("      this certificate's safety margin. %s is what is tight." % m["binds"].upper())
        P()
        P("      FREEZE THIS BUCKET. n_next = 0 is not thrift, it is correctness: the certificate")
        P("      lives on the SGF bucket, and every game added to it re-tests coverage at a")
        P("      NARROWER window. THIS IS THE COVERAGE HALF ONLY -- the containment margin above")
        P("      does not decay with n, it grows. This certificate survives to n = %s games, i.e."
          % ("inf" if not math.isfinite(d.get("survives_to", float("inf")))
             else "%.0f" % d["survives_to"]))
        P("      %s more."
          % ("unboundedly many" if not math.isfinite(hd) else "%.0f" % hd))
        if math.isfinite(hd) and hd < 4 * CHUNK:
            P("      !! THAT IS UNDER %d CHUNKS. Do not play another game against this bot name."
              % max(1, int(hd // CHUNK) + 1))
        P("      deepkyu_ladder.py `plan` already drops a certified rung from ACTIVE, so the")
        P("      campaign does not top it up; a dial change is mandatory before any further play.")
        return
    # -- 4. cost ------------------------------------------------------------
    P("-- 4. price of every candidate dial, in games ------------------------------------")
    P("cost = forward simulation of the TWO-SIDED rule from each dial's realised (w,n), looked at")
    P("every %d games; it can end in CERTIFY, REFUTE, OVERSHOT or the abandon cap of %d games, so"
      % (cost.chunk, cost.cap))
    P("every expectation here is bounded. P(cert) is the probability this dial EVER certifies from")
    P("where it stands: for a dead dial it is 0.00 by the simulation, not by assertion.")
    _ph = getattr(cost, "phi", 1.0)
    if _ph != 1.0:
        P("PLANNING DISPERSION phi = %.2f (W2): the stop rule is looked at with n/phi effective"
          % _ph)
        P("games in the simulation, so every spend below is the budget an OVERDISPERSED rung needs.")
    else:
        P("games are priced as independent Bernoulli trials, phi = 1 -- measured, not assumed:")
        P("--dispersion reads phi = 1.00, 95% [0.85, 1.18] over ~290 df on this campaign's own")
        P("SGFs, grouped by match process. Under-dispersion is not banked (plan_phi clamps at 1).")
    if d.get("p_fid", 0.0) > 0 or d.get("fid_basis") == "distance":
        P("M = W*miss(x) + (1-W)*M*, the expected miss of the certificate this rung ends up")
        P("shipping if it stands here. TOTAL = V(x) + move + %.0f games/ELO x (M - best M)."
          % d.get("p_fid", 0.0))
    else:
        P("NO FIDELITY PRICE IS CHARGED (p_fid = 0), and that is not an omission. Under the")
        P("two-sided rule P(certify) IS the fidelity preference -- .99 at a true gap of 100, .94")
        P("at 95, .78 at 90, .51 at 85 -- so V(x) already charges ~400 games per ELO near the")
        P("target. The old charge priced SPAN DRIFT across 11 targets spread over a budget; every")
        P("target is now 100, so there is no budget to allocate and nothing to trade. TOTAL =")
        P("V(x) + move. M is printed because it is informative, not because it is charged.")
    if d.get("fid_basis") == "distance":
        P("SATURATED LEVER: nothing can certify, M is the same number at every dial, so the column")
        P("below is the UNCONDITIONAL E|gap-T| and TOTAL prices exploration, not a certificate.")
    P("P(centre) is the posterior probability that this dial's TRUE gap is inside [%.1f,%.1f],"
      % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
    P("where a certificate's POINT ESTIMATE must land under the two-sided rule -- it has replaced")
    P("P(band) as the viability filter. It is NOT a bound on the TRUE gap: the coverage gate")
    P("selects on the estimate, so a true gap of 85 certifies ~0.49 of the time and 80 ~0.25.")
    P("%-9s %-11s %7s %8s %7s %8s %8s %8s %6s %8s  %s"
      % ("x", "bank w/n", "medgap", "P(centre)", "P(safe)", "P(cert)", "E[spend]", "V(x)",
         "M ELO", "TOTAL", "note"))
    order = sorted(range(len(d["rec"])), key=lambda i: d["rec"][i]["total"])
    shown = order[:14]
    for i in sorted(shown, key=lambda i: d["rec"][i]["x"]):
        c = d["rec"][i]
        tag = "<== CHOSEN" if i == d["i"] else (c["dead_why"].lower() if c["dead"] else
                                                ("" if c["prior_free"] else "extrapolation"))
        P("%-9.4f %-11s %+7.1f %9.2f %7.2f %8.2f %8.0f %8.0f %6.1f %8.0f  %s"
          % (c["x"], ("%.0f/%.0f" % (c["w0"], c["n0"])) if c["n0"] else "-",
             c["med"], c["p_centre"], c["p_safe"], c["W"], c["S"], c["V"], c["fid"], c["total"],
             tag))
    if len(order) > len(shown):
        P("(%d further candidates priced and dominated)" % (len(order) - len(shown)))
    for dd in d.get("dead_dials", []):
        P("%s at x = %+.4f: %.0f games banked, observed gap %+.1f, coverage died at n = %s."
          % (dd["why"], dd["x"], dd["n"], dd["gap"],
             "inf" if not math.isfinite(dd["n_kill"]) else "%.0f" % dd["n_kill"]))
        P("   residual P(this dial EVER certifies, %d more games) = %.4f. Those games are spent;"
          % (cost.cap, dd["resid_P"]))
        P("   no further game at it can be. This is a printed number, not a judgement.")
    P("continuation: V* = %.0f games and M* = %.1f ELO of miss, solved as ONE fixed point"
      % (d["Vstar"], d.get("Mstar", float("nan"))))
    P("(abandon -> move -> re-place at the dial that minimises games AND miss together).")
    if d["hopeless"]:
        P()
        P("!! NO CANDIDATE DIAL HAS A REAL CHANCE OF CERTIFYING FROM WHERE IT STANDS NOW: the")
        P("   games-only continuation value ran into its ceiling of %.0f games (it reads %.0f)."
          % (d["V_cap"], d.get("Vstar_games", float("nan"))))
        P("   Reported, not priced -- and with nothing able to certify, M(x) is the same number at")
        P("   every dial, so the fidelity charge decides nothing here either.")
        if d.get("room"):
            P("   THIS IS NOT SATURATION AND IT IS NOT A REASON TO STOP:")
            P("   %s." % d["why_room"])
            P("   At round 0, with two dials 50 ELO below the band and everything still to")
            P("   explore, a rung looks exactly like this. The action below is PLAY, n > 0.")
        else:
            P("   %s" % d["why_room"])
            if kind == "interior":
                P("   Escape levers (deepkyu_cfg): chosenMoveTemperatureOnlyBelowProb, which")
                P("   flattens only the tail and protects the endgame pass, and")
                P("   nnPolicyTemperature past X_HALFLIFE_CAP = %.1f. Otherwise renegotiate this"
                  % dc.X_HALFLIFE_CAP)
                P("   rung's target.")
            else:
                P("   The lever is against its own stop. Change the lever or renegotiate.")
    P()
    # -- 5. action ----------------------------------------------------------
    b = d["best"]
    P("-- 5. ACTION ---------------------------------------------------------------------")
    nm = b["row"]["name"] if b["row"] else (bot_for(b["x"], rank) if rank else "new dial")
    if d["action"] == "STOP":
        P("STOP.  n_next = 0.  PLAY NOTHING.  Do not start katago.")
        P("The target %.0f ELO is not attainable on this lever:" % T)
        P("  %s" % d["stop_reason"])
        P("x_next = %+.4f is reported for reference only -- it is the least bad dial priced, not"
          % b["x"])
        P("a dial to play. The %d dial%s below %s what this rung has, and what they are worth:"
          % (len(rows), "" if len(rows) == 1 else "s", "is" if len(rows) == 1 else "are"))
        P("  %-9s %-11s %8s %8s %10s" % ("x", "bank w/n", "gap", "P(cert)", "state"))
        for c in sorted(d["rec"], key=lambda c: c["x"]):
            if not c["n0"]:
                continue
            P("  %-9.4f %-11s %+8.1f %8.2f %10s"
              % (c["x"], "%.0f/%.0f" % (c["w0"], c["n0"]),
                 float(gap_of_p(c["w0"] / c["n0"])), c["W"], c["dead_why"] or "alive"))
        P("Escape: a different lever (deepkyu_cfg.dial_params), or a renegotiated target for this")
        P("rung. Whatever is chosen, this rung's ladder contribution has to be re-planned.")
        if d.get("sens"):
            P()
            P("-- 6. does the STOP survive the assumptions? --------------------------------------")
            P("%-36s %9s  %s" % ("assumption", "x_next", "action"))
            for label, xn, act, tt, pb, md in d["sens"]:
                P("%-36s %9s  %s" % (label, "n/a" if xn != xn else "%+.4f" % xn, act))
            nstop = sum(1 for v in d["sens"] if v[2] == "STOP")
            P("%d of %d assumption settings also STOP. A STOP that is not unanimous here is a"
              % (nstop, len(d["sens"])))
            P("STOP that depends on the merge or the prior, and should be escalated, not obeyed.")
        return
    P("%s %d games at x = %+.4f   (%s)%s"
      % (d["action"], d["n_next"], b["x"], nm,
         "" if b["row"] else "   NEW BUCKET (no banked games)"))
    P()
    P("  the price of standing on this dial, in games (every line is a bounded quantity):")
    P("    E[games here before it certifies, dies (refuted/overshot) or caps]     S = %8.0f"
      % b["S"])
    if d.get("obj_k") is None:
        P("    P(it certifies before the cap)                                        W = %8.2f"
          % b["W"])
    else:
        # G1b is ON: the fixed point below is run on P(certify AND near 100), so the W in the
        # arithmetic is NOT P(certify) and must not be printed as if it were.
        P("    P(it certifies before the cap)                                   P(cert) = %8.2f"
          % b["W_cert"])
        P("    ...AND the true gap is within %4.1f ELO of %.0f -- THE OBJECTIVE IN FORCE   W = %8.2f"
          % (d["obj_k"], BAND_MID, b["W"]))
    if d.get("gate_p", 0.0) > 0.0:
        P("    COMMIT GATE ON: %d of %d candidate dials refused for P(|true gap-%.0f| <= %.0f) "
          "< %.2f" % (d.get("n_gated", 0), len(d["rec"]), BAND_MID, d["gate_k"], d["gate_p"]))
        P("    this dial's P(|true gap-%.0f| <= %.0f)                                 = %8.2f"
          % (BAND_MID, d["gate_k"], b["p_gate"]))
    P("    if it does not: move %3.0f + continuation V* %.0f, weighted by 1-W       = %8.0f"
      % (MOVE_COST, d["Vstar"], (1.0 - b["W"]) * (MOVE_COST + d["Vstar"])))
    P("    ----------------------------------------------------------------------------------")
    P("    V(x) = S + (1-W)*(MOVE+V*)                                              = %8.0f" % b["V"])
    P("    move to get there from x = %-9s                                   + %8.0f"
      % (("%+.4f" % d["x_cur"]) if d["x_cur"] is not None else "(nowhere)", b["move"]))
    # in the saturated branch the rate that was actually charged is P_EXPLORE, not p_fid
    _pf = max(d.get("p_fid_ch", d.get("p_fid", 0.0)), 1e-9)
    if d.get("fid_basis") == "distance":
        P("    target fidelity: NO candidate can certify from where it stands, so M = W*miss +")
        P("    (1-W)*M* is the same number at every dial and has no opinion. These games are")
        P("    exploration, and they are priced by the UNCONDITIONAL distance to the target,")
        P("    E|gap-%.0f| = %.1f ELO here against the best %.1f on offer:"
          % (T, b["fid"], b["fid"] - b["pen"] / _pf))
        P("    this is EXPLORATION pricing, not a fidelity price: nothing can certify, so there")
        P("    is no certificate for a target miss to damage. P_EXPLORE is the only gradient that")
        P("    walks a stuck lever toward the target (selftest [11e]).")
        P("    %.0f games/ELO x %.2f ELO of excess                                 + %8.0f"
          % (_pf, b["pen"] / _pf, b["pen"]))
    elif d.get("p_fid", 0.0) <= 0.0:
        P("    target fidelity: NOT PRICED. P(certify) = %.2f is itself the fidelity preference"
          % b["W"])
        P("    under the two-sided rule (a dial 10 ELO low certifies 0.78 of the time and one 15")
        P("    ELO low 0.51), and the posterior says this dial's TRUE gap is inside the feasible")
        P("    set [%.1f,%.1f] with probability %.2f.                        + %8.0f"
          % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS, b["p_centre"], 0.0))
        P("    HONEST SHARE of that P(certify): %.2f. The rest is the rule's own type-I rate --"
          % (b.get("lot_share", float("nan"))))
        P("    a true gap of 85 certifies 0.49 of the time and a true gap of 80 still 0.25, and")
        P("    the certificate it buys reads near +95 because the coverage gate selects on the")
        P("    point estimate. That is a property of the GOAL, not of this tool, and no price")
        P("    inside it can close it. It is printed so that it is not invisible.")
    else:
        P("    target fidelity, BOTH branches. If it certifies here (W = %.2f) the gap it delivers"
          % b["W"])
        P("    misses %.0f by E[|gap-%.0f| | it certifies here] = %.1f ELO; if it does not, the rung"
          % (T, T, b["miss"]))
        P("    certifies at the continuation dial instead and misses by M* = %.1f. The ladder miss"
          % d.get("Mstar", float("nan")))
        P("    this dial is answerable for is M = W*miss + (1-W)*M* = %.1f ELO, against the best M"
          % b["M"])
        P("    on offer %.1f, so %.0f games/ELO x %.2f ELO of excess                + %8.0f"
          % (b["M"] - b["pen"] / _pf, d.get("p_fid", P_FID), b["pen"] / _pf, b["pen"]))
    P("    ----------------------------------------------------------------------------------")
    P("    TOTAL                                                                   = %8.0f"
      % b["total"])
    # The arithmetic above must close from the printed numbers alone -- the old tool printed one
    # candidate's cost against another's baseline and reported 4104 - 3596 as 207. Checked here,
    # and raised rather than asserted so that -O cannot switch the check off.
    lhs = b["S"] + (1.0 - b["W"]) * (MOVE_COST + d["Vstar"])
    if abs(lhs - b["V"]) > 1.0 or abs(b["V"] + b["move"] + b["pen"] - b["total"]) > 1.0:
        raise SystemExit("internal: the ACTION arithmetic does not close (%.3f vs %.3f, %.3f vs "
                         "%.3f)" % (lhs, b["V"], b["V"] + b["move"] + b["pen"], b["total"]))
    alt = sorted((c for c in d["rec"] if abs(c["x"] - b["x"]) > 1e-9), key=lambda c: c["total"])
    if alt:
        a = alt[0]
        if a["total"] >= b["total"]:
            P("  next best dial x = %+.4f at %.0f games: this choice saves %.0f games (%.0f - %.0f)."
              % (a["x"], a["total"], a["total"] - b["total"], a["total"], b["total"]))
        else:
            P("  the CHEAPEST dial is x = %+.4f at %.0f games, %.0f fewer than the %.0f here --"
              % (a["x"], a["total"], b["total"] - a["total"], b["total"]))
            P("  inside the %.0f-game tie band, so the choice was made on P(centre) %.2f against"
              % (d["tie_tol"], b["p_centre"]))
            P("  %.2f, not on a cost difference the simulation cannot resolve." % a["p_centre"])
    # HOW FINELY THIS RUNG IS RESOLVED AT ALL (W1). The lattice was accused of limiting the
    # delivered gap on a steep lever. It does not: what limits it is the data. This line prints
    # the posterior sd at the dial about to be played, in ELO and in LATTICE STEPS at the local
    # slope. Measured over closed-loop runs, that number is 0.9 steps on a 1200 ELO/unit truth and
    # 0.8 on a 1400 one -- i.e. the grid is already finer than the rung can resolve, which is why
    # refining it to 0.005 cost +261 to +546 games and bought no fidelity, and why the honest
    # answer to "the argmin is quantisation-limited" is that the argmin is DATA-limited.
    sl = fit.local_slope(b["x"])
    if sl and sl > 0:
        steps = b.get("gd_sd", float("nan")) / (sl * LATTICE)
        P("  RESOLUTION HERE: the gap posterior at this dial has sd %.1f ELO and the local slope is"
          % b.get("gd_sd", float("nan")))
        P("  %.0f ELO/unit, so one lattice step of %.3f is %.1f ELO and the data resolves this dial"
          % (sl, LATTICE, sl * LATTICE))
        P("  to %.1f lattice steps. A finer lattice cannot help while that is >= 1: it would only"
          % steps)
        P("  add dials this rung cannot tell apart, and split the certificate over more buckets.")
    if b["p_safe"] < 0.90:
        P("  PRIOR-DEPENDENT: monotonicity alone only says this dial delivers between the two")
        P("  bracketing block levels, and P(that whole range is inside the feasible set "
          "[%.1f,%.1f])" % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
        P("  is %.2f, not >= 0.90." % b["p_safe"])
        P("  The rest -- where in the bracket it lands -- is the interpolation prior. Section 6 is")
        P("  the check that the recommendation does not depend on it.")
    fs = d["fwd"]
    P("  at this dial, summarising over the gap posterior (medians, never a plug-in):")
    P("    P(certify without re-placing) %.2f;  games to the certificate: median %s, 10-90%% %s-%s"
      % (fs["p_cert"],
         "n/a" if fs["med"] != fs["med"] else "%.0f" % fs["med"],
         "n/a" if fs["q10"] != fs["q10"] else "%.0f" % fs["q10"],
         "n/a" if fs["q90"] != fs["q90"] else "%.0f" % fs["q90"]))
    P("    the window at this dial, if the median gap %+.1f is the truth: it %s."
      % (b["med"], window_note(b["med"])))
    P("    the pair above is the whole honest answer: under the two-sided rule the requirement")
    P("    is an INTERVAL in n, bounded above as well as below, so no single N answers it. The")
    P("    `need~N` the status lines used to print was deepkyu_tally's ONE-SIDED power table;")
    P("    deepkyu_tally.cert_outlook() reports this same pair to them now.")
    if rate:
        P("    at %.0f games/h: median %s h to the certificate."
          % (rate, "n/a" if fs["med"] != fs["med"] else "%.0f" % (fs["med"] / rate)))
    if b["pen"] > 0:
        f = d["rec"][d["i_free"]]
        price = max(0.0, b["J"] - f["J"])      # games actually spent, NOT the charge itself
        P("  WHAT THE TARGET FIDELITY CHARGE ACTUALLY COST. The charge is an offset on every")
        P("  candidate, so the number that matters is not the %.0f above but the difference it"
          % b["pen"])
        P("  made to the choice. Cheapest to certify IGNORING the target entirely: x = %+.4f"
          % f["x"])
        P("  (median gap %+.1f, ladder miss M = %.1f ELO) at %.0f games; the dial chosen costs %.0f."
          % (f["med"], f["M"], f["J"], b["J"]))
        P("  PRICE OF HITTING THE TARGET HERE: %.0f GAMES%s."
          % (price, " -- the same dial wins either way" if price < 1.0 else ""))
        P("  The ladder's 959 ELO span is the sum of its 11 rungs' delivered gaps, so a rung")
        P("  that silently ships %+.1f instead of %.0f moves the whole ladder." % (f["med"], T))
    if d.get("ties", 1) > 1:
        P("  (%d candidate dials are within %.0f games of each other -- the Monte-Carlo standard"
          % (d["ties"], d["tie_tol"]))
        P("   error of the cost itself -- so the tie was settled by the largest P(centre), the")
        P("   posterior probability that the dial's TRUE gap is in the set the rule can certify")
        P("   at all; then by proximity to the target where P(centre) cannot separate them; then")
        P("   by standing still, not by a cost difference nothing can resolve.)")
    if d.get("sens"):
        P()
        P("-- 6. does the recommendation survive the assumptions? ----------------------------")
        P("%-36s %9s %9s %8s %9s  %s"
          % ("assumption", "x_next", "total", "P(band)", "med games", "action"))
        for label, xn, act, tt, pb, md in d["sens"]:
            P("%-36s %9s %9s %8s %9s  %s"
              % (label, "n/a" if xn != xn else "%+.4f" % xn,
                 "n/a" if tt != tt else "%.0f" % tt,
                 "n/a" if pb != pb else "%.2f" % pb,
                 "n/a" if md != md else "%.0f" % md, act))
        xs = [v[1] for v in d["sens"] if v[1] == v[1]]
        if xs:
            P("spread of the recommended dial across all %d: %.4f of dial (%.0f ELO at the fitted"
              % (len(d["sens"]), max(xs) - min(xs),
                 (max(xs) - min(xs)) * abs(fit.local_slope(b["x"]) or 0.0)))
            P("local slope). Anything wider than the lattice %.3f means the answer is the prior's,"
              % LATTICE)
            P("not the data's.")


def sensitivity(rows, T, cost, x_cur, draws, seed, chunk, p_fid=0.0, tol_t=TOL_T, base=None,
                **g1):
    """Re-decide under every assumption that can actually move the answer, and report the spread.

    The shipped sweep varied merge width over 0.025 and 0.100, NEITHER of which separates dials
    0.01 apart -- so on the live rung-1 data, where the whole question is whether 0.520/0.545/0.550
    are one point or three, its merge rows were identical to the baseline and its gate could never
    fire. The first row here is min_sep = 0, which gives every dial its own block and is the only
    setting that can disagree; the next three switch off the homogeneity test, the within-block
    response charge, and widen the merge. The rest move the interpolation prior and the
    Monte-Carlo seed. If the recommendation is stable across all eight it is the data talking.
    """
    out = []
    base = dict(base or {})              # whatever the CLI set, so row 1 IS the decision above
    for label, kw, sd in (("baseline", {}, seed),
                          ("NO MERGE: every dial its own block", {"min_sep": 0.0}, seed),
                          ("merge width 0.100 (double)", {"min_sep": 0.100}, seed),
                          ("no homogeneity test (pool anyway)", {"merge_alpha": 0.0}, seed),
                          ("no within-block response charge", {"het_mult": 0.0}, seed),
                          ("interpolation prior sd 0.40 only", {"sig_warp": (0.40,), "w_warp": (1.0,)}, seed),
                          ("interpolation prior sd 1.00 only", {"sig_warp": (1.00,), "w_warp": (1.0,)}, seed),
                          ("FLAT extrapolant (acc_k = 1, the pre-fix tool)", {"acc_k": 1.0}, seed),
                          ("another Monte-Carlo seed", {}, seed + 101)):
        try:
            f = Fit(rows, B=draws, seed=sd, **dict(base, **kw))
            dd = decide(rows, T, cost, fit=f, x_cur=x_cur, draws=draws, seed=sd, chunk=chunk,
                        p_fid=p_fid, tol_t=tol_t, **g1)
            out.append((label, dd["x_next"], dd["action"],
                        dd["best"]["total"] if dd["action"] != "DONE" else 0.0,
                        dd["best"]["p_band"] if dd["action"] != "DONE" else float("nan"),
                        dd["fwd"]["med"] if dd["action"] != "DONE" else float("nan")))
        except SystemExit as e:
            out.append((label, float("nan"), "REFUSED: %s" % e, float("nan"), float("nan"),
                        float("nan")))
    return out


# ---------------------------------------------------------------------------- 9. acceptance
# The bar: beat a naive bracket-and-interpolate baseline on TOTAL GAMES TO A VALID CERTIFICATE,
# over several independent monotone truths and seeds, with certification judged by the
# re-implementation below -- which is written from the specification and shares no code with the
# tool, so a bug in rule_state() cannot flatter the tool.
def _indep_wilson_gap(w, n, z):
    """(gap_lo, gap_hi) of the Wilson-z interval. Independent scalar re-implementation."""
    ph = float(w) / float(n)
    den = 1.0 + z * z / n
    cen = (ph + z * z / (2.0 * n)) / den
    hw = (z / den) * math.sqrt(ph * (1.0 - ph) / n + z * z / (4.0 * n * n))
    plo, phi = cen - hw, cen + hw
    if plo <= 0.0 or phi >= 1.0:
        return None
    return (400.0 * math.log10((1.0 - phi) / phi),     # the HIGH winrate is the SMALL gap
            400.0 * math.log10((1.0 - plo) / plo))


def indep_certified(w, n):
    """The TWO-SIDED rule, re-implemented from the specification and sharing no code with the
    tool: the Z=2.50 interval lies inside [70,130] AND the Z=1.50 interval contains 100. The
    second half is the goal change; without it this judge would keep scoring the benchmark
    against the OLD goal and would certify a broken tool."""
    if n <= 0:
        return False
    a = _indep_wilson_gap(w, n, 2.50)
    b = _indep_wilson_gap(w, n, 1.50)
    if a is None or b is None:
        return False
    return a[0] >= 70.0 and a[1] <= 130.0 and b[0] <= 100.0 <= b[1]


def indep_overshot(w, n, z_kill=3.50):
    """OVERSHOT, re-implemented: the observed gap is more than z_kill of its own sd off 100."""
    if n <= 0:
        return False
    ph = min(max(float(w) / float(n), 1e-9), 1.0 - 1e-9)
    g = 400.0 * math.log10((1.0 - ph) / ph)
    sd = (400.0 / math.log(10.0)) / math.sqrt(n * ph * (1.0 - ph))
    return abs(g - 100.0) > z_kill * sd


def indep_refuted(w, n):
    if n <= 0:
        return False
    z = 2.50
    ph = float(w) / float(n)
    den = 1.0 + z * z / n
    cen = (ph + z * z / (2.0 * n)) / den
    hw = (z / den) * math.sqrt(ph * (1.0 - ph) / n + z * z / (4.0 * n * n))
    plo, phi = max(cen - hw, 1e-12), min(cen + hw, 1 - 1e-12)
    gap_hi = 400.0 * math.log10((1.0 - plo) / plo)
    gap_lo = 400.0 * math.log10((1.0 - phi) / phi)
    return gap_lo > 130.0 or gap_hi < 70.0


TRUTHS = {
    # the shape the live rung-1 data actually shows: flat, a steep rise through the band, a
    # plateau at 115-140 from 0.63 to 0.95, then steep again to 432 at 1.37
    "rung1":   [(-0.70, 30.0), (0.35, 38.0), (0.5377, 86.5), (0.63, 113.6), (0.95, 140.0),
                (1.37, 432.0), (2.00, 600.0)],
    # the target sits inside an exactly flat stretch: x is genuinely unidentified, every dial ships
    "plateau": [(-0.70, 25.0), (0.30, 40.0), (0.60, 100.0), (0.95, 100.0), (1.20, 190.0),
                (2.00, 400.0)],
    # a corner: 750 ELO/unit through the crossing, where an interpolation prior is worth least
    "steep":   [(-0.70, 20.0), (0.50, 40.0), (0.58, 100.0), (0.70, 160.0), (1.00, 240.0),
                (2.00, 420.0)],
    # the opposite regime: 120 ELO/unit, so many dials are nearly as good as each other
    "shallow": [(-0.70, 10.0), (0.00, 40.0), (1.00, 160.0), (2.00, 260.0)],
    # the target is far beyond every dial in the start state: the extrapolation regime
    "far":     [(-0.70, 5.0), (0.35, 20.0), (1.30, 100.0), (1.80, 150.0), (2.00, 190.0)],
    # a near-cliff, 1400 ELO/unit: the band is only 0.043 of dial wide, which is the regime where
    # the old tool's intervals collapsed (in-band 23-35%, gap-CI coverage 17% at S_MAX = 1500)
    "cliff":   [(-0.70, 15.0), (0.55, 40.0), (0.65, 180.0), (1.00, 260.0), (2.00, 420.0)],
    # 1200 ELO/unit with the crossing INSIDE a 0.05 span: the regime the structural merge width
    # smears, and the one the tool lost outright on before the homogeneity test was restored.
    "c1200":   [(-0.70, 15.0), (0.50, 40.0), (0.60, 160.0), (0.65, 220.0), (1.00, 340.0),
                (2.00, 520.0)],
    # ---- OFF-CENTRE TRUTHS, ATTAINABLE. Every truth above has a lattice dial delivering almost
    # exactly 100, which under the two-sided rule is the ONLY place that is safe at EVERY
    # precision -- so on all of them the new rule never bites and this bench could not see the
    # failure the rewrite is about. These two have no dial at the centre, but every dial they
    # offer is inside the feasible set 100 +- 11.25, so a certificate from them is honest and
    # they belong in the games comparison.
    # (a) the crossing sits BETWEEN two lattice dials: 0.60 -> 94, 0.61 -> 106. Both can certify
    #     (P = .94 and .86) but a dial 6 ELO off centre must be caught while the window is open,
    #     which is what a coarse look cadence misses.
    "tilt":    [(-0.70, 20.0), (0.50, 70.0), (0.60, 94.0), (0.61, 106.0), (1.00, 180.0),
                (2.00, 320.0)],
    # ---- THE COMPOUNDING TRUTH. Every truth above is a broken line whose secants RISE AND FALL
    # with no particular pattern, so on all of them a slope continued flat past the data is wrong
    # only by noise -- which is why the flat extrapolant survived ten rungs and two rounds of
    # adversarial verification without this defect ever being visible. THE LEVER IS NOT LIKE
    # THAT ABOVE x = 4.30: both temperature caps are pinned there and the dial weakens through
    # halflife = 30 * 2**(x - 4.30), so equal steps in x are equal DOUBLINGS of the noisy phase
    # and the response COMPOUNDS -- 39, 78, 209, 440 ELO/unit on the campaign's own 600-game arms.
    # Here the secant DOUBLES every 0.35 of dial exactly, which is the shape a flat continuation
    # cannot see and the one the geometric continuation (Fit._accel) is for. The crossing at
    # ~1.244 is far beyond the cold start, so the placement is an EXTRAPOLATION every time.
    "compound": [(-0.70, 16.0), (0.00, 20.0), (0.35, 27.0), (0.70, 41.0), (1.05, 69.0),
                 (1.40, 125.0), (1.75, 237.0), (2.00, 317.0)],
    # (b) a WIDE PLATEAU 10 ELO LOW: every dial in the bracket delivers ~90, which certifies 0.78
    #     of the time and whose window CLOSES at n = 2902. Grinding is fatal here and re-placing
    #     buys nothing, so this is the truth that prices the OVERSHOT exit.
    "off90":   [(-0.70, 15.0), (0.35, 45.0), (0.55, 90.0), (0.95, 90.5), (1.30, 200.0),
                (2.00, 330.0)],
}
# LEVERS THE RULE PERMITS BUT WHICH NO DIAL DESERVES. On these, EVERY legal dial's true gap is
# outside the feasible set 100 +- 11.25, so every certificate they produce is a LOTTERY TICKET
# bought at the rule's own type-I rate -- and the certificate reads near +95 whatever the truth,
# because the coverage gate selects on the point estimate. They are NOT part of the games
# benchmark and NOT part of UNATTAINABLE (selftest [7] must not fire: the rule really does
# certify here, so STOP would be wrong). They are their own measurement, and the statistic is
# the share of certificates shipped from a dial that was wrong. No policy can win this; the
# question is how much it burns and how honestly it reports.
SELECTION = {
    # one 0.01 step spans 86 -> 114: no lattice dial is inside the feasible set, and the two
    # nearest are ~14 ELO out on either side, i.e. outside it by more than any estimate error.
    # The tool must pick a side and stop grinding. (The step is 86/114 rather than 88/112 on
    # purpose: at 88 a dial is outside the feasible set by 0.75 ELO, which is inside the noise
    # of every statistic below and would make the lottery column ambiguous.)
    "step28":  [(-0.70, 20.0), (0.50, 40.0), (0.60, 86.0), (0.61, 114.0), (1.00, 220.0),
                (2.00, 400.0)],
    # THE WHOLE LEVER IS 14 ELO LOW. Every dial sits at ~86 -- legal under the OLD rule, which
    # asked only for [70,130], and infeasible under the new one at every sample size.
    "plateau86": [(-0.70, 10.0), (0.40, 60.0), (0.70, 86.0), (2.00, 86.5), (11.50, 87.0)],
}
# Levers on which the target is genuinely unattainable. These are NOT part of the games benchmark
# -- no baseline can ever finish them, so including them would flatter the tool. They are the
# separate capability check that STOP fires when, and only when, it should.
UNATTAINABLE = {
    # the dial saturates below the band: gap never reaches 70 anywhere in the legal domain
    "saturate": [(-0.70, 2.0), (0.35, 10.0), (2.00, 30.0), (6.00, 48.0), (11.50, 55.0)],
    # the response steps over the whole band between two ADJACENT lattice dials: no legal dial
    # delivers a gap inside [70,130], and the bracket closes onto 0.60/0.61
    "ledge":    [(-0.70, 10.0), (0.60, 40.0), (0.61, 200.0), (2.00, 300.0), (11.50, 400.0)],
}
START = [(0.00, 90), (0.35, 137)]        # the campaign's real cold start
MAXGAMES = 40000


def truth_gap(name, x):
    pts = TRUTHS.get(name) or SELECTION.get(name) or UNATTAINABLE[name]
    return float(np.interp(float(x), [p[0] for p in pts], [p[1] for p in pts]))


class Table:
    """The opponent. One Bernoulli stream per dial, so two policies that play the same dial see
    the same games: cost DIFFERENCES between policies are then far better determined than levels."""

    def __init__(self, truth, seed):
        self.truth, self.seed, self.st = truth, seed, {}

    def play(self, x, k):
        key = round(float(x), 6)
        if key not in self.st:
            self.st[key] = np.random.default_rng(abs(hash((self.seed, key))) % (2 ** 31))
        p = float(p_of_gap(truth_gap(self.truth, key)))
        return float(self.st[key].binomial(int(k), p))


def _obs_gap(r):
    return float(gap_of_p(r["w"] / r["n"]))


def lin_place(rows, T):
    """Bracket-and-interpolate: the naive placement, and the one the campaign did by hand."""
    pts = sorted((round(r["x"], 6), _obs_gap(r)) for r in rows)
    below = [t for t in pts if t[1] <= T]
    above = [t for t in pts if t[1] > T]
    if below and above:
        a = max(below, key=lambda t: t[0])
        b = min(above, key=lambda t: t[0])
        if b[0] > a[0] and b[1] > a[1]:
            return snap(a[0] + (b[0] - a[0]) * (T - a[1]) / (b[1] - a[1]))
    near = sorted(pts, key=lambda t: abs(t[1] - T))[:2]
    if len(near) == 2:
        (x1, g1), (x2, g2) = sorted(near)
        if x2 > x1 and g2 > g1:
            return snap(min(max(x2 + (T - g2) / ((g2 - g1) / (x2 - x1)), X_LO), X_HI))
    x0 = max(t[0] for t in pts)
    return snap(x0 + (0.25 if pts[-1][1] < T else -0.25))


# Every policy below returns the SAME 4-tuple the tool's contract defines --
# (action, x_next, n_next, n_suggest) -- so that run_policy can obey it identically for all of
# them and no policy gets a driver written specially for it.
def make_baseline(kind, T, chunk, dial_cap=3000):
    """kind: 'move' re-places every chunk; 'sticky' only when the placement moves by > 0.02;
    'grind' stays until the dial certifies or is refuted, then re-places; 'capped' grinds but
    abandons a dial after dial_cap games, which is the strongest of the four and the one the
    tool used to lose to on a 1200 ELO/unit truth. No baseline ever returns STOP: a
    bracket-and-interpolate placement has no notion of an unattainable target, which is the
    capability the separate --bench STOP section measures."""
    state = {"x": None}

    def pol(rows):
        x = state["x"]
        if kind in ("grind", "capped") and x is not None:
            cur = [r for r in rows if abs(r["x"] - x) < 1e-9]
            if cur and not indep_refuted(cur[0]["w"], cur[0]["n"]) \
                    and not (kind == "capped" and cur[0]["n"] >= dial_cap):
                return "PLAY", x, chunk, chunk
        xn = lin_place(rows, T)
        if kind == "sticky" and x is not None and abs(xn - x) <= 0.02:
            xn = x
        state["x"] = xn
        return "PLAY", xn, chunk, chunk
    return pol


def make_tool(T, chunk, cap, trials, draws, seed, p_fid=0.0, look=LOOK, z_kill=Z_KILL,
              cover=True, **kw):
    """The tool as a policy. It returns its OWN action; run_policy in faithful mode obeys it, the
    way deepkyu_step.sh will. Nothing here discards a field of the contract.

    `look` is the interval at which the cost model believes the rule is looked at; `chunk` is the
    budget it hands the driver. They are different numbers and the file used to conflate them.
    `z_kill`/`cover` exist so that --bench can price W1 and W2 separately -- cover=False is the
    SHIPPED ONE-SIDED tool, z_kill=inf is the two-sided rule with no OVERSHOT exit."""
    cost = Cost(chunk=look, cap=cap, trials=trials, seed=seed, z_kill=z_kill, cover=cover)
    state = {"x": None}

    def pol(rows):
        d = decide(rows, T, cost, x_cur=state["x"], draws=draws, seed=seed, chunk=chunk,
                   p_fid=p_fid, **kw)
        state["x"] = d["x_next"]
        state["last"] = d
        return d["action"], d["x_next"], int(d["n_next"]), int(d["n_suggest"])
    pol.state = state                 # so the harness can read back WHY it stopped
    return pol


def run_policy(pol, truth, seed, T=100.0, chunk=CHUNK, maxgames=MAXGAMES, start=START,
               faithful=True, look=LOOK):
    """Drive a policy the way an automated driver would.

    faithful=True is the shipped contract: STOP ends the rung with no certificate, DONE ends it,
    and exactly n_next games are played. faithful=False is CHARITABLE mode -- the action field is
    discarded and n_suggest is played regardless, which is what the benchmark used to do and
    which cannot see a wrong STOP at all. The difference between the two IS the cost of D1.

    THE BUDGET IS PLAYED IN LOOKS, NOT IN ONE BLOCK, and under the two-sided rule that is a
    correctness requirement rather than realism for its own sake. deepkyu_auto.sh plays the
    budget in completion waves of 12 games and re-runs the tool after every one, so a certificate
    is collected the moment it exists; a harness that played the whole budget and only then
    looked would step straight over a window that is 880 games wide at an observed gap of +90,
    and would measure a driver nobody runs. `look` is that cadence.

    -> (games to a valid certificate or None, true gap of the certifying dial, rounds, how it
        ended, games actually played). The 5th field is what a STOPped or censored run really
        cost; the 1st is None for both, because neither produced a certificate.
    """
    tb = Table(truth, seed)
    rows, total = [], 0
    for x, n in start:
        rows.append({"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                     "w": tb.play(x, n), "n": float(n)})
        total += n
    rounds = 0
    while total < maxgames:
        for r in rows:
            if indep_certified(r["w"], r["n"]):
                return total, truth_gap(truth, r["x"]), rounds, "certified", total
        act, x, k, k_sug = pol(rows)
        if not in_domain(x):
            raise AssertionError("policy proposed an ILLEGAL dial x = %.4f" % x)
        if faithful:
            if act == "STOP":
                return None, float("nan"), rounds, "stopped", total
            if act == "DONE":
                break                      # the certify check at the top of the loop settles it
            if k <= 0:
                raise AssertionError("policy returned action %s with n_next = %d" % (act, k))
        else:
            k = k_sug                      # charitable: the action field is thrown away
        k = int(min(k, maxgames - total))
        if k <= 0:
            break
        hit = [r for r in rows if abs(r["x"] - x) < 1e-9]
        if not hit:
            rows.append({"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                         "w": 0.0, "n": 0.0})
            rows.sort(key=lambda r: r["x"])
            hit = [r for r in rows if abs(r["x"] - x) < 1e-9]
        played = 0
        while played < k:
            step = int(min(max(1, look), k - played))
            hit[0]["w"] += tb.play(x, step)
            hit[0]["n"] += step
            played += step
            total += step
            if indep_certified(hit[0]["w"], hit[0]["n"]):
                break                  # FREEZE: the certificate exists, and the next look could
                                       # take it away. This is the whole of cadence finding (B).
        rounds += 1
    for r in rows:
        if indep_certified(r["w"], r["n"]):
            return total, truth_gap(truth, r["x"]), rounds, "certified", total
    return None, float("nan"), rounds, "censored", total


def _agg(v, maxgames, T, cap=CAP_GAMES):
    """Aggregate one policy's runs. A censored or STOPPED run is charged the cap, which is a LOWER
    bound on what it really cost, and is counted as a failure to certify.

    `mean` is that cap-charged mean and is what the acceptance bar reads. It is also the statistic
    with the heaviest tail: on a steep truth the per-seed sd of the PAIRED difference in it is
    ~5030 games, all of it from runs at the 40000 cap, which needs ~2430 seeds to resolve to
    +/-200. So two more summaries are carried beside it, and every quoted comparison prints all
    three: `meanw`, the same mean WINSORISED at the per-dial abandon cap (sd 1423, ~195 seeds),
    and `ncens`, the number of runs that never certified -- which is where a censored policy's
    real cost lives and must not be left buried inside a mean."""
    keys = sorted(v)
    tot = [(v[k][0] if v[k][0] is not None else maxgames) for k in keys]
    dg = [abs(v[k][1] - T) for k in keys if v[k][0] is not None]
    ncert = sum(1 for k in keys if v[k][0] is not None)
    nstop = sum(1 for k in keys if v[k][3] == "stopped")
    # A STOP AT ROUND 0-2 AND A STOP AT ROUND 78 ARE DIFFERENT EVENTS NOW, and only the first is
    # the D1 defect. Under the ONE-SIDED rule "the truth is attainable, so any STOP is wrong" was
    # sound: more games at a dial could only help, so a lever that could deliver the target could
    # always still deliver it. The two-sided rule makes a lever DESTRUCTIBLE -- over-collect the
    # one dial whose true gap is inside 100 +- 11.25 and that dial can never certify again, and
    # on a 1400 ELO/unit lever there may be only one or two such dials. A late STOP is then the
    # correct answer to a state the games created, and stop_reason says so ("every legal dial in
    # the bracket has been refuted"). Measured: 1 of 48 seeds on `cliff`.
    nstop_early = sum(1 for k in keys if v[k][3] == "stopped" and v[k][2] <= 2)
    ncens = sum(1 for k in keys if v[k][3] == "censored")
    return {"med": float(np.median(tot)), "mean": float(np.mean(tot)),
            "lot": (float(np.mean([1.0 if g > MAX_MISS else 0.0 for g in dg])) if dg
                    else float("nan")),
            "q90": float(np.quantile(tot, 0.9)), "cert": ncert / float(len(keys)),
            "ncert": ncert, "N": len(keys), "nstop": nstop,
            "nstop_early": nstop_early, "ncens": ncens,
            "meanw": float(np.mean([min(t, float(cap)) for t in tot])),
            "nocert": len(keys) - ncert,
            "nclust": len(set(k[:2] for k in keys)),
            "fidmean": float(np.mean(dg)) if dg else float("nan"),
            "fid": float(np.median(dg)) if dg else float("nan")}


def _boot_paired(a, b, maxgames, seed=4242, nboot=4000, winsor=None):
    """Paired bootstrap 95% interval on the mean difference a - b, resampled over CLUSTERS.

    A cluster is (truth, table seed): the Bernoulli stream both policies played against. K runs of
    the tool at different internal Monte-Carlo seeds on the same table are K draws of ONE run, not
    K runs, so they are averaged inside the cluster and the resampling is over clusters. With one
    tool seed per table -- the default -- every cluster holds one pair and this is the interval it
    has always been. `winsor` charges every run at most that many games, which is the form of this
    difference that is not dominated by the 40000-game cap."""
    keys = sorted(set(a) & set(b))
    cl = {}
    for k in keys:
        ga, gb = float(a[k][0] or maxgames), float(b[k][0] or maxgames)
        if winsor:
            ga, gb = min(ga, float(winsor)), min(gb, float(winsor))
        cl.setdefault(k[:2], []).append(ga - gb)
    d = np.array([float(np.mean(cl[c])) for c in sorted(cl)], float)
    if not len(d):
        return float("nan"), float("nan"), float("nan")
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(d), size=(nboot, len(d)))
    bs = d[idx].mean(axis=1)
    return float(d.mean()), float(np.quantile(bs, 0.025)), float(np.quantile(bs, 0.975))


def _meanfid(v, T):
    f = [abs(v[k][1] - T) for k in sorted(v) if v[k][0] is not None]
    return float(np.mean(f)) if f else float("nan")


def _boot_fid(a, b, T, seed=9191, nboot=4000):
    """Paired bootstrap 95% interval on the difference of MEDIAN |delivered gap - T|. Two point
    medians of a discrete quantity differing by 0.01 ELO is not a difference, and the acceptance
    bar should not be decided by one."""
    keys = [k for k in sorted(set(a) & set(b)) if a[k][0] is not None and b[k][0] is not None]
    if not keys:
        return float("nan"), float("nan"), float("nan")
    x = np.array([abs(a[k][1] - T) for k in keys])
    y = np.array([abs(b[k][1] - T) for k in keys])
    cl = {}
    for i, k in enumerate(keys):
        cl.setdefault(k[:2], []).append(i)
    grp = [np.array(cl[c], int) for c in sorted(cl)]
    rng = np.random.default_rng(seed)
    cidx = rng.integers(0, len(grp), size=(nboot, len(grp)))
    if all(len(g) == 1 for g in grp):
        idx = np.concatenate([g for g in grp])[cidx]       # one run per cluster: unchanged
        d = np.median(x[idx], axis=1) - np.median(y[idx], axis=1)
    else:
        d = np.empty(nboot)
        for t in range(nboot):
            ii = np.concatenate([grp[c] for c in cidx[t]])
            d[t] = np.median(x[ii]) - np.median(y[ii])
    return float(np.median(x) - np.median(y)), float(np.quantile(d, 0.025)), \
        float(np.quantile(d, 0.975))


def _crit_clusters(v, maxgames, T, cap):
    """One policy's runs, grouped by cluster: (games charged, certified flags, |gap - T| of the
    certified runs, games winsorised at the per-dial abandon cap)."""
    cl = {}
    for k in sorted(v):
        r = v[k]
        g = float(r[0]) if r[0] is not None else float(maxgames)
        c = cl.setdefault(k[:2], [[], [], [], []])
        c[0].append(g)
        c[1].append(1.0 if r[0] is not None else 0.0)
        c[3].append(min(g, float(cap)))
        if r[0] is not None:
            c[2].append(abs(r[1] - T))
    return {c: tuple(np.array(x, float) for x in cl[c]) for c in cl}


def _crit_stat(parts):
    g = np.concatenate([p[0] for p in parts])
    c = np.concatenate([p[1] for p in parts])
    w = np.concatenate([p[3] for p in parts])
    f = np.concatenate([p[2] for p in parts])
    if not f.size:
        f = np.array([float("nan")])
    return {"med": float(np.median(g)), "mean": float(np.mean(g)),
            "q90": float(np.quantile(g, 0.9)), "cert": float(np.mean(c)),
            "meanw": float(np.mean(w)), "fid": float(np.median(f)),
            "lot": float(np.mean(f > MAX_MISS)) if np.isfinite(f).all() else float("nan"),
            "fidmean": float(np.mean(f))}


def _boot_crits(a, b, maxgames, T, cap, seed=5151, nboot=1500):
    """Paired CLUSTER bootstrap on every acceptance criterion at once: statistic(a) - statistic(b),
    resampled over (truth, table seed).

    This exists because the acceptance table was read as evidence without one. At 12 seeds the
    median-games difference has a sampling sd of 423 games and the mean-games difference +/-2846,
    and |delivered gap - T| on a steep truth takes only the values {0, 12, 24} -- so a bare
    median of it flips on a single seed. Every criterion the VERDICT prints now carries the
    interval it was measured to, and a row whose interval contains zero is a TIE, not a loss."""
    A = _crit_clusters(a, maxgames, T, cap)
    B = _crit_clusters(b, maxgames, T, cap)
    keys = sorted(set(A) & set(B))
    if not keys:
        return {}
    pa, pb = _crit_stat([A[k] for k in keys]), _crit_stat([B[k] for k in keys])
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(keys), size=(nboot, len(keys)))
    D = {k: np.empty(nboot) for k in pa}
    for t in range(nboot):
        sel = idx[t]
        sa = _crit_stat([A[keys[i]] for i in sel])
        sb = _crit_stat([B[keys[i]] for i in sel])
        for k in D:
            D[k][t] = sa[k] - sb[k]
    out = {}
    for k in D:
        v = D[k][np.isfinite(D[k])]
        out[k] = (pa[k] - pb[k],
                  float(np.quantile(v, 0.025)) if v.size else float("nan"),
                  float(np.quantile(v, 0.975)) if v.size else float("nan"))
    return out


BENCH_MIN_SEEDS = 48     # below this, no per-truth row and no criterion is resolved well enough
                         # to be quoted as a win or a loss. MEASURED, not chosen: subsampling
                         # 12-seed benches out of 240 seeds on the c1200 truth, P(the median
                         # difference reads >= +540 games) = 0.227 and P(the |gap-T| median reads
                         # +6.0) = 0.132 -- purely from which seeds were drawn. Both of the
                         # "steep-response weaknesses" W1 reported are inside that noise.
TOOL_SEED_STEP = 1009    # internal Monte-Carlo seed stride for --tool-seeds


def calibrate(args):
    """Sweep p_fid and report, for each value, the median |delivered gap - T| against the best
    baseline and what the constraint costs in games. This is how P_FID was set; re-run it after
    any change to the fit or the cost, on BOTH seed blocks, because a value tuned on one block of
    seeds is a value tuned on noise.

    WHAT IT STILL MEANS AFTER THE GOAL CHANGE, which is much less than it did. p_fid is no
    longer charged when any dial can certify -- the two-sided rule puts the target preference
    inside P(certify), and a separate exchange rate double-counts it -- so this sweep now moves
    only the EXPLORATION charge on a lever where nothing can certify (P_EXPLORE, which the sweep
    cannot lower below its floor). Expect a flat table on any truth with a dial near the centre.
    It is kept because P_EXPLORE is still a calibrated constant and this is the harness that
    calibrated it."""
    T = args.target if args.target is not None else 100.0
    truths = args.truths.split(",") if args.truths else list(TRUTHS)
    grid = [float(v) for v in args.pfid_grid.split(",")] if args.pfid_grid else \
        [0.0, 100.0, 200.0, 400.0, 800.0, 1600.0]
    blocks = [(0, args.seeds), (args.seeds, 2 * args.seeds)]
    print("== p_fid calibration: fidelity against the best baseline, and what it costs ==")
    for lo, hi in blocks:
        bs = {}
        for kind in ("move", "sticky", "grind", "capped"):
            v = {(tr, sd): run_policy(make_baseline(kind, T, args.chunk), tr, sd, T, args.chunk,
                                      args.maxgames, faithful=True, look=args.look)
                 for tr in truths for sd in range(lo, hi)}
            bs[kind] = (_agg(v, args.maxgames, T), v)
        bfid = min(bs[k][0]["fid"] for k in bs)
        bmed = min(bs[k][0]["med"] for k in bs)
        base0 = None
        print("seeds %d-%d   best baseline: median %.0f games, |gap-T| %.2f ELO"
              % (lo, hi - 1, bmed, bfid))
        print("  %-9s %9s %9s %9s %9s  %s" % ("p_fid", "median", "mean", "|gap-T|", "vs p_fid=0",
                                              "verdict"))
        for pf in grid:
            v = {(tr, sd): run_policy(make_tool(T, args.chunk, args.cap, args.trials, args.draws,
                                                args.seed, pf),
                                      tr, sd, T, args.chunk, args.maxgames, faithful=True,
                                      look=args.look)
                 for tr in truths for sd in range(lo, hi)}
            s = _agg(v, args.maxgames, T)
            if base0 is None:
                base0 = v
            dg = _boot_paired(v, base0, args.maxgames)[0]
            print("  %-9.0f %9.0f %9.0f %9.2f %+9.0f  %s"
                  % (pf, s["med"], s["mean"], s["fid"], dg,
                     ("fidelity OK" if s["fid"] <= bfid else "fidelity LOSES")
                     + (", games OK" if s["med"] <= bmed else ", GAMES LOSE")))
        print()
    print("ship the smallest p_fid whose fidelity is OK on BOTH blocks; its 'vs p_fid=0' column is")
    print("the price of the constraint in games, which the acceptance run then quotes.")
    return 0


def bench(args):
    T = args.target if args.target is not None else 100.0
    truths = args.truths.split(",") if args.truths else list(TRUTHS)
    seeds = list(range(args.seeds))
    K = max(1, int(getattr(args, "tool_seeds", 1)))
    # THE TOOL'S OWN MONTE CARLO IS A NOISE SOURCE, and it is not the table's. Within one table
    # seed the scatter of total games over internal seeds is sd 601, and over five internal seeds
    # the c1200 mean ran 4457..4794 -- with the shipped 20260911 the WORST of the five. K > 1
    # averages each place2 row over K internal seeds against the SAME Bernoulli tables, which is
    # free variance reduction: the baselines do not read the seed at all, so they are run once and
    # their result is carried across the K draws. K = 1 reproduces the shipped table exactly.
    hk = getattr(args, "het_k", HET_K)
    ak = float(getattr(args, "acc_k", ACC_K))
    sa = float(getattr(args, "sig_acc", SIG_SLOPE_ACC))
    mk_tool = lambda pf: (lambda j=0: make_tool(T, args.chunk, args.cap, args.trials, args.draws,
                                                args.seed + TOOL_SEED_STEP * j, pf,
                                                look=args.look, het_k=hk, acc_k=ak, sig_acc=sa))
    # place2 appears three times on purpose:
    #   FAITHFUL     the shipped contract, action obeyed. This is the only row that may be quoted.
    #   charitable   the action field discarded, n_suggest played anyway -- what the benchmark did
    #                before, and the reason a STOP emitted at round 0 was invisible.
    #   p_fid=0      the same tool with target fidelity unpriced, so the price of D3 is a number.
    mk_legacy = lambda j=0: make_tool(T, args.chunk, args.cap, args.trials, args.draws,
                                      args.seed + TOOL_SEED_STEP * j,
                                      0.0 if args.p_fid is None else args.p_fid,
                                      look=args.look, legacy_stop=True, het_k=hk,
                                      acc_k=ak, sig_acc=sa)
    _pf = 0.0 if args.p_fid is None else args.p_fid
    # THE TWO ABLATIONS THAT PRICE THIS REWRITE. `1sided` is the tool as it shipped -- its cost
    # model believes certification is containment alone -- and it is the row that shows W1 is a
    # real defect rather than a tidier docstring. `nokill` is the two-sided rule WITHOUT the
    # OVERSHOT exit: W1 alone, which is the combination that must NOT be shipped.
    mk_1sided = lambda j=0: make_tool(T, args.chunk, args.cap, args.trials, args.draws,
                                      args.seed + TOOL_SEED_STEP * j, _pf, look=args.look,
                                      cover=False, het_k=hk, acc_k=ak, sig_acc=sa)
    mk_nokill = lambda j=0: make_tool(T, args.chunk, args.cap, args.trials, args.draws,
                                      args.seed + TOOL_SEED_STEP * j, _pf, look=args.look,
                                      z_kill=float("inf"), het_k=hk, acc_k=ak, sig_acc=sa)
    pols = [("place2", mk_tool(_pf), True),
            ("place2:chrty", mk_tool(_pf), False),
            ("place2:oldstop", mk_legacy, True),
            ("place2:1sided", mk_1sided, True),
            ("place2:nokill", mk_nokill, True),
            ("base:move", lambda j=0: make_baseline("move", T, args.chunk), True),
            ("base:sticky", lambda j=0: make_baseline("sticky", T, args.chunk), True),
            ("base:grind", lambda j=0: make_baseline("grind", T, args.chunk), True),
            ("base:capped", lambda j=0: make_baseline("capped", T, args.chunk), True)]
    res = {p[0]: {} for p in pols}
    t0 = time.time()
    for tr in truths:
        for sd in seeds:
            for nm, mk, faith in pols:
                reps = K if nm.startswith("place2") else 1
                for j in range(reps):
                    res[nm][(tr, sd, j)] = run_policy(mk(j), tr, sd, T, args.chunk, args.maxgames,
                                                      faithful=faith, look=args.look)
                for j in range(reps, K):            # a baseline does not read the internal seed
                    res[nm][(tr, sd, j)] = res[nm][(tr, sd, 0)]
            if args.verbose:
                print("  %-8s seed %d: %s" % (tr, sd, "  ".join(
                    "%s %s" % (nm, "cens" if res[nm][(tr, sd, 0)][0] is None
                               else "%d" % res[nm][(tr, sd, 0)][0]) for nm, _, _ in pols)),
                    file=sys.stderr)
    stat = {nm: _agg(res[nm], args.maxgames, T, args.cap) for nm, _, _ in pols}
    base_names = [p[0] for p in pols if p[0].startswith("base:")]

    print("== acceptance: total games to a VALID certificate (judged by indep_certified) ==")
    print("%d truths x %d table seeds = %d paired clusters x %d tool Monte-Carlo seed%s = %d runs"
          % (len(truths), len(seeds), len(truths) * len(seeds), K, "" if K == 1 else "s",
             len(truths) * len(seeds) * K))
    print("per place2 policy, chunk %d, per-dial abandon cap %d, run cap %d games, "
          "planning dispersion phi = %.2f, %.0f s"
          % (args.chunk, args.cap, args.maxgames, PHI_PLAN, time.time() - t0))
    print("`place2` is run FAITHFULLY: its action field is obeyed, so a STOP ends the rung with no")
    print("certificate and is charged the run cap. `place2:chrty` is the same tool with the action")
    print("discarded -- the charitable mode every earlier benchmark number was produced in.")
    if len(seeds) < BENCH_MIN_SEEDS:
        print()
        print("!! %d table seeds. NOTHING BELOW IS RESOLVED WELL ENOUGH TO QUOTE AS A WIN OR A "
              "LOSS" % len(seeds))
        print("   on any single truth: at 12 seeds the paired median-games difference has a "
              "sampling")
        print("   sd of 423 games and the mean +/-2846, and on a steep truth |gap-T| takes only "
              "the")
        print("   values {0, 12, 24}, so its median flips on one seed. Run --seeds %d before "
              "quoting" % BENCH_MIN_SEEDS)
        print("   a per-truth row; every interval printed below is the half-width actually "
              "achieved.")
    print()
    print("%-13s %8s %9s %9s %9s %9s %6s %6s %8s %7s" %
          ("policy", "cert/N", "median", "mean*", "meanw+", "q90", "|gT|md", "|gT|mn", "no-cert",
           "STOPs"))
    for nm, _, _ in pols:
        st = stat[nm]
        print("%-13s %8s %9.0f %9.0f %9.0f %9.0f %6.1f %6.1f %8d %7d"
              % (nm, "%d/%d" % (st["ncert"], st["N"]), st["med"], st["mean"], st["meanw"],
                 st["q90"], st["fid"], st["fidmean"], st["nocert"], st["nstop"]))
    print("* mean counts a censored or STOPPED run as the %d-game cap, so it is a LOWER BOUND on"
          % args.maxgames)
    print("  the cost of any policy that failed to certify -- every such run is really worse.")
    print("+ meanw is the same mean WINSORISED at the per-dial abandon cap of %d games, and"
          % args.cap)
    print("  `no-cert` is how many runs never certified at all. The cap-charged mean mixes those")
    print("  two facts into one number whose paired sd is 5030 games; winsorised it is 1423, and")
    print("  the censoring it hides is where a baseline's real cost lives -- 5 runs in 240 on the")
    print("  steep truth, each charged %d games it would never have stopped spending."
          % args.maxgames)
    print()

    # -- D1: what obeying the action costs ---------------------------------
    print("-- the price of the action contract (D1) ------------------------------------------")
    df, lo, hi = _boot_paired(res["place2"], res["place2:chrty"], args.maxgames)
    nstop = stat["place2"]["nstop"]
    print("three rows, all on attainable targets, where a STOP is always wrong:")
    print("  place2          the shipped stop rule, action OBEYED  -> %d STOPs (%d of them at "
          "round <= 2, which is the D1 defect), %d/%d certified, mean %.0f games"
          % (nstop, stat["place2"]["nstop_early"], stat["place2"]["ncert"],
             stat["place2"]["N"], stat["place2"]["mean"]))
    print("  place2:chrty    the same tool, action DISCARDED       -> %d/%d certified, mean %.0f"
          % (stat["place2:chrty"]["ncert"], stat["place2:chrty"]["N"],
             stat["place2:chrty"]["mean"]))
    print("  place2:oldstop  STOP whenever V* hit its ceiling, obeyed -> %d wrong STOPs, %d/%d "
          "certified, mean %.0f"
          % (stat["place2:oldstop"]["nstop"], stat["place2:oldstop"]["ncert"],
             stat["place2:oldstop"]["N"], stat["place2:oldstop"]["mean"]))
    print("faithful vs charitable, paired: mean difference %+.0f games [%+.0f, %+.0f] 95%% boot."
          % (df, lo, hi))
    do, lo2, hi2 = _boot_paired(res["place2:oldstop"], res["place2"], args.maxgames)
    print("THE SIZE OF D1: obeying the OLD stop rule costs %+.0f games per rung [%+.0f, %+.0f]"
          % (do, lo2, hi2))
    print("against obeying the fixed one, and abandons %d rungs that were going to certify. That"
          % stat["place2:oldstop"]["nstop"])
    print("is what the charitable benchmark could not see, because it threw the action away.")
    if stat["place2"]["nstop_early"]:
        print("!! %d WRONG STOPs REMAIN in the shipped rule -- each at round <= 2, i.e. a rung"
              % stat["place2"]["nstop_early"])
        print("   abandoned before it was measured. This is a SHIP BLOCKER.")
    elif nstop:
        print("%d LATE STOP(s), none at round <= 2. Under the two-sided rule that is not"
              % nstop)
        print("automatically wrong: over-collecting the one dial whose true gap is inside")
        print("100 +- %.1f kills THAT dial for good, and on a steep lever there may be only one"
              % MAX_MISS)
        print("or two such dials, so a lever that WAS attainable can stop being attainable. The")
        print("stop_reason on each is a statement about the data. Read them before dismissing")
        print("them -- and if a late STOP is common, the fix is not the stop rule, it is not")
        print("over-collecting in the first place.")
    else:
        print("no STOP at all on an attainable truth: faithful and charitable take the same")
        print("decisions everywhere, so the benchmark below is of the tool a driver runs.")
    print()

    # -- W1/W2: what the two-sided rule and the OVERSHOT exit are worth ----
    print("-- the price of the goal change (W1, W2) -----------------------------------------")
    print("place2:1sided is this same tool with its COST MODEL believing the old one-sided rule")
    print("(containment only). place2:nokill is the two-sided rule with no OVERSHOT exit. Both")
    print("are judged by indep_certified, which now implements the two-sided rule independently.")
    for nm in ("place2:1sided", "place2:nokill"):
        dd, dlo, dhi = _boot_paired(res[nm], res["place2"], args.maxgames)
        print("  %-14s %d/%d certified, mean %6.0f games, lottery %s  vs place2 %+6.0f "
              "[%+6.0f,%+6.0f]"
              % (nm, stat[nm]["ncert"], stat[nm]["N"], stat[nm]["mean"],
                 "n/a" if stat[nm]["lot"] != stat[nm]["lot"] else "%.2f" % stat[nm]["lot"],
                 dd, dlo, dhi))
    print("  %-14s %d/%d certified, mean %6.0f games, lottery %s"
          % ("place2", stat["place2"]["ncert"], stat["place2"]["N"], stat["place2"]["mean"],
             "n/a" if stat["place2"]["lot"] != stat["place2"]["lot"]
             else "%.2f" % stat["place2"]["lot"]))
    print("a ONE-SIDED cost model does not merely mis-price: it declares DONE at a state the")
    print("judge does not certify, which ends the run with nothing. W1 and W2 must land together")
    print("-- the two-sided rule WITHOUT an abandon exit grinds a dead dial to the cap.")
    print()
    print("-- what happened to the fidelity price (W3) ---------------------------------------")
    print("p_fid = %.0f. It is no longer a price on target miss: with every target pinned at 100"
          % _pf)
    print("there is no span budget to allocate, and the two-sided rule puts the preference inside")
    print("P(certify) (.99 at a true gap of 100, .78 at 90, .51 at 85). The constant survives only")
    print("as P_EXPLORE = %.0f on a lever where NOTHING can certify, where it is an exploration"
          % P_EXPLORE)
    print("gradient and not an exchange rate. `lottery` below is what replaced it as a REPORT:")
    print("the fraction of certificates shipped from a dial whose true gap is more than %.1f ELO"
          % MAX_MISS)
    print("off centre -- certificates the rule permits and no pricing inside this tool can stop.")
    print()
    print("paired on the CLUSTER -- one truth, one table seed, common random numbers per dial --")
    print("because K tool draws on one table are one run, not K. A win is a cluster, not a run:")
    print("%-14s %6s %6s %6s %10s %9s %21s %21s"
          % ("place2 vs", "wins", "loss", "ties", "med diff", "sign test",
             "mean diff [95% boot]", "winsorised [95% boot]"))
    for b in base_names:
        wn = ls = ti = 0
        cl = {}
        for k in sorted(res["place2"]):
            if k not in res[b]:
                continue
            a = res["place2"][k][0] or args.maxgames
            c = res[b][k][0] or args.maxgames
            cl.setdefault(k[:2], []).append(float(a) - float(c))
        diffs = [float(np.mean(cl[c])) for c in sorted(cl)]
        for dd in diffs:
            wn += int(dd < 0); ls += int(dd > 0); ti += int(dd == 0)
        md, blo, bhi = _boot_paired(res["place2"], res[b], args.maxgames)
        wd, wlo, whi = _boot_paired(res["place2"], res[b], args.maxgames, winsor=args.cap)
        print("%-14s %6d %6d %6d %+10.0f %9s   %+6.0f [%+6.0f,%+6.0f]   %+6.0f [%+6.0f,%+6.0f]"
              % (b, wn, ls, ti, np.median(diffs), "p = %.2g" % sign_test(wn, ls), md, blo, bhi,
                 wd, wlo, whi))
    print("the winsorised column charges every run at most the %d-game abandon cap, so it is the"
          % args.cap)
    print("column that is not dominated by whichever policy hit the %d-game run cap; the "
          "`no-cert`" % args.maxgames)
    print("column above is the rest of that story and the two must be read together.")
    print()
    print("PER TRUTH. Every number here is a %d-cluster measurement; the line under each block is"
          % len(seeds))
    print("the paired difference against that truth's best baseline WITH ITS INTERVAL, because a")
    print("bare per-truth median is exactly what was read as a steep-response weakness when the")
    print("same measurement at 240 seeds reversed its sign.")
    print("%-9s %-13s %8s %8s %8s %8s %8s" % ("truth", "", "median", "cert", "|gT|md", "|gT|mn",
                                              "rounds"))
    ok = True
    for tr in truths:
        for nm, _, _ in pols:
            v = {k: res[nm][k] for k in res[nm] if k[0] == tr}
            st = _agg(v, args.maxgames, T, args.cap)
            rn = [v[k][2] for k in sorted(v)]
            print("%-9s %-13s %8.0f %8s %8.1f %8.1f %8.0f"
                  % (tr if nm == "place2" else "", nm, st["med"], "%d/%d" % (st["ncert"], st["N"]),
                     st["fid"], st["fidmean"], np.median(rn)))
        mine = {k: res["place2"][k] for k in res["place2"] if k[0] == tr}
        bt = min(base_names,
                 key=lambda b: _agg({k: res[b][k] for k in res[b] if k[0] == tr},
                                    args.maxgames, T, args.cap)["med"])
        theirs = {k: res[bt][k] for k in res[bt] if k[0] == tr}
        cb = _boot_crits(mine, theirs, args.maxgames, T, args.cap,
                         seed=7000 + 13 * truths.index(tr), nboot=800)
        gd, glo, ghi = cb.get("mean", (float("nan"),) * 3)
        fd, flo, fhi = cb.get("fidmean", (float("nan"),) * 3)
        resolved = (glo > 0 or ghi < 0)
        print("%-9s %-13s vs %-11s mean games %+6.0f [%+6.0f,%+6.0f]   mean |gap-T| %+5.2f "
              "[%+5.2f,%+5.2f]   games: %s"
              % ("", "", bt, gd, glo, ghi, fd, flo, fhi,
                 ("RESOLVED for place2" if gd < 0 else "RESOLVED against place2")
                 if resolved else "TIE, the CI spans 0"))
        if resolved and gd > 0:
            ok = False
        print()

    # -- SELECTION levers: the rule permits a certificate that no dial deserves ----
    print("-- levers where EVERY dial is outside the feasible set (%.1f..%.1f) -----------------"
          % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
    print("The two-sided rule still certifies here, about half the time, and the certificate it")
    print("produces reads near +95 whatever the truth -- the coverage gate is a selection ON the")
    print("point estimate, so a stopped sample that passes it is pulled toward 100 by")
    print("construction. NO POLICY CAN WIN THIS and none of it feeds the verdict: it is the")
    print("GOAL's property, measured. What a policy can do is burn less and report it.")
    print("%-11s %-13s %8s %9s %10s %9s  %s"
          % ("lever", "policy", "cert/N", "games", "|gap-100|", "lottery", "note"))
    print("(|gap-100| is the MEDIAN over runs of the shipped dial's TRUE distance from the")
    print("centre -- not the median shipped gap, which on a lever with dials at 86 and 114 and")
    print("an even number of runs averages the two and reads a triumphant +100.)")
    for tr in sorted(SELECTION):
        for nm, mk, faith in pols:
            if not faith or nm in ("place2:chrty",):
                continue
            v = {}
            for sd in seeds:
                v[(tr, sd)] = run_policy(mk(0), tr, sd, T, args.chunk, args.maxgames,
                                         faithful=True, look=args.look)
            st = _agg(v, args.maxgames, T, args.cap)
            print("%-11s %-13s %8s %9.0f %10s %9s  %s"
                  % (tr if nm == "place2" else "", nm, "%d/%d" % (st["ncert"], st["N"]),
                     st["med"],
                     "n/a" if st["fid"] != st["fid"] else "%10.1f" % st["fid"],
                     "n/a" if st["lot"] != st["lot"] else "%.2f" % st["lot"],
                     "every certificate here is off target by construction"
                     if nm == "place2" else ""))
        print()

    # -- STOP capability, on levers where the target really is unattainable --
    print("-- does STOP fire when, and ONLY when, it should? ---------------------------------")
    print("levers on which NO legal dial delivers the target. No baseline can finish these; the")
    print("question is whether the tool quits, and how many games it burns before it does.")
    print("%-10s %-13s %9s %9s  %s" % ("lever", "policy", "outcome", "games", "reason"))
    print("(`games` is what the policy actually played, not the cap it is charged elsewhere.)")
    stops_ok = True
    for tr in sorted(UNATTAINABLE):
        for nm, mk, faith in pols:
            if not faith or nm in ("place2:1sided", "place2:nokill", "place2:oldstop"):
                continue
            ends, gms, reason = [], [], ""
            for sd in seeds[:max(1, min(4, len(seeds)))]:
                pl = mk(0)
                g, dg, rn, end, played = run_policy(pl, tr, sd, T, args.chunk, args.maxgames,
                                                    faithful=True, look=args.look)
                ends.append(end)
                gms.append(played)
                if end == "stopped" and not reason:
                    reason = (getattr(pl, "state", {}).get("last", {}) or {}).get("stop_reason", "")
            nstop = sum(1 for e in ends if e == "stopped")
            ncert = sum(1 for e in ends if e == "certified")
            if nm == "place2" and nstop != len(ends):
                stops_ok = False
            print("%-10s %-13s %9s %9.0f  %s"
                  % (tr, nm, "%d stop" % nstop if nstop else ("%d cert" % ncert if ncert
                                                             else "censored"),
                     np.median(gms), reason[:74]))
        print()
    if stops_ok:
        print("the tool quit on every unattainable lever; no baseline did (they cannot).")
    else:
        print("!! the tool FAILED to quit on an unattainable lever.")
    print()

    # Each criterion is judged against the BEST baseline ON THAT CRITERION, which is a stiffer
    # comparator than any single baseline: no one baseline has to be good at all five.
    crit = [("median games", "med", -1), ("mean games", "mean", -1),
            ("mean games, winsor", "meanw", -1), ("q90 games", "q90", -1),
            ("certification rate", "cert", +1), ("|delivered gap - T| med", "fid", -1),
            ("|delivered gap - T| mean", "fidmean", -1),
            # NEW, and it is the criterion the old bench could not have: the fraction of
            # certificates bought at a dial whose TRUE gap is outside the feasible set. It is
            # printed, NOT gated -- on a lever that is 12 ELO low every policy ships 12 ELO off
            # and the rule permits it, so gating on it would fail the tool for the goal's own
            # property. It is here so that a policy that wins on games by buying lottery tickets
            # cannot do it invisibly.
            ("lottery certificates", "lot", -1)]
    print("VERDICT, place2 run FAITHFULLY, each criterion against the BEST baseline on it.")
    print("The interval is the paired CLUSTER bootstrap against that same baseline: a criterion")
    print("whose interval contains 0 is NOT a win and NOT a loss, it is an unresolved measurement,")
    print("and the acceptance bar is the point comparison it has always been -- printed here with")
    print("the error it was measured to, so it can no longer be read as more than it is.")
    allok = True
    cbs = {}
    for label, key, sgn in crit:
        mine = stat["place2"][key]
        theirs = (max if sgn > 0 else min)(stat[b][key] for b in base_names)
        bb = (max if sgn > 0 else min)(base_names, key=lambda b: stat[b][key])
        good = (mine >= theirs) if sgn > 0 else (mine <= theirs)
        if key in ("med", "mean", "q90", "cert", "fid"):      # the five the bar has always used
            allok &= good
        if bb not in cbs:
            cbs[bb] = _boot_crits(res["place2"], res[bb], args.maxgames, T, args.cap,
                                  seed=9100, nboot=1200)
        cb = cbs[bb]
        dd, dlo, dhi = cb.get(key, (float("nan"),) * 3)
        small = key in ("cert", "fid", "fidmean", "lot")
        fmt = "%8.2f" if small else "%8.0f"
        dfmt = "%+7.2f [%+7.2f,%+7.2f]" if small else "%+7.0f [%+7.0f,%+7.0f]"
        tag = ("" if (dlo > 0 or dhi < 0) else
               (" (exact tie)" if dlo == dhi == 0.0 else " (unresolved)"))
        print(("  %-25s place2 " + fmt + "  best " + fmt + "  " + dfmt + "  %s%s")
              % (label, mine, theirs, dd, dlo, dhi, "beats/ties" if good else "LOSES", tag))
    print("  %-22s %9d wrong   %s   (%d late STOP(s), see D1)"
          % ("STOP before round 3", stat["place2"]["nstop_early"],
             "clean" if not stat["place2"]["nstop_early"] else "SHIP BLOCKER",
             stat["place2"]["nstop"] - stat["place2"]["nstop_early"]))
    allok &= (stat["place2"]["nstop_early"] == 0) and stops_ok
    print("VERDICT: %s" % ("PASS" if allok else
                           "FAIL -- a rejected tool is a valid outcome; do not ship this"))
    if not ok:
        print("         (at least one per-truth mean-games difference above is RESOLVED against")
        print("          place2 -- its interval excludes zero. That is a per-truth report, not")
        print("          the acceptance bar, which is the aggregate block just printed; but an")
        print("          interval that excludes zero is a real per-truth loss and is worth")
        print("          chasing, unlike a bare median that merely reads high.)")
    return 0 if allok else 1


JSON_CONTRACT = 3        # bumped whenever the meaning of a field changes. 2 -> 3: the rule is
                         # two-sided (z_cover, band_mid), a dial can be OVERSHOT (x_cur_dead,
                         # dead_dials), a certificate has a lifetime (survives_to), and p_fid is
                         # no longer a fidelity price.


def _finite(o):
    """Recursively replace every non-finite float with null. RFC 8259 has no NaN and no Infinity;
    a bare NaN in the output file is a parse error in every strict reader, and the saturated-lever
    branch produced one every time (forward.med is nan whenever nothing certifies)."""
    if isinstance(o, dict):
        return {k: _finite(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_finite(v) for v in o]
    if isinstance(o, (bool, int, str)) or o is None:
        return o
    if isinstance(o, float) or isinstance(o, np.floating):
        f = float(o)
        return f if math.isfinite(f) else None
    if isinstance(o, np.integer):
        return int(o)
    return o


def decision_json(d, T, rank=None, strong=None):
    """The machine-readable form of the ACTION, for a driver. Everything a driver must obey, plus
    everything it must be able to escalate on. Strict JSON: no NaN, no Infinity, ever."""
    b = d.get("best") or {}
    fs = d.get("fwd") or {}
    fit = d.get("fit")
    blob = {
        "contract": JSON_CONTRACT,
        # -- the three fields a driver obeys -------------------------------
        "action": d["action"],                    # PLAY | DONE | STOP
        "x_next": d["x_next"],
        "n_next": d["n_next"],                    # 0 unless action == PLAY
        # -- identity ------------------------------------------------------
        "target": float(T),
        "band": [BAND_LO, BAND_HI],
        "band_mid": BAND_MID,
        "z_stop": Z_STOP,
        "z_cover": Z_COVER,
        "z_kill": Z_KILL,
        "n_open": N_OPEN,
        "feasible_true_gap": [BAND_MID - MAX_MISS, BAND_MID + MAX_MISS],
        # FOR THE DRIVER'S ANTI-THRASH HOLD. deepkyu_auto.sh defers a requested dial change and
        # plays the wave at the dial ALREADY SET until HOLD chunk-equivalents have been served.
        # If that dial is dead those waves are pure waste and deepen the overshoot, so the hold
        # must be gated on this field: the hold already never blocks DONE or STOP, and it must
        # also never block a move off a dead dial.
        "x_cur_dead": bool(d.get("x_cur_dead", False)),
        "dead_dials": d.get("dead_dials") or None,
        "x_cur": d.get("x_cur"),
        "rank": rank,
        "strong": strong,
        "bot": bot_for(d["x_next"], rank) if rank else None,
        "moved": bool(d.get("x_cur") is not None
                      and abs(float(d["x_next"]) - float(d["x_cur"])) > 1e-9),
        # -- why, and how much of it is a prior ----------------------------
        "n_suggest": d.get("n_suggest"),          # informational; never obey this instead of n_next
        "stop_reason": d.get("stop_reason") or None,
        "hopeless": bool(d.get("hopeless", False)),
        "room": d.get("room"),
        "why_room": d.get("why_room"),
        "p_safe": b.get("p_safe"),
        "p_band": b.get("p_band"),
        "p_centre": b.get("p_centre"),           # P(true gap inside the FEASIBLE set), the filter
        "lottery_share": b.get("lot_share"),     # share of P(certify) from worlds where it is right
        # P(this dial ever certifies from its own bank). THE FIELD'S MEANING IS FIXED: it is
        # P(certify), even when --obj-k makes the value iteration run on P(certify AND near 100).
        # A driver reads this name; it must not change meaning under a flag.
        "resid_p": b.get("W_cert", b.get("W")),
        "resid_p_objective": b.get("W"),         # the weight the fixed point actually used
        "n_kill": b.get("n_kill"),
        "prior_dependent": (None if not b else bool(b.get("p_safe", 0.0) < 0.90)),
        "prior_free_dial": b.get("prior_free"),
        "med_gap": b.get("med"),
        "gap_q05_q95": list(b.get("gd_q", ())) or None,
        "expected_target_miss": b.get("miss"),          # E[|gap-T| | it certifies HERE]
        "expected_ladder_miss": b.get("M"),             # W*miss + (1-W)*M*: what the rung ships
        "miss_star": d.get("Mstar"),                    # the continuation's miss, same fixed point
        "expected_distance": b.get("miss_u"),           # E|gap-T|, unconditional
        "fid_basis": d.get("fid_basis"),                # "ladder-miss", or "distance" if saturated
        "fid_bound": bool(d.get("fid_bound", False)),
        "p_fid": d.get("p_fid"),
        # THE EXTRAPOLANT, so a driver (and the next reader of a stale action file) can see
        # whether the dial it was handed rests on a measurement or on a continued slope, and
        # whether that continuation was flat or geometric. extrap_accel == 1.0 is flat.
        "extrap_slope_hi": (None if fit is None else
                            float(fit.s_ref_hi * getattr(fit, "acc_hi", 1.0))),
        "extrap_slope_lo": (None if fit is None else
                            float(fit.s_ref_lo * getattr(fit, "acc_lo", 1.0))),
        "extrap_accel_hi": (None if fit is None else float(getattr(fit, "acc_hi", 1.0))),
        "extrap_accel_lo": (None if fit is None else float(getattr(fit, "acc_lo", 1.0))),
        "extrap_accel_clamp": (None if fit is None else float(getattr(fit, "acc_k", 1.0))),
        "extrap_sigma": (None if fit is None else
                         float(fit.sig_acc if getattr(fit, "acc_hi", 1.0) > 1.0 else SIG_SLOPE)),
        # G1, and both are 0/None on every shipped run. A driver that sees a non-zero commit_gate
        # or a non-null obj_k is being driven by a MEASUREMENT configuration, not the ship one.
        "commit_gate": d.get("gate_p", 0.0),
        "commit_k": d.get("gate_k", GATE_K),
        "commit_p": b.get("p_gate"),             # P(|true gap-100| <= commit_k) at the chosen dial
        "n_gated": d.get("n_gated", 0),
        "obj_k": d.get("obj_k"),
        "p_cert_raw": b.get("W_cert"),           # P(certify) even when the objective is W_k
                                                 # (same number as resid_p; kept explicit)
        "Vstar": d.get("Vstar"),                        # games, under the JOINT continuation
        "Vstar_games": d.get("Vstar_games"),            # games-only continuation (the STOP gate)
        "V_cap": d.get("V_cap"),
        "bank": ([b.get("w0"), b.get("n0")] if b else None),
        "forward": {k: fs.get(k) for k in ("p_cert", "med", "q10", "q90", "e_spend",
                                           "p_refute_or_cap")} if fs else None,
        "merge": ([{"lo": bl["lo"], "hi": bl["hi"], "n": bl["n"], "df": bl["df"],
                    "pval": bl["pval"], "phi": bl["phi"], "het": float(fit.het[k]),
                    "members": [m["x"] for m in bl["members"]]}
                   for k, bl in enumerate(fit.blocks)] if fit is not None else None),
        "sensitivity": ([{"assumption": s[0], "x_next": s[1], "action": s[2], "total": s[3]}
                         for s in d["sens"]] if d.get("sens") else None),
    }
    if d["action"] == "DONE":
        r = d.get("row") or {}
        blob.update({"certified_at": r.get("name"), "n": r.get("n"), "gap": d.get("gap"),
                     "stop_ci": list(d.get("stop_ci", ())), "pub_ci": list(d.get("pub_ci", ())),
                     # FREEZE: the last n at which this certificate still holds, and how many
                     # games of headroom that leaves. A driver must add none of them. BOTH are
                     # the COVERAGE half only -- see `margin_*` for the half that actually
                     # binds, which on every live certificate so far is containment.
                     "survives_to": d.get("survives_to"),
                     "headroom": d.get("headroom"),
                     "margin_contain": (d.get("margins") or {}).get("contain"),
                     "margin_cover": (d.get("margins") or {}).get("cover"),
                     "margin_elo": (d.get("margins") or {}).get("margin"),
                     "margin_binds": (d.get("margins") or {}).get("binds"),
                     "margin_sd": (d.get("margins") or {}).get("margin_sd"),
                     # the certificate's own distance from failing, in games. There is no
                     # `thin` flag: see the measurement above CERT_TYPICAL_CONTAIN -- a
                     # quarter-sd flag fires on ~90% of the certificates this rule produces.
                     "margin_swing_games": (d.get("margins") or {}).get("swing"),
                     "margin_typical_contain": CERT_TYPICAL_CONTAIN,
                     "margin_typical_swing": CERT_TYPICAL_SWING})
    return _finite(blob)


def write_decision_json(path, blob):
    """Write it, then PARSE IT BACK STRICTLY. A driver reads this file with a strict parser; if it
    would not survive that, the tool must fail here rather than hand over something unreadable."""
    txt = json.dumps(blob, indent=1, allow_nan=False, sort_keys=False)

    def _bare(tok):
        raise SystemExit("internal: --json-out produced the bare token %s, which is not JSON" % tok)
    json.loads(txt, parse_constant=_bare)
    with open(path, "w") as f:
        f.write(txt + "\n")
    return txt


def sign_test(wins, losses):
    """Two-sided exact sign test on the paired wins/losses, ties dropped. No scipy here."""
    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    tail = sum(math.comb(n, i) for i in range(0, k + 1)) / float(2 ** n)
    return min(1.0, 2.0 * tail)


# ---------------------------------------------------------------------------- 10. self-test
SELFTEST_DESIGN = [(-0.650, 99), (0.000, 90), (0.350, 137), (0.520, 409), (0.545, 792),
                   (0.550, 122), (0.630, 240), (0.750, 51), (0.950, 50), (1.370, 26)]
RE_DIALNUM = re.compile(r"x (?:=|in \[)\s*([-+]?\d+\.\d+)")


def _pava_brute(y, w):
    """O(K^3) min-max isotonic, for checking the vectorised one."""
    K = len(y)
    out = []
    for i in range(K):
        best = float("inf")
        for j in range(i + 1):
            m = -float("inf")
            for k in range(i, K):
                num = sum(y[t] * w[t] for t in range(j, k + 1))
                den = sum(w[t] for t in range(j, k + 1))
                m = max(m, num / den)
            best = min(best, m)
        out.append(best)
    return out


def _mkrows(design, truth, rng):
    rows = []
    for x, n in design:
        p = float(p_of_gap(truth_gap(truth, x)))
        rows.append({"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                     "w": float(rng.binomial(n, p)), "n": float(n)})
    return rows


def selftest(args):
    import io
    ok = True
    fail = lambda m: (print("  FAIL: %s" % m), False)[1]
    print("deepkyu_place2 self-test")
    # the cost model every case below shares. Built here rather than in [4] because the rule
    # tests now run the tool end to end.
    cost = Cost(chunk=args.look, cap=args.cap, trials=args.trials, seed=args.seed)
    tiny = Cost(chunk=args.look, cap=args.look, trials=args.trials, seed=args.seed)

    # 1. isotonic ----------------------------------------------------------
    rng = np.random.default_rng(1)
    bad = 0
    for _ in range(200):
        K = int(rng.integers(1, 9))
        y = rng.normal(size=K); w = rng.uniform(0.5, 50, K)
        a = pava_dec(y[None, :], w)[0]
        b = _pava_brute(list(y), list(w))
        bad += int(np.max(np.abs(a - np.array(b))) > 1e-9)
    print("  [1] weighted decreasing isotonic vs brute force, 200 random cases: %d mismatches" % bad)
    ok &= (bad == 0) or fail("pava_dec")

    # 2. the rule ----------------------------------------------------------
    # THE ORACLE IS deepkyu_tally.pair_stats() ITSELF. The version of this test that shipped
    # called pair_stats with a junk totals dict inside a `or True`, threw the result away, and
    # then re-derived the OLD one-sided condition BY HAND -- so it kept passing after the goal
    # changed, which is exactly the failure it exists to prevent. It now builds the totals dict
    # the tally actually parses out of SGFs and reads its `certified` field.
    import deepkyu_tally as dt

    def tally_cert(w, n):
        """deepkyu_tally's own verdict, through the ENTRY POINT the campaign calls: the totals
        dict it parses out of SGFs, straight into pair_stats()."""
        tot = {("S", "W"): [int(round(n - w)), int(round(w)), 0, 0, 0, int(n)]}
        return bool(dt.pair_stats(tot, "S", "W").get("certified"))

    def tally_cert_fast(w, n):
        """The same verdict from deepkyu_tally's own formulas, skipping pair_stats' need_median()
        -- which costs 10 ms a call and decides nothing. Checked against tally_cert below, and
        used only where the grid is too dense for the slow path."""
        if n <= 0:
            return False
        slo, shi = dt.wilson_gap_ci(w, n, dt.Z_STOP)[1:]
        clo, chi = dt.wilson_gap_ci(w, n, dt.Z_COVER)[1:]
        return bool(slo >= dt.BAND_LO and shi <= dt.BAND_HI and clo <= dt.BAND_MID <= chi)

    mism = mismr = ncert = 0
    ex = []
    npair = 0
    for n in (20, 60, 121, 240, 409, 540, 792, 914, 1500, 2400, 4000, 8000):
        # a coarse sweep of the whole range, PLUS every win count within 3 of the certification
        # window at this n -- otherwise the grid steps straight over the window (it is 50 wide in
        # w at n = 2400) and the three-way agreement is tested only where nothing certifies.
        _lo, _hi = cert_window(n)
        ws = set(range(0, n + 1, max(1, n // 60)))
        if _hi >= _lo - 3:
            ws |= set(range(max(0, int(_lo) - 3), min(n, int(_hi) + 3) + 1))
        for w in sorted(ws):
            npair += 1
            a = bool(rule_state(np.array([float(w)]), np.array([float(n)]))[0][0])
            b = indep_certified(w, n)
            c = tally_cert(w, n)
            ncert += int(c)
            if a != b or a != c or c != tally_cert_fast(w, n):
                mism += 1
                if len(ex) < 4:
                    ex.append("n=%d w=%d tool=%s indep=%s tally=%s" % (n, w, a, b, c))
            mismr += int(bool(rule_state(np.array([float(w)]), np.array([float(n)]))[1][0])
                         and indep_certified(w, n))
    print("  [2] TWO-SIDED rule: tool vs INDEPENDENT re-implementation vs deepkyu_tally."
          "pair_stats(): %d mismatches over %d (w,n) pairs, %d of which tally CERTIFIES; %d "
          "states both dead and certified" % (mism, npair, ncert, mismr))
    for e in ex:
        print("      %s" % e)
    ok &= (mism == 0 and mismr == 0 and ncert > 0) or fail("the certification rule does not agree")

    # 2c. THE RULE IN CLOSED FORM, and the geometry the goal change created -----------------
    bad = []
    tot = mis = 0
    for n in range(200, 20001, 37):
        lo, hi = cert_window(n)
        ws = set(range(int(0.15 * n), int(0.60 * n) + 1, max(1, n // 40)))
        if hi >= lo - 3:
            ws |= set(range(max(0, int(lo) - 3), min(n, int(hi) + 3) + 1))
        for w in sorted(ws):
            tot += 1
            if (lo <= w <= hi) != tally_cert_fast(w, n):
                mis += 1
    if mis:
        bad.append("the closed-form window disagrees with deepkyu_tally on %d of %d pairs"
                   % (mis, tot))
    if N_OPEN != 914:
        bad.append("N_OPEN moved to %s" % N_OPEN)
    # N_OPEN is the smallest n at which an INTEGER win count certifies. The real-valued window
    # opens 6 games earlier (908) and is narrower than one game there, which is why the pin is on
    # integers -- a rung is decided in whole games.
    for _n in range(100, N_OPEN):
        _lo, _hi = cert_window(_n)
        if math.ceil(_lo) <= math.floor(_hi):
            bad.append("an integer win count certifies at n = %d, below N_OPEN = %d"
                       % (_n, N_OPEN))
            break
    if math.ceil(cert_window(N_OPEN)[0]) > math.floor(cert_window(N_OPEN)[1]):
        bad.append("no integer win count certifies AT N_OPEN")
    if not (2300 <= N_PEAK <= 2450):
        bad.append("N_PEAK moved to %d" % N_PEAK)
    if abs(MAX_MISS - 11.25) > 0.1:
        bad.append("MAX_MISS moved to %.2f" % MAX_MISS)
    hw = [0.5 * (gap_window(n)[1] - gap_window(n)[0]) for n in range(N_PEAK + 50, 20000, 250)]
    if any(b >= a for a, b in zip(hw, hw[1:])):
        bad.append("the window is not strictly closing past the peak")
    for g, want in ((95.6, 15118), (97.6, 50973), (92.2, 4786), (90.0, 2902)):
        if abs(n_kill(g) - want) > 0.01 * want:
            bad.append("n_kill(%.1f) = %.0f, want %d" % (g, n_kill(g), want))
    print("  [2c] the rule in closed form vs deepkyu_tally over %d (w,n) pairs: %d mismatches"
          % (tot, mis))
    print("       geometry: the window OPENS at n = %d, is widest at n = %d (+-%.2f ELO on the"
          % (N_OPEN, N_PEAK, MAX_MISS))
    print("       point estimate), and closes monotonically after. [%.1f, %.1f] is therefore the"
          % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
    print("       set of PUBLISHED POINT ESTIMATES a certificate can carry -- NOT the set of true")
    print("       gaps that can be ground into one. A true gap of 85 certifies about half the")
    print("       time and one of 80 about a quarter ([2e] measures it); the estimate it")
    print("       publishes is inside the window because the coverage gate selected it there.")
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("the closed-form rule / window geometry")

    # 2d. MORE GAMES DESTROY A RUNG. The whole goal change in one assertion: a state that
    # certifies at n and does NOT certify at 4n with the SAME winrate. This is a property of the
    # RULE, not of the tool, so it is checked against deepkyu_tally as well.
    bad = []
    kills = []
    for g0, n in ((90.0, 2200), (92.2, 1704), (93.0, 2000), (108.0, 2400), (110.0, 2200)):
        w = n * float(p_of_gap(g0))
        c1 = bool(rule_state(np.array([w]), np.array([float(n)]))[0][0])
        c4 = bool(rule_state(np.array([4 * w]), np.array([float(4 * n)]))[0][0])
        t1, t4 = tally_cert(w, n), tally_cert(4 * w, 4 * n)
        kills.append((g0, n, c1, c4))
        if not (c1 and not c4):
            bad.append("gap %+.1f: certified at n=%d is %s, at n=%d is %s -- the over-collection "
                       "case does not reproduce" % (g0, n, c1, 4 * n, c4))
        if (c1, c4) != (t1, t4):
            bad.append("gap %+.1f: tool and deepkyu_tally disagree about over-collection" % g0)
        if n_kill(g0) >= 4 * n:
            bad.append("n_kill(%.1f) = %.0f does not explain the loss at n = %d"
                       % (g0, n_kill(g0), 4 * n))
    # and the same thing as the campaign will meet it: the LIVE certified rungs, and how many
    # more games each survives.
    print("  [2d] OVER-COLLECTION: a rung that certifies at n and NOT at 4n, same winrate")
    for g0, n, c1, c4 in kills:
        print("       observed gap %+6.1f: n = %5d %s   ->   n = %5d %s   (dies at n = %.0f)"
              % (g0, n, "CERTIFIED" if c1 else "no", 4 * n, "CERTIFIED" if c4 else "LOST",
                 n_kill(g0)))
    print("       the LIVE certified rungs and what is left of them:")
    for label, w, n in (("14k-15k", 474.0, 1296.0), ("15k-16k", 597.0, 1644.0),
                        ("16k-17k", 631.0, 1704.0)):
        g0 = float(gap_of_p(w / n))
        c = bool(rule_state(np.array([w]), np.array([n]))[0][0])
        if not c:
            bad.append("%s no longer certifies under the shipped rule" % label)
        mg = cert_margins(w, n)
        print("       %s n = %4d gap %+5.1f: CERTIFIED, survives to n = %.0f (%.0f more games) "
              "-- but that" % (label, int(n), g0, n_kill(g0), n_kill(g0) - n))
        print("                is the COVERAGE half; %s binds at %.2f ELO (coverage %.2f)"
              % (mg["binds"], mg["margin"], mg["cover"]))
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("the over-collection property of the two-sided rule")

    # 2e. OFF-CENTRE TRUTHS: where the two-sided rule actually bites. Every --bench truth used to
    # put a dial at the band centre, which is now the ONLY place that is safe at every precision,
    # so nothing in this file could see the failure the rewrite is about.
    bad = []
    rows_off = []
    for g in (100.0, 95.0, 90.0, 85.0, 110.0, 115.0):
        W, S, _sd = sim_dial(np.array([g]), 0.0, 0.0, chunk=args.look, cap=12000,
                             trials=4000, seed=20260913)
        W1, S1, _ = sim_dial(np.array([g]), 0.0, 0.0, chunk=args.look, cap=12000,
                             trials=4000, seed=20260913, cover=False)
        rows_off.append((g, float(W[0]), float(S[0]), float(W1[0])))
    p100 = rows_off[0][1]
    print("  [2e] OFF-CENTRE true gaps, cold dial, %d-game looks, 4000 trials:" % args.look)
    print("       %8s %10s %10s %12s" % ("true gap", "P(certify)", "E[games]", "one-sided P"))
    for g, W, S, W1 in rows_off:
        print("       %+8.1f %10.3f %10.0f %12.3f" % (g, W, S, W1))
    if p100 < 0.93:
        bad.append("a dial at the centre certifies only %.2f of the time" % p100)
    for g, W, S, W1 in rows_off[1:]:
        if W >= p100:
            bad.append("a dial at %+.1f certifies at least as often as one at the centre" % g)
        if W1 <= W + 0.02:
            bad.append("the one-sided rule is not easier at %+.1f (%.3f vs %.3f)" % (g, W1, W))
    if not (rows_off[3][1] < 0.65 and rows_off[5][1] < 0.65):
        bad.append("a dial 15 ELO off centre still certifies more than 65% of the time")
    print("       P(certify) IS the fidelity preference now: it is the whole reason p_fid is 0.")
    print("       The one-sided column is what the tool believed before this change; the gap")
    print("       between the columns off centre is W1, measured.")
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("the off-centre behaviour of the two-sided rule")

    # 2f. THE OVERSHOT EXIT (W2) -----------------------------------------------------------
    bad = []
    live = [("14k-15k x=0.63", 474.0, 1296.0, False), ("15k-16k x=1.00", 597.0, 1644.0, False),
            ("16k-17k x=1.20", 631.0, 1704.0, False), ("17k-18k x=1.36", 1807.0, 4668.0, True),
            ("17k-18k x=1.20", 74.0, 168.0, False), ("17k-18k x=2.10", 33.0, 168.0, True)]
    print("  [2f] the OVERSHOT exit on the LIVE rung states (kill above %.1f sd):" % Z_KILL)
    for label, w, n, want in live:
        g = float(gap_of_p(w / n))
        k = abs(g - BAND_MID) / sd_gap(w, n)
        got = bool(overshot(w, n))
        gi = indep_overshot(w, n)
        print("       %-16s n = %4d gap %+7.1f  |gap-100|/sd = %5.2f  %s"
              % (label, int(n), g, k, "OVERSHOT" if got else "alive"))
        if got != want:
            bad.append("%s: overshot = %s, expected %s" % (label, got, want))
        if got != gi:
            bad.append("%s: the independent re-implementation disagrees" % label)
    # the dead rung-4 dial must be priced at ~0 by the COST MODEL, not by a special case
    Wd, Sd, _ = sim_dial(np.array([79.8]), 1807.0, 4668.0, chunk=args.look, cap=12000,
                         trials=2000, seed=7)
    Wl, _, _ = sim_dial(np.array([79.8]), 1807.0, 4668.0, chunk=args.look, cap=12000,
                        trials=2000, seed=7, z_kill=float("inf"))
    print("       residual P(certify) at the live x=+1.36 bank (1807/4668, gap %+.1f): %.4f, and"
          % (float(gap_of_p(1807.0 / 4668.0)), float(Wd[0])))
    print("       %.4f with the OVERSHOT exit switched off -- so the exit is not what makes that"
          % float(Wl[0]))
    print("       dial worthless, it is what stops the tool paying for it.")
    if Wd[0] > 0.01 or Wl[0] > 0.02:
        bad.append("the dead rung-4 dial is priced at P(certify) = %.3f / %.3f" % (Wd[0], Wl[0]))
    # and it must not fire on a centred dial: measure what it costs there
    Wc, _, _ = sim_dial(np.array([100.0]), 0.0, 0.0, chunk=args.look, cap=12000, trials=4000,
                        seed=11)
    Wc0, _, _ = sim_dial(np.array([100.0]), 0.0, 0.0, chunk=args.look, cap=12000, trials=4000,
                         seed=11, z_kill=float("inf"))
    print("       what it costs a CENTRED dial: P(certify) %.3f with the exit, %.3f without."
          % (float(Wc[0]), float(Wc0[0])))
    if Wc0[0] - Wc[0] > 0.02:
        bad.append("the OVERSHOT exit costs %.3f of P at a centred dial" % (Wc0[0] - Wc[0]))
    # end to end: the tool must LEAVE the dead dial, and must not stop the rung to do it
    rows_r4 = [{"x": 1.20, "name": "x=+1.2000", "sig": None, "w": 74.0, "n": 168.0},
               {"x": 1.36, "name": "x=+1.3600", "sig": None, "w": 1807.0, "n": 4668.0},
               {"x": 2.10, "name": "x=+2.1000", "sig": None, "w": 33.0, "n": 168.0}]
    d_r4 = decide(rows_r4, 100.0, cost, x_cur=1.36, draws=4000, seed=args.seed,
                  chunk=args.chunk)
    print("       end to end on the LIVE rung-4 rows: %s at x = %+.4f (was %+.4f), x_cur_dead = %s"
          % (d_r4["action"], d_r4["x_next"], 1.36, d_r4["x_cur_dead"]))
    if d_r4["action"] != "PLAY" or abs(d_r4["x_next"] - 1.36) < 1e-9:
        bad.append("the tool stays on the OVERSHOT rung-4 dial (%s at %+.4f)"
                   % (d_r4["action"], d_r4["x_next"]))
    if not d_r4["x_cur_dead"]:
        bad.append("x_cur_dead is not set on the live rung-4 state")
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("the OVERSHOT exit")

    # 2g. the three CERTIFIED rungs must read DONE and play NOTHING ------------------------
    bad = []
    for label, x, w, n in (("14k-15k", 0.63, 474.0, 1296.0), ("15k-16k", 1.00, 597.0, 1644.0),
                           ("16k-17k", 1.20, 631.0, 1704.0)):
        rws = [{"x": x - 0.10, "name": "lo", "sig": None, "w": 90.0, "n": 168.0},
               {"x": x, "name": "cur", "sig": None, "w": w, "n": n}]
        dd = decide(rws, 100.0, cost, x_cur=x, draws=2000, seed=args.seed, chunk=args.chunk)
        if dd["action"] != "DONE" or dd["n_next"] != 0:
            bad.append("%s reads %s with n_next = %d" % (label, dd["action"], dd["n_next"]))
        if not (dd.get("headroom", 0) > 0):
            bad.append("%s has no headroom left on its own certificate" % label)
        # R1: the lifetime is the COVERAGE half. A DONE must also carry the containment margin
        # and must name whichever of the two is smaller.
        mm = dd.get("margins")
        if not mm:
            bad.append("%s: DONE carries no margins" % label)
        elif mm["binds"] != ("containment" if mm["contain"] <= mm["cover"] else "coverage"):
            bad.append("%s: the named binding half is not the smaller margin" % label)
        elif not (mm["contain"] > 0 and mm["cover"] > 0):
            bad.append("%s: a certified rung has a non-positive margin" % label)
    print("  [2g] the three LIVE CERTIFIED rungs: DONE, n_next = 0, a printed lifetime and BOTH "
          "margins: %d failures" % len(bad))
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("a certified rung is not frozen")

    # 2h. LEVERS WHERE EVERY DIAL IS OUTSIDE THE FEASIBLE SET. The rule permits a certificate
    # here and the tool must NOT call STOP -- that would be a wrong STOP on a lever the goal
    # accepts -- but every certificate it buys is off target by construction. Pinned so that a
    # future change cannot quietly turn these into STOPs, and printed so the size of the goal's
    # own selection problem stays visible.
    bad = []
    print("  [2h] levers where EVERY legal dial is outside [%.1f,%.1f]: the rule still certifies"
          % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
    for tr in sorted(SELECTION):
        ends, gaps, gms = [], [], []
        for sd in range(max(2, min(4, args.seeds))):
            pol = make_tool(100.0, args.chunk, args.cap, args.trials, args.draws, args.seed,
                            look=args.look)
            g, dg, rn, end, pl = run_policy(pol, tr, sd, 100.0, args.chunk, args.maxgames,
                                            look=args.look)
            ends.append(end)
            gms.append(pl)
            if g is not None:
                gaps.append(dg)
        nstop = sum(1 for e in ends if e == "stopped")
        lot = (float(np.mean([abs(x - 100.0) > MAX_MISS for x in gaps])) if gaps
               else float("nan"))
        d100 = sorted(abs(x - 100.0) for x in gaps)
        print("       %-10s %d/%d certified, median %5.0f games, shipped |gap-100| %s, lottery %s"
              % (tr, len(gaps), len(ends), float(np.median(gms)),
                 "n/a" if not d100 else "%.1f" % float(np.median(d100)),
                 "n/a" if lot != lot else "%.2f" % lot))
        if nstop:
            bad.append("%s: the tool STOPped %d/%d times on a lever the RULE accepts"
                       % (tr, nstop, len(ends)))
    print("       no policy can win these: the certificate is off target by construction, and")
    print("       the coverage gate selects ON the point estimate, so what gets published reads")
    print("       near +95 whatever the truth. --bench measures it; nothing prices it away.")
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("a STOP on a lever the rule accepts")


    # 2b. THE PUBLISHED RUNGS. deepkyu_tally must keep reproducing the two certificates the
    # campaign has already shipped. Nothing in this file may change them, and this is the check
    # that says so out loud after any edit to deepkyu_tally.py or deepkyu_cfg.py.
    bad = []
    for label, w, n, g, lo, hi in (("+100 rung", 213.0, 592, 100.0, 71.0, 129.2),
                                   ("+29 rung", 242.0, 528, 29.0, -0.7, 58.7)):
        pt, plo, phi_ = dt.wilson_gap_ci(w, n, dt.Z)
        slo, shi = dt.wilson_gap_ci(w, n, dt.Z_STOP)[1:]
        got = (abs(pt - g) <= 0.5 and abs(plo - lo) <= 0.06 and abs(phi_ - hi) <= 0.06)
        print("      %-10s n = %3d, w = %5.1f -> %+6.1f [%+6.1f,%+6.1f] at Z=1.96   published "
              "%+6.1f [%+6.1f,%+6.1f]  %s   (Z=2.50 [%+6.1f,%+6.1f])"
              % (label, n, w, pt, plo, phi_, g, lo, hi, "MATCH" if got else "MISMATCH", slo, shi))
        if not got:
            bad.append(label)
    print("  [2b] the two PUBLISHED rung certificates still reproduce: %s"
          % ("both" if not bad else "BROKEN: " + ", ".join(bad)))
    ok &= (not bad) or fail("a published rung certificate changed")

    # 3. refusals ----------------------------------------------------------
    def refuses(rows, what):
        try:
            check_rows(rows)
        except SystemExit:
            return True
        print("  FAIL: accepted %s" % what)
        return False
    r1 = [{"x": 0.5, "name": "a", "sig": ("15k", 1, 1, 1.0, 1.0, "P2"), "w": 10, "n": 20},
          {"x": 0.5, "name": "b", "sig": ("15k", 40, 1, 1.0, 1.0, "P2"), "w": 10, "n": 20}]
    r2 = [{"x": 0.5, "name": "a", "sig": None, "w": 10, "n": 20},
          {"x": 0.5, "name": "b", "sig": None, "w": 10, "n": 20}]
    r3 = [{"x": 99.0, "name": "a", "sig": None, "w": 10, "n": 20}]
    r4 = [{"x": 0.5, "name": "a", "sig": None, "w": 10, "n": 0}]
    r5 = [{"x": 0.5, "name": "a", "sig": None, "w": 30, "n": 20}]
    good = all([refuses(r1, "two different bots at one dial"), refuses(r2, "a duplicate dial"),
                refuses(r3, "a dial outside the legal domain"), refuses(r4, "a dial with 0 games"),
                refuses(r5, "w > n")])
    print("  [3] refusals (two bots at one dial / duplicate x / illegal x / n=0 / w>n): %s"
          % ("all refused" if good else "SOME ACCEPTED"))
    ok &= good

    # 3b. THE THREE REPORTING DEFECTS (R1, R2, R3), PINNED --------------------------------
    # None of these touched the decision layer or the rule; all three were the tool saying
    # something untrue about a correct engine, which is the failure mode a selftest that only
    # checks the engine cannot see. Each is pinned by the fact that made it wrong, not by the
    # wording that was changed.
    bad = []

    # -- R1. The reported certificate margin described the NON-BINDING half. `survives_to` /
    #    `headroom` are the COVERAGE lifetime; on every live certificate the binding half is
    #    CONTAINMENT, whose margin is up to 20x smaller. Both are reported now and the smaller is
    #    named. The pin is that the two halves DISAGREE about which binds -- shown on real states
    #    in both directions, so "name the binder" cannot degenerate into a constant.
    print("  [3b] R1: both certificate margins, and which one binds")
    print("       %-22s %6s %6s %10s %7s %6s %s"
          % ("state", "n", "gap", "contain", "cover", "sd", "binds"))
    marg_cases = [("14k-15k live", 474.0, 1296.0, "containment"),
                  ("15k-16k live", 597.0, 1644.0, "containment"),
                  ("16k-17k live", 631.0, 1704.0, "containment"),
                  # LARGE n, SLIGHTLY OFF CENTRE: the intervals are narrow, so containment is
                  # comfortable and it is COVERAGE that is about to die. This is the same state
                  # n_kill() describes, and the half the old report happened to be measuring.
                  ("n=6000 gap +97", None, 6000.0, "coverage"),
                  ("n=4000 gap +103", None, 4000.0, "coverage")]
    for i_c, (label, w, n, want) in enumerate(marg_cases):
        if w is None:
            g_want = 97.0 if "97" in label else 103.0
            w = round(float(p_of_gap(g_want)) * n)
        m = cert_margins(w, n)
        cert = bool(rule_state(np.array([float(w)]), np.array([float(n)]))[0][0])
        print("       %-22s %6d %+6.1f %10.2f %7.2f %6.1f %s%s"
              % (label, int(n), float(gap_of_p(w / n)), m["contain"], m["cover"], m["sd"],
                 m["binds"], "" if cert else "   (does not certify)"))
        if not cert:
            bad.append("%s does not certify, so it is not a margin case" % label)
        if m["binds"] != want:
            bad.append("%s: %s binds, expected %s" % (label, m["binds"], want))
        if abs(m["margin"] - min(m["contain"], m["cover"])) > 1e-9:
            bad.append("%s: the named margin is not the smaller of the two" % label)
        # the SWING is a fact about the games: certified at w, not certified at w +- swing, and
        # certified at every smaller displacement.
        k = m["swing"]
        if k is None:
            bad.append("%s: a certified state reports no swing" % label)
        else:
            if bool(rule_state(np.array([w - k]), np.array([n]))[0][0]) and \
               bool(rule_state(np.array([w + k]), np.array([n]))[0][0]):
                bad.append("%s: swing = %d breaks nothing" % (label, k))
            for j in range(1, k):
                if not (bool(rule_state(np.array([w - j]), np.array([n]))[0][0])
                        and bool(rule_state(np.array([w + j]), np.array([n]))[0][0])):
                    bad.append("%s: swing = %d is not the SMALLEST break (%d does)"
                               % (label, k, j))
                    break
    # ...and the live certificates are the case the old report got wrong: coverage OVERSTATES.
    for label, w, n in (("14k-15k", 474.0, 1296.0), ("15k-16k", 597.0, 1644.0),
                        ("16k-17k", 631.0, 1704.0)):
        m = cert_margins(w, n)
        if not (m["cover"] > m["contain"]):
            bad.append("%s: coverage no longer overstates; the R1 fixture has moved" % label)
    # ...AND WHETHER A THIN BINDING MARGIN DESERVES A FLAG. Measured, small version of the table
    # above CERT_TYPICAL_CONTAIN, so a future maintainer who wants a warning here sees first that
    # it would fire on almost every certificate. This is a BASE-RATE pin, not a tolerance.
    _rate = []
    for _g in (85.0, 100.0, 112.0):
        _rng = np.random.default_rng(int(_g))
        _p = float(p_of_gap(_g)); _T = 400
        _w = np.zeros(_T); _n = np.zeros(_T); _dn = np.zeros(_T, bool)
        _wc = np.zeros(_T); _nc = np.zeros(_T)
        for _st in look_steps(args.look, 12000):
            _a = ~_dn
            if not _a.any():
                break
            _w[_a] += _rng.binomial(_st, _p, int(_a.sum())); _n[_a] += _st
            _c, _d = rule_state(_w, _n)
            _new = _c & ~_dn
            _wc[_new] = _w[_new]; _nc[_new] = _n[_new]
            _dn |= (_c | _d)
        _ms = [cert_margins(float(_wc[i]), float(_nc[i]))
               for i in np.flatnonzero(_nc > 0)[:200]]
        if not _ms:
            continue
        _rate.append((_g, float(np.mean([mm["margin_sd"] < 0.25 for mm in _ms])),
                      float(np.median([mm["contain"] for mm in _ms])),
                      float(np.median([mm["swing"] for mm in _ms])), len(_ms)))
    print("       would a THIN flag mean anything? the certificates this stop rule actually "
          "makes:")
    for _g, _u, _mc, _msw, _k in _rate:
        print("         true gap %+6.1f: %.2f of %d certificates under 0.25 sd, median "
              "containment %.2f ELO, median swing %.0f games" % (_g, _u, _k, _mc, _msw))
    if _rate and not all(_u > 0.6 for _g, _u, _mc, _msw, _k in _rate):
        bad.append("the thin-margin base rate has moved; a flag may now be worth having "
                   "(%s)" % ", ".join("%.2f" % _u for _g, _u, _mc, _msw, _k in _rate))
    print("       -- so no alarm is raised on thinness: it is the first-crossing rule's shape.")
    print("       so a report quoting the coverage half alone claims %.1f ELO of room on the "
          "live" % cert_margins(474.0, 1296.0)["cover"])
    print("       14k-15k rung, which stands %.1f ELO from the band edge (%d more wins by the"
          % (cert_margins(474.0, 1296.0)["contain"], cert_margins(474.0, 1296.0)["swing"]))
    print("       weaker side would have taken it away). Both are printed on every DONE now.")

    # the DONE report must actually SAY both, and name the binder
    _rw = [{"x": 0.53, "name": "lo", "sig": None, "w": 90.0, "n": 168.0},
           {"x": 0.63, "name": "x=+0.6300", "sig": None, "w": 474.0, "n": 1296.0}]
    _d = decide(_rw, 100.0, cost, x_cur=0.63, draws=1200, seed=args.seed, chunk=args.chunk)
    _buf = io.StringIO()
    report(_rw, 100.0, _d, cost, rank="15k", strong="14k_v40", rate=740.0, out=_buf)
    _txt = _buf.getvalue()
    if _d["action"] != "DONE":
        bad.append("the R1 fixture no longer reads DONE (%s)" % _d["action"])
    if not _d.get("margins"):
        bad.append("a DONE decision carries no margins")
    for need in ("containment", "coverage", "BINDS", "BINDING MARGIN"):
        if need not in _txt:
            bad.append("the DONE report does not print %r" % need)
    _blob = decision_json(_d, 100.0, rank="15k", strong="14k_v40")
    for kk in ("margin_contain", "margin_cover", "margin_binds", "margin_elo"):
        if _blob.get(kk) is None:
            bad.append("--json-out carries no %s on a DONE" % kk)
    if _blob.get("margin_binds") != _d["margins"]["binds"]:
        bad.append("the JSON binder disagrees with the report")

    # -- R2. A false universal claim -- that no TRUE gap outside [88.7, 111.3] can ever be
    #    turned into one -- was printed on every live run and on every selftest run. It is false:
    #    +-MAX_MISS bounds the
    #    PUBLISHED POINT ESTIMATE, and the coverage gate is a selection ON that estimate, so a
    #    rung whose truth is well outside the window certifies routinely and publishes a number
    #    inside it. Pinned by MEASURING the counterexample, not by checking the wording.
    off = []
    for g in (85.0, 80.0):
        W, _S, _sd = sim_dial(np.array([g]), 0.0, 0.0, chunk=args.look, cap=12000,
                              trials=1500, seed=20260914)
        off.append((g, float(W[0])))
    print("  [3b] R2: true gaps OUTSIDE the feasible window [%.1f,%.1f] still certify --"
          % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
    for g, W in off:
        print("       a TRUE gap of %+.1f certifies %.2f of the time (1500 trials, cold dial)"
              % (g, W))
    if not (off[0][1] > 0.30 and off[1][1] > 0.10):
        bad.append("the R2 counterexample no longer fires: P = %.2f / %.2f" % (off[0][1], off[1][1]))
    # assembled from pieces so that this line is not itself the match it is looking for
    _FALSE = "ground into a " + "certificate"
    if _FALSE.lower() in _txt.lower():
        bad.append("the live report still prints the false universal claim")
    _src = open(__file__).read() if os.path.exists(__file__) else ""
    if _src and _FALSE.lower() in _src.lower():
        bad.append("the false universal claim is still somewhere in this file")
    print("       so the window bounds what a certificate SAYS, never what it IS. The claim is")
    print("       gone from the report and from this file (checked on the source text).")

    # -- R3. games_needed / need_median answer the ONE-SIDED question and were printed as
    #    "need~N" / "GRIND (>=N more)". Under the two-sided rule no such N exists. Pinned on the
    #    live rung-4 dial where the two answers were furthest apart.
    _r3 = [("17k-18k x=1.36 (the live rung 4)", 1807.0, 4668.0),
           ("17k-18k x=1.46 (where it went)", 547.0, 1463.0),
           ("a cold chunk at the centre", 194.0, 540.0)]
    print("  [3b] R3: the one-sided `need~N` against the two-sided truth")
    print("       %-34s %9s   %s" % ("bucket", "old need~", "what is true under the rule"))
    for label, w, n in _r3:
        nm = dt.need_median(w, n)[0]
        ol = dt.cert_outlook(w, n)
        print("       %-34s %9s   %s"
              % (label, "OUT" if nm is None else "%d" % nm, dt.outlook_str(ol)))
    _dead = dt.cert_outlook(1807.0, 4668.0)
    _deadneed = dt.need_median(1807.0, 4668.0)[0]
    if not (_dead["p_cert"] < 0.05 and _dead["med_more"] is None):
        bad.append("the dead rung-4 dial no longer reads as hopeless (P = %.3f)" % _dead["p_cert"])
    if not (_deadneed is not None and _deadneed > 5000):
        bad.append("the R3 fixture has moved: need_median reads %s" % _deadneed)
    if "need~" in dt.outlook_str(_dead) or "need~" in dt.outlook_str(dt.cert_outlook(547.0, 1463.0)):
        bad.append("outlook_str still speaks of need~N")
    # the two forward simulations are written separately on purpose; they must still agree
    for label, w, n in _r3:
        p0 = min(max(w / n, 0.5 / n), 1.0 - 0.5 / n)
        sdg = C_ELO / math.sqrt(n * p0 * (1.0 - p0))
        gd = float(gap_of_p(p0)) + sdg * np.random.default_rng(5).standard_normal(8000)
        fs = forward_summary(gd, w, n, chunk=dt.LOOK_FINE, cap=dt.CAP_GAMES, seed=17,
                             nsim=3000, z_kill=float("inf"))
        got = dt.cert_outlook(w, n)["p_cert"]
        if abs(fs["p_cert"] - got) > 0.06:
            bad.append("%s: deepkyu_tally P = %.3f, deepkyu_place2 P = %.3f"
                       % (label, got, fs["p_cert"]))
    # tally's closed-form window (its simulation's inner loop) vs its own Wilson formulas
    _cf = 0
    for n_ in range(200, 9000, 137):
        clo_, chi_, rlo_, rhi_ = dt._cert_bounds(float(n_))
        for w_ in range(0, n_ + 1, max(1, n_ // 40)):
            c1, r1_ = dt._cert_state(float(w_), float(n_))
            if c1 != (clo_ <= w_ <= chi_) or r1_ != ((w_ < rlo_ or w_ > rhi_) and not c1):
                _cf += 1
    if _cf:
        bad.append("deepkyu_tally's closed-form window disagrees with its Wilson form in %d "
                   "cases" % _cf)
    # AND NO CALLER MAY PRINT THE OLD QUANTITY AGAIN. Checked on STRING LITERALS only, via the
    # parse tree: the prose that explains why `need~N` went away is allowed to name it, the text
    # an operator reads is not.
    import ast as _ast
    for _f in ("deepkyu_ladder.py", "deepkyu_tally.py"):
        _pp = os.path.join(os.path.dirname(os.path.abspath(__file__)), _f)
        if not os.path.exists(_pp):
            continue
        _tree = _ast.parse(open(_pp).read())
        _docs = set()
        for _node in _ast.walk(_tree):
            if isinstance(_node, (_ast.Module, _ast.FunctionDef, _ast.AsyncFunctionDef,
                                  _ast.ClassDef)):
                _b = getattr(_node, "body", None)
                if _b and isinstance(_b[0], _ast.Expr) and isinstance(_b[0].value, _ast.Constant) \
                        and isinstance(_b[0].value.value, str):
                    _docs.add(id(_b[0].value))
        for _node in _ast.walk(_tree):
            if isinstance(_node, _ast.Constant) and isinstance(_node.value, str) \
                    and "need~" in _node.value and id(_node) not in _docs:
                bad.append("%s still has a printable `need~` literal" % _f)
                break
    print("       the two forward simulations (separate implementations) agree to <= 0.06 of P,")
    print("       and the closed-form window matches the Wilson form in all %d checked states."
          % sum(1 for n_ in range(200, 9000, 137) for _w in range(0, n_ + 1, max(1, n_ // 40))))
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("the reporting contract (R1/R2/R3)")

    # 4. every report branch runs, and prints no illegal dial ---------------
    rng = np.random.default_rng(7)
    cases = [
        ("interior (the live rung-1 design)", _mkrows(SELFTEST_DESIGN, "rung1", rng), cost, 100.0),
        ("right-open (target above every dial)",
         _mkrows([(-0.65, 99), (0.0, 90), (0.35, 137)], "far", rng), cost, 100.0),
        ("left-open (target below every dial)",
         _mkrows([(1.0, 200), (1.2, 200), (1.4, 200)], "steep", rng), cost, 100.0),
        ("near-duplicate dials 0.520/0.545/0.550 only",
         _mkrows([(0.520, 409), (0.545, 792), (0.550, 122)], "rung1", rng), cost, 100.0),
        ("single dial", _mkrows([(0.545, 792)], "rung1", rng), cost, 100.0),
        ("HOPELESS branch (abandon cap of one chunk)",
         _mkrows(SELFTEST_DESIGN, "rung1", rng), tiny, 100.0),
        ("DONE branch", [{"x": 0.58, "name": "x=+0.5800", "sig": None, "w": 1520.0, "n": 4000.0}],
         cost, 100.0),
    ]
    bad = []
    for label, rws, cm, T in cases:
        buf = io.StringIO()
        try:
            d = decide(rws, T, cm, x_cur=None, draws=2000, seed=args.seed, chunk=args.chunk)
            report(rws, T, d, cm, rank="15k", strong="14k_v40", rate=56.0, out=buf)
        except Exception as e:
            bad.append("%s: %s: %s" % (label, type(e).__name__, e))
            continue
        txt = buf.getvalue()
        for tok in RE_DIALNUM.findall(txt):
            if not in_domain(float(tok)):
                bad.append("%s printed an illegal dial %s" % (label, tok))
        if d["action"] != "DONE" and not in_domain(d["x_next"]):
            bad.append("%s recommended an illegal dial %.4f" % (label, d["x_next"]))
        if d["action"] == "PLAY" and d["n_next"] <= 0:
            bad.append("%s recommended %d games (the loop would not terminate)" % (label, d["n_next"]))
        if "x_hat" in txt:
            bad.append("%s printed an x_hat" % label)
    print("  [4] all %d report branches (incl. the low-P(certify) and DONE branches, which is "
          "where the old tool died on a malformed %%-format): %d failures"
          % (len(cases), len(bad)))
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("report branches")

    # 5. the action is always legal and always plays games -------------------
    rng = np.random.default_rng(11)
    bad = 0
    for _ in range(args.reps):
        tr = list(TRUTHS)[int(rng.integers(0, len(TRUTHS)))]
        k = int(rng.integers(1, 6))
        design = [(float(rng.uniform(X_LO, 1.6)), int(rng.integers(20, 800))) for _ in range(k)]
        design = sorted({round(x, 3): n for x, n in design}.items())
        rws = _mkrows(design, tr, rng)
        d = decide(rws, 100.0, cost, x_cur=None, draws=1500, seed=args.seed, chunk=args.chunk)
        if d["action"] != "DONE" and (not in_domain(d["x_next"]) or d["n_next"] <= 0):
            bad += 1
    print("  [5] %d random data sets: %d illegal or no-op recommendations" % (args.reps, bad))
    ok &= (bad == 0) or fail("illegal recommendation")

    # 6a. the action contract ------------------------------------------------
    # D1 was: action = STOP with n_next = 540, emitted at round 0 with zero games played, on 6 of
    # 126 runs -- and the benchmark discarded the action field, so it could not see it. Both halves
    # are checked here: the contract itself, and that the cold start never STOPs on an attainable
    # target.
    bad, nstop = [], 0
    rng = np.random.default_rng(20260912)
    for tr in list(TRUTHS):
        for sd in range(max(args.seeds, 6)):
            tb = Table(tr, sd)
            rws = [{"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                    "w": tb.play(x, n), "n": float(n)} for x, n in START]
            d = decide(rws, 100.0, cost, x_cur=None, draws=1500, seed=args.seed, chunk=args.chunk)
            if d["action"] == "STOP":
                nstop += 1
                bad.append("round 0 on %s seed %d: STOP with the bracket still %s (%s)"
                           % (tr, sd, d["fit"].bracket(100.0)[2], d.get("stop_reason")))
    for _ in range(args.reps):
        tr = list(TRUTHS)[int(rng.integers(0, len(TRUTHS)))]
        k = int(rng.integers(1, 6))
        design = sorted({round(float(rng.uniform(X_LO, 1.6)), 2): int(rng.integers(20, 900))
                         for _ in range(k)}.items())
        rws = _mkrows(design, tr, rng)
        for xc in (None, design[-1][0]):
            d = decide(rws, 100.0, cost, x_cur=xc, draws=1500, seed=args.seed, chunk=args.chunk)
            if d["action"] == "PLAY" and (d["n_next"] <= 0 or not in_domain(d["x_next"])):
                bad.append("PLAY %d at %.4f" % (d["n_next"], d["x_next"]))
            if d["action"] != "PLAY" and d["n_next"] != 0:
                bad.append("%s with n_next = %d" % (d["action"], d["n_next"]))
            if d["action"] == "STOP" and lever_room(d["fit"], rws, 100.0, cost.cap)[0]:
                bad.append("STOP while lever_room() reports a dial left to try")
            try:
                write_decision_json(os.devnull, decision_json(d, 100.0, rank="15k"))
            except SystemExit as e:
                bad.append("json: %s" % e)
    # the branch that used to emit a bare NaN: nothing certifies, so forward.med is nan
    tiny_rows = _mkrows(SELFTEST_DESIGN, "rung1", rng)
    dt_ = decide(tiny_rows, 100.0, tiny, x_cur=None, draws=1500, seed=args.seed, chunk=args.chunk)
    try:
        blob = decision_json(dt_, 100.0, rank="15k")
        write_decision_json(os.devnull, blob)
        if blob["forward"]["med"] is not None and not math.isfinite(blob["forward"]["med"]):
            bad.append("json: forward.med is non-finite")
    except SystemExit as e:
        bad.append("json (saturated-lever branch): %s" % e)
    print("  [6] the ACTION CONTRACT over %d cold starts and %d random states, and --json-out on "
          "every branch: %d violations (%d round-0 STOPs)"
          % (len(TRUTHS) * max(args.seeds, 6), 2 * args.reps, len(bad), nstop))
    for b in bad[:8]:
        print("      %s" % b)
    ok &= (not bad) or fail("the action contract")

    # 6b. STOP fires when it SHOULD ------------------------------------------
    miss = []
    for tr in sorted(UNATTAINABLE):
        for sd in range(2):
            g, dg, rn, end, _pl = run_policy(make_tool(100.0, args.chunk, args.cap, args.trials,
                                                       args.draws, args.seed, look=args.look),
                                             tr, sd, 100.0, args.chunk, args.maxgames,
                                             faithful=True, look=args.look)
            if end != "stopped":
                miss.append("%s seed %d ended %s, not stopped" % (tr, sd, end))
    print("  [7] STOP on levers where the target really IS unattainable (%s): %d failures"
          % ("/".join(sorted(UNATTAINABLE)), len(miss)))
    for m in miss:
        print("      %s" % m)
    ok &= (not miss) or fail("STOP does not fire on an unattainable lever")

    # 7. the homogeneity test -------------------------------------------------
    bad = []
    # chi-square tail against published critical values
    for df, x, want in ((1, 3.841459, 0.05), (1, 6.634897, 0.01), (2, 5.991465, 0.05),
                        (2, 9.210340, 0.01), (3, 7.814728, 0.05), (5, 11.070498, 0.05),
                        (10, 18.307038, 0.05), (10, 23.209251, 0.01)):
        if abs(chi2_sf(x, df) - want) > 2e-4:
            bad.append("chi2_sf(%.4f, %d) = %.6f, want %.4f" % (x, df, chi2_sf(x, df), want))
        if abs(chi2_ppf(1.0 - want, df) - x) > 1e-3 * max(1.0, x):     # the dispersion CI (W2)
            bad.append("chi2_ppf(%.4f, %d) = %.6f, want %.6f"
                       % (1.0 - want, df, chi2_ppf(1.0 - want, df), x))
    # a proximity group that is really one rate must pool; one with a real step must not
    homog = [{"x": 0.520, "w": 200.0, "n": 500.0}, {"x": 0.545, "w": 200.0, "n": 500.0},
             {"x": 0.550, "w": 202.0, "n": 500.0}]
    step = [{"x": 0.520, "w": 200.0, "n": 500.0}, {"x": 0.545, "w": 200.0, "n": 500.0},
            {"x": 0.550, "w": 120.0, "n": 500.0}]
    if len(merge_rows(homog)) != 1:
        bad.append("split three dials that share a rate")
    st = merge_rows(step)
    if any(len(b["members"]) > 1 and any(abs(m["x"] - 0.550) < 1e-9 for m in b["members"])
           for b in st):
        bad.append("pooled a 1500-game 16-ELO step (%s)"
                   % [[m["x"] for m in b["members"]] for b in st])
    if len(merge_rows(homog, min_sep=0.0)) != 3:
        bad.append("min_sep = 0 did not give every dial its own block")
    # D2: the knob the SHIPPED sweep varied (0.025 vs 0.100) cannot separate dials 0.005 apart,
    # so its merge rows were identical to the baseline on the live data and its gate could never
    # fire. min_sep = 0 can, and that is the row the sweep now carries.
    if len(merge_rows(homog, min_sep=0.100)) != 1:
        bad.append("merge width 0.100 separated a homogeneous group")
    if [len(b["members"]) for b in merge_rows(homog, min_sep=0.0)] == \
            [len(b["members"]) for b in merge_rows(homog, min_sep=0.100)]:
        bad.append("the NO MERGE sensitivity row cannot disagree with the baseline")
    # the resolution gate: two dials 0.01 apart on a 1200 ELO/unit response hide more than the
    # pooled games buy, and must not be one point however homogeneous they look
    steep = [{"x": 0.30, "w": 236.0, "n": 500.0}, {"x": 0.53, "w": 190.0, "n": 500.0},
             {"x": 0.55, "w": 180.0, "n": 500.0}, {"x": 0.80, "w": 45.0, "n": 500.0}]
    sb = merge_rows(steep)
    if any(len(b["members"]) > 1 for b in sb):
        bad.append("pooled dials 0.02 apart beside a %.0f ELO/unit response (het %.1f ELO "
                   "against a %.1f ELO pooled sd)"
                   % ((gap_of_p(45 / 500.) - gap_of_p(180 / 500.)) / 0.25,
                      block_het(sb, 1), sd_gap(370.0, 1000.0)))
    if not any(len(b["members"]) > 1 for b in merge_rows(steep, het_k=float("inf"))):
        bad.append("het_k = inf did not switch the resolution gate off")
    # W1. THE RESOLUTION GATE IS THE ONE PIECE OF MACHINERY THAT CARRIES THE STEEP REGIME, and
    # until now nothing would have noticed if it silently stopped firing. Ablated at 288 paired
    # runs on a 1200 ELO/unit truth it is worth +326 games [+197, +458] and +0.12 of P(landing on
    # the optimal dial); every other structure accused of the steep-lever cost (the 0.01 lattice,
    # MIN_SEP, the interpolation prior, P_FID, the extrapolation reach) measured at zero or worse.
    # Pinned here in the currency the gate is sized in: the ELO of response a block hides.
    g_on = merge_rows(steep)
    g_off = merge_rows(steep, het_k=float("inf"))
    h_on = max([block_het(g_on, k) for k in range(len(g_on))] or [0.0])
    h_off = max([block_het(g_off, k) for k in range(len(g_off))] or [0.0])
    sd_pool = max([sd_gap(b["w"], b["n"]) for b in g_off if len(b["members"]) > 1] or [0.0])
    if not (h_off > 20.0 and h_off > sd_pool and h_on <= max(HET_K * sd_pool, 1e-9)):
        bad.append("the resolution gate is not doing its job: it hides %.1f ELO with the gate on "
                   "and %.1f with it off, against a %.1f ELO pooled sd" % (h_on, h_off, sd_pool))
    # overdispersion is charged, and only when it is real
    b1 = merge_rows(homog)[0]
    if b1["phi"] != 1.0 or b1["n_eff"] != b1["n"]:
        bad.append("charged overdispersion on a homogeneous block (phi = %.3f)" % b1["phi"])
    het = [{"x": 0.520, "w": 205.0, "n": 500.0}, {"x": 0.550, "w": 185.0, "n": 500.0}]
    b2 = merge_rows(het)[0]
    if not (1.0 <= b2["phi"] and b2["n_eff"] <= b2["n"]):
        bad.append("n_eff exceeds n")
    print("  [8] merge gates: chi-square tail and quantile vs published critical values, "
          "homogeneity pool/split, min_sep=0, overdispersion: %d failures" % len(bad))
    print("      the RESOLUTION gate, pinned in ELO: on a 1200 ELO/unit fixture it hides %.1f ELO"
          % h_on)
    print("      of response with the gate on and %.1f with it off (%.0f%% of the %g ELO band), "
          "against" % (h_off, 100.0 * h_off / (BAND_HI - BAND_LO), BAND_HI - BAND_LO))
    print("      the %.1f ELO sd the pooled games buy. Measured worth: +326 games [+197,+458] and"
          % sd_pool)
    print("      +0.12 of P(optimal dial) over 288 paired runs on the c1200 truth. Reproduce it:")
    print("      --bench --truths c1200 --seeds 96   against   the same with --het-k inf.")
    for b in bad:
        print("      %s" % b)
    ok &= (not bad) or fail("the merge homogeneity test")

    # 8. termination + calibration ------------------------------------------
    print("  [9] closed loop from the cold start: terminates, and the dial it lands on")
    # WHAT THIS TEST MAY NOW ASSERT, AND WHY IT IS WEAKER THAN IT WAS. It used to require every
    # seed on every truth to certify inside the run cap, and that was sound while more games at
    # a dial could only bring a certificate closer. The two-sided rule makes a lever
    # DESTRUCTIBLE: the dials whose TRUE gap is inside 100 +- 11.25 are the only ones that can
    # ever certify, on a 1400 ELO/unit lever there are one or two of them, and a run that
    # over-collects one before it knows which one it is has lost it for good. So the assertion
    # is now in two parts:
    #   TERMINATION  every run must end in a DEFINITE outcome -- a certificate or an explicit
    #                STOP. A run that is still playing at the cap is the loop failing to
    #                terminate, which is what this test has always been for, and is still fatal.
    #   YIELD        at least CERT_FLOOR of runs must certify. 1 of 48 seeds on `cliff` ends in
    #                a STOP whose reason is "every legal dial in the bracket has been refuted",
    #                which is the correct answer to the state its own games created.
    CERT_FLOOR = 0.95
    print("      %-9s %8s %9s %9s %9s %9s %7s" %
          ("truth", "cert/N", "med games", "rounds", "true gap", "90% cover", "STOP/cens"))
    for tr in list(TRUTHS):
        tot, gaps, rounds, cov, ends = [], [], [], [], []
        for sd in range(args.seeds):
            pol = make_tool(100.0, args.chunk, args.cap, args.trials, args.draws, args.seed,
                            look=args.look)
            g, dg, rn, _end, _pl = run_policy(pol, tr, sd, 100.0, args.chunk, args.maxgames,
                                              look=args.look)
            tot.append(g if g is not None else args.maxgames)
            rounds.append(rn)
            ends.append(_end)
            if g is not None:
                gaps.append(dg)
        rng2 = np.random.default_rng(2026)
        for _ in range(args.reps):
            rws = _mkrows(SELFTEST_DESIGN, tr, rng2)
            d = decide(rws, 100.0, cost, x_cur=None, draws=3000, seed=args.seed, chunk=args.chunk)
            if d["action"] == "DONE":
                continue
            lo, hi = d["best"]["gd_q"]
            cov.append(lo <= truth_gap(tr, d["best"]["x"]) <= hi)
        nst = sum(1 for e in ends if e == "stopped")
        ncen = sum(1 for e in ends if e == "censored")
        ncert = sum(1 for e in ends if e == "certified")
        print("      %-9s %8s %9.0f %9.0f %+9.1f %8.0f%% %7s"
              % (tr, "%d/%d" % (ncert, len(tot)),
                 np.median(tot), np.median(rounds),
                 np.median(gaps) if gaps else float("nan"),
                 100 * np.mean(cov) if cov else float("nan"), "%d/%d" % (nst, ncen)))
        if ncen:
            ok = fail("on truth %s, %d run(s) were still playing at the %d-game cap: the loop "
                      "did not terminate" % (tr, ncen, args.maxgames))
        if ncert < math.ceil(CERT_FLOOR * len(tot)):
            ok = fail("on truth %s only %d of %d runs certified, under the %.0f%% floor"
                      % (tr, ncert, len(tot), 100 * CERT_FLOOR))
    # 10. the variance model (W2) -------------------------------------------
    # Everything above -- Wilson, the cost simulation, the acceptance bar -- is a phi = 1
    # statement. phi = 1 was verified on this campaign's own games (phi = 1.00, 95% [0.85, 1.18],
    # ~290 df, grouped by match process), and this is the contract that keeps it verified: the
    # published +100 rung has 5% of headroom in phi and the measurement's own one-sided upper
    # bound is 1.15, so a protocol change that introduced real overdispersion -- nnRandomize
    # turned back on, a shared opening book, a wall-clock cut that selects on game length -- would
    # be worth catching here rather than in a certificate. A genuine UNDER-dispersion is only
    # conservatism and is reported, not failed.
    mdisp, why = None, ""
    try:
        _dirs = args.sgf_dir
        if not _dirs:
            import deepkyu_ladder as dl
            _dirs = [dl.sgf_dir()]
        mdisp = measure_dispersion(_dirs, getattr(args, "wave_gap", WAVE_GAP_S))
        if mdisp is None:
            why = "no campaign SGFs on this machine"
    except Exception as e:
        why = "%s: %s" % (type(e).__name__, e)
    if mdisp and mdisp["df"] >= DISP_MIN_DF:
        sz = np.array(mdisp["wave_sizes"], float)
        print("  [10] dispersion of the LIVE games, grouped by match process (%d waves, median "
              "size %.0f):" % (mdisp["nwaves"], np.median(sz)))
        print("      phi = %.3f, 95%% [%.3f, %.3f] over %d df (%.0f decided games); one-sided 95%%"
              % (mdisp["phi"], mdisp["ci"][0], mdisp["ci"][1], mdisp["df"], mdisp["N"]))
        print("      bounds [%.3f, %.3f]; plan_phi = %.2f, so the cost model is unchanged%s"
              % (mdisp["lo95_1s"], mdisp["hi95_1s"], mdisp["phi_plan"],
                 "." if mdisp["phi_plan"] == 1.0 else " -- IT IS NOT: the plan now budgets "
                 "n/phi."))
        if mdisp["lo95_1s"] > 1.0:
            ok = fail("the live games are OVERDISPERSED (one-sided 95%% lower bound %.3f > 1): "
                      "every Wilson interval in this file is too narrow by ~sqrt(phi)"
                      % mdisp["lo95_1s"])
        elif mdisp["hi95_1s"] < 1.0:
            print("      UNDER-dispersed (upper bound %.3f < 1): the budget is conservative by at"
                  % mdisp["hi95_1s"])
            print("      most %.0f%%. Reported, not banked -- see plan_phi()."
                  % (100.0 * (1.0 - mdisp["phi"])))
        else:
            print("      phi = 1 is inside the interval: the binomial variance model stands.")
    elif mdisp is not None:
        print("  [10] dispersion contract: SKIPPED -- only %d pooled df on disk, and the plan is "
              "not" % mdisp["df"])
        print("      allowed to react below %d. Nothing here is evidence either way." % DISP_MIN_DF)
    else:
        print("  [10] dispersion contract: SKIPPED (%s), so the phi = 1 assumption is unverified"
              % why)
        print("      HERE. It is verified where the games are; nothing in this run is evidence")
        print("      either way, and plan_phi stays at 1.0.")

    # 11. the JOINT fixed point: games and ladder miss ----------------------
    # THE DEFECT THIS PINS. Cost.miss is E[|gap-T| | THIS DIAL CERTIFIES]: dividing by P(certify)
    # normalises away the probability of ever collecting the certificate, so a dial that certifies
    # 1% of the time is charged almost nothing (in the rare world where it certifies, its gap was
    # in band all along) while a dial that certifies half the time near the target is charged
    # thousands of games. On the live rung 2 that inversion stood the tool on +0.63 -- 39 ELO
    # below the target, P(certify) = 0.01 -- and paid 0 for it. The fix charges
    # M(x) = W*miss(x) + (1-W)*M*, both branches, with M* the miss of the dial the rung certifies
    # at after abandoning x, solved in the SAME value iteration as V*.
    bad = []
    Vc = V_CAP_MULT * 12000.0
    # (a) the live rung-2 prices, as they were printed when the defect was found: +0.63, +1.04 and
    #     +1.12 with their (S, W, miss). Deterministic -- no Monte Carlo in this fixture.
    S_f = np.array([3020.0, 5290.0, 5160.0])
    W_f = np.array([0.01, 0.45, 0.46])
    m_f = np.array([9.20, 13.78, 15.86])
    Vg_f = value_iterate(S_f, W_f, Vc)[0]
    old_tot = Vg_f + P_FID * (m_f - float(np.min(m_f)))          # the charge that was wrong
    Vj, Mj, Vs_f, Ms_f, i_f, sat_f = joint_value_iterate(S_f, W_f, m_f, P_FID, Vc)
    new_tot = Vj + P_FID * (Mj - float(np.min(Mj)))
    if int(np.argmin(old_tot)) != 0:
        bad.append("the rung-2 fixture no longer reproduces the defect it exists to pin")
    if int(np.argmin(new_tot)) == 0:
        bad.append("the joint charge still stands on the dial that certifies 1% of the time")
    print("      [a] live rung-2 prices (S,W,miss): the conditional charge picks x=+0.63 "
          "(P(cert)=0.01,")
    print("          total %.0f vs %.0f); the joint charge picks x=+%.2f (P(cert)=%.2f, total "
          "%.0f vs %.0f)"
          % (old_tot[0], old_tot[1], (0.63, 1.04, 1.12)[int(np.argmin(new_tot))],
             W_f[int(np.argmin(new_tot))], float(np.min(new_tot)), new_tot[0]))
    # (b) the algebra of the fixed point, on random prices: the Bellman equation closes at every
    #     dial, U* is the minimum, and M* / V* are the continuation dial's own values.
    rng = np.random.default_rng(4242)
    for _ in range(200):
        K = int(rng.integers(1, 8))
        Sr = rng.uniform(200.0, 12000.0, K)
        Wr = np.where(rng.random(K) < 0.25, 0.0, rng.uniform(0.02, 1.0, K))   # some cannot certify
        mr = rng.uniform(0.0, 40.0, K)
        pf = float(rng.choice([0.0, 200.0, 800.0, 5000.0]))
        V, M, Vs, Ms, i_s, sat = joint_value_iterate(Sr, Wr, mr, pf, Vc)
        U, Us = V + pf * M, Vs + pf * Ms
        rhs = Sr + pf * Wr * mr + (1.0 - Wr) * (MOVE_COST + Us)
        sc = max(1.0, float(np.max(np.abs(U))))
        if not sat and float(np.max(np.abs(U - rhs))) > 1e-6 * sc:
            bad.append("U(x) != S + p_fid*W*miss + (1-W)*(MOVE+U*) at some dial")
        if not sat and int(np.argmin(U)) != i_s:
            bad.append("the continuation dial is not the argmin of the joint total")
        if Vs > Vc * (1.0 + 1e-9):
            bad.append("V* ran past the games ceiling (%.0f > %.0f)" % (Vs, Vc))
        if not sat and abs(Us - float(np.min(U))) > 1e-3 * sc:
            bad.append("U* is not min_x U(x)")
        if not sat and Wr[i_s] > 1e-9:
            if abs(Ms - mr[i_s]) > 1e-9:
                bad.append("M* is not miss(x*)")
            if abs(Vs - (Sr[i_s] + (1.0 - Wr[i_s]) * MOVE_COST) / Wr[i_s]) > 1e-3 * max(1.0, Vs):
                bad.append("V* is not the games fixed point at x*")
        if pf == 0.0 and float(np.max(np.abs(V - value_iterate(Sr, Wr, Vc)[0]))) > 1e-3 * sc:
            bad.append("p_fid = 0 does not reproduce the games-only value iteration")
        # (c) convergence: the map is monotone and bounded, so the iterates from 0 increase to the
        #     fixed point; and the fixed point does not depend on where the iteration starts.
        cap = Vc + pf * float(np.max(mr))
        F = lambda u: min(float(np.min(Sr + pf * Wr * mr + (1.0 - Wr) * (MOVE_COST + u))), cap)
        u, mono = 0.0, True
        for _ in range(1500):
            un = F(u)
            mono &= (un >= u - 1e-9)
            u = un
        if not mono:
            bad.append("the iterates from 0 are not monotone")
        for u0 in (cap, float(rng.uniform(0.0, cap))):
            v = u0
            for _ in range(1500):
                v = F(v)
            if abs(v - u) > 1e-3 * max(1.0, abs(u)):
                bad.append("the fixed point depends on where the iteration starts (%.3f vs %.3f)"
                           % (v, u))
        if not sat and abs(Us - u) > 1e-2 * max(1.0, abs(u)):
            bad.append("joint_value_iterate did not reach the fixed point (%.3f vs %.3f)"
                       % (Us, u))
    # (d) end to end, on the live rung-2 rows that produced the defect: the action must not be a
    #     dial that cannot plausibly certify, and must land near the target.
    rows_r2 = [{"x": 0.60, "name": "x=+0.6000", "sig": None, "w": 668.0, "n": 1524.0},
               {"x": 0.63, "name": "x=+0.6300", "sig": None, "w": 63.0, "n": 168.0},
               {"x": 0.84, "name": "x=+0.8400", "sig": None, "w": 15.0, "n": 24.0},
               {"x": 1.50, "name": "x=+1.5000", "sig": None, "w": 41.0, "n": 168.0}]
    # RE-POINTED AT 100. This fixture shipped at the old rung-2 target of 86.7, which the
    # two-sided rule cannot certify at ANY sample size (the feasible set is 100 +- 11.25). Every
    # target in the campaign is now 100, and the defect the fixture exists to pin -- standing on
    # a dial that certifies 1% of the time and charging it nothing -- is unchanged by the move.
    d_r2 = decide(rows_r2, 100.0, cost, x_cur=0.60, draws=8000, seed=args.seed, chunk=args.chunk)
    b_r2 = d_r2["best"]
    if abs(d_r2["x_next"] - 0.63) < 1e-9:
        bad.append("end to end, the tool is back on x = +0.63 at rung 2")
    if b_r2["W"] < 0.20:
        bad.append("end to end, the chosen dial certifies with probability %.2f" % b_r2["W"])
    if abs(b_r2["med"] - 100.0) > 15.0:
        bad.append("end to end, the chosen dial's median gap is %+.1f against a target of 100"
                   % b_r2["med"])
    print("      [d] end to end on the live rung-2 rows: PLAY at x = %+.4f, P(certify) = %.2f, "
          "median gap %+.1f" % (d_r2["x_next"], b_r2["W"], b_r2["med"]))
    # (e) THE SATURATED LEVER MUST NOT STAND STILL. Every dial 80 ELO below the band: W = 0
    #     everywhere, so M(x) = M* at every dial and the only thing left in TOTAL is the 150-game
    #     move cost, which says "stay". This is the state that ended 74 rounds and 40000 games at
    #     one dial on truth `far` seed 5 before the charge learned to say it has no opinion.
    rows_sat = [{"x": 0.00, "name": "x=+0.0000", "sig": None, "w": 36.0, "n": 90.0},
                {"x": 0.35, "name": "x=+0.3500", "sig": None, "w": 18860.0, "n": 39910.0}]
    d_sat = decide(rows_sat, 100.0, cost, x_cur=0.35, draws=4000, seed=args.seed,
                   chunk=args.chunk)
    stay = abs(d_sat["x_next"] - 0.35) < 1e-9
    cur_u = [c["miss_u"] for c in d_sat["rec"] if abs(c["x"] - 0.35) < 1e-9]
    if not d_sat["hopeless"] or d_sat.get("fid_basis") != "distance":
        bad.append("a lever no dial can certify on is not reported saturated (%s/%s)"
                   % (d_sat["hopeless"], d_sat.get("fid_basis")))
    if d_sat["action"] == "PLAY" and stay:
        bad.append("the saturated lever stands still on the dial it has 39910 games at")
    if max(c["pen"] for c in d_sat["rec"]) <= 0.0:
        bad.append("the charge is flat on a saturated lever: nothing can move it off a dial")
    if cur_u and d_sat["best"]["miss_u"] > cur_u[0]:
        bad.append("the saturated lever moved AWAY from the target (%.1f -> %.1f ELO)"
                   % (cur_u[0], d_sat["best"]["miss_u"]))
    print("      [e] saturated lever (every dial %s ELO below the band, 39910 games banked at "
          "+0.35):" % "80")
    print("          %s at x = %+.4f, E|gap-T| %.1f -> %.1f ELO, charge spread %.0f games"
          % (d_sat["action"], d_sat["x_next"], cur_u[0] if cur_u else float("nan"),
             d_sat["best"]["miss_u"], max(c["pen"] for c in d_sat["rec"])))
    print("  [11] the joint fixed point (Bellman closure, argmin, M* = miss(x*), monotone "
          "convergence from")
    print("       any start, p_fid = 0 reduces to the games-only iteration), 200 random price "
          "sets: %d failures" % len(bad))
    for b in bad[:8]:
        print("      %s" % b)
    ok &= (not bad) or fail("the joint games/miss fixed point")

    # 12. G1: THE COMMIT GATE AND THE FIDELITY-WEIGHTED OBJECTIVE ------------
    # Both are OFF by default, so most of this section is about what must NOT change. The one
    # measurement it pins is the fact that decided the question: a gate built on the dial's own
    # posterior CANNOT fire on a dial at the moment that dial certifies, because certification is
    # a selection on the same estimate the posterior is centred on.
    bad = []
    if GATE_P != 0.0 or OBJ_K is not None:
        bad.append("G1 is not OFF by default (GATE_P = %r, OBJ_K = %r)" % (GATE_P, OBJ_K))
    rng = np.random.default_rng(20260913)
    # (a) OFF IS OFF. The default call and an explicitly-off call must agree on every field a
    #     driver obeys. p_gate draws no randomness, so no Monte-Carlo stream can move either.
    for _ in range(8):
        tr = list(TRUTHS)[int(rng.integers(0, len(TRUTHS)))]
        design = sorted({round(float(rng.uniform(X_LO, 1.6)), 2): int(rng.integers(200, 2600))
                         for _ in range(int(rng.integers(2, 6)))}.items())
        rws = _mkrows(design, tr, rng)
        a_ = decide(rws, 100.0, cost, draws=1500, seed=args.seed, chunk=args.chunk)
        b_ = decide(rws, 100.0, cost, draws=1500, seed=args.seed, chunk=args.chunk,
                    gate_p=0.0, gate_k=GATE_K, obj_k=None)
        if (a_["action"], a_["x_next"], a_["n_next"]) != (b_["action"], b_["x_next"], b_["n_next"]):
            bad.append("the default decision moves when G1 is switched off explicitly")
    # (b) THE OBJECTIVE IS WHAT IT CLAIMS. W_k = P(certify AND |gap-100| <= k) must be W times
    #     the share of P(certify) that comes from near-100 worlds, must be bounded by W, must be
    #     non-decreasing in k, and must RECOVER W as k -> infinity (so the change is a genuine
    #     generalisation of the shipped objective, not a different simulation).
    _rws = _mkrows(SELFTEST_DESIGN, "rung1", rng)
    _fit = Fit(_rws, B=4000, seed=args.seed)
    _gd = _fit.gap_draws([0.55])[:, 0]
    _w0, _n0 = 300.0, 900.0
    _W = cost.on(_gd, _w0, _n0)[0]
    _prev = -1.0
    for _k in (5.0, 10.0, 15.0, 25.0, 60.0, 1e9):
        _wk = cost.w_good(_gd, _w0, _n0, _k)
        _sh = cost.lottery_share(_gd, _w0, _n0, _k)
        if _wk > _W + 1e-9:
            bad.append("W_k > P(certify) at k = %.0f" % _k)
        if abs(_wk - _W * _sh) > 1e-6:
            bad.append("W_k != P(certify) * share(k) at k = %.0f" % _k)
        if _wk < _prev - 1e-12:
            bad.append("W_k is not non-decreasing in k")
        _prev = _wk
    if abs(cost.w_good(_gd, _w0, _n0, 1e9) - _W) > 1e-9:
        bad.append("W_k does not recover P(certify) as k -> infinity")
    # (c) THE GATE FIRES WHERE IT IS AIMED AND NOWHERE ELSE. The fixture is a dial that is still
    #     ALIVE under the rule (not refuted, not OVERSHOT) but whose own games say it is off
    #     centre. The shipped viability filter (p_centre < 0.01) lets it through; the gate is a
    #     stronger version of the same test, and the THRESHOLD is the whole design question --
    #     at an observed +80 the proposal (p >= 0.25) still lets it through while the tool is
    #     pricing it at W = 0.20, i.e. a one-in-five lottery ticket on a dial 20 ELO out.
    gate_tab = []
    for _g, _n in ((66.0, 1300), (80.0, 1300), (100.0, 800)):     # 800 < N_OPEN, so the centre
                                                                 # fixture is a live dial and not
                                                                 # a certificate (DONE has no rec)
        _r = [{"x": 0.00, "name": "a", "sig": None, "w": float(round(900 * p_of_gap(30.0))),
               "n": 900.0},
              {"x": 0.60, "name": "b", "sig": None, "w": float(round(_n * p_of_gap(_g))),
               "n": float(_n)},
              {"x": 1.20, "name": "c", "sig": None, "w": float(round(600 * p_of_gap(240.0))),
               "n": 600.0}]
        row = []
        for _gp in (0.0, 0.25, 0.50):
            _d = decide(_r, 100.0, cost, draws=4000, seed=11, gate_p=_gp, gate_k=15.0)
            if _d["action"] == "DONE":
                bad.append("the gate fixture at %+.0f/%d already certifies -- it cannot show "
                           "what the gate does to a LIVE dial" % (_g, _n))
                row = [(False, 0.0, 0.0, False)] * 3
                break
            _c = [q for q in _d["rec"] if abs(q["x"] - 0.60) < 1e-9][0]
            row.append((_c["gated"], _c["W"], _c["p_gate"], _c["dead"]))
        if row[0][0]:
            bad.append("a dial is gated with the gate OFF")
        if row[0][3]:
            bad.append("the gate fixture at %+.0f is DEAD, so it cannot show what the gate does"
                       % _g)
        if _g == 100.0 and (row[1][0] or row[2][0]):
            bad.append("the gate refuses a dial whose posterior is ON the centre")
        if _g == 66.0 and not (row[1][0] and row[2][0]):
            bad.append("the gate does not refuse a dial whose posterior says %+.0f" % _g)
        if _g == 80.0 and (row[1][0] or not row[2][0]):
            bad.append("the K=15 gate thresholds moved: %+.0f is no longer let through at 0.25 "
                       "and refused at 0.50" % _g)
        gate_tab.append((_g, _n, row[0][2], row[0][1], row[1][0], row[2][0]))
    # (d) THE ACTION CONTRACT HOLDS UNDER BOTH DESIGNS. Neither touches lever_room(), so neither
    #     can manufacture a round-0 STOP -- at round 0 every posterior is wide, every dial is
    #     gated, and the lever reads `hopeless`, which is the EXPLORATION branch, not STOP.
    nstop0, nseed = 0, max(args.seeds // 4, 6)
    for _kw in (dict(gate_p=0.25, gate_k=15.0), dict(gate_p=0.50, gate_k=10.0), dict(obj_k=15.0)):
        for tr in list(TRUTHS):
            for sd in range(nseed):
                tb = Table(tr, sd)
                rws = [{"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                        "w": tb.play(x, n), "n": float(n)} for x, n in START]
                d_ = decide(rws, 100.0, cost, draws=1500, seed=args.seed, chunk=args.chunk, **_kw)
                if d_["action"] == "STOP":
                    nstop0 += 1
                    bad.append("round-0 STOP on %s seed %d under %s" % (tr, sd, _kw))
                if d_["action"] == "PLAY" and (d_["n_next"] <= 0 or not in_domain(d_["x_next"])):
                    bad.append("PLAY %d at %.4f under %s" % (d_["n_next"], d_["x_next"], _kw))
                if d_["action"] != "PLAY" and d_["n_next"] != 0:
                    bad.append("%s with n_next = %d under %s" % (d_["action"], d_["n_next"], _kw))
        for _ in range(10):
            tr = list(TRUTHS)[int(rng.integers(0, len(TRUTHS)))]
            design = sorted({round(float(rng.uniform(X_LO, 1.6)), 2): int(rng.integers(20, 2600))
                             for _ in range(int(rng.integers(1, 6)))}.items())
            rws = _mkrows(design, tr, rng)
            d_ = decide(rws, 100.0, cost, x_cur=design[-1][0], draws=1500, seed=args.seed,
                        chunk=args.chunk, **_kw)
            try:
                write_decision_json(os.devnull, decision_json(d_, 100.0, rank="15k"))
            except SystemExit as e:
                bad.append("json under %s: %s" % (_kw, e))
    # (e) THE MEASUREMENT THAT DECIDES IT. Run the SHIPPED policy to a certificate, then ask the
    #     tool's own posterior at the dial that certified what p_gate was there. The coverage
    #     half forces the point estimate into [88.7, 111.3] at the moment of certification, and
    #     the posterior at a dial with ~1000-2000 of its own games is centred on that estimate --
    #     so p_gate is HIGH on exactly the certificates a gate is supposed to stop. No gate in
    #     this family can refuse them; both designs act on placement only.
    pg = []
    for tr in ("off90", "step28", "tilt"):
        for sd in range(4):
            tb = Table(tr, sd)
            rws = [{"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                    "w": tb.play(x, n), "n": float(n)} for x, n in START]
            pol = make_tool(100.0, args.chunk, args.cap, args.trials, 2000, args.seed,
                            look=args.look)
            tot, cert = sum(n for _x, n in START), None
            while tot < 20000:
                cert = next((q for q in rws if indep_certified(q["w"], q["n"])), None)
                if cert is not None:
                    break
                act, x, k, _ = pol(rws)
                if act != "PLAY":
                    break
                k = int(min(k, 20000 - tot))
                hit = [q for q in rws if abs(q["x"] - x) < 1e-9]
                if not hit:
                    rws.append({"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                                "w": 0.0, "n": 0.0})
                    rws.sort(key=lambda q: q["x"])
                    hit = [q for q in rws if abs(q["x"] - x) < 1e-9]
                played = 0
                while played < k:
                    st = int(min(args.look, k - played))
                    hit[0]["w"] += tb.play(x, st); hit[0]["n"] += st
                    played += st; tot += st
                    if indep_certified(hit[0]["w"], hit[0]["n"]):
                        break
            if cert is None:
                continue
            gdc = Fit(rws, B=4000, seed=args.seed).gap_draws([cert["x"]])[:, 0]
            pg.append((float(np.mean(np.abs(gdc - BAND_MID) <= 15.0)),
                       float(np.mean(np.abs(gdc - BAND_MID) <= 10.0))))
    if pg:
        p15 = min(q[0] for q in pg)
        p10 = min(q[1] for q in pg)
        ref15 = float(np.mean([q[0] < 0.25 for q in pg]))     # what the PROPOSAL would refuse
        ref10 = float(np.mean([q[1] < 0.50 for q in pg]))     # what the strongest gate reaches
        # THE CLAIM, AND IT IS A SHARE, NOT A BOUND. The coverage half pushes p_gate high on any
        # dial that certifies -- a posterior centred at +85 or +115 splits [85,115] exactly in
        # half, and every certifying ESTIMATE is inside [88.7, 111.3] -- but the posterior is the
        # FIT's, not the dial's own games alone, so it can sit a little off that estimate and
        # p_gate is not bounded below by 0.5 exactly. On 254 certificates the shipped tool
        # produced over 16 truths the distribution is: K=15 min 0.44, 1st percentile 0.60,
        # median 0.84; a K=15 p>=0.25 gate refuses 0 of 254 (and 0 of the 96 that are actually
        # more than 10 ELO off), a K=15 p>=0.50 gate 1 of 254, and a K=10 p>=0.50 gate 12 of 254
        # (8 of the 96 wrong ones). That last 4.7% is the whole of the quality the strongest
        # gate buys, and the cost table above says it costs +875 games a rung.
        if ref15 > 0.0:
            bad.append("the PROPOSED gate (K=15, p>=0.25) refused %.0f%% of the certifying dials "
                       "in this sample -- it refused 0 of 254 when this was measured, so the "
                       "share needs re-measuring" % (100.0 * ref15))
        if p15 < 0.30:
            bad.append("a certifying dial's own K=15 posterior fell to %.2f, below the 0.44 "
                       "minimum measured over 254 certificates" % p15)
        if ref10 <= 0.0 and len(pg) >= 12:
            bad.append("not one certifying dial is within reach of a K=10 p>=0.50 gate: the "
                       "measured 4.7%% reach has gone")
    print("  [12] G1: the COMMIT GATE (a filter) and the FIDELITY-WEIGHTED OBJECTIVE (the same")
    print("       preference in the optimand), both OFF by default: %d failures" % len(bad))
    print("       the gate fixture -- one dial, still ALIVE under the rule, its own games saying:")
    print("       %-12s %6s %8s %8s %10s %10s" % ("observed gap", "n", "p_gate", "W", "gate .25",
                                                  "gate .50"))
    for _g, _n, _pg, _W_, _a, _b in gate_tab:
        print("       %+12.0f %6d %8.3f %8.3f %10s %10s"
              % (_g, _n, _pg, _W_, "refused" if _a else "let through",
                 "refused" if _b else "let through"))
    if pg:
        print("       AND THE FACT THAT DECIDES THE QUESTION: over %d certificates the shipped"
              % len(pg))
        print("       tool actually produced, the tool's own posterior AT THE DIAL THAT CERTIFIED")
        print("       reads p_gate(K=15) min %.2f median %.2f, p_gate(K=10) min %.2f -- because"
              % (p15, float(np.median([q[0] for q in pg])), p10))
        print("       the coverage half forces the ESTIMATE into [%.1f,%.1f] to certify at all"
              % (BAND_MID - MAX_MISS, BAND_MID + MAX_MISS))
        print("       and the posterior sits on it. So the PROPOSED gate (K=15, p>=0.25) refuses")
        print("       %.0f%% of them here (0 of 254 when measured at scale) and the strongest one"
              % (100.0 * ref15))
        print("       (K=10, p>=0.50) reaches %.0f%% (4.7%% at scale). Both designs move games,"
              % (100.0 * ref10))
        print("       not certificates. The whole trade, on both axes and with intervals, is the")
        print("       table above GATE_K in section 5b.")
    for b in bad[:8]:
        print("      %s" % b)
    ok &= (not bad) or fail("the G1 commit gate / fidelity-weighted objective")


    # 13. THE EXTRAPOLANT'S CURVATURE ---------------------------------------
    # WHY THIS SECTION EXISTS, AND WHY IT COULD NOT HAVE FAILED BEFORE. Past the last dial played,
    # gap(x) used to be continued LINEARLY IN x off a reference slope that is a max() of three
    # terms -- a FLOOR, not a second derivative -- so the extrapolant could not see acceleration
    # at all. Every bench truth above is a broken line whose secants wander, so a flat
    # continuation is wrong there only by noise and no test could see the defect. THE LEVER IS
    # NOT LIKE THAT: past x = 4.30 both temperature caps are pinned and the dial weakens through
    # halflife = 30 * 2**(x - 4.30), so equal steps in x are equal DOUBLINGS and the ELO response
    # COMPOUNDS. It cost rung 9 3,706 games. The `compound` truth and the fixtures below are the
    # compounding shape the bench did not have.
    bad = []
    # (a) _accel() IN ISOLATION: identity unless the last two segments accelerate.
    def _acc_of(xs, gaps, **kw):
        """A Fit whose POINT isotonic levels are exactly `gaps` at dials `xs` (n large enough
        that the isotonic fit is the data), and its high-end acceleration factor."""
        rws = [{"x": float(x), "name": "x=%+.6f" % x, "sig": None,
                "w": float(round(p_of_gap(g) * 4000.0)), "n": 4000.0}
               for x, g in zip(xs, gaps)]
        f = Fit(rws, B=200, seed=7, **kw)
        return f, float(f.acc_hi)
    ACC_CASES = [
        # xs,                      gaps,                  expected acc_hi, what it is
        ([0.0, 0.6, 1.2],          [0.0, 24.0, 72.0],     2.0,  "equal widths, secants 40 -> 80"),
        ([0.0, 0.6, 1.2],          [0.0, 48.0, 72.0],     1.0,  "DECELERATING 80 -> 40: identity"),
        ([0.0, 0.6, 1.2],          [0.0, 24.0, 48.0],     1.0,  "LINEAR 40 -> 40: identity"),
        ([0.0, 0.6, 1.2],          [0.0, 12.0, 252.0],    ACC_K, "secants 20 -> 400: CLAMPED"),
        ([0.0, 0.6],               [0.0, 24.0],           1.0,  "two blocks: no previous segment"),
        # width normalisation, and it only ever DAMPS. Same raw ratio of secants (4) in both:
        ([0.0, 0.6, 0.7],          [0.0, 24.0, 40.0],     4.0 ** (0.1 / 0.35),
         "NARROW last segment: secants 40 -> 160, ratio 4 damped to 4**(w_last/dm)"),
        ([0.0, 0.1, 0.7],          [0.0, 4.0, 100.0],     min(4.0, ACC_K),
         "NARROW previous segment: the exponent is capped at 1, never amplified"),
    ]
    for xs, gaps, want, why in ACC_CASES:
        _f, got = _acc_of(xs, gaps)
        if abs(got - want) > 0.02 * max(1.0, want):
            bad.append("_accel %s: got %.3f, want %.3f" % (why, got, want))
        _f2, got2 = _acc_of(xs, gaps, acc_k=1.0)
        if got2 != 1.0:
            bad.append("_accel with acc_k = 1 returned %.3f, not the identity" % got2)
    # A segment narrower than MIN_SEP identifies no slope at all -- the same rule local_slope()
    # uses -- so it must not be read as an acceleration.
    _f, got = _acc_of([0.0, 0.03, 0.63], [0.0, 60.0, 300.0])
    if _f.K == 3 and got != 1.0:
        bad.append("_accel read an acceleration off a segment narrower than MIN_SEP (%.3f)" % got)

    # (b) THE SHALLOW REGIME IS BIT-IDENTICAL, which is the whole of "do not degrade it". On any
    #     design whose point fit does not accelerate, the default Fit must draw the SAME
    #     extrapolation slopes, from the same variates, as the pre-fix tool (acc_k = 1).
    rng13 = np.random.default_rng(1313)
    n_same = n_acc = n_diff = 0
    for _ in range(300):
        k = int(rng13.integers(2, 7))
        design = sorted({round(float(rng13.uniform(X_LO, 1.6)), 2): int(rng13.integers(60, 1200))
                         for _ in range(k)}.items())
        rws = _mkrows(design, "rung1", rng13)
        fa = Fit(rws, B=500, seed=99)
        fb = Fit(rws, B=500, seed=99, acc_k=1.0)
        if fa.acc_hi == 1.0 and fa.acc_lo == 1.0:
            n_same += 1
            if not (np.array_equal(fa.S_hi, fb.S_hi) and np.array_equal(fa.S_lo, fb.S_lo)):
                n_diff += 1
        else:
            n_acc += 1
            if fa.acc_hi < 1.0 or fa.acc_lo < 1.0 or fa.acc_hi > ACC_K or fa.acc_lo > ACC_K:
                bad.append("acceleration factor outside [1, ACC_K]: %.3f / %.3f"
                           % (fa.acc_hi, fa.acc_lo))
    if n_diff:
        bad.append("%d non-accelerating designs changed their extrapolation draws" % n_diff)

    # (c) THE RUNG-9 PLACEMENT, from the arms the tool actually had and against the response the
    #     campaign actually measured. THIS IS THE DEFECT, PINNED. 600-game arms at 3.52/4.12/4.72
    #     reading -3.5/+19.7/+66.8; the flat extrapolant read s_ref ~ 78 ELO/unit, proposed 5.04,
    #     and 5.04 measured +133.7 -- 34 ELO past the centre, P(certify) = 0.00, dead after 3,706
    #     games. The truth below is those four measured points, continued past 5.04 at the secant
    #     they define (209 ELO/unit).
    R9 = [(3.52, -3.5), (4.12, 19.7), (4.72, 66.8), (5.04, 133.7)]
    def r9_truth(x):
        xs = [t[0] for t in R9]; gs = [t[1] for t in R9]
        if x >= xs[-1]:
            return gs[-1] + (x - xs[-1]) * (gs[-1] - gs[-2]) / (xs[-1] - xs[-2])
        return float(np.interp(x, xs, gs))
    r9rows = [{"x": x, "name": "x=%+.6f" % x, "sig": None,
               "w": float(round(p_of_gap(g) * 600.0)), "n": 600.0} for x, g in R9[:3]]
    r9 = {}
    for _lab, _kw in (("flat", {"acc_k": 1.0}), ("geom", {})):
        _f = Fit(r9rows, B=args.draws, seed=args.seed, **_kw)
        _d = decide(r9rows, 100.0, cost, fit=_f, x_cur=None, draws=args.draws, seed=args.seed,
                    chunk=args.chunk, **_kw)
        r9[_lab] = (float(_d["x_next"]), float(_d["best"]["med"]), float(_f.s_ref_hi * _f.acc_hi),
                    float(_f.acc_hi))
    if abs(r9["flat"][0] - 5.04) > 1e-6:
        bad.append("the FLAT extrapolant no longer reproduces the shipped rung-9 dial 5.04 "
                   "(it proposes %.3f), so this fixture no longer pins the defect" % r9["flat"][0])
    if abs(r9["geom"][0] - 5.04) < 1e-9:
        bad.append("the geometric extrapolant proposes the same 5.04 the flat one did")
    _mf = abs(r9_truth(r9["flat"][0]) - 100.0)
    _mg = abs(r9_truth(r9["geom"][0]) - 100.0)
    if _mg >= _mf:
        bad.append("the geometric dial is no closer to the target than the flat one "
                   "(%.1f vs %.1f ELO)" % (_mg, _mf))
    # AND THE POSTERIOR ITSELF IS CALIBRATED, which is the reason the dial moved: at the dial it
    # chooses, the flat median was 39 ELO below the truth.
    _cf = abs(r9["flat"][1] - r9_truth(r9["flat"][0]))
    _cg = abs(r9["geom"][1] - r9_truth(r9["geom"][0]))
    if _cg >= _cf:
        bad.append("the geometric posterior median is no better calibrated at the dial it picks "
                   "(%.1f vs %.1f ELO off the truth)" % (_cg, _cf))

    # (d) THE EXTRAPOLANT'S OWN ERROR ON A COMPOUNDING TRUTH, WITH AN INTERVAL ON EVERY
    #     DIFFERENCE. Three arms inside the compounding stretch, then the posterior is asked for
    #     the gap one and two segments beyond the last of them.
    #
    #     WHAT THIS MEASURES, AND WHAT IT HONESTLY COSTS. The geometric continuation buys BIAS
    #     and pays in SCATTER, and the exchange rate is set by how well the games identify the
    #     ratio. At 600-game arms one segment of this truth is 14 ELO of signal against a ~14 ELO
    #     sd per arm, so a secant has a standard error of ~57 ELO/unit against a true 40-80, and
    #     the ratio of two such secants is a weak measurement: the acceleration factor is much
    #     closer to a PRIOR (the lever's halflife really does double every 0.35 of dial) than to
    #     an estimate. So the pin is on the thing the mechanism is FOR -- the systematic error --
    #     and the scatter it costs is printed beside it rather than hidden. The clamp ACC_K is
    #     what bounds that cost; it is calibrated on the PLACEMENT error over a family of
    #     compounding truths (the table above ACC_K), because expected GAMES cannot resolve it --
    #     on the `compound` truth at the 48-seed --bench default every acc_k's paired mean
    #     difference against flat contains zero.
    XS13, W13 = (0.35, 0.70, 1.05), 0.35
    err = {}
    for _n13 in (600, 2400):
        rng13b = np.random.default_rng(20260915)
        err[_n13] = {"flat": {1: [], 2: []}, "geom": {1: [], 2: []}}
        for _ in range(160):
            rws = _mkrows([(x, _n13) for x in XS13], "compound", rng13b)
            for _lab, _kw in (("flat", {"acc_k": 1.0}), ("geom", {})):
                _f = Fit(rws, B=1500, seed=args.seed, **_kw)
                for _m in (1, 2):
                    _x = XS13[-1] + _m * W13
                    _gd = _f.gap_draws([_x])[:, 0]
                    err[_n13][_lab][_m].append(float(np.median(_gd))
                                               - truth_gap("compound", _x))
    def _boot13(a, b, stat, nboot=2000, sd=11):
        """Paired bootstrap 95% interval on stat(geom) - stat(flat) over the Monte-Carlo designs."""
        a = np.asarray(a, float); b = np.asarray(b, float)
        r = np.random.default_rng(sd)
        idx = r.integers(0, len(a), size=(nboot, len(a)))
        dd = stat(a[idx]) - stat(b[idx])
        return (float(stat(a[None, :])[0] - stat(b[None, :])[0]),
                float(np.quantile(dd, 0.025)), float(np.quantile(dd, 0.975)))
    _absbias = lambda v: np.abs(np.mean(v, axis=1))
    _scat = lambda v: np.mean(np.abs(v), axis=1)
    d13, d13s = {}, {}
    for _n13 in (600, 2400):
        for _m in (1, 2):
            d13[(_n13, _m)] = _boot13(err[_n13]["geom"][_m], err[_n13]["flat"][_m], _absbias)
            d13s[(_n13, _m)] = _boot13(err[_n13]["geom"][_m], err[_n13]["flat"][_m], _scat)
    for _k, _v in sorted(d13.items()):
        if not (_v[2] < 0.0):
            bad.append("on the compounding truth at %d-game arms the geometric extrapolant does "
                       "not measurably reduce the BIAS %d segment(s) out: |bias| difference "
                       "%+.1f ELO 95%% [%+.1f, %+.1f]" % (_k[0], _k[1], _v[0], _v[1], _v[2]))
    print("  [13] the EXTRAPOLANT'S CURVATURE (the rung-9 defect): %d failures" % len(bad))
    print("      %d of %d random designs accelerate at either end; on the other %d the default"
          % (n_acc, n_acc + n_same, n_same))
    print("      draws the SAME extrapolation slopes as acc_k = 1, variate for variate (%d differ)."
          % n_diff)
    print("      RUNG 9, from the 600-game arms 3.52/4.12/4.72 = -3.5/+19.7/+66.8, target 100:")
    print("      %-9s %8s %10s %10s %10s %9s" % ("extrapol", "s_ext", "acc", "x_next",
                                                 "post.med", "TRUE gap"))
    for _lab in ("flat", "geom"):
        _x, _md, _se, _a = r9[_lab]
        print("      %-9s %8.0f %10.2f %10.3f %+10.1f %+9.1f"
              % (_lab, _se, _a, _x, _md, r9_truth(_x)))
    print("      so the shipped (flat) dial misses the centre by %.1f ELO and the geometric one"
          % _mf)
    print("      by %.1f; the posterior median at the dial it picks is %.1f ELO off the truth,"
          % (_mg, _cg))
    print("      against %.1f flat. 5.04 measured +133.7 and died after 3,706 games." % _cf)
    print("      ON THE `compound` TRUTH (secant doubles every %.2f of dial), 160 Monte-Carlo"
          % W13)
    print("      designs of three arms at %s, extrapolating 1 and 2 segments past the last:"
          % ("/".join("%.2f" % x for x in XS13)))
    print("      %-6s %-5s %11s %11s %13s %24s"
          % ("arms", "out", "flat bias", "geom bias", "|bias| diff", "scatter E|err| diff"))
    for _n13 in (600, 2400):
        for _m in (1, 2):
            _b, _l, _h = d13[(_n13, _m)]
            _sb, _sl, _sh = d13s[(_n13, _m)]
            print("      %-6d %-5s %+8.1f E %+8.1f E %+6.1f[%+.0f,%+.0f] %+11.1f [%+.1f, %+.1f]"
                  % (_n13, "%dseg" % _m, np.mean(err[_n13]["flat"][_m]),
                     np.mean(err[_n13]["geom"][_m]), _b, _l, _h, _sb, _sl, _sh))
    print("      THE TRADE, STATED: the flat continuation is SYSTEMATICALLY LOW on a compounding")
    print("      response and the geometric one is not, and it pays for that in scatter wherever")
    print("      the ratio is a weak measurement -- at 600-game arms one segment of this truth is")
    print("      14 ELO of signal against a ~14 ELO per-arm sd, so a secant carries a ~57 ELO/unit")
    print("      standard error and the acceleration factor is nearer a prior than an estimate.")
    print("      ACC_K = %.1f is the clamp that bounds the cost of that, and it is calibrated on"
          % ACC_K)
    print("      the PLACEMENT error over a family of compounding truths -- the table above ACC_K,")
    print("      worst-case excess in ELO: K=1 52.9, K=1.5 7.6, K=2 2.2, K=2.5 2.5, K=3 2.6. GAMES")
    print("      cannot choose it: at the 48-seed --bench default (never fewer) every acc_k's")
    print("      paired mean-games difference against flat contains zero on `compound`.")
    for b in bad[:8]:
        print("      %s" % b)
    ok &= (not bad) or fail("the curvature-aware extrapolant")

    print("\nSELFTEST %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", default="", help='JSON [{"x":..,"w":..,"n":..,"name":..}, ...]')
    ap.add_argument("--rung", type=int, default=0, help="live: scan the ladder SGFs for this rung")
    ap.add_argument("--sgf-dir", action="append", default=None)
    ap.add_argument("--cache", default="")
    ap.add_argument("--sig", default="", help="restrict a live scan to one bot signature")
    ap.add_argument("--rank", default=None, help="weaker rank name, for printing bot names")
    ap.add_argument("--target", type=float, default=None, help="default 100 (the band centre)")
    ap.add_argument("--x-cur", type=float, default=None, help="dial currently set (for the move cost)")
    ap.add_argument("--rate", type=float, default=None, help="games/h, for the hours line only")
    ap.add_argument("--need-json", default="", help="report forward games at one dial and exit")
    ap.add_argument("--at", type=float, default=None, help="the dial for --need-json")
    ap.add_argument("--draws", type=int, default=8000)
    ap.add_argument("--trials", type=int, default=300, help="cost-simulation trials per gap")
    ap.add_argument("--chunk", type=int, default=CHUNK,
                    help="the BUDGET handed to the driver at one dial")
    ap.add_argument("--look", type=int, default=LOOK,
                    help="the interval at which the stop rule is looked at, which the cost model "
                         "simulates. NOT the budget: deepkyu_auto.sh looks every 12 games")
    ap.add_argument("--cap", type=int, default=CAP_GAMES, help="abandon cap, in games at one dial")
    ap.add_argument("--p-fid", type=float, default=None,
                    help="games per ELO of target miss. DEFAULT 0: under the two-sided rule "
                         "P(certify) is itself the fidelity preference and a separate price "
                         "double-counts it. The constant survives only as P_EXPLORE, on a lever "
                         "where nothing can certify")
    ap.add_argument("--tol-t", type=float, default=TOL_T, help="free ELO either side of the target")
    ap.add_argument("--merge-alpha", type=float, default=MERGE_ALPHA,
                    help="G^2 homogeneity level for pooling nearby dials (0 = pool regardless)")
    ap.add_argument("--min-sep", type=float, default=MIN_SEP,
                    help="dials closer than this MAY pool (0 = every dial its own block)")
    ap.add_argument("--acc-k", type=float, default=ACC_K,
                    help="clamp on the GEOMETRIC slope continuation beyond the data: the "
                         "extrapolation slope is s_last * clamp(s_last/s_prev, 1, this). 1.0 "
                         "switches the mechanism off and continues the slope FLAT, which is the "
                         "pre-fix tool and the ablation the --bench sweep is run against")
    ap.add_argument("--sig-acc", type=float, default=SIG_SLOPE_ACC,
                    help="lognormal spread of the extrapolation slope prior in the ACCELERATING "
                         "branch only (floored at SIG_SLOPE = %.2f)" % SIG_SLOPE)
    ap.add_argument("--het-k", type=float, default=HET_K,
                    help="resolution gate: pool only while the hidden response is under this "
                         "many pooled sd. `inf` switches the gate off, which is the ablation "
                         "that measures what it is worth (+326 games on a 1200 ELO/unit truth)")
    # G1. Both OFF by default: the shipped objective is P(certify), which is the goal as
    # written. These exist so the trade can be MEASURED rather than argued (see 5b).
    ap.add_argument("--commit-gate", type=float, default=GATE_P,
                    help="G1a: refuse to stand on a dial whose posterior says "
                         "P(|true gap-100| <= --commit-k) is below this. 0 = off (shipped)")
    ap.add_argument("--commit-k", type=float, default=GATE_K,
                    help="ELO half-width for --commit-gate (default %.0f)" % GATE_K)
    ap.add_argument("--obj-k", type=float, default=None,
                    help="G1b: optimise P(certify AND |true gap-100| <= K) instead of "
                         "P(certify). Unset = off (shipped)")
    ap.add_argument("--seed", type=int, default=20260911)
    ap.add_argument("--json-out", default="")
    ap.add_argument("--no-sensitivity", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--dispersion", action="store_true",
                    help="measure phi on the campaign SGFs (W2) and exit")
    ap.add_argument("--wave-gap", type=float, default=WAVE_GAP_S,
                    help="seconds of quiet that separate two match processes, for --dispersion")
    ap.add_argument("--phi-plan", type=float, default=None,
                    help="planning dispersion for the COST model; default is measured on the "
                         "live SGFs and clamped to [1, %.1f]" % PHI_PLAN_CAP)
    ap.add_argument("--tool-seeds", type=int, default=1,
                    help="--bench: average each place2 row over this many internal Monte-Carlo "
                         "seeds against the same tables (variance reduction, not a new sample)")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--calibrate", action="store_true", help="sweep p_fid against the baselines")
    ap.add_argument("--pfid-grid", default="", help="comma-separated p_fid values for --calibrate")
    ap.add_argument("--truths", default="")
    # WAS 6. A 12-seed run of this bench reported place2 losing 540 games on the c1200 truth and
    # missing the target by 6.0 ELO; at 240 seeds the sign REVERSES (-745 games [-1447,-175]).
    # Subsampling 12-seed blocks out of 240: P(median difference >= +540) = 0.227, and the exact
    # reported pattern occurs 2.7% of the time. The per-seed sd of the paired difference is ~5030
    # games. An acceptance bar that cannot resolve its own criteria manufactures defects; a whole
    # improvement cycle was spent chasing that one.
    ap.add_argument("--seeds", type=int, default=48)
    ap.add_argument("--reps", type=int, default=30)
    ap.add_argument("--maxgames", type=int, default=MAXGAMES)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    if a.dispersion:
        dirs = a.sgf_dir
        if not dirs:
            import deepkyu_ladder as dl
            dirs = [dl.sgf_dir()]
        sys.exit(dispersion_report(measure_dispersion(dirs, a.wave_gap)))
    if a.selftest:
        sys.exit(selftest(a))
    if a.bench:
        sys.exit(bench(a))
    if a.calibrate:
        sys.exit(calibrate(a))
    T = a.target if a.target is not None else 100.0
    rank, strong = a.rank, None
    if a.need_json:
        rows = load_json(a.need_json)
        if a.at is None:
            raise SystemExit("--need-json requires --at X")
        fit = Fit(rows, B=a.draws, seed=a.seed, acc_k=a.acc_k, sig_acc=a.sig_acc)
        r = [q for q in rows if abs(q["x"] - a.at) < 1e-9]
        w0, n0 = (r[0]["w"], r[0]["n"]) if r else (0.0, 0.0)
        gd = fit.gap_draws([a.at])[:, 0]
        fs = forward_summary(gd, w0, n0, chunk=a.look, cap=a.cap, seed=a.seed + 31)
        _med = float(np.median(gd))
        print("dial x = %+.4f   bank %g/%g   posterior gap: median %+.1f, 90%% [%+.1f,%+.1f]"
              % (a.at, w0, n0, np.median(gd), np.quantile(gd, 0.05), np.quantile(gd, 0.95)))
        print("forward games to a certificate, summarised OVER THE GAP POSTERIOR:")
        print("  P(certify before the %d-game abandon cap) = %.2f" % (a.cap, fs["p_cert"]))
        print("  median %s   10-90%% %s - %s"
              % tuple("n/a" if v != v else "%.0f" % v for v in (fs["med"], fs["q10"], fs["q90"])))
        print("  the WINDOW at the median gap %+.1f: it %s." % (_med, window_note(_med)))
        print("  deepkyu_tally.games_needed() is the ONE-SIDED power table and")
        print("  answers a question the two-sided rule no longer asks: the requirement is an")
        print("  INTERVAL in n, bounded above as well as below, so no single N answers it and a")
        print("  game-count line may be advising games that DESTROY the certificate. The ladder")
        print("  status lines report deepkyu_tally.cert_outlook() -- the same pair as above,")
        print("  computed from the bucket's own bank -- instead of a count.")
        return
    scan_dirs = a.sgf_dir or None
    if a.data:
        rows = load_json(a.data)
    elif a.rung:
        import deepkyu_ladder as dl
        dirs = a.sgf_dir or [dl.sgf_dir()]
        scan_dirs = dirs
        cache = a.cache or os.path.join(dl.RUN, "cache_ladder.json")
        rows, strong, rank, nfiles, warns = load_live(a.rung, dirs, cache, a.sig or None)
        for w in warns:
            print(w, file=sys.stderr)
        st = dl.load()
        if a.target is None:
            T = float(dl.target_gap_for(st, a.rung - 1)) if hasattr(dl, "target_gap_for") \
                else float(st.get("target", 100.0))
        if a.x_cur is None:
            a.x_cur = float(st["ranks"][a.rung - 1]["x"])
        if a.rate is None:
            a.rate = 56.0 if a.rung == 1 else 740.0
    else:
        raise SystemExit("give --data FILE or --rung N (or --selftest / --bench)")
    if not rows:
        raise SystemExit("no games at all for this rung: play a first chunk anywhere legal")
    # W2. The cost model plans with a STATED dispersion instead of a silent phi = 1. It is
    # measured on the same SGFs the games came from, clamped to [1, PHI_PLAN_CAP] and ignored
    # below DISP_MIN_DF degrees of freedom -- so on today's campaign (phi = 1.00 [0.86,1.19],
    # 289 df) it is exactly 1.0 and nothing moves. NOTE, measured and NOT as first claimed: raising
    # the PLAN phi does not buy materially more games (at plan phi 1.3/2.0/4.0 the played games
    # barely move), because phi enters only the forward COST simulation and never the certification
    # rule. So this is a planning refinement, NOT protection against real overdispersion -- real
    # overdispersion raises P(false certificate) and only a wider Z_STOP would answer that.
    # The manual override used to bypass plan_phi()'s clamp entirely, so --phi-plan 0.43 (a value
    # that would shrink planned games on an UNMEASURED claim) and --phi-plan 3.0 were both accepted
    # silently. Clamp the override to the same [1, PHI_PLAN_CAP] the measured path uses: phi below 1
    # must never be usable to plan FEWER games, because the campaign has no evidence for it.
    if a.phi_plan is not None:
        _raw = float(a.phi_plan)
        phi_plan = min(max(_raw, 1.0), PHI_PLAN_CAP)
        if abs(phi_plan - _raw) > 1e-9:
            print("--phi-plan %.3f clamped to %.3f (allowed range [1, %.2f])"
                  % (_raw, phi_plan, PHI_PLAN_CAP), file=sys.stderr)
    else:
        phi_plan = 1.0
    disp = None
    if a.phi_plan is None and scan_dirs:
        try:
            disp = measure_dispersion(scan_dirs, a.wave_gap)
        except Exception as e:                     # a diagnostic must never take the tool down
            print("dispersion not measured (%s: %s); planning with phi = 1"
                  % (type(e).__name__, e), file=sys.stderr)
        if disp:
            phi_plan = disp["phi_plan"]
            print("dispersion: phi = %.3f 95%% [%.3f,%.3f] over %d df (%.0f decided games, "
                  "wave level) -> plan_phi = %.2f"
                  % (disp["phi"], disp["ci"][0], disp["ci"][1], disp["df"], disp["N"], phi_plan),
                  file=sys.stderr)
            if disp["lo95_1s"] > 1.0:
                print("!! OVERDISPERSED: the one-sided 95%% lower bound is %.3f > 1. Every Wilson "
                      "interval in this rung is too narrow; run --dispersion."
                      % disp["lo95_1s"], file=sys.stderr)
    cost = Cost(chunk=a.look, cap=a.cap, trials=a.trials, seed=a.seed, phi=phi_plan)
    fit = Fit(rows, B=a.draws, seed=a.seed, min_sep=a.min_sep, merge_alpha=a.merge_alpha,
              het_k=a.het_k, acc_k=a.acc_k, sig_acc=a.sig_acc)
    p_fid_use = 0.0 if a.p_fid is None else float(a.p_fid)
    if a.p_fid is None:
        print("p_fid = 0: the two-sided rule puts the target preference inside P(certify), so a "
              "separate exchange rate double-counts it, and with every target pinned at %.0f "
              "there is no span budget left for it to allocate. P_EXPLORE = %.0f still applies "
              "on a lever where nothing can certify." % (BAND_MID, P_EXPLORE), file=sys.stderr)
    g1 = {"gate_p": float(a.commit_gate), "gate_k": float(a.commit_k),
          "obj_k": (None if a.obj_k is None else float(a.obj_k))}
    d = decide(rows, T, cost, fit=fit, x_cur=a.x_cur, draws=a.draws, seed=a.seed, chunk=a.chunk,
               p_fid=p_fid_use, tol_t=a.tol_t, het_k=a.het_k, acc_k=a.acc_k, sig_acc=a.sig_acc,
               **g1)
    if not a.no_sensitivity and d["action"] != "DONE":
        d["sens"] = sensitivity(rows, T, cost, a.x_cur, a.draws, a.seed, a.chunk, p_fid_use,
                                a.tol_t, base={"min_sep": a.min_sep, "merge_alpha": a.merge_alpha,
                                               "acc_k": a.acc_k, "sig_acc": a.sig_acc},
                                **g1)
    report(rows, T, d, cost, rank=rank or a.rank, strong=strong, rate=a.rate)
    if a.json_out:
        write_decision_json(a.json_out, decision_json(d, T, rank=rank or a.rank,
                                                      strong=strong))


if __name__ == "__main__":
    main()
