#!/usr/bin/env python3
"""Guard: every play-affecting parameter must be IDENTICAL between the bot that was calibrated
(the `katago match` config) and the bot that ships (gtp_human<rank>.cfg).

This exists because the campaign nearly certified FP32 measurements and shipped FP16 bots:
no gtp_human*.cfg sets mlxUseFP16, and `mlxUseFP16 = auto` resolves to fp16 (mlxbackend.cpp:9),
while the calibration config sets it false. Every certificate would have described a bot nobody
runs. Nothing ships unless this reports OK.
"""
import re, sys, os
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)

# Anything that can change which move comes out, or the numerics that produce it.
PLAY_KEYS = [
    "maxVisits", "numSearchThreads", "humanSLProfile", "humanSLChosenMovePiklLambda",
    "humanSLChosenMoveProp", "humanSLChosenMoveIgnorePass",
    "humanSLRootExploreProbWeightless", "humanSLRootExploreProbWeightful",
    "humanSLPlaExploreProbWeightless", "humanSLPlaExploreProbWeightful",
    "humanSLOppExploreProbWeightless", "humanSLOppExploreProbWeightful",
    "humanSLCpuctExploration", "humanSLCpuctPermanent",
    "chosenMoveTemperature", "chosenMoveTemperatureEarly", "chosenMoveTemperatureHalflife",
    "chosenMoveTemperatureOnlyBelowProb", "chosenMoveSubtract", "chosenMovePrune",
    "rootNumSymmetriesToSample", "winLossUtilityFactor", "staticScoreUtilityFactor",
    "dynamicScoreUtilityFactor", "useLcbForSelection", "useUncertainty",
    "subtreeValueBiasFactor", "useNoisePruning", "nnPolicyTemperature",
    "rootPolicyTemperature", "rootPolicyTemperatureEarly", "rootNoiseEnabled",
    "mlxUseFP16", "nnRandomize", "numNNServerThreadsPerModel",
    "deviceToUseThread0", "deviceToUseThread1",
]
# KataGo's own defaults, for a key absent from BOTH files (setup.cpp / mlxbackend.cpp).
DEFAULTS = {"nnPolicyTemperature": "1.0", "rootPolicyTemperature": "1.0",
            "rootPolicyTemperatureEarly": "1.0", "rootNoiseEnabled": "false",
            "chosenMoveTemperatureOnlyBelowProb": "1.0", "chosenMoveSubtract": "0",
            "chosenMovePrune": "0", "mlxUseFP16": "auto->FP16", "nnRandomize": "true",
            "numNNServerThreadsPerModel": "1", "deviceToUseThread0": "<default>",
            "deviceToUseThread1": "<default>"}


def norm(v):
    v = v.strip()
    try:
        f = float(v)
        return ("%.6f" % f).rstrip("0").rstrip(".")
    except ValueError:
        return v.lower()


def parse(path, idx=None):
    """Effective values: a per-bot `key<idx>` wins over the bare `key`."""
    out = {}
    if not os.path.exists(path):
        raise SystemExit("missing config: %s" % path)
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        # A trailing number is a per-bot index ONLY if the key is not itself a known key --
        # `mlxUseFP16` ends in "16", and treating it as an index silently hid the precision
        # mismatch this whole guard exists to catch.
        m = None if k in PLAY_KEYS else re.match(r"^([A-Za-z]+)(\d+)$", k)
        if m and idx is not None and m.group(2) == str(idx):
            out[m.group(1)] = norm(v)
        elif not m:
            out.setdefault(k, norm(v))
    return out


def check(rank, shipped_path, match_path, bot_idx):
    ship, match = parse(shipped_path), parse(match_path, bot_idx)
    bad = []
    for k in PLAY_KEYS:
        a = ship.get(k, DEFAULTS.get(k, "<unset>"))
        b = match.get(k, DEFAULTS.get(k, "<unset>"))
        if a != b:
            bad.append((k, a, b))
    return bad


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--rank", required=True)
    ap.add_argument("--shipped", required=True)
    ap.add_argument("--match", required=True)
    ap.add_argument("--bot-idx", type=int, required=True)
    a = ap.parse_args()
    bad = check(a.rank, a.shipped, a.match, a.bot_idx)
    if not bad:
        print("OK  %s: calibrated bot == shipped config on all %d play-affecting keys" % (a.rank, len(PLAY_KEYS)))
        sys.exit(0)
    print("MISMATCH  %s -- these would certify one bot and ship another:" % a.rank)
    for k, ship, match in bad:
        print("   %-38s shipped=%-14s calibrated=%s" % (k, ship, match))
    sys.exit(1)
