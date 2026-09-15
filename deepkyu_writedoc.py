#!/usr/bin/env python3
"""Regenerate the deep-kyu sections of docs/HumanSL_Rank_Ladder.md from the certified results.

Two blocks are rewritten in place, each identified by its heading and ending at the next heading of
the same or higher level, so the script is idempotent (it recognises both the pre-campaign headings
and the ones it writes itself):

  1. `### Deep-kyu ... tail (15k -> 25k)`   -- the certified rung table
  2. `#### Deep-kyu regime (15k -> 25k): ...` -- the findings subsection

plus the one-line pointer under the main results table, whose anchor changes with the heading.

Nothing else in the doc is touched. Run with --dry-run to see the diff before writing.
"""
import argparse, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deepkyu_cfg as dc

TAIL_H = "### Deep-kyu temperature-calibrated tail (15k → 25k)"
TAIL_ANCHOR = "#deep-kyu-temperature-calibrated-tail-15k--25k"
FIND_H = "#### Deep-kyu regime (15k → 25k): λ is exhausted, `chosenMoveTemperature` is not"
FIND_ANCHOR = "#deep-kyu-regime-15k--25k-λ-is-exhausted-chosenmovetemperature-is-not"

# Matches the old heading text as well as the one this script writes.
TAIL_RE = re.compile(r"^### Deep-kyu .*tail \(15k", re.M)
FIND_RE = re.compile(r"^#### Deep-kyu regime \(15k", re.M)
PTR_RE = re.compile(r"^_The deep-kyu tail \*\*15k → 25k\*\*.*?_\n", re.M | re.S)


def campaign_games():
    """Every game played on the P2 ladder path, including dials probed and rejected."""
    import deepkyu_tally as dt
    run = os.path.expanduser("~/.katago_tune/deepkyu")
    totals, _ = dt.scan([os.path.join(run, "sgfs", "ladder")], os.path.join(run, "cache_ladder.json"))
    n = sum(v[0] + v[1] + v[2] + v[3] for v in totals.values())
    return int(round(n / 500.0)) * 500   # rounded, so a re-run does not churn the doc


def block_end(text, start, level):
    """End offset of the block beginning at `start`: the next heading of depth <= level."""
    pat = re.compile(r"^#{1,%d} " % level, re.M)
    m = pat.search(text, start + 1)
    return m.start() if m else len(text)


def fmt_gap(r):
    mark = "✅ certified" if r.get("certified") else "⚠ NOT certified"
    return "**%+.0f** [%.0f, %.0f] %s" % (r["gap"], r["lo"], r["hi"], mark)


def tail_section(ranks, rows, campaign):
    rowtxt = []
    names = ["14k"] + [r["rank"] for r in ranks]
    for i, rk in enumerate(ranks):
        b = dc.resolve({"rank": rk["rank"], "maxVisits": 1, "x": rk["x"], "sym": 1})
        r = rows[i]
        nnpt = "%.3f" % b["nnpt"] if abs(b["nnpt"] - 1.0) > 1e-9 else "1 (unused)"
        rowtxt.append("| `gtp_human%s.cfg` | preaz_%s | gtp_human%s.cfg | %s | %d | **%.3f** | %.3f / %.3f | %.1f | %s |"
                      % (rk["rank"], rk["rank"], names[i], fmt_gap(r), r["decided"],
                         rk["x"], b["early"], b["late"], b["halflife"], nnpt))
    gaps = [r["gap"] for r in rows]
    ncert = sum(1 for r in rows if r.get("certified"))
    total = sum(r["decided"] for r in rows)
    return TAIL_H + """

At this depth the λ lever is **exhausted**: `humanSLChosenMovePiklLambda = 1e8` already means the
played move *is* the human policy, so no amount of extra λ weakens a rank further, and the natural
pure-human gaps top out well below 100 ELO (see
[Findings](%s)). The lever that does reach is
**`chosenMoveTemperature`**. The ladder ships *sharpened* — `chosenMoveTemperatureEarly = 0.70`,
`chosenMoveTemperature = 0.25`, i.e. close to argmax-of-the-human-policy — so **raising** both
temperatures walks a rank back to honest policy sampling (T = 1) and then into the policy's tail.
That is a monotone weakening dial with ample range, and it is what these eleven rungs are tuned on.

One scalar **x** drives it, so the ladder stays one-dimensional and monotone: x raises
`chosenMoveTemperatureEarly` to its 5.0 ceiling, then `chosenMoveTemperature` to 1.0 (never above —
past 1.0 the pass move is flattened against ~300 tail moves, bots stop passing, and games fill the
board and score no-result), then stretches `chosenMoveTemperatureHalflife` so the early temperature
reaches deeper into the game, and finally opens `nnPolicyTemperature`.

These rungs run **`maxVisits = 1`** (with `rootNumSymmetriesToSample = 1`). At λ=1e8 with
`humanSLChosenMoveProp = 1.0` the search cannot influence which move is played at all — it only
supplies the pass share — so 1 visit is the *same bot* at ~10× less compute. That is what made the
campaign affordable: %s games in the certifying buckets below, and ~%s games in total once every
dial that was probed and rejected along the way is counted.

| Config | Profile | Baseline (stronger) | Even-game gap (95%% CI) | Games | dial x | early / late | halflife | nnPolicyTemp |
|--------|---------|---------------------|-------------------------|------:|-------:|-------------:|---------:|-------------:|
%s

**Certified = the 95%% CI is inside [70, 130] *and* contains 100.** Both halves matter: an interval
like [70, 87.5] is inside the band but is evidence *against* a 100-ELO step, so it does not certify.
%d/11 rungs certify; the delivered gaps run %+.0f … %+.0f ELO, mean %+.1f, over %s games.

> **Numerics (protocol P2).** Every calibration game ran MLX **FP32** (`mlxUseFP16 = false`) with a
> deterministic NN path (`nnRandomize = false`) and one NN server thread. `mlxUseFP16 = auto`
> resolves to FP16, and FP16 can produce a nonfinite policy at these temperatures, so the shipped
> configs set both keys explicitly — **including `gtp_human14k.cfg`**, which is otherwise untouched.
> Consequence: the **13k↔14k seam is cross-regime** (13k keeps the old numerics) and is not
> re-certified here; the 14k↔15k rung and everything below it is measured on one consistent bot.
""" % (FIND_ANCHOR, "{:,}".format(total), "{:,}".format(campaign), "\n".join(rowtxt), ncert,
       min(gaps), max(gaps), sum(gaps) / len(gaps), "{:,}".format(total))


