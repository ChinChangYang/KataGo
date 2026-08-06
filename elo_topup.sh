#!/usr/bin/env bash
#
# elo_topup.sh — certify UNDER-CERTIFIED rungs (from the 2026-07-18 pooled-window audit).
#
# Some early rungs (6d/5d/4d/3d) locked via the since-removed optimistic pooled-window estimator; at
# their EXACT shipped lambda the honest single-cell (phi=1) Wilson gap-CI is not yet within
# [GAP-CI, GAP+CI]. This pass adds games AT the exact shipped lambda (= lam_star, the intended gap=100
# crossing) until that single-cell CI lands in band, then appends an honest LOCK to the lock log.
#
# NON-DISRUPTIVE: it never changes any config's lambda (it tops up the exact shipped lambda), so no
# downstream baseline moves and no chain revert is needed. Rungs are processed STRONG->WEAK. Runs ONE
# resumable tunehuman chunk per invocation and exits — GPU-serialized, so do NOT run it concurrently
# with elo_ladder_loop.sh (one katago at a time, or the box OOMs). It is meant to run in the loop's
# DONE phase (after the linear 7d->25k grind) or standalone with the linear grind stopped.
#
#   DRY_RUN=1 bash elo_topup.sh   # print which rung/lambda it would top up, without playing
#   bash elo_topup.sh             # play one chunk toward the strongest under-certified rung
#
set -u
ROOT=${KATAGO_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)}
TUNE=$HOME/.katago_tune
CONFIGS=$ROOT/cpp/configs
LOCKLOG=$TUNE/elo_ladder_locks.txt
CI=30                        # required 95% CI half-width (ELO)
GAP=100                      # uniform 100-ELO/rung target
TIMEOUT=${TIMEOUT:-1400}
DRY_RUN=${DRY_RUN:-0}
MEASURE_ONLY=${MEASURE_ONLY:-0}  # 1 = just MEASURE each rung's exact-λ gap to CI half-width <= CI and log
                                 # it (no +100 requirement, NO λ retuning — user directive 2026-08-06);
                                 # the gap is whatever the shipped λ produces, documented as-is.
BUDGET_CAP=${BUDGET_CAP:-2600}   # per-rung cap at the exact lambda: beyond this the exact-lambda gap is
                                 # too far off to certify by games alone -> STOP (needs a manual lambda re-tune)

stronger() { case "$1" in
  7d)echo 8d;;6d)echo 7d;;5d)echo 6d;;4d)echo 5d;;3d)echo 4d;;2d)echo 3d;;1d)echo 2d;;
  1k)echo 1d;; *k) echo "$(( ${1%k} - 1 ))k";; *)echo "";; esac; }

# strong -> weak rank order (7d..1d then 1k..25k)
RANKS="7d 6d 5d 4d 3d 2d 1d"; for k in $(seq 1 25); do RANKS="$RANKS ${k}k"; done

# Honest single-cell (phi=1) status of ONE lambda-cell samples file (sums its rounds).
# Prints: "CERT g gap lo hi wr" | "NEED g gap lo hi wr" | "NONE 0"
cell_status() {
  PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 - "$1" "$GAP" "$CI" "${MEASURE_ONLY:-0}" <<'PY'
import sys, os
import tune_elo as te
f, G, ci = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
mo = (sys.argv[4] == "1")
if not os.path.exists(f):
    print("NONE 0"); raise SystemExit
w = g = 0.0
for i, line in enumerate(open(f)):
    if i == 0 or line.startswith('#'):
        continue
    p = line.split()
    if len(p) >= 3:
        w += float(p[1]); g += int(p[2])
g = int(g)
if g == 0:
    print("NONE 0"); raise SystemExit
gp, lo, hi = te.wilson_gap_ci(w, g)               # phi=1: iid within a single lambda
if mo:                                            # MEASURE_ONLY: done when CI is tight enough (hw<=ci),
    ok = g >= te.LOCK_MIN_G and (hi - lo) / 2.0 <= ci   # regardless of where the gap lands (no +100 req)
else:
    ok = g >= te.LOCK_MIN_G and lo >= G - ci and hi <= G + ci
print(f"{'CERT' if ok else 'NEED'} {g} {gp:.0f} {lo:.0f} {hi:.0f} {100*w/g:.1f}")
PY
}

