# PROTOTYPE (wayfinder #36), throwaway: element-by-element parity of a Core AI translation of a
# KataGo network against the Core ML model MILBuilder builds, on the CPU and the Neural Engine.
#
#   parity.py inputs <boardLen> <out.npz> [fp32.mlpackage]  positions encoded by python/katago/game;
#                                                       with a model, also games it plays (policy-sampled)
#   parity.py run <arm> <model> <inputs.npz> <out.npz>  arm: coreml-cpu|coreml-ane|coreai-cpu|coreai-ane
#   parity.py residency <arm> <model> <out.json>        where every op runs
#   parity.py compare <outDir> <boardLen>               the tables
#
# Run with USE_OS_COREAI=1 so coreai.runtime uses the OS framework, as the app would.
import asyncio
import collections
import json
import random
import re
import sys
import time
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "python"))

HEADS = ["policy_p2_conv", "policy_pass", "value_v3_bias", "value_sv3_bias", "value_ownership_conv"]


# ---------------------------------------------------------------------------------------------
# Inputs


def make_inputs(board_len, out, selfplay_model=None):
    from katago.game.board import Board
    from katago.game.features import Features
    from katago.game.gamestate import GameState
    from katago.train import modelconfigs

    features = Features(modelconfigs.config_of_name["b18c384nbt"], board_len)
    rules = dict(GameState.RULES_TT, whiteKomi=7.5)
    positions = []

    def snapshot(gs, label):
        spatial, glob = gs.get_input_features(features)
        positions.append((label, spatial, glob))

    def random_game(seed, stops):
        rng = random.Random(seed)
        gs = GameState(board_len, rules)
        for n in range(max(stops) + 1):
            if n in stops:
                snapshot(gs, f"random{seed}_m{n}")
            pla = gs.board.pla
            cands = []
            for y in range(board_len):
                for x in range(board_len):
                    loc = gs.board.loc(x, y)
                    if gs.board.board[loc] != Board.EMPTY or not gs.board.would_be_legal(pla, loc):
                        continue
                    nbrs = [gs.board.board[loc + d] for d in gs.board.adj]
                    if all(v == pla or v == Board.WALL for v in nbrs):
                        continue  # never fill an own eye
                    cands.append(loc)
            gs.play(pla, rng.choice(cands) if cands else Board.PASS_LOC)

    def legal_moves(gs, pla):
        moves = []
        for y in range(board_len):
            for x in range(board_len):
                loc = gs.board.loc(x, y)
                if gs.board.board[loc] != Board.EMPTY or not gs.board.would_be_legal(pla, loc):
                    continue
                nbrs = [gs.board.board[loc + d] for d in gs.board.adj]
                if all(v == pla or v == Board.WALL for v in nbrs):
                    continue  # never fill an own eye
                moves.append((loc, y * board_len + x))
        return moves

    def selfplay_game(model, seed, stops):
        # Sample each move from the network's own policy (temperature 1, no pass), so the
        # positions look like the ones the engine evaluates.
        rng = np.random.default_rng(seed)
        gs = GameState(board_len, rules)
        for n in range(max(stops) + 1):
            if n in stops:
                snapshot(gs, f"selfplay{seed}_m{n}")
            spatial, glob = gs.get_input_features(features)
            y = model.predict({"spatial_input": spatial.astype(np.float32), "global_input": glob.astype(np.float32),
                               "input_mask": spatial[:, 0:1].astype(np.float32)})
            logits = np.asarray(y["policy_p2_conv"], dtype=np.float64)[0, 0].reshape(-1)
            moves = legal_moves(gs, gs.board.pla)
            if not moves:
                break
            lg = np.array([logits[pos] for _, pos in moves])
            pr = np.exp(lg - lg.max()); pr /= pr.sum()
            gs.play(gs.board.pla, moves[rng.choice(len(moves), p=pr)][0])

    snapshot(GameState(board_len, rules), "empty")
    if board_len == 19:
        sgf = (REPO / "cpp/tests/data/humanslbigdiff.sgf").read_text()
        moves = re.findall(r";([BW])\[([a-s]{2})\]", sgf)
        gs = GameState(19, rules)
        for i, (c, mv) in enumerate(moves, 1):
            pla = Board.BLACK if c == "B" else Board.WHITE
            gs.play(pla, gs.board.loc(ord(mv[0]) - 97, ord(mv[1]) - 97))
            if i % 10 == 0 or i == len(moves):
                snapshot(gs, f"humanslbigdiff_m{i}")
        for seed in (1, 2, 3):
            random_game(seed, {60, 150, 250})
    else:
        for seed in (1, 2, 3, 4, 5):
            random_game(seed, {100, 400, 800, 1200})
    if selfplay_model:
        import coremltools as ct
        model = ct.models.MLModel(selfplay_model, compute_units=ct.ComputeUnit.CPU_ONLY)
        stops = {30, 100, 200} if board_len == 19 else {40, 120, 250, 450}
        for seed in range(1, 9):
            selfplay_game(model, seed, stops)
    labels = [p[0] for p in positions]
    spatial = np.concatenate([p[1] for p in positions]).astype(np.float32)
    glob = np.concatenate([p[2] for p in positions]).astype(np.float32)
    np.savez(out, labels=labels, spatial_input=spatial, global_input=glob,
             input_mask=spatial[:, 0:1].copy())
    print(f"{len(labels)} positions: {labels}")


