# Human-SL KGS-Rank Ladder

A set of GTP configs that make KataGo (with the Human-SL net) play at a chosen amateur
rank, from **9d (top)** down to **25k**, where **each consecutive rank is exactly 1 KGS rank
apart**. The ladder is anchored at the top; every weaker rank is tuned to be exactly 1 rank
below the rank above it.

> **What "1 KGS rank" means here (important correction).** An earlier version of this doc
> equated the 1-rank gap with **"1 handicap stone (~7 points)."** That is wrong. The gap is
> operationalized as a **komi-0.5 reverse-komi even game** (the *stronger* side, White, gets
> ~0 komi instead of the territory-even 6.5), which is worth only **≈ ½ a Go-stone (~4–6
> points)** — the KGS half-stone-per-rank convention — **not** a full placed handicap stone
> (~13 points). A true full-stone gap (komi **−6.5**) was tried and **abandoned**: it
> over-handicaps the dan rungs (they saturate and can't be balanced by λ alone). So the
> deployed ladder uses **komi 0.5 = 1 KGS rank ≈ ½ stone**. (A yet-earlier version targeted a
> fixed **−100 ELO** per rung; also superseded — the profiles *are* KGS ranks, so rank spacing
> is the right target, not an ELO number.)

## Why rank-spacing, not ELO

The Human-SL net is **conditioned on KGS rank**. In `cpp/neuralnet/sgfmetadata.cpp`,
`makeBasicRankProfile` sets `source = SOURCE_KGS` (*"KGS rating system is pretty reasonable, so
let's use KGS as the source"*), and the rank→index map is:

```
9d→1  8d→2  7d→3  6d→4  5d→5  4d→6  3d→7  2d→8  1d→9
1k→10 2k→11 … 5k→14 … 10k→19 … 20k→29 … 25k→34   (34 = the net's weakest representable rank)
```

So `preaz_9d` and `preaz_8d` are **exactly 1 KGS rank apart** by construction (`preaz_` = the
pre-AlphaZero era, game date 2016-09). The right thing to calibrate is the **1-rank gap**. The
ladder stops at **25k** because inverse-rank 34 is the net's rank-input floor — 26k+ would
encode identically to 25k.

**The 1-rank calibration target.** A 1-rank difference is operationalized as an even game where
the **stronger player (White) gets no komi compensation** (komi 0.5 instead of the
territory-even 6.5); the weaker player keeps the first-move advantage. Two configs are exactly 1
rank apart when:

> **weaker rank as Black** vs **stronger rank as White**, **komi 0.5** → **even game (50%)**.

This is the calibration target for every rung below the anchor. A 50% winrate is bounded and
well-conditioned, which (with the curve-fit calibrator below) makes each rung pin cleanly.

## Anchors (special cases)

- **9d (legacy).** Anchored differently and left from the original run: `preaz_9d` calibrated to
  even parity vs the modern `rank_9d` reference at **400 visits**, giving `gtp_human9d.cfg` =
  `preaz_9d @ 400v, λ0.045`. It is **not** part of the re-tuned fast chain and is a separate,
  stronger reference; the 8d↔9d link is currently **unmeasured** (a documented seam).
- **8d (hand-set anchor of the re-tuned chain).** `preaz_8d @ maxVisits 40, λ 0.06,
  winLossUtilityFactor 0`. Hand-set (not calibrated) to be a deliberately weak, fast top rung;
  every rung 7d→25k calibrates down the chain from it.

## File naming

One config per rank: **`gtp_human<rank>.cfg`** — `gtp_human9d.cfg` … `gtp_human25k.cfg`. The
upstream examples `gtp_human5k_example.cfg` and `gtp_human9d_search_example.cfg` are left
untouched.

## Method

Configs are produced by the **`katago tunehuman`** subcommand, which plays in-process
candidate-vs-baseline games and tunes `humanSLChosenMovePiklLambda` (the strength dial) to hit a
50% winrate against the prior rung.

### Nets used (calibration is net-specific)

- **Main net (`-model`)**: **`kata1-b28c512nbt-s8326494464-d4628051565.bin.gz`** (b28c512, the
  strong modern net). The re-tune switched to this from the tiny b24c64 net: at low λ the strong
  main net **overrides** the human profile (search dominates), which both compresses the whole λ
  scale downward and lets the dan rungs separate cleanly. **A different main net invalidates the
  calibration.**
- **Human-SL net (`-human-model`)**: `b18c384nbt-humanv0.bin.gz`.
- **Profile**: each config sets `humanSLProfile = preaz_<rank>`.

### Fast, score-sensitive settings

- **`maxVisits = 40`** (not 400): ~10× faster; fine because the human-SL policy dominates
  move-selection at these λ. The **same 40 visits are set in the deployed configs** — tuning and
  deployment settings must match for the calibration to hold.
- **`winLossUtilityFactor = 0.0`** (in both tuning and deployed configs): makes the search value
  pure score-margin, so the komi handicap maps smoothly/monotonically to winrate and the crossing
  pins without the noisy "cliff" the old winLoss=1 method suffered. (Accepted trade-off:
  score-maximizing endgame play may grind points after the game is decided; resignation is
  unaffected — it uses raw win-probability, not utility.)

### The lever — `humanSLChosenMovePiklLambda`

- **high λ** → closer to raw human policy → **weaker** / more human;
- **low λ** → trusts KataGo's search more → **stronger**.

`maxVisits` is a weak lever, so all rungs run at the fixed 40 visits and differ only in λ.

### Handicap calibration (rungs below the 8d anchor)

For each rung, tune λ so the **weaker rank (Black) vs the prior rung (White), komi 0.5** is 50%:

```
-target-elo 0        # 0 ELO offset == 50% winrate target
-komi 0.5            # 1 KGS rank: White (stronger) gets ~0 komi compensation
-cand-color black    # weaker candidate always plays Black (the handicap is color-bound)
-handicap 0          # NO placed stones — the reverse komi is the whole handicap
```

`-komi`/`-cand-color`/`-handicap` were added to `tunehuman`; the harness pins `komiStdev=0` and
`komiAllowIntegerProb=0` so komi is applied **exactly** (0.5, never rounded). Colors are **not**
alternated (the handicap asymmetry is the point). Games are scored under **Japanese / territory**
rules (each config declares `rules = japanese`), matching real play and the ruleset the net's
KGS-rank conditioning was learned from. With komi 0.5 a genuine jigo is impossible, so a
turn-limit game (winner undetermined) is **discarded**, not scored as a 0.5 draw — this avoids a
subtle bias toward the 50% lock target (matters only for the deep-kyu rungs, whose long
board-filling games can hit the move cap).

### The calibrator — `tune_fit.py` (curve fit, replaces manual grinding)

The ladder is driven by **`tune_fit.py`**, a pure-Python **Bayesian grid-posterior logistic
fit** of winrate vs `ln(λ)`. It pools **all** `(λ, wins, games)` samples for a rank toward one
monotone-decreasing crossing, estimates the 50% crossing λ\* with a posterior-predictive
winrate CI, and decides one of:

- **GRIND** — play one ~18-min `tunehuman` chunk at the recommended λ (active-learning: explore
  wide to pin the slope, or grind the crossing);
- **LOCK** — a conjunctive gate: predictive **95% winrate CI ⊂ [40%, 60%]** *and* lack-of-fit
  residual ≤ 3.5 *and* interpolation/bracketing/local-shape guards *and* slope confidently
  negative *and* ≥3 distinct λ / ≥60 games. On LOCK it writes `gtp_human<rank>.cfg` (forcing
  `maxVisits=40`, `winLossUtilityFactor=0.0`, the tuned λ), builds the next ANE baseline, and
  advances;
- **STOP** — best-effort if the 50% target is unreachable (λ saturates); ships the weakest tried
  λ and flags the rung.

This cut per-rung cost from ~500–1000 games (old manual method) to ~130–290, and hardened the
LOCK against model-misspecification false-locks. State persists in `ladder_state.txt` +
per-λ `jpn<rank>_ane_L*.samples` checkpoints, so a run interrupted by the environment's
process-kill cap resumes from its last completed round. `ladder_step.sh` runs one chunk per
invocation; `ladder_loop.sh` batches several; `tune_maxvisits.sh` wraps the fixed-λ `tunehuman`
call with a per-chunk `timeout`.

## Reproduction

**8d anchor (hand-set, not calibrated):** `preaz_8d @ 40v, λ0.06, winLossUtilityFactor 0`.

**Each weaker rank → 1 KGS rank below the prior rung, via the komi-0.5 handicap.** Example, 7d
(`preaz_7d` as Black vs the tuned `gtp_human8d.cfg` as White), fixed-λ grind to 50%:

```bash
katago tunehuman \
  -model kata1-b28c512nbt-s8326494464-d4628051565.bin.gz \
  -human-model b18c384nbt-humanv0.bin.gz \
  -baseline-config gtp_human8d.cfg \
  -profile preaz_7d -target-elo 0 -elo-tol 8 \
  -search-visits 40 -max-visits-cap 40 -pikl-floor 0.084 -x-lo 2.0 -x-hi 3.0 \
  -komi 0.5 -cand-color black -handicap 0 \
  -games-per-round 4 -num-game-threads 4 \
  -resume-file gtp_human7d.samples -output-config gtp_human7d.cfg
```

In practice this is driven automatically — `python3 tune_fit.py '~/.katago_tune/jpn7d_ane_L*.samples'`
recommends the λ, and `ladder_step.sh` runs the chunk and locks when the CI gate passes. The next
rung (6d) chains off `gtp_human7d.cfg` the same way, down to 25k.

Deployed run command (per config header):

```bash
./katago gtp -config gtp_human<rank>.cfg \
  -model kata1-b28c512nbt-s8326494464-d4628051565.bin.gz \
  -human-model b18c384nbt-humanv0.bin.gz
```

## Results

Winrates are direct candidate-vs-baseline results (weaker rank as Black, komi 0.5, Japanese,
b28c512 main net, 40v, winLossUtilityFactor 0) with a **95%** posterior-predictive CI. Every
rung below is tuned to 50% with its 95% CI ⊂ [40, 60].

> **Status: COMPLETE.** The re-tuned fast chain is locked from the **8d anchor through 25k** (33
> rungs incl. the anchor), every rung tuned to 50% with its 95% CI ⊂ [40, 60]. The 9d row is the
> legacy 400v reference (separate from this chain).

| Config | Profile | Baseline (White) | Measured (Black, komi 0.5) | maxVisits | piklLambda |
|--------|---------|------------------|----------------------------|----------:|-----------:|
| `gtp_human9d.cfg` | preaz_9d | rank_9d @ 400v (legacy) | 49.0% [39, 59], 100 g (even-game parity) | 400 | **0.045** |
| `gtp_human8d.cfg` | preaz_8d | — (hand-set anchor) | anchor, not calibrated | 40 | **0.06** |
| `gtp_human7d.cfg` | preaz_7d | gtp_human8d.cfg | 49.2% [40.4, 58.0], 444 g ✅ | 40 | **0.084** |
| `gtp_human6d.cfg` | preaz_6d | gtp_human7d.cfg | 50.0% [46.1, 54.1], 1036 g ✅ | 40 | **0.1269** |
| `gtp_human5d.cfg` | preaz_5d | gtp_human6d.cfg | 50.0% [42.1, 57.8], 272 g ✅ | 40 | **0.2055** |
| `gtp_human4d.cfg` | preaz_4d | gtp_human5d.cfg | 50.0% [43.9, 56.1], 288 g ✅ | 40 | **0.2277** |
| `gtp_human3d.cfg` | preaz_3d | gtp_human4d.cfg | 50.0% [43.3, 56.7], 212 g ✅ | 40 | **0.1957** |
| `gtp_human2d.cfg` | preaz_2d | gtp_human3d.cfg | 49.9% [41.7, 58.3], 272 g ✅ | 40 | **0.2530** |
| `gtp_human1d.cfg` | preaz_1d | gtp_human2d.cfg | 50.0% [42.0, 58.0], 164 g ✅ | 40 | **0.1779** |
| `gtp_human1k.cfg` | preaz_1k | gtp_human1d.cfg | 50.0% [41.5, 58.5], 140 g ✅ | 40 | **0.1537** |
| `gtp_human2k.cfg` | preaz_2k | gtp_human1k.cfg | 50.0% [41.2, 58.6], 168 g ✅ | 40 | **0.1518** |
| `gtp_human3k.cfg` | preaz_3k | gtp_human2k.cfg | 50.0% [42.0, 58.0], 164 g ✅ | 40 | **0.1285** |
| `gtp_human4k.cfg` | preaz_4k | gtp_human3k.cfg | 50.0% [41.2, 58.8], 136 g ✅ | 40 | **0.1219** |
| `gtp_human5k.cfg` | preaz_5k | gtp_human4k.cfg | 50.0% [42.1, 57.9], 184 g ✅ | 40 | **0.1093** |
| `gtp_human6k.cfg` | preaz_6k | gtp_human5k.cfg | 50.0% [41.0, 58.9], 180 g ✅ | 40 | **0.1162** |
| `gtp_human7k.cfg` | preaz_7k | gtp_human6k.cfg | 50.0% [41.6, 58.4], 188 g ✅ | 40 | **0.1039** |
| `gtp_human8k.cfg` | preaz_8k | gtp_human7k.cfg | 50.0% [43.0, 57.1], 204 g ✅ | 40 | **0.1053** |
| `gtp_human9k.cfg` | preaz_9k | gtp_human8k.cfg | 50.0% [41.9, 58.1], 184 g ✅ | 40 | **0.1178** |
| `gtp_human10k.cfg` | preaz_10k | gtp_human9k.cfg | 50.0% [41.2, 58.7], 128 g ✅ | 40 | **0.1059** |
| `gtp_human11k.cfg` | preaz_11k | gtp_human10k.cfg | 50.0% [42.1, 58.0], 172 g ✅ | 40 | **0.1219** |
| `gtp_human12k.cfg` | preaz_12k | gtp_human11k.cfg | 50.0% [41.6, 58.4], 148 g ✅ | 40 | **0.1439** |
| `gtp_human13k.cfg` | preaz_13k | gtp_human12k.cfg | 50.0% [41.1, 59.0], 144 g ✅ | 40 | **0.1327** |
| `gtp_human14k.cfg` | preaz_14k | gtp_human13k.cfg | 50.0% [41.5, 58.5], 152 g ✅ | 40 | **0.1418** |
| `gtp_human15k.cfg` | preaz_15k | gtp_human14k.cfg | 50.0% [41.5, 58.5], 144 g ✅ | 40 | **0.1872** |
| `gtp_human16k.cfg` | preaz_16k | gtp_human15k.cfg | 50.0% [42.0, 58.0], 184 g ✅ | 40 | **0.1871** |
| `gtp_human17k.cfg` | preaz_17k | gtp_human16k.cfg | 50.0% [41.8, 58.2], 200 g ✅ | 40 | **0.1845** |
| `gtp_human18k.cfg` | preaz_18k | gtp_human17k.cfg | 50.0% [41.4, 58.7], 147 g ✅ | 40 | **0.2228** |
| `gtp_human19k.cfg` | preaz_19k | gtp_human18k.cfg | 50.0% [41.2, 58.9], 140 g ✅ | 40 | **0.2479** |
| `gtp_human20k.cfg` | preaz_20k | gtp_human19k.cfg | 50.0% [42.7, 57.3], 260 g ✅ | 40 | **0.2967** |
| `gtp_human21k.cfg` | preaz_21k | gtp_human20k.cfg | 50.0% [42.6, 57.5], 424 g ✅ (noisy — concentrated) | 40 | **0.3495** |
| `gtp_human22k.cfg` | preaz_22k | gtp_human21k.cfg | 50.0% [41.5, 58.6], 144 g ✅ | 40 | **0.3378** |
| `gtp_human23k.cfg` | preaz_23k | gtp_human22k.cfg | 50.9% [42.8, 58.9], 164 g ✅ | 40 | **0.3666** |
| `gtp_human24k.cfg` | preaz_24k | gtp_human23k.cfg | 50.0% [42.5, 57.5], 188 g ✅ | 40 | **0.3692** |
| `gtp_human25k.cfg` | preaz_25k | gtp_human24k.cfg | 50.0% [41.7, 58.3], 143 g ✅ | 40 | **0.3334** |

### Findings

- **λ progression (b28c512 method).** With the strong main net, the whole λ scale is far lower
  than the old b24c64 era (where 20k needed λ≈1.22): the dan rungs rise 8d **0.06** → 5d 0.206
  then wobble ~0.18–0.25 (3d–1d); single-digit kyu sit low and flat (~**0.10–0.15**); the deep
  kyu then climb — 15k 0.187, 18k 0.223, 19k 0.248 — and **plateau ~0.30–0.37 through 20k–25k**
  (20k 0.297, 21k 0.350, 22k 0.338, 23k 0.367, 24k 0.369, 25k 0.333). λ is **not** globally
  monotone (each rung is calibrated independently to its own baseline), but the deep-kyu rise is
  real: the net's `preaz_` rank profiles **compress at the weak end**, so it takes more λ (more
  human, less search) to bring each weaker rung down to 50% — until, near the 25k floor, adjacent
  profiles are so close that the λ plateaus.
- **The extension rungs (20k–21k) are noisy.** Near the net's rank floor the winrate-vs-λ curve is
  overdispersed and near-step (a wide flat band, then a sharp drop); 20k and 21k needed ~260–424
  games and a **fixed-λ concentration pass** (`conc_loop.sh`) to build enough games at one point to
  pin the crossing CI into [40, 60], where the shifting active-learning grind alone kept spreading
  games across a moving estimate.
- **The gap is ~½ a Go-stone per rank, not a full stone.** komi 0.5 ≈ 4–6 points ≈ ½ stone ≈ 1
  KGS rank; a full Go-stone (~13 pts, komi −6.5) over-handicaps the dan rungs and was abandoned.
  Confirmed by self-play (identical 8d bots): Black wins ~58% at komi +0.5 vs ~71% at komi −6.5.
- **Adjacent-only calibration.** Each rung is pinned to 50% against *its immediate neighbor* only.
  Monotonicity/transitivity across non-adjacent ranks is **assumed, not proven** (validation
  matches — e.g. a 2-rank pairing predicted ~30–37% — are designed but not yet run). Because each
  rung carries ~±(4–6)% winrate noise, absolute-rank labels drift by **~±1 rank** through the
  high kyu and **~±2 ranks** by the deepest kyu; the *relative* 1-rank spacing is what's
  calibrated.
- **Three regimes / seams (documented).** 9d is legacy (400v, stronger, 8d↔9d link unmeasured);
  8d is a hand-set anchor; 7d→25k are the curve-fit chain. All at komi 0.5 / 40v / winLoss=0.

### Cost & practical notes

- Per rung: ~130–290 games (deep-kyu and a couple of noisy rungs cost more), tuned automatically
  by `tune_fit.py`. Backend: MLX (Apple-Silicon GPU + ANE); tuned λ are backend-independent.
- Run **one** GPU job at a time (~4 game-threads) — concurrent `katago` processes trigger
  memory-pressure (jetsam) kills.
- **Keep several GiB of disk free.** Each tuning chunk writes a ~100–200 MB CoreML temp
  (ANE-mux); on a full disk katago silently dies mid-game (symptom: chunks end in ~72 s with 0
  rounds, deep-kyu throughput collapses to a few games/chunk). Check `df -h /` first if
  games/chunk suddenly drops.
- Always report a tuned winrate **with its 95% CI and sample count** — small samples are
  deceptive on these curves.

---
_Generated by the `tunehuman` + `tune_fit.py` workflow. Configs and this doc are local artifacts
(not the upstream KataGo examples)._
