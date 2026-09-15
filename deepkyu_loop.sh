#!/usr/bin/env bash
# Run N bounded chunks back to back. Kept under ~20 min total because the environment
# SIGKILLs long-lived processes at ~25-45 min; each chunk is independently checkpointed
# (its SGFs are on disk), so a kill costs at most the games in flight.
set -u
N=${N:-2}
for i in $(seq 1 "$N"); do
  echo "[$(date +%H:%M:%S)] chunk $i/$N"
  bash "$(dirname "$0")/deepkyu_run.sh" || true
done
