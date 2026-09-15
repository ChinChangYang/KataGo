#!/usr/bin/env python3
"""Write the calibrated dials + certified headers into cpp/configs/gtp_human<rank>.cfg.

Only the deep-kyu tail (15k..25k) is touched; gtp_human14k.cfg and everything above it are the
already-certified anchor and are never modified. Per config exactly five value lines change
(maxVisits, numSearchThreads, rootNumSymmetriesToSample, the two chosenMoveTemperature*
lines and the halflife),
plus the three header comment lines.
"""
import argparse, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deepkyu_cfg as dc

HEAD = ("# CALIBRATED DEEP-KYU (Japanese, even-game ELO ladder (komi 6.5, alternating colors; "
        "1 visit; winLossUtilityFactor=0; b28c512 main net; MLX FP32)): {profile} vs {baseline} at "
        "chosenMoveTemperatureEarly={early}/chosenMoveTemperature={late}/Halflife={hl} "
        "(weakening dial x={x}; humanSLChosenMovePiklLambda stays 1e8 = pure-human move choice). "
        "Even game = {wr:.1f}% -> gap {gap:+.0f} ELO [{lo:.0f},{hi:.0f}] over {n} games "
        "(target 100, 95% CI ⊂ [70,130]). See docs/HumanSL_Rank_Ladder.md.")
HEAD2 = "# gtp_human{rank}.cfg — {rank} rung (deep-kyu temperature-calibrated tail) of the Human-SL even-game ELO ladder."


def patch(path, rank, dials, meas, dry):
    with open(path) as f:
        lines = f.read().split("\n")
    # drop the old leading comment block (the 3 generated header lines)
    i = 0
    while i < len(lines) and lines[i].startswith("#"):
        i += 1
    run_line = [l for l in lines[:i] if l.startswith("# Run:")]
    body = lines[i:]

    def setkey(key, val):
        pat = re.compile(r"^%s\s*=" % re.escape(key))
        for j, l in enumerate(body):
            if pat.match(l):
                body[j] = "%s = %s" % (key, val)
                return True
        return False

    ok = all([
        setkey("maxVisits", dials["maxVisits"]),
        # measured with one search thread; at one visit it is what the calibration games used
        setkey("numSearchThreads", dials.get("searchThreads", 1)),
        setkey("rootNumSymmetriesToSample", dials["sym"]),
        setkey("chosenMoveTemperatureEarly", "%.4f" % dials["early"]),
        setkey("chosenMoveTemperature", "%.4f" % dials["late"]),
        setkey("chosenMoveTemperatureHalflife", "%.4f" % dials["halflife"]),
    ])
    # The deepest rungs continue past the temperature family onto nnPolicyTemperature, which is not
    # in the stock config, so add the line rather than replacing one.
    # The calibrated bot runs FP32 with a deterministic NN path; gtp_human*.cfg sets neither, and
    # `mlxUseFP16 = auto` resolves to FP16 (mlxbackend.cpp:9). Without these two lines every
    # certificate would describe a bot nobody runs.
    for key, val in (("mlxUseFP16", "false"), ("nnRandomize", "false")):
        if not setkey(key, val):
            for j, l in enumerate(body):
                if l.startswith("nnCacheSizePowerOfTwo"):
                    body.insert(j, "%s = %s" % (key, val)); break
    nnpt = float(dials.get("nnpt", 1.0))
    if abs(nnpt - 1.0) > 1e-9 and not setkey("nnPolicyTemperature", "%.4f" % nnpt):
        for j, l in enumerate(body):
            if l.startswith("chosenMoveTemperatureHalflife"):
                body.insert(j + 1, "nnPolicyTemperature = %.4f" % nnpt)
                break
    if not ok:
        raise SystemExit("missing a key in %s" % path)
    head = [HEAD.format(profile="preaz_" + rank, baseline=meas["baseline"],
                        early="%.4f" % dials["early"], late="%.4f" % dials["late"],
                        hl="%.4f" % dials["halflife"], x="%.3f" % dials["x"],
                        wr=100 * meas["winrate"], gap=meas["gap"], lo=meas["lo"],
                        hi=meas["hi"], n=meas["decided"]),
            HEAD2.format(rank=rank)] + run_line
    out = "\n".join(head + body)
    if dry:
        print("=== %s ===\n%s\n%s" % (path, head[0][:160] + "...", "\n".join(
            l for l in body if re.match(r"^(maxVisits|rootNumSym|chosenMoveTemperature)", l))))
    else:
        with open(path, "w") as f:
            f.write(out)
        print("wrote %s" % path)


def patch_anchor(path, dry):
    """The 14k anchor keeps every play dial it ships with -- it is already certified against 13k --
    but the calibration necessarily runs it on the P2 NN path (FP32, deterministic symmetries),
    and gtp_human14k.cfg sets neither key, so it would ship as FP16 + nnRandomize=true. That is a
    DIFFERENT bot from the one that plays the 14k-15k rung, which would void rung 1's certificate.
    So the anchor gets these two backend lines and nothing else."""
    with open(path) as f:
        body = f.read().split("\n")
    changed = []
    for key, val in (("mlxUseFP16", "false"), ("nnRandomize", "false")):
        pat = re.compile(r"^%s\s*=" % re.escape(key))
        hit = False
        for j, l in enumerate(body):
            if pat.match(l):
                if l.strip() != "%s = %s" % (key, val):
                    body[j] = "%s = %s" % (key, val); changed.append(key)
                hit = True
                break
        if not hit:
            for j, l in enumerate(body):
                if l.startswith("nnCacheSizePowerOfTwo"):
                    body.insert(j, "%s = %s" % (key, val)); changed.append(key); break
            else:
                raise SystemExit("no nnCacheSizePowerOfTwo anchor line in %s" % path)
    if dry:
        print("=== %s (anchor, backend keys only) === would set: %s" % (path, ", ".join(changed) or "nothing"))
    else:
        with open(path, "w") as f:
            f.write("\n".join(body))
        print("wrote %s (anchor: %s)" % (path, ", ".join(changed) or "already correct"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default=os.path.expanduser("~/.katago_tune/deepkyu/ladder.json"))
    ap.add_argument("--results", required=True, help="json from deepkyu_tally --json-out")
    ap.add_argument("--configs", default=os.path.join(HERE, "cpp", "configs"))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    st = json.load(open(a.state))
    res = json.load(open(a.results))["rungs"]
    if len(res) != len(st["ranks"]):
        raise SystemExit("results/ranks length mismatch")
    names = ["14k"] + [r["rank"] for r in st["ranks"]]
    patch_anchor(os.path.join(a.configs, "gtp_human14k.cfg"), a.dry_run)
    for i, r in enumerate(st["ranks"]):
        b = dc.resolve({"rank": r["rank"], "maxVisits": 1, "x": r["x"], "sym": 1})
        meas = dict(res[i]); meas["baseline"] = "gtp_human%s.cfg" % names[i]
        if not meas.get("certified"):
            print("WARNING: %s rung is NOT certified: %s" % (r["rank"], meas.get("gap")))
        b["x"] = r["x"]
        patch(os.path.join(a.configs, "gtp_human%s.cfg" % r["rank"]), r["rank"], b, meas, a.dry_run)


if __name__ == "__main__":
    main()
