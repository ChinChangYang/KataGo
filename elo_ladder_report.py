#!/usr/bin/env python3
"""elo_ladder_report.py — status table + ETA for the even-game ELO re-tune.

For every rung of the Human-SL even-game ELO ladder (8d anchor, then 7d..1d, 1k..25k) prints:
  - target even-game gap to its stronger baseline (100 for 7d..1k, 50 for 2k..25k),
  - tuned lambda, measured even-game ELO gap + 95% CI, games, status (LOCKED / grinding / pending),
  - cumulative ELO vs the 8d anchor,
and a self-calibrating ETA to completion (games/hr measured from a rate log × remaining work).

Sources (all read-only): LOCKED rungs come from ~/.katago_tune/elo_ladder_locks.txt (what the
calibrator actually reported at lock time — the authoritative "done" list); the current grinding rung's
live gap uses tune_elo.pooled_estimate (the same pooled-window quantity the LOCK gate tests). Reuses
tune_elo/tune_fit for the winrate->gap math.
"""
import os, math, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tune_fit as tf
import tune_elo as te

TUNE = os.path.expanduser("~/.katago_tune")
CONFIGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cpp/configs")
LOCKLOG = os.path.join(TUNE, "elo_ladder_locks.txt")
RATELOG = os.path.join(TUNE, "elo_ladder_ratelog.tsv")
STATEFILE = os.path.join(TUNE, "elo_ladder_state.txt")
CI = 30
DEFAULT_RATE = 110.0        # games/hr fallback before the rate log has history (measured early on)
N_RUNGS = 32                # gaps to pin: 7d..1d,1k (8 @ 100) + 2k..25k (24 @ 50)

RANKS = ["7d", "6d", "5d", "4d", "3d", "2d", "1d"] + [f"{k}k" for k in range(1, 26)]
def gap_for(r): return 100   # uniform 100 ELO/rung (changed 2026-07-17 from 100-dan/50-kyu)


def cfg_lambda(rank):
    p = os.path.join(CONFIGS, f"gtp_human{rank}.cfg")
    lam, is_even = None, False
    if os.path.exists(p):
        with open(p) as f:
            for line in f:
                if line.startswith("humanSLChosenMovePiklLambda"):
                    try: lam = float(line.split("=")[1].split()[0])
                    except (IndexError, ValueError): pass
                if "even-game ELO ladder" in line:
                    is_even = True
    return lam, is_even


def parse_locks():
    """rank -> (lam, gap, lo, hi, n, action) — the LAST LOCK/STOP line per rank in the lock log.
    Line format: 'YYYY-MM-DD HH:MM:SS  <rank>  λ=<L>  gap=<G> CI[<lo>,<hi>] <N>g  target=<T>  <ACTION>'."""
    locks = {}
    if not os.path.exists(LOCKLOG):
        return locks
    pat = re.compile(r'\s(\d+[dk])\s+\S*=([\d.]+)\s+gap=([+-]?\d+)\s+CI\[([+-]?\d+),([+-]?\d+)\]\s+(\d+)g'
                     r'.*\b(LOCK|STOP)\b')
    with open(LOCKLOG) as f:
        for line in f:
            m = pat.search(line)
            if m:
                locks[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)),
                                     float(m.group(5)), int(m.group(6)), m.group(7))
    return locks


def rung_games(rank):
    """(total games across all elo<rank>_L*.samples, the pooled pts list)."""
    pts = tf.load(os.path.join(TUNE, f"elo{rank}_L*.samples"))
    return sum(g for _, _, g in pts), pts


