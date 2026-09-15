#!/usr/bin/env python3
"""Kill a grinding dial the moment the tool can see it is dead.

WHY THIS EXISTS, measured on this campaign's own dead dials: 5,522 games -- 37% of every game ever
played at a dial that turned out dead -- were spent AFTER deepkyu_tally.cert_outlook could already
see P(certify) had collapsed. 7.5 hours at 740 games/h. The tool was right and was not being asked:
its ACTION says "PLAY 540 games ... and call again", while the driver runs 400 chunks and the
operator re-consults only when a waiter fires at n >= 2500.

    dead dial       played   dead by n=   wasted
    rung4 x=1.36      4668      3480       1188
    rung5 x=2.08      1500      1200        300
    rung6 x=2.48      2608       900       1708
    rung9 x=5.04      3706      1380       2326

This is a WATCHDOG, not a decision-maker: it never chooses a dial and never certifies. It polls the
live bucket, and when the rung's own outlook says the dial cannot certify it stops the driver so the
operator re-consults the tool. Everything it acts on is the tool's number.
"""
import argparse, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deepkyu_tally as dt
import deepkyu_ladder as dl

P_DEAD = 0.005      # outlook below this = the rule says no future n certifies at this dial
N_FLOOR = 600       # never kill on fewer games than this: the outlook is itself noisy below it
                    # (rung 9 read 0.110 at n=540 and 0.000 by n=1620 -- 540 is too few to trust)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rung", type=int, required=True)
    ap.add_argument("--poll", type=int, default=120)
    ap.add_argument("--p-dead", type=float, default=P_DEAD)
    ap.add_argument("--n-floor", type=int, default=N_FLOOR)
    a = ap.parse_args()
    st = dl.load(); rg = dl.rungs(st)
    strong, weak, rank = rg[a.rung - 1]
    print("watchdog: rung %d  %s vs %s" % (a.rung, strong, weak), flush=True)
    while True:
        if subprocess.call(["pgrep", "-f", "bash deepkyu_step.sh"],
                           stdout=subprocess.DEVNULL) != 0:
            print("watchdog: driver gone; exiting", flush=True); return 0
        totals, _ = dt.scan([dl.sgf_dir()], os.path.join(dl.RUN, "cache_ladder.json"))
        s = dt.pair_stats(totals, strong, weak)
        n = s.get("decided", 0)
        if n >= a.n_floor:
            if s.get("certified"):
                print("watchdog: CERTIFIED at n=%d (%.1f) -- stopping the driver so the bucket is "
                      "frozen; playing on cannot help and the tool never asks for it."
                      % (n, s["gap"]), flush=True)
                subprocess.call(["pkill", "-f", "bash deepkyu_step.sh"]); return 0
            o = dt.cert_outlook(s["weak_wins"], n)
            if o["p_cert"] < a.p_dead:
                print("watchdog: DIAL DEAD at n=%d, gap %+.1f, outlook P(cert)=%.3f -- stopping. "
                      "Re-consult deepkyu_place2.py for the next dial."
                      % (n, s["gap"], o["p_cert"]), flush=True)
                subprocess.call(["pkill", "-f", "bash deepkyu_step.sh"]); return 0
        time.sleep(a.poll)

if __name__ == "__main__":
    sys.exit(main())