# ---------------------------------------------------------------------------------------------
# Runs


def coreai_options(unit, debug=False):
    from coreai.runtime import ComputeUnitKind, SpecializationOptions
    o = (SpecializationOptions.cpu_only() if unit == "cpu" else
         SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.neural_engine()))
    return o.with_debug(enabled=True) if debug else o


def run(arm, model, inputs, out):
    framework, unit = arm.split("-")
    data = np.load(inputs)
    n = len(data["labels"])
    feeds = [{k: data[k][i:i + 1] for k in ("spatial_input", "global_input", "input_mask")} for i in range(n)]
    results = collections.defaultdict(list)
    t0 = time.time()
    if framework == "coreml":
        import coremltools as ct
        cu = ct.ComputeUnit.CPU_ONLY if unit == "cpu" else ct.ComputeUnit.CPU_AND_NE
        m = ct.models.MLModel(model, compute_units=cu)
        load_s = time.time() - t0
        for feed in feeds:
            m.predict(feed)  # warm-up, as the comparison should not depend on a first call
            y = m.predict(feed)
            for k, v in y.items():
                results[k].append(np.asarray(v, dtype=np.float32))
    else:
        from coreai.runtime import AIModel, NDArray

        async def go():
            m = await AIModel.load(model, coreai_options(unit))
            ls = time.time() - t0
            fn = m.load_function("main")
            for feed in feeds:
                nd = {k: NDArray(np.ascontiguousarray(v)) for k, v in feed.items()}
                await fn(nd)
                y = await fn(nd)
                for k, v in y.items():
                    results[k].append(np.asarray(v.numpy(), dtype=np.float32))
            return ls
        load_s = asyncio.run(go())
    np.savez(out, **{k: np.concatenate(v) for k, v in results.items()})
    print(f"{arm} {Path(model).name}: load {load_s:.2f} s, total {time.time() - t0:.2f} s")


# ---------------------------------------------------------------------------------------------
# Residency


def residency(arm, model, out):
    framework, unit = arm.split("-")
    counts = collections.Counter()
    if framework == "coreai":
        from coreai.runtime import AIModel

        async def go():
            return (await AIModel.load(model, coreai_options(unit, debug=True)))._debug_infos
        records = json.loads(asyncio.run(go()))
        # Each op carries one residency per lowering level; the MPSGraph-level one says where the
        # kernel runs. The mps-level GPU tag is on every op, and odix records are delegate dispatch.
        for rec in records:
            delegate = rec["identifier"].split("_op_id")[0]
            for op in rec["operations"]:
                level, res = None, None
                for m in op["metadatas"]:
                    if m["key"] == "op_id":
                        level = m["value"]["dictionary"]["_0"]["type"]["string"]["_0"]
                    elif m["key"] == "residency" and level == "MPSGraph":
                        res = m["value"]["string"]["_0"]
                counts[f"{delegate}:{res or 'no kernel residency'}"] += 1
        Path(out).write_text(json.dumps(records))
    else:
        import coremltools as ct
        from coremltools.models.compute_plan import MLComputePlan
        compiled = ct.utils.compile_model(model)
        cu = ct.ComputeUnit.CPU_ONLY if unit == "cpu" else ct.ComputeUnit.CPU_AND_NE
        plan = MLComputePlan.load_from_path(path=compiled, compute_units=cu)
        fn = plan.model_structure.program.functions["main"]
        for op in fn.block.operations:
            if op.operator_name == "const":
                continue
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
            dev = type(usage.preferred_compute_device).__name__ if usage else "none"
            counts[f"{op.operator_name}:{dev}"] += 1
        Path(out).write_text(json.dumps(dict(counts)))
    print(arm, Path(model).name, dict(sorted(counts.items())))


