#!/usr/bin/env bash
# One campaign step: regenerate the match cfg from ladder.json (so dial edits take effect),
# play N bounded chunks on the ACTIVE rungs, then report every rung's gap + Wilson CI.
#
#   RUNGS=1 N=2 bash deepkyu_step.sh        # rungs is a comma list, empty = all 11
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN=${RUN:-$HOME/.katago_tune/deepkyu}
RUNGS=${RUNGS:-}
N=${N:-2}
CHUNK=${CHUNK:-540}
THREADS=${THREADS:-12}
NNBATCH=${NNBATCH:-8}   # >8 blows the footprint to 36GB and the machine thrashes to 0 games/h
NNSERVER=${NNSERVER:-1}   # P2: the NN path gtp_human*.cfg uses; 2 muxes onto ANE
# Bound the chunk by GAMES (a clean exit that writes every game) rather than by the timeout,
# which kills whatever is in flight -- with 40-visit rung-1 games all N threads finish at once,
# so a timeout can throw away an entire chunk.
GAMES=${GAMES:-100000000}

# Serialize: only one campaign step (i.e. one katago) may run at a time on this machine.
# Queued steps wait here instead of fighting over the GPU.
LOCK="$RUN/.busy.d"
# mkdir is atomic, so several queued steps cannot all decide the GPU is free at once.
while ! mkdir "$LOCK" 2>/dev/null; do
  owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
    echo "clearing stale lock from pid $owner"; rm -rf "$LOCK"; continue
  fi
  sleep 10
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

if [ "$RUNGS" = "auto" ]; then
  # every rung that is not yet certified, so finished rungs stop consuming GPU
  RUNGS=$(python3 "$HERE/deepkyu_ladder.py" plan | sed -n 's/^ACTIVE=//p')
  echo "auto rungs: ${RUNGS:-none}"
  [ -z "$RUNGS" ] && { echo "all rungs certified"; exit 0; }
fi
python3 "$HERE/deepkyu_ladder.py" cfg --out "$RUN/cfg/ladder.cfg" --rungs "$RUNGS" \
        --game-threads "$THREADS" --nn-batch "$NNBATCH" --games-total "$GAMES" --nn-server-threads "$NNSERVER"
for i in $(seq 1 "$N"); do
  echo "[$(date +%H:%M:%S)] chunk $i/$N (rungs=${RUNGS:-all})"
  CFG="$RUN/cfg/ladder.cfg" SGF="$RUN/sgfs/ladder" LOG="$RUN/logs/ladder.log" CHUNK="$CHUNK" \
    bash "$HERE/deepkyu_run.sh" || true
done
python3 "$HERE/deepkyu_ladder.py" status
echo
python3 "$HERE/deepkyu_ladder.py" fit
echo
python3 "$HERE/deepkyu_ladder.py" sweep
