#!/usr/bin/env bash
# conc_loop.sh RANK LAM — CONCENTRATE one fixed λ for a rung over MAX_CHUNKS chunks, to pin the
# located crossing to enough games for a lock. (The decide's per-chunk re-interpolation spreads
# ~12g across shifting λ on the steep b28c512 cliffs and never builds one point to 50g+.) Pools
# with any decide-ground file at the same λ via the piklFloor header. Resumable.
#   Drive: `bash conc_loop.sh 6d 0.145` in background; relaunch until CI ⊂ [40,60], then run
#   `bash ladder_step.sh` once to LOCK+advance.
set -u
RANK=$1; LAM=$2
ROOT=${KATAGO_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)}; TD=$HOME/.katago_tune
CHUNK_TIMEOUT=${CHUNK_TIMEOUT:-1100}; MAX_CHUNKS=${MAX_CHUNKS:-2}
stronger() { case "$1" in
  8d)echo 9d;;7d)echo 8d;;6d)echo 7d;;5d)echo 6d;;4d)echo 5d;;3d)echo 4d;;2d)echo 3d;;1d)echo 2d;;
  1k)echo 1d;; *k) echo "$(( ${1%k} - 1 ))k";; *)echo "";; esac; }
STR=$(stronger "$RANK"); BASE=$TD/tunebase_human${STR}_ane.cfg
[ -f "$BASE" ] || { echo "ERROR: baseline $BASE missing"; exit 2; }
TAG=jpn${RANK}_ane_Lc$(printf '%s' "$LAM" | sed 's/[^0-9]//g')
echo "=== conc $RANK λ=$LAM vs $STR, $MAX_CHUNKS chunks @ ${CHUNK_TIMEOUT}s ==="
for i in $(seq 1 "$MAX_CHUNKS"); do
  BASELINE_CFG=$BASE CAND_PROFILE=preaz_$RANK PIKL=$LAM V_LO=40 V_HI=40 \
    KOMI=0.5 CAND_COLOR=black HANDICAP=0 TARGET_ELO=0 ELO_TOL=8 \
    GAMES_PER_ROUND=4 GAME_THREADS=4 TIMEOUT=$CHUNK_TIMEOUT \
    TAG=$TAG RESUME=$TD/$TAG.samples LOG=$TD/$TAG.log OUT=$TD/$TAG.out.cfg \
    bash "$ROOT/tune_maxvisits.sh" >/dev/null 2>&1
  echo "[chunk $i] $(awk 'NR>1&&!/^#/{w+=$2;g+=$3}END{if(g>0)printf "%d/%d=%.1f%%",w,g,100*w/g}' "$TD/$TAG.samples")"
done
awk 'NR>1&&!/^#/{w+=$2;g+=$3}END{if(g>0){ph=w/g;n=g;z=1.96;d=1+z*z/n;c=(ph+z*z/(2*n))/d;m=(z/d)*sqrt(ph*(1-ph)/n+z*z/(4*n*n));printf "  -> %d/%d=%.1f%% CI[%.1f,%.1f]%s\n",w,g,100*ph,100*(c-m),100*(c+m),((c-m>=0.40&&c+m<=0.60)?" ⊂[40,60] LOCK-READY (run ladder_step)":" (continue)")}}' "$TD/$TAG.samples"