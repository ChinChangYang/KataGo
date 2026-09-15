#!/usr/bin/env python3
"""Emit a `katago match` config for the deep-kyu even-game ladder (14k..25k).

Every bot is one (rank, maxVisits, delta-tau) point. The bot NAME encodes the dial, so games
played at different dials can never be pooled: they land under different PB/PW in the SGFs.

Protocol is byte-for-byte the ladder's even-game protocol (komi 6.5 fixed, Japanese
SIMPLE/TERRITORY/SEKI, both colors, no resignation, winLossUtilityFactor=0, b28c512 main net),
so numbers are comparable to the certified 7d->14k rungs.

Usage:
  python3 deepkyu_cfg.py --bots bots.json --pairs A-B,C-D --out match.cfg [--game-threads 8]
"""
import argparse, json, sys

MAIN_MODEL = "/Users/chinchangyang/Code/KataGo-MLX/cpp/models/kata1-b28c512nbt-s8326494464-d4628051565.bin.gz"

TEMP_BASE_LATE = 0.25   # shipped chosenMoveTemperature for the whole ladder
TEMP_BASE_EARLY = 0.70  # shipped chosenMoveTemperatureEarly
TEMP_MAX = 5.0          # cpp/program/setup.cpp:602-610 upper bound
LATE_CAP = 1.0          # see dial_params(): never flatten the endgame past honest policy
HALFLIFE_BASE = 30.0    # shipped chosenMoveTemperatureHalflife
X_EARLY_CAP = TEMP_MAX - TEMP_BASE_EARLY   # 4.30: where the early temperature saturates
X_HALFLIFE_CAP = 8.5    # halflife 551 -- beyond this the decay outlives the game, so it is inert
NNPT_MAX = 5.0          # cpp/program/setup.cpp:680 upper bound


def dial_params(x):
    """Monotone weakening coordinate x >= 0 -> (early temp, late temp, halflife).

    Why the late temperature is capped at 1.0: chosenMoveTemperature reshapes the FINAL move
    distribution, whose pass entry is the main net's raw pass probability
    (humanSLChosenMoveIgnorePass=true). T>1 flattens a 90%-pass endgame against ~300 tail moves
    and the bot stops passing -- pilot games at late T=2.25 filled the whole board, ran past 400
    turns, scored no-result, and one position made the net return a nonfinite policy, which
    aborts the whole match process. T<=1 never flattens past the honest policy, so the endgame
    behaves exactly like the shipped configs. The weakening therefore rides mostly on the EARLY
    temperature, where the pass probability is ~0 and blunders are cheap to inject safely.
    Past x = 4.30 the early temperature is at its 5.0 config maximum, so the lever continues by
    stretching the halflife, i.e. by keeping the noisy phase going for more of the game.
    """
    early = min(TEMP_MAX, TEMP_BASE_EARLY + x)
    late = min(LATE_CAP, TEMP_BASE_LATE + 0.25 * x)
    hl = HALFLIFE_BASE
    if x > X_EARLY_CAP:
        hl = HALFLIFE_BASE * (2.0 ** (min(x, X_HALFLIFE_CAP) - X_EARLY_CAP))
    nnpt = 1.0
    if x > X_HALFLIFE_CAP:
        # The temperature family saturates once the halflife outlives the game. Past that the dial
        # continues on nnPolicyTemperature, which scales the policy LOGITS and is applied to the
        # human net as well, so it multiplies with the chosen-move temperature. Measured on 25k:
        # +209 ELO going to nnpt=3 and +92 more to nnpt=5, i.e. ~300 ELO beyond the halflife limit.
        nnpt = min(NNPT_MAX, 1.0 + (x - X_HALFLIFE_CAP) * 4.0 / 3.0)
    return early, late, hl, nnpt


def fmt(v):
    return ("%.4f" % v).rstrip("0").rstrip(".")


PROTOCOL_TAG = "P2"   # FP32 + default NN path (1 server thread, no device override) +
                      # nnRandomize=false. Bump when any of those change.


def bot_name(rank, visits, early, late, hl, sym=2, q=1.0, nnpt=1.0, rootpt=1.0):
    """SGF-safe name that fully fingerprints the dial point, so games played under two different
    dials can never be pooled by deepkyu_tally.py even if the dial mapping itself changes."""
    n = "%s_v%d_e%s_l%s" % (rank, visits, fmt(early), fmt(late))
    if abs(hl - HALFLIFE_BASE) > 1e-9:
        n += "_h%s" % fmt(hl)
    if sym != 2:
        n += "_s%d" % sym
    if abs(q - 1.0) > 1e-9:
        n += "_q%s" % fmt(q)
    if abs(nnpt - 1.0) > 1e-9:
        n += "_p%s" % fmt(nnpt)
    if abs(rootpt - 1.0) > 1e-9:
        n += "_r%s" % fmt(rootpt)
    return n + "_" + PROTOCOL_TAG


def resolve(b):
    """Fill in a bot spec: {rank, maxVisits, x} or explicit {early, late, halflife}."""
    b = dict(b)
    if "x" in b:
        early, late, hl, nnpt_x = dial_params(float(b["x"]))
        b.setdefault("nnpt", nnpt_x)
    else:
        early, late, hl = float(b["early"]), float(b["late"]), float(b.get("halflife", HALFLIFE_BASE))
    b["early"], b["late"], b["halflife"] = early, late, hl
    b.setdefault("profile", "preaz_%s" % b["rank"])
    b.setdefault("lam", "100000000")
    b.setdefault("maxVisits", 1)
    b.setdefault("searchThreads", 1)
    b.setdefault("sym", 2)  # shipped ladder value; part of the bot name when it differs
    # chosenMoveTemperatureOnlyBelowProb: 1.0 = plain temperature. Below 1, moves whose normalized
    # probability exceeds q keep it untouched and only the tail is flattened upward -- which protects
    # a high-probability endgame pass from being flattened away, the failure mode that makes plain
    # high temperature fill the board and double the game length.
    b.setdefault("q", 1.0)
    # nnPolicyTemperature scales the net's policy LOGITS before softmax and is applied to the human
    # net as well as the main one (the same MiscNNInputParams goes to both evaluators), so it is a
    # second, multiplicative flattening knob: the effective exponent is 1/(nnpt * chosenMoveTemp).
    # Held in reserve for the deep end, where stretching the halflife eventually saturates.
    b.setdefault("nnpt", 1.0)
    # rootPolicyTemperature flattens the MAIN net's root policy, which at one visit is where the
    # pass share comes from (humanSLChosenMoveIgnorePass=true). Above 1 it injects stray passes --
    # the one mechanism that can push a bot BELOW near-random play, since a pass hands over a free
    # move. Ugly, so it is a last resort, not part of the normal dial.
    b.setdefault("rootpt", 1.0)
    b.setdefault("name", bot_name(b["rank"], int(b["maxVisits"]), early, late, hl, int(b["sym"]),
                                  float(b["q"]), float(b["nnpt"]), float(b["rootpt"])))
    return b


