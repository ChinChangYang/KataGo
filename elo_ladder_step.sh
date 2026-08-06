#!/usr/bin/env bash
#
# elo_ladder_step.sh — one autonomous step of the EVEN-GAME ELO re-tune of the Human-SL ladder.
#
# Sibling of ladder_step.sh, but the calibration target is a fixed even-game ELO GAP (not a
# komi-0.5 handicap 50%): each rung is tuned so the candidate (weaker) sits exactly G ELO below
# its already-locked baseline in EVEN games (komi 6.5, alternating colors). G = 100 for
# 7d..1d and the 1d->1k boundary (rungs 7d,6d,5d,4d,3d,2d,1d,1k); G = 50 for 2k..25k.
#
# Uses tune_elo.py (decision brain): pooled logistic fit LOCATES the target-winrate crossing
# lambda; LOCK requires a single concentrated lambda's Wilson gap-CI within [G-30, G+30] ELO.
#   GRIND -> run ONE resumable tunehuman chunk (even game) at the recommended lambda
#   LOCK  -> gap CI within [G-30,G+30]: write gtp_human<rank>.cfg, build next ANE baseline, advance
#   STOP  -> best-effort (saturated/budget): write config anyway, advance, flag it
#
# Invoke repeatedly (survives the env process-kill cap). State: elo_ladder_state.txt +
# per-lambda elo<rank>_L*.samples (DISTINCT prefix from the komi-0.5 jpn<rank>_* so they never
# pool). 8d anchor and 9d legacy are OUT of scope (unchanged). Run in background; one chunk/call.
set -u
ROOT=${KATAGO_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)}
TUNE=$HOME/.katago_tune
CONFIGS=$ROOT/cpp/configs
STATE=$TUNE/elo_ladder_state.txt
LOCKLOG=$TUNE/elo_ladder_locks.txt
TIMEOUT=${TIMEOUT:-1400}
CI=30                       # required 95% CI half-width (ELO) on each adjacent gap

# rank chain 7d..1d then 1k..25k (case-functions; macOS bash 3.2 lacks `declare -A`)
stronger() { case "$1" in
  7d)echo 8d;;6d)echo 7d;;5d)echo 6d;;4d)echo 5d;;3d)echo 4d;;2d)echo 3d;;1d)echo 2d;;
  1k)echo 1d;; *k) echo "$(( ${1%k} - 1 ))k";; *)echo "";; esac; }
weaker()   { case "$1" in
  7d)echo 6d;;6d)echo 5d;;5d)echo 4d;;4d)echo 3d;;3d)echo 2d;;2d)echo 1d;;1d)echo 1k;;
  *k) n=${1%k}; if [ "$n" -ge 25 ]; then echo DONE; else echo "$((n+1))k"; fi;; *)echo "";; esac; }
# Target even-game gap (ELO) to the STRONGER baseline: a UNIFORM 100 for EVERY consecutive rung
# (7d..25k). Changed 2026-07-17 from 100-dan/50-kyu to a flat 100 (low-dan lambdas are small = strong
# play, so a moderate 100/rung throughout; revisit if deep-kyu lambda runs too high). See doc.
gap_for() { case "$1" in *d) echo 100;; *k) echo 100;; *) echo "";; esac; }

[ -f "$STATE" ] || echo 7d > "$STATE"
RANK=$(cat "$STATE" 2>/dev/null || echo 7d)
if [ "$RANK" = DONE ]; then echo "ELO LADDER COMPLETE — all rungs 7d..1d, 1k..25k done."; exit 0; fi
STR=$(stronger "$RANK")
[ -z "$STR" ] && { echo "ERROR: unknown rank '$RANK'"; exit 2; }
GAP=$(gap_for "$RANK")
[ -z "$GAP" ] && { echo "ERROR: no gap target for '$RANK'"; exit 2; }
PROFILE=preaz_$RANK
BASELINE=$TUNE/tunebase_human${STR}_ane.cfg
[ -f "$BASELINE" ] || { echo "ERROR: baseline $BASELINE missing (need tuned ${STR} first)"; exit 2; }

