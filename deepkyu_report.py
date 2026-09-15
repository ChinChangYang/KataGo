#!/usr/bin/env python3
"""Render the certified deep-kyu ladder as the markdown table used in docs/HumanSL_Rank_Ladder.md."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import deepkyu_cfg as dc, deepkyu_ladder as dl

st = dl.load()
rows, _ = dl.tally(st)
names = ["14k"] + [r["rank"] for r in st["ranks"]]
print("| Config | Profile | Baseline | Dial x | Early / Late / Halflife | Even-game gap (95% CI) | Games |")
print("|---|---|---|---:|---|---:|---:|")
for i, r in enumerate(st["ranks"]):
    e, l, h = dc.dial_params(r["x"])
    row = rows[i]
    gap = ("**%+d [%d, %d]**" % (round(row["gap"]), round(row["lo"]), round(row["hi"]))
           if row["decided"] else "-")
    print("| `gtp_human%s.cfg` | `preaz_%s` | `gtp_human%s.cfg` | %.2f | %.2f / %.2f / %.0f | %s | %d |"
          % (r["rank"], r["rank"], names[i], r["x"], e, l, h, gap, row["decided"]))
cert = sum(1 for r in rows if r.get("certified"))
print("\nCERTIFIED %d/%d" % (cert, len(rows)))