# ---------------------------------------------------------------------------------------------
# Comparison


LEAD_MULTIPLIER = 20.0  # postProcessParams.leadMultiplier of kata1-b18c384nbt-s9996604416-d4316597426


def derived(y, mask):
    """testgpuerror-style quantities per position: winrate, lead (points), policy over legal cells + pass."""
    v = y["value_v3_bias"].astype(np.float64)[:, :2]  # Tromp-Taylor: noResult is excluded
    win = np.exp(v - v.max(1, keepdims=True)); win = win[:, 0] / win.sum(1)
    lead = y["value_sv3_bias"].astype(np.float64)[:, 2] * LEAD_MULTIPLIER
    pol = y["policy_p2_conv"].astype(np.float64)[:, 0].reshape(len(v), -1)
    pol = np.where(mask.reshape(len(v), -1) > 0, pol, -np.inf)
    logits = np.concatenate([pol, y["policy_pass"].astype(np.float64)[:, :1]], axis=1)
    p = np.exp(logits - logits.max(1, keepdims=True)); p /= p.sum(1, keepdims=True)
    return win, lead, p


def err_summary(test, ref, mask):
    w1, l1, p1 = derived(test, mask); w0, l0, p0 = derived(ref, mask)
    top = p0.argmax(1); r = np.arange(len(top))
    kl = np.sum(np.where(p0 > 0, p0 * (np.log(np.maximum(p0, 1e-300)) - np.log(np.maximum(p1, 1e-300))), 0), axis=1)
    return {"winrate %": np.abs(w1 - w0) * 100, "lead pts": np.abs(l1 - l0),
            "top policy %": np.abs(p1[r, top] - p0[r, top]) * 100, "policy KL": kl}


def boot_ratio(a, b, f, n=2000, seed=0):
    """90% bootstrap interval, over positions, of f(a)/f(b) for per-position error arrays."""
    rng = np.random.default_rng(seed); k = len(a)
    rs = [f(a[idx]) / max(f(b[idx]), 1e-30) for idx in (rng.integers(0, k, k) for _ in range(n))]
    return np.percentile(rs, [5, 95])