for R in $RANKS; do
  CFG=$CONFIGS/gtp_human${R}.cfg
  [ -f "$CFG" ] || continue                     # not tuned yet -> out of scope for top-up
  # ONLY touch EVEN-GAME-tuned rungs. The kyu rungs still carry their pre-existing komi-0.5 configs
  # until the linear grind re-tunes them; without this guard, running top-up mid-grind would wrongly
  # "top up" an un-retuned old config at its old λ. (At DONE every config is even-game, so this is a
  # no-op then — it only makes the pass safe if ever run early.)
  grep -q 'even-game ELO ladder' "$CFG" || continue
  # SKIP the deep-kyu pure-human tail (15k..25k @ λ=1e8). Those rungs are INTENTIONALLY not +100 —
  # the deep-kyu gap is non-monotonic and peaks below 100, so they ship at pure-human λ=1e8 with a
  # documented (small) gap. Topping them up toward +100 is infeasible (would grind to BUDGET_CAP→STOP).
  grep -q 'DEEP-KYU / PURE-HUMAN' "$CFG" && continue
  LAM=$(grep -E '^humanSLChosenMovePiklLambda' "$CFG" | awk '{print $3}')
  [ -z "$LAM" ] && continue
  TAG=L$(printf '%s' "$LAM" | sed 's/^0\.//; s/0*$//')   # 0.09940 -> L0994
  SF=$TUNE/elo${R}_${TAG}.samples
  read -r ST G GAPV LO HI WR <<<"$(cell_status "$SF")"
  [ "$ST" = CERT ] && continue                  # this exact-lambda cell already certifies -> next rung

  # --- strongest rung needing top-up ---
  STR=$(stronger "$R"); BASELINE=$TUNE/tunebase_human${STR}_ane.cfg
  echo "[topup] target=$R  λ=$LAM  cell=$(basename "$SF")  status=$ST games=${G:-0} gap=${GAPV:-?} CI[${LO:-?},${HI:-?}]"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRY_RUN: would play at exact λ=$LAM vs $(basename "$BASELINE") until single-cell CI ⊂ [$((GAP-CI)),$((GAP+CI))] (cap ${BUDGET_CAP}g)."
    exit 0
  fi
  [ -f "$BASELINE" ] || { echo "ERROR: baseline $BASELINE missing (need certified ${STR} first)"; exit 2; }
  if [ "${G:-0}" -ge "$BUDGET_CAP" ]; then
    echo "  BUDGET: $R passed ${BUDGET_CAP}g at exact λ without certifying — its exact-λ gap is too far off"
    echo "          to certify by games alone; needs a manual λ re-tune. Logging STOP (best-effort)."
    echo "$(date '+%F %T')  ${R}  λ=${LAM}  gap=${GAPV} CI[${LO},${HI}] ${G}g  target=${GAP}  STOP" >> "$LOCKLOG"
    exit 0
  fi
  for p in $(ps aux | grep "[k]atago tunehuman" | awk '{print $2}'); do kill -9 "$p" 2>/dev/null; done
  sleep 1
  BASELINE_CFG=$BASELINE CAND_PROFILE=preaz_$R PIKL=$LAM V_LO=40 V_HI=40 \
    KOMI=6.5 CAND_COLOR=auto HANDICAP=0 TARGET_ELO=-$GAP ELO_TOL=1 \
    GAMES_PER_ROUND=8 GAME_THREADS=4 TIMEOUT=$TIMEOUT \
    TAG=elo${R}_${TAG} RESUME=$SF LOG=$TUNE/elo${R}_${TAG}.log OUT=$TUNE/elo${R}_${TAG}.out.cfg \
    "$ROOT/tune_maxvisits.sh"

  # re-check the same cell; if it now certifies, append an HONEST single-cell LOCK to the log
  read -r ST2 G2 GAPV2 LO2 HI2 WR2 <<<"$(cell_status "$SF")"
  if [ "$ST2" = CERT ]; then
    LBL=$([ "${MEASURE_ONLY:-0}" = 1 ] && echo MEASURED || echo LOCK)
    echo "$(date '+%F %T')  ${R}  λ=${LAM}  gap=${GAPV2} CI[${LO2},${HI2}] ${G2}g  target=${GAP}  ${LBL}" >> "$LOCKLOG"
    echo "[topup] ${LBL} $R at exact λ=$LAM: gap ${GAPV2} CI[${LO2},${HI2}] ${G2}g (honest single-cell φ=1, hw$(( (${HI2}-${LO2})/2 ))≤${CI})."
  else
    echo "[topup] $R still NEED: gap ${GAPV2:-?} CI[${LO2:-?},${HI2:-?}] ${G2:-?}g — continues next invocation."
  fi
  exit 0
done
echo "[topup] ALL CERTIFIED — every tuned rung's exact-λ single-cell CI is ⊂ band."