def build(bots, pairs, game_threads, nn_batch, games_total, main_model, fp32=False, nn_cache_pow=18, gpu_only=False, nn_server_threads=1):
    # The bot names already carry PROTOCOL_TAG, so a cfg built on a different NN path would pool
    # its games with the tagged ones and silently void the certificate. Refuse instead: a run with
    # numNNServerThreadsPerModel=2 puts half of every game's evaluations on CoreML/ANE, which is
    # neither FP32 nor the path gtp_human*.cfg uses.
    if PROTOCOL_TAG == "P2" and not (fp32 and nn_server_threads == 1 and not gpu_only):
        raise SystemExit(
            "protocol %s requires fp32=True, nn_server_threads=1, gpu_only=False; got "
            "fp32=%s nn_server_threads=%d gpu_only=%s -- bump PROTOCOL_TAG before changing the NN path"
            % (PROTOCOL_TAG, fp32, nn_server_threads, gpu_only))
    names = [b["name"] for b in bots]
    for a, b in pairs:
        if a not in names or b not in names:
            raise SystemExit("pair %s-%s references an unknown bot" % (a, b))
    L = []
    L.append("# Deep-kyu even-game ladder match config -- GENERATED by deepkyu_cfg.py, do not edit.")
    L.append("# Protocol: komi 6.5 fixed, japanese (SIMPLE/TERRITORY/SEKI), both colors,")
    L.append("# allowResignation=false, winLossUtilityFactor=0, b28c512 main net + humanv0 human net.")
    L.append("")
    L.append("logSearchInfo = false")
    L.append("logMoves = false")
    L.append("logGamesEvery = 20")
    L.append("logToStdout = true")
    L.append("")
    L.append("numBots = %d" % len(bots))
    L.append("nnModelFile = %s" % main_model)
    L.append("")
    for i, b in enumerate(bots):
        L.append("botName%d = %s" % (i, b["name"]))
        L.append("humanSLProfile%d = %s" % (i, b["profile"]))
        L.append("humanSLChosenMovePiklLambda%d = %s" % (i, b["lam"]))
        L.append("maxVisits%d = %d" % (i, int(b["maxVisits"])))
        L.append("numSearchThreads%d = %d" % (i, int(b["searchThreads"])))
        L.append("chosenMoveTemperatureEarly%d = %.4f" % (i, b["early"]))
        L.append("chosenMoveTemperature%d = %.4f" % (i, b["late"]))
        L.append("chosenMoveTemperatureHalflife%d = %.4f" % (i, b["halflife"]))
        L.append("rootNumSymmetriesToSample%d = %d" % (i, int(b["sym"])))
        L.append("chosenMoveTemperatureOnlyBelowProb%d = %.5f" % (i, float(b["q"])))
        if abs(float(b["nnpt"]) - 1.0) > 1e-9:
            L.append("nnPolicyTemperature%d = %.4f" % (i, float(b["nnpt"])))
        if abs(float(b["rootpt"]) - 1.0) > 1e-9:
            L.append("rootPolicyTemperature%d = %.4f" % (i, float(b["rootpt"])))
            L.append("rootPolicyTemperatureEarly%d = %.4f" % (i, float(b["rootpt"])))
        L.append("")
    L.append("# Shared Human-SL / search params -- identical across every gtp_human<rank>.cfg.")
    L.append("humanSLChosenMoveProp = 1.0")
    L.append("humanSLChosenMoveIgnorePass = true")
    L.append("humanSLRootExploreProbWeightless = 0.8")
    L.append("humanSLRootExploreProbWeightful = 0.0")
    L.append("humanSLPlaExploreProbWeightless = 0.0")
    L.append("humanSLPlaExploreProbWeightful = 0.0")
    L.append("humanSLOppExploreProbWeightless = 0.0")
    L.append("humanSLOppExploreProbWeightful = 0.0")
    L.append("humanSLCpuctExploration = 0.50")
    L.append("humanSLCpuctPermanent = 2.0")
    L.append("")
    L.append("chosenMoveSubtract = 0")
    L.append("chosenMovePrune = 0")
    L.append("")
    L.append("winLossUtilityFactor = 0.0")
    L.append("staticScoreUtilityFactor = 0.5")
    L.append("dynamicScoreUtilityFactor = 0.5")
    L.append("useUncertainty = false")
    L.append("subtreeValueBiasFactor = 0.0")
    L.append("useNoisePruning = false")
    L.append("useLcbForSelection = false")
    L.append("")
    L.append("nnCacheSizePowerOfTwo = %d" % nn_cache_pow)
    L.append("nnMutexPoolSizePowerOfTwo = 12")
    # nnRandomize seeds a fresh nnRandSeed per PROCESS and picks a random symmetry per cache miss,
    # so each of ~150 chunk restarts freezes a different symmetry-perturbed policy -- between-chunk
    # overdispersion that makes a phi=1 Wilson interval overconfident. Determinism per position
    # costs nothing: game variety comes from the chosen-move temperature RNG.
    L.append("nnRandomize = false")
    L.append("nnMaxBatchSize = %d" % nn_batch)
    if fp32:
        # FP16 overflows to a nonfinite policy in lopsided positions (one colour nearly wiped out),
        # which throws "Got nonfinite for policy sum" and aborts the whole match process. FP32 also
        # cuts the backend's winrate error from ~2.6% to ~0.001% vs the Eigen reference, which
        # matters when the whole campaign is measuring winrates to a few tenths of a percent.
        L.append("mlxUseFP16 = false")
    # Match what a user actually runs: gtp_human*.cfg sets neither of these, so the certified bot
    # must use the same single-thread, default-device NN path.
    L.append("numNNServerThreadsPerModel = %d" % nn_server_threads)
    if nn_server_threads > 1:
        L.append("deviceToUseThread1 = %d" % (0 if gpu_only else 100))

    L.append("")
    L.append("koRules = SIMPLE")
    L.append("scoringRules = TERRITORY")
    L.append("taxRules = SEKI")
    L.append("multiStoneSuicideLegals = false")
    L.append("hasButtons = false")
    L.append("bSizes = 19")
    L.append("bSizeRelProbs = 1")
    L.append("komiAuto = false")
    L.append("komiMean = 6.5")
    L.append("komiStdev = 0.0")
    L.append("komiAllowIntegerProb = 0.0")
    L.append("handicapProb = 0.0")
    L.append("handicapCompensateKomiProb = 1.0")
    L.append("")
    L.append("allowResignation = false")
    L.append("resignThreshold = -0.98")
    L.append("resignConsecTurns = 10")
    L.append("maxMovesPerGame = 1200")
    L.append("")
    L.append("numGameThreads = %d" % game_threads)
    L.append("numGamesTotal = %d" % games_total)
    L.append("")
    L.append("secondaryBots = %s" % ",".join(str(i) for i in range(len(bots))))
    idx = {n: i for i, n in enumerate(names)}
    L.append("extraPairs = %s" % ",".join("%d-%d" % (idx[a], idx[b]) for a, b in pairs))
    L.append("")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", required=True)
    ap.add_argument("--pairs", required=True, help="comma-separated botA-botB (bot NAMES)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--game-threads", type=int, default=8)
    ap.add_argument("--nn-batch", type=int, default=8)
    ap.add_argument("--games-total", type=int, default=100000000)
    ap.add_argument("--main-model", default=MAIN_MODEL)
    ap.add_argument("--fp32", action="store_true", help="force mlxUseFP16=false")
    ap.add_argument("--nn-cache-pow", type=int, default=18)
    ap.add_argument("--gpu-only", action="store_true", help="both NN server threads on the GPU (no ANE/CoreML)")
    ap.add_argument("--nn-server-threads", type=int, default=1)
    a = ap.parse_args()
    with open(a.bots) as f:
        bots = [resolve(b) for b in json.load(f)]
    pairs = []
    for tok in a.pairs.split(","):
        tok = tok.strip()
        if not tok:
            continue
        p = tok.split("-")
        if len(p) != 2:
            raise SystemExit("bad pair %r" % tok)
        pairs.append((p[0], p[1]))
    text = build(bots, pairs, a.game_threads, a.nn_batch, a.games_total, a.main_model, a.fp32, a.nn_cache_pow, a.gpu_only, a.nn_server_threads)
    with open(a.out, "w") as f:
        f.write(text)
    print("wrote %s: %d bots, %d pairs" % (a.out, len(bots), len(pairs)), file=sys.stderr)


if __name__ == "__main__":
    main()