def compare(out_dir, board_len):
    out_dir = Path(out_dir)
    load = lambda name: np.load(out_dir / f"{name}_{board_len}.npz")
    ref, ai_ref = load("coreml-fp32-cpu"), load("coreai-fp32-cpu")
    inp = np.load(out_dir / f"inputs_{board_len}.npz")
    labels, mask = list(inp["labels"]), inp["input_mask"]
    arms = {a: load(a) for a in ("coreml-fp16-cpu", "coreai-fp16-cpu", "coreml-fp16-ane", "coreai-fp16-ane")}
    n3 = out_dir / f"coreml-fp16n3-ane_{board_len}.npz"
    print(f"\n## {board_len}x{board_len}: {len(labels)} positions\n")
    print("FP32 Core AI (cpu) vs FP32 Core ML (cpu), the reference: max |diff| per head "
          + ", ".join(f"{h} {np.abs(ai_ref[h] - ref[h]).max():.2g}" for h in HEADS))
    if n3.exists():
        d = np.load(n3)
        print("App batch config (Core ML, max batch 3, ANE) vs max batch 1, at batch 1: max |diff| "
              + ", ".join(f"{h} {np.abs(d[h] - arms['coreml-fp16-ane'][h]).max():.2g}" for h in HEADS))
    pct = [50, 99, 99.9, 100]
    print("\n### Raw outputs, element by element (|diff| percentiles p50 / p99 / p99.9 / max; rms)\n")
    print("| head | unit | Core AI vs Core ML | identical | Core ML vs FP32 | Core AI vs FP32 | rms ratio AI/ML [90% CI] |")
    print("|---|---|---|---|---|---|---|")
    for h in HEADS:
        for unit in ("cpu", "ane"):
            ml, ai, r = (x[h].astype(np.float64) for x in (arms[f"coreml-fp16-{unit}"], arms[f"coreai-fp16-{unit}"], ref))
            fmt = lambda d: " / ".join(f"{v:.2g}" for v in np.percentile(d, pct)) + f"; {np.sqrt((d ** 2).mean()):.2g}"
            e_ml = np.abs(ml - r).reshape(len(labels), -1); e_ai = np.abs(ai - r).reshape(len(labels), -1)
            ci = boot_ratio(e_ai, e_ml, lambda e: np.sqrt((e ** 2).mean()))
            ratio = np.sqrt((e_ai ** 2).mean() / (e_ml ** 2).mean())
            nf = (~np.isfinite(ml)).sum() + (~np.isfinite(ai)).sum()
            print(f"| {h} | {unit} | {fmt(np.abs(ai - ml))} | {(ai == ml).mean() * 100:.0f}% | {fmt(e_ml)} | {fmt(e_ai)} "
                  f"| {ratio:.2f} [{ci[0]:.2f}, {ci[1]:.2f}]{'  NON-FINITE ' + str(nf) if nf else ''} |")
    print("\n### testgpuerror-style, per position vs FP32 (p50 / p90 / max over positions)\n")
    print("| stat | unit | Core ML | Core AI | max ratio AI/ML | mean ratio AI/ML [90% CI] |")
    print("|---|---|---|---|---|---|")
    for unit in ("cpu", "ane"):
        s_ml = err_summary(arms[f"coreml-fp16-{unit}"], ref, mask); s_ai = err_summary(arms[f"coreai-fp16-{unit}"], ref, mask)
        for k in s_ml:
            f3 = lambda e: " / ".join(f"{v:.3g}" for v in np.percentile(e, [50, 90, 100]))
            ci = boot_ratio(s_ai[k], s_ml[k], np.mean)
            print(f"| {k} | {unit} | {f3(s_ml[k])} | {f3(s_ai[k])} | {s_ai[k].max() / s_ml[k].max():.2f} "
                  f"| {s_ai[k].mean() / s_ml[k].mean():.2f} [{ci[0]:.2f}, {ci[1]:.2f}] |")
    peaks_file = out_dir / f"peaks_{board_len}.json"
    if "peaks" in ai_ref.files and peaks_file.exists():
        names = json.loads(peaks_file.read_text())
        peaks = ai_ref["peaks"].reshape(len(labels), len(names))
        # Mish's own e+2 and 1+2/(e(e+2)) overflow to inf in FP16 by design (the branch-free form
        # lands on the right limit), and x_for_max only shifts off-board cells, so leave them out.
        keep = [k for k, n in enumerate(names) if not re.search(r"_(ep|optdemep)\d+$|x_for_max", n)]
        names = [names[k] for k in keep]; peaks = peaks[:, keep]
        i = int(np.argmax(peaks.max(axis=0)))
        resid = [k for k, n in enumerate(names) if re.search(r"_residual_\d+$", n)]
        sums = [k for k, n in enumerate(names) if "_sum" in n and "mask_sum" not in n]
        if sums:
            j = sums[int(np.argmax(peaks[:, sums].max(axis=0)))]
            print(f"\nFP16-graph reduce_sum peak (global pooling sums, FP32 run): {peaks[:, sums].max():.4g} at {names[j]} "
                  f"(headroom {65504 / peaks[:, sums].max():.1f}x)")
        print(f"\nFP32 activation peak over {len(names)} conv, BN-bias, residual and sum results: {peaks.max():.4g} at "
              f"{names[i]} ({peaks.max() / 65504 * 100:.2f}% of the FP16 max, headroom {65504 / peaks.max():.0f}x); "
              f"residual stream {peaks[:, resid].max():.4g}; worst position {labels[int(np.argmax(peaks.max(axis=1)))]}")


if __name__ == "__main__":
    sys.setrecursionlimit(20000)  # board.py builds regions recursively; an empty 37x37 needs ~1400 frames
    cmd = sys.argv[1]
    if cmd == "inputs":
        make_inputs(int(sys.argv[2]), sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    elif cmd == "run":
        run(*sys.argv[2:6])
    elif cmd == "residency":
        residency(*sys.argv[2:5])
    elif cmd == "compare":
        compare(sys.argv[2], int(sys.argv[3]))