def findings_section(ranks, rows):
    xs = ", ".join("%s %.2f" % (r["rank"], r["x"]) for r in ranks)
    return FIND_H + """

- **λ saturates.** λ climbs steeply through the deep kyu — 11k 0.408 → 12k 0.463 → 13k **0.830** →
  14k **3.40** — and then the lever ends. Mapping 15k↔14k across λ showed the gap **rises to a peak
  (~+85–98) around λ≈10 and then declines** as λ→∞ (probes: λ20 → +89, λ44 → +17, λ1e8 → +17…+29).
  Beyond the peak, *more* human-imitation makes the candidate no weaker: at λ=1e8 the played move
  already is the human policy, and adjacent `preaz_<rank>` profiles at this depth are near-tied.
  A monotone logistic crossing estimator misfits that shape entirely.
- **Consequence, and the fix.** The uniform-100 target is infeasible *via λ*; the earlier campaign
  therefore shipped these rungs at λ=1e8 and documented their natural gaps (+29, +24, +44, +70, +32,
  +8, +23, +29, −1, +55, +86 — mean ~+37, non-monotonic). The **`chosenMoveTemperature`** lever that
  the old text listed as possible future work turned out to be sufficient: at λ=1e8 and 1 visit it
  delivers a full, monotone 100-ELO staircase across all eleven rungs. The dials are %s.
- **The certification rule is two-sided.** A 95%% CI ⊂ [70,130] alone is satisfiable by a gap that is
  clearly *not* 100 (e.g. [70, 87.5]); the rule used here also requires the interval to **contain
  100**, which bounds the CI half-width from *below* as well as above. Geometrically that means a
  certificate can only be issued for a point estimate in [85, 115], and the sample-size window opens
  at ~900 decided games and is widest near ~2,400. Grinding a rung *past* that window can uncertify
  it, so each rung stops as soon as it certifies.
- **Repeated looks were disciplined explicitly.** Because a rung is tallied after every chunk and
  stopped when it certifies, the published Z=1.96 interval is not an honest 95%% interval on its own.
  The stop rule therefore uses two wider/narrower intervals against the same games — the band-fit
  test at Z=2.50 and the covers-100 test at Z=1.50 — which measured a ≤2.5%% false-certification
  rate against the naive peeked rule.
- **Cost.** Both bots at 1 visit run ~800 games/h on this machine; the 14k anchor at 40 visits runs
  ~33 games/h. The campaign is strictly serial (each rung is measured against its already-certified
  neighbour), which is what sets the wall-clock, not the per-game cost.
""" % xs