def load_rate(total_games, now):
    """Self-calibrating throughput (games/hr): append (now,total) to RATELOG and estimate the rate from
    the oldest sample in the last 24h (long window averages in real downtime => honest wall-clock rate)."""
    hist = []
    if os.path.exists(RATELOG):
        with open(RATELOG) as f:
            for line in f:
                p = line.split()
                if len(p) == 2:
                    try: hist.append((float(p[0]), int(p[1])))
                    except ValueError: pass
    rate, src, stalled = DEFAULT_RATE, "default (no history yet)", False
    window = [h for h in hist if now - h[0] <= 24 * 3600] or hist
    if window:
        base = window[0]
        elapsed_h = (now - base[0]) / 3600.0
        if now - base[0] > 1800:                      # >30 min of history to judge progress
            grew = total_games - base[1]
            if grew > 0:
                rate = grew / elapsed_h
                src = f"measured over {elapsed_h:.1f}h"
            else:                                      # no new games over a long span -> the grind is stalled
                rate, stalled = 0.0, True
                src = f"STALLED — no new games in {elapsed_h:.1f}h"
    try:
        with open(RATELOG, "a") as f:
            f.write(f"{now:.0f}\t{total_games}\n")
    except OSError:
        pass
    return rate, src, stalled


def main():
    state = open(STATEFILE).read().strip() if os.path.exists(STATEFILE) else "?"
    locks = parse_locks()
    now = time.time()
    te.seed_slope_prior(os.path.join(TUNE, "x"))   # match the grind's slope prior so displayed crossings agree

    print(f"Even-game ELO re-tune — current rung: {state}   (target: 100 ELO/rung; CI goal +-{CI})")
    print(f"{'rank':>5} {'target':>6} {'lambda':>9} {'gap ELO':>9} {'95% CI (ELO)':>16} {'games':>6} {'cum vs8d':>9}  status")
    print(f"{'8d':>5} {'anchor':>6} {'0.06':>9} {'—':>9} {'—':>16} {'—':>6} {'0':>9}  ANCHOR")

    cum, cum_ok, total_games, rgames, certified = 0.0, True, 0, {}, set()
    for r in RANKS:
        tgt = gap_for(r)
        lam_cfg, _ = cfg_lambda(r)
        tg, pts = rung_games(r)
        rgames[r] = tg
        total_games += tg
        row_lam, gap, lo, hi, ng, status = lam_cfg, None, None, None, tg, "pending"
        if r in locks:
            lam, gp, glo, ghi, n, action = locks[r]
            row_lam, gap, lo, hi, ng = lam, gp, glo, ghi, n
            if action == "LOCK":
                # Honest re-verify: does a single cell STILL certify CI⊂band NOW? Path-B-era log-locks
                # can be under-certified (2026-07-18 audit: 6d/5d/4d/3d locked via the optimistic pooled
                # window). Only honest single-cell locks count toward the goal. decide() default has no
                # stickiness/side-effects; seed_slope_prior already matched the grind's fit above.
                hact = te.decide(pts, tgt, CI)[0] if pts else ""
                if "ACTION=LOCK" in hact:
                    status = "LOCKED"; certified.add(r)
                else:
                    status = "UNDERCERT"   # logged lock, but single-cell CI not ⊂band -> needs top-up
            else:
                status = "STOP*"
            cum += gap
        elif r == state:
            est = te.pooled_estimate(pts, tgt) if pts else None
            status = "grinding"
            if est and est[1] is not None:
                row_lam, gap, lo, hi, ng = est[0], est[1], est[2], est[3], est[4]
                cum += gap
        lam_s = f"{row_lam:.5f}" if row_lam is not None else "—"
        gap_s = f"{gap:+.0f}" if gap is not None else "—"
        ci_s = f"[{lo:.0f}, {hi:.0f}]" if lo is not None else "—"
        cum_ok = cum_ok and (gap is not None or status == "pending")
        cum_s = f"-{cum:.0f}" if (gap is not None and status != "pending") else "…"
        print(f"{r:>5} {tgt:>6} {lam_s:>9} {gap_s:>9} {ci_s:>16} {str(ng) if ng else '—':>6} {cum_s:>9}  {status}")

    # GOAL / done counting: only genuine LOCKs among the 32 ladder rungs count (STOP = best-effort,
    # target NOT met; a stray non-RANKS lock-log line must never inflate the count -> iterate RANKS).
    lock_set = {r for r in RANKS if r in locks and locks[r][5] == "LOCK"}
    stop_set = {r for r in RANKS if r in locks and locks[r][5] == "STOP"}
    undercert = lock_set - certified               # logged LOCK but NOT honestly single-cell certified
    n_locked = len(certified)                       # ONLY honest single-cell locks count toward the goal
    if n_locked >= N_RUNGS:
        goal = "GOAL MET — all 32 gaps honestly locked (single-cell CI ⊂ ±30 of target)."
    else:
        extra = f", {len(stop_set)} best-effort STOP" if stop_set else ""
        uc = (f", {len(undercert)} UNDER-CERTIFIED need top-up: {' '.join(sorted(undercert))}"
              if undercert else "")
        goal = (f"GOAL: {n_locked}/{N_RUNGS} gaps honestly locked within ±30 of target "
                f"({N_RUNGS - n_locked} to go{extra}{uc}).")
    print("\n" + goal)

    # Tuned-lambda recap: the locked (calibrated) humanSLChosenMovePiklLambda per rung, front-and-center.
    tuned = [(r, locks[r][0]) for r in RANKS if r in lock_set]
    if tuned:
        print("tuned λ (locked): " + "  ".join(f"{r}={lam:.5f}" for r, lam in tuned))

    # ---- ETA (self-calibrating, per-regime, stall-aware) ----
    rate, src, stalled = load_rate(total_games, now)
    advanced = lock_set | stop_set                     # rungs the loop has moved past -> need no more games
    remaining_rungs = [r for r in RANKS if r not in advanced]
    if state == "DONE" or not remaining_rungs:
        print("\nETA: complete." if state == "DONE" else "\nETA: all rungs resolved.")
    else:
        # cost/rung by REGIME (dan rungs are cheap & fast; the 24 kyu rungs run longer, noisier games)
        dan_costs = [rgames[r] for r in lock_set if r.endswith("d") and rgames.get(r, 0) > 0]
        kyu_costs = [rgames[r] for r in lock_set if r.endswith("k") and rgames.get(r, 0) > 0]
        avg_dan = sum(dan_costs) / len(dan_costs) if dan_costs else 900.0
        avg_kyu = sum(kyu_costs) / len(kyu_costs) if kyu_costs else avg_dan   # until a kyu locks: assume ~dan
        # per-rung remainder, floored individually (an over-budget current rung can't cancel others' budget)
        remaining_games = sum(max(0.0, (avg_dan if r.endswith("d") else avg_kyu) - rgames.get(r, 0))
                              for r in remaining_rungs)
        kyu_uncal = (not kyu_costs) and any(r.endswith("k") for r in remaining_rungs)
        print(f"\nETA to finish ({len(remaining_rungs)} rungs left; ~{avg_dan:.0f} g/dan-rung, "
              f"~{avg_kyu:.0f} g/kyu-rung; {total_games} games so far):")
        if stalled or rate <= 0:
            print(f"  ⚠ {src} — grind may be dead; ETA unknown until games resume "
                  f"(~{remaining_games:,.0f} games still needed).")
        else:
            eta_h = remaining_games / rate
            fin = time.localtime(now + eta_h * 3600)
            print(f"  ~{remaining_games:,.0f} more games @ ~{rate:.0f} games/hr [{src}]")
            print(f"  ~{eta_h:.0f}h = {eta_h / 24:.1f} days  →  est. finish {time.strftime('%a %b %-d ~%H:%M', fin)}")
            if kyu_uncal:
                print("  ⚠ kyu cost not yet calibrated (no kyu rung locked); assumes ~dan cost — ETA will likely grow.")

    try:
        st = os.statvfs("/")
        free_gib = st.f_bavail * st.f_frsize / (1024 ** 3)
        warn = "  ⚠ LOW — katago silently fast-exits on a full disk" if free_gib < 5 else ""
        print(f"\ndisk free: {free_gib:.0f} GiB{warn}")
    except OSError:
        pass

    print(f"\nGOAL_MET={'1' if n_locked >= N_RUNGS else '0'}")


if __name__ == "__main__":
    main()
