"""Stage 2 visits/s driver for the Mac (wayfinder #41). Throwaway.

One block = one engine launch on one arm, measuring every position:
clear_board, replay the moves, kata-analyze with rootInfo, and count root
visits gained per second of wall time from t=10 s to t=70 s.
Appends one JSON line per position to --out.
"""
import argparse, json, subprocess, sys, threading, time, queue

ap = argparse.ArgumentParser()
ap.add_argument("--katago", required=True)
ap.add_argument("--cfg", required=True)
ap.add_argument("--model", required=True)
ap.add_argument("--arm", required=True)
ap.add_argument("--rep", type=int, required=True)
ap.add_argument("--overrides", required=True)
ap.add_argument("--positions", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--warmup", type=float, default=10.0)
ap.add_argument("--window", type=float, default=60.0)
a = ap.parse_args()

positions = json.load(open(a.positions))
t_launch = time.time()
p = subprocess.Popen([a.katago, "gtp", "-config", a.cfg, "-model", a.model, "-override-config", a.overrides],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(a.out + f".{a.arm}.{a.rep}.stderr", "w"),
                     text=True, bufsize=1)
lines = queue.Queue()
threading.Thread(target=lambda: [lines.put((time.time(), l.rstrip("\n"))) for l in p.stdout], daemon=True).start()

def send(cmd):
    p.stdin.write(cmd + "\n"); p.stdin.flush()

def reply(timeout=900):
    """Read one GTP reply (first line starting with = or ?), skipping info lines."""
    end = time.time() + timeout
    while True:
        try:
            t, l = lines.get(timeout=5)
        except queue.Empty:
            if p.poll() is not None or time.time() > end:
                raise RuntimeError("engine exited or timed out")
            continue
        if l.startswith("=") or l.startswith("?"):
            if l.startswith("?"):
                raise RuntimeError(l)
            return l

send("version"); reply()
load_s = time.time() - t_launch

for name, moves in positions.items():
    send("clear_board"); reply()
    for m in moves:
        send("play " + m); reply()
    send("kata-analyze interval 100 rootInfo true"); reply()
    t0 = time.time(); first = None; samples = []
    while True:
        try:
            t, l = lines.get(timeout=5)
        except queue.Empty:
            if p.poll() is not None or time.time() - t0 > 300:
                raise RuntimeError("engine exited or stalled")
            continue
        if "rootInfo" in l:
            toks = l.split()
            i = toks.index("rootInfo"); v = int(toks[toks.index("visits", i) + 1])
            samples.append((t - t0, v))
            if first is None:
                first = t - t0
            if t - t0 >= a.warmup + a.window:
                break
    s0 = next(s for s in samples if s[0] >= a.warmup)
    s1 = samples[-1]
    vps = (s1[1] - s0[1]) / (s1[0] - s0[0])
    send("protocol_version"); reply()
    rec = dict(arm=a.arm, rep=a.rep, position=name, vps=vps, t0=s0[0], v0=s0[1], t1=s1[0], v1=s1[1],
               first_line_s=first, load_s=load_s, wall=time.strftime("%H:%M:%S"))
    print(json.dumps(rec), flush=True)
    open(a.out, "a").write(json.dumps(rec) + "\n")

send("quit")
p.wait(timeout=60)