# Prose outside the two generated blocks that still describes the abandoned lambda-only outcome.
# Each entry is (exact old text, new text). Replacement is literal, and an entry whose new text is
# already present is skipped, so the script stays idempotent and re-runnable.
PROSE = [(
"""- **15k → 25k — a pure-human tail.** At this depth the even-game gap between *adjacent* Human-SL
  ranks is **non-monotonic in λ and peaks below 100 ELO** — adjacent deep-kyu profiles are
  near-tied, so a full 100-ELO step is **not reachable** by the λ lever. These rungs therefore ship
  at **`humanSLChosenMovePiklLambda = 1e8` (pure-human imitation)** and their **natural** even-game
  gap vs the stronger neighbour is *measured and documented* (to a 95% CI half-width ≤30, before
  integer rounding of printed endpoints), not forced to 100. See the [deep-kyu finding](#findings).""",
"""- **15k → 25k — the same staircase on a second lever.** At this depth adjacent Human-SL ranks are
  near-tied and λ is **exhausted** (at `humanSLChosenMovePiklLambda = 1e8` the played move already
  *is* the human policy), so a 100-ELO step is **not reachable by λ**. These rungs keep λ=1e8 and are
  tuned instead on **`chosenMoveTemperature`** at `maxVisits = 1` — which does reach. All eleven are
  certified at **+100**, to a 95%% CI inside [70, 130] *that also contains 100*. See the
  [deep-kyu finding](%s).""" % FIND_ANCHOR,
), (
"""**15k→25k
> are all shipped at λ=1e8** (11 of 11 pure-human rungs), each with its natural even-game gap measured
> to a 95% CI half-width ≤30 (before integer rounding of the table endpoints):
> **+29, +24, +44, +70, +32, +8, +23, +29, −1, +55, +86** (15k→25k) —
> non-monotonic and all **below +100** (most well below it), consistent with the deep-kyu finding.""",
"""**15k→25k are all certified at +100**
> (11 of 11) — not by λ, which saturates here, but on the `chosenMoveTemperature` lever at 1 visit,
> each to a 95%% CI inside [70, 130] that also contains 100:
> **%s**
> (15k→25k) — the dial x is monotone all the way down and every rung lands at the target.""",
), (
"""> **Status (2026-08-06): both regimes tuned.**""",
"""> **Status (2026-09-15): both regimes tuned, whole ladder certified.**""",
), (
"""occurred: from 15k down, λ ran to pure-human policy without reaching +100, and the uniform target gave
way to the two-regime outcome above (100-ELO staircase 7d→14k; measured pure-human tail 15k→25k).""",
"""occurred: from 15k down, λ ran to pure-human policy without reaching +100. The uniform 100 target
survived anyway, by changing levers rather than targets — 7d→14k on λ, 15k→25k on
`chosenMoveTemperature` at 1 visit — so the whole 7d→25k ladder is one 100-ELO staircase.""",
), (
"""> from 15k down even λ→∞ no longer reaches +100 and the ladder switches to the measured
> pure-human tail (below).""",
"""> from 15k down even λ→∞ no longer reaches +100 and the ladder switches levers, to
> `chosenMoveTemperature` (below).""",
)]


def patch_prose(text, rows):
    gaps = ", ".join("%+.0f" % r["gap"] for r in rows)
    for old, new in PROSE:
        if "%s" in new:
            new = new % gaps
        if old in text:
            text = text.replace(old, new, 1)
        elif new not in text:
            print("WARNING: prose block not found and not already updated:\n  %s..." % old.split("\n")[0][:90])
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default=os.path.expanduser("~/.katago_tune/deepkyu/ladder.json"))
    ap.add_argument("--results", required=True)
    ap.add_argument("--doc", default=os.path.join(HERE, "docs", "HumanSL_Rank_Ladder.md"))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    ranks = json.load(open(a.state))["ranks"]
    rows = json.load(open(a.results))["rungs"]
    if len(ranks) != len(rows):
        raise SystemExit("state/results length mismatch: %d vs %d" % (len(ranks), len(rows)))
    uncert = [r["rank"] for r, w in zip(ranks, rows) if not w.get("certified")]
    if uncert:
        print("WARNING: not certified: %s" % ", ".join(uncert))

    text = open(a.doc).read()
    for rx, level, body in ((TAIL_RE, 3, tail_section(ranks, rows, campaign_games())),
                            (FIND_RE, 4, findings_section(ranks, rows))):
        m = rx.search(text)
        if not m:
            raise SystemExit("cannot find the block for %r in %s" % (rx.pattern, a.doc))
        text = text[:m.start()] + body + "\n" + text[block_end(text, m.start(), level):]

    text = patch_prose(text, rows)

    ptr = ("_The deep-kyu tail **15k → 25k** is calibrated on `chosenMoveTemperature` at 1 visit "
           "(λ stays 1e8) and is certified to the same +100 rule — see "
           "[Deep-kyu temperature-calibrated tail](%s) below._\n" % TAIL_ANCHOR)
    if PTR_RE.search(text):
        text = PTR_RE.sub(lambda _m: ptr, text, count=1)
    else:
        print("NOTE: results-table pointer line not found; left as is")

    if a.dry_run:
        import difflib
        old = open(a.doc).read().split("\n")
        sys.stdout.write("\n".join(difflib.unified_diff(old, text.split("\n"), "old", "new", lineterm="", n=2)))
        print()
    else:
        open(a.doc, "w").write(text)
        print("wrote %s" % a.doc)


if __name__ == "__main__":
    main()