DEC=$(python3 "$ROOT/tune_elo.py" "$TUNE/elo${RANK}_L*.samples" "$GAP" "$CI")
echo "[$(date '+%H:%M:%S')] rank=$RANK baseline=$STR gap=${GAP}ELO  ->  $DEC"
ACTION=$(printf '%s' "$DEC" | sed -n 's/.*ACTION=\([A-Z]*\).*/\1/p')
LAMBDA=$(printf '%s' "$DEC" | sed -n 's/.*LAMBDA=\([0-9.]*\).*/\1/p')

case "$ACTION" in
  GRIND)
    if [ -z "$LAMBDA" ] || [ "$LAMBDA" = NA ]; then
      # fresh rank, no samples: seed from the STRONGER NEIGHBOUR's newly-tuned EVEN-GAME lambda.
      # Adjacent even-game rungs cluster tightly (e.g. 1k..5k = 0.20150/0.19950/0.20760/0.21180/0.21600),
      # so this lands right next to this rung's crossing and tune_elo.py barely has to walk. Far better
      # than seeding from the OLD komi-0.5 config lambda (~0.10-0.12 for kyu), which forced a long
      # ~0.11 -> ~0.22 walk every kyu rung. The chain is sequential so the stronger neighbour is already
      # even-game-tuned; fall back to old-config lambda, then stronger+0.02, only if it somehow isn't.
      SEED=$(grep -E '^humanSLChosenMovePiklLambda' "$CONFIGS/gtp_human${RANK}.cfg" 2>/dev/null | awk '{print $3}')
      SLAM=$(grep -E '^humanSLChosenMovePiklLambda' "$CONFIGS/gtp_human${STR}.cfg" 2>/dev/null | awk '{print $3}')
      STREVEN=$(grep -q 'even-game ELO ladder' "$CONFIGS/gtp_human${STR}.cfg" 2>/dev/null && echo 1 || echo 0)
      LAMBDA=$(python3 -c "se='${STREVEN}'; slam='${SLAM}'; seed='${SEED}'; v=(float(slam) if se=='1' and slam else (float(seed) if seed else (float(slam)+0.02 if slam else 0.08))); print(f'{max(0.001,v):.5f}')")
      echo "  seeding fresh rank $RANK at λ=$LAMBDA (stronger ${STR}=${SLAM:-NA} even=${STREVEN}, old-cfg=${SEED:-NA})"
    fi
    LAMTAG=$(printf '%s' "$LAMBDA" | sed 's/^0\.//; s/0*$//')   # 0.07500 -> 075
    for p in $(ps aux | grep "[k]atago tunehuman" | awk '{print $2}'); do kill -9 "$p" 2>/dev/null; done
    sleep 1
    BASELINE_CFG=$BASELINE CAND_PROFILE=$PROFILE PIKL=$LAMBDA V_LO=40 V_HI=40 \
      KOMI=6.5 CAND_COLOR=auto HANDICAP=0 TARGET_ELO=-$GAP ELO_TOL=1 \
      GAMES_PER_ROUND=8 GAME_THREADS=4 TIMEOUT=$TIMEOUT \
      TAG=elo${RANK}_L${LAMTAG} \
      RESUME=$TUNE/elo${RANK}_L${LAMTAG}.samples \
      LOG=$TUNE/elo${RANK}_L${LAMTAG}.log \
      OUT=$TUNE/elo${RANK}_L${LAMTAG}.out.cfg \
      "$ROOT/tune_maxvisits.sh"
    ;;
  LOCK|STOP)
    WR=$(printf '%s' "$DEC" | sed -n 's/.*WR=\([0-9.]*\).*/\1/p')
    GVAL=$(printf '%s' "$DEC" | sed -n 's/.*GAP=\([+-]*[0-9.]*\).*/\1/p')
    GCI=$(printf '%s' "$DEC" | sed -n 's/.*CI=\([0-9.,-]*\).*/\1/p')
    N=$(printf '%s' "$DEC" | sed -n 's/.*N=\([0-9]*\).*/\1/p')
    LOSPAN=$((GAP-CI)); HISPAN=$((GAP+CI))
    HMETH="even-game ELO ladder (komi 6.5, alternating colors; 40v; winLossUtilityFactor=0; b28c512 main net)"
    DST=$CONFIGS/gtp_human${RANK}.cfg
    SRC=$DST; [ -f "$DST" ] || SRC=$CONFIGS/gtp_human${STR}.cfg
    if [ "$ACTION" = LOCK ]; then
      H1="# CALIBRATED (Japanese, ${HMETH}, ANE): preaz_${RANK} vs gtp_human${STR}.cfg, even game = ${WR}% -> gap ${GVAL} ELO [${GCI}] over ${N} games (target ${GAP}, 95% CI ⊂ [${LOSPAN},${HISPAN}]). λ=${LAMBDA}."
    else
      H1="# BEST-EFFORT (Japanese, ${HMETH}, ANE): preaz_${RANK} vs gtp_human${STR}.cfg, even game = ${WR}% -> gap ${GVAL} ELO [${GCI}] over ${N} games. The ${GAP}-ELO target is UNREACHABLE by λ alone (saturation/budget); 95% CI NOT within [${LOSPAN},${HISPAN}]. Ships the closest-to-target λ=${LAMBDA}."
    fi
    H2="# gtp_human${RANK}.cfg — ${RANK} rung of the Human-SL even-game ELO ladder. See docs/HumanSL_Rank_Ladder.md."
    H3="# Run: ./katago gtp -config gtp_human${RANK}.cfg -model kata1-b28c512nbt-s8326494464-d4628051565.bin.gz -human-model b18c384nbt-humanv0.bin.gz   (calibrated for THIS main net; a different one invalidates the calibration)"
    { printf '%s\n%s\n%s\n' "$H1" "$H2" "$H3"
      awk 'BEGIN{h=1} h && /^#/ {next} {h=0} {print}' "$SRC"
    } | sed -e "s/^humanSLProfile *=.*/humanSLProfile = ${PROFILE}/" \
            -e "s/^humanSLChosenMovePiklLambda *=.*/humanSLChosenMovePiklLambda = ${LAMBDA}/" \
            -e "s/^maxVisits *=.*/maxVisits = 40/" \
            -e "s/^winLossUtilityFactor *=.*/winLossUtilityFactor = 0.0/" > "$DST.tmp"
    mv "$DST.tmp" "$DST"
    echo "WROTE $DST   λ=${LAMBDA}  ${ACTION}  gap ${GVAL} ELO [${GCI}] ${N}g  (target ${GAP})"
    echo "$(date '+%F %T')  ${RANK}  λ=${LAMBDA}  gap=${GVAL} CI[${GCI}] ${N}g  target=${GAP}  ${ACTION}" >> "$LOCKLOG"
    if [ "$ACTION" = STOP ]; then
      echo "  NOTE: $RANK is BEST-EFFORT — ${GAP}-ELO target unreachable by λ; shipped closest-to-target λ."
    fi
    NB=$TUNE/tunebase_human${RANK}_ane.cfg
    sed -e 's/^nnCacheSizePowerOfTwo *=.*/nnCacheSizePowerOfTwo = 18/' \
        -e 's/^nnMutexPoolSizePowerOfTwo *=.*/nnMutexPoolSizePowerOfTwo = 12/' "$DST" > "$NB"
    { echo ""; echo "# ANE-mux tuning baseline (GPU thread0 + ANE thread1); cache lowered — no play effect.";
      echo "numNNServerThreadsPerModel = 2"; echo "deviceToUseThread0 = 0"; echo "deviceToUseThread1 = 100"; } >> "$NB"
    rm -f "$TUNE/elo${RANK}_conc.txt"   # clear this rung's sticky-concentration state (clean handoff)
    NEXT=$(weaker "$RANK")
    echo "$NEXT" > "$STATE"
    echo "ADVANCED $RANK -> $NEXT   (${ACTION}; next baseline: $NB)"
    ;;
  *) echo "ERROR: could not parse action from: $DEC"; exit 3 ;;
esac
