#!/usr/bin/env bash
# ladder_loop.sh — run several ladder_step chunks per invocation (maximize compute before the
# env's ~25-45 min process-kill cap). Each ladder_step is one resumable tunehuman chunk. Breaks
# early when a rung LOCKs/advances (state changes) so the agent can react to the new rung.
# Drive: `bash ladder_loop.sh` in the background; relaunch on completion. Resumable via samples files.
ROOT=${KATAGO_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)}
TD=$HOME/.katago_tune
CHUNK_TIMEOUT=${CHUNK_TIMEOUT:-700}
MAX_CHUNKS=${MAX_CHUNKS:-6}
start=$(cat "$TD/ladder_state.txt" 2>/dev/null)
echo "=== ladder_loop start: rank=$start, up to $MAX_CHUNKS chunks @ ${CHUNK_TIMEOUT}s ==="
for i in $(seq 1 "$MAX_CHUNKS"); do
  out=$(TIMEOUT=$CHUNK_TIMEOUT bash "$ROOT/ladder_step.sh" 2>&1)
  line=$(echo "$out" | grep -E "rank=|ACTION=|LOCK|ADVANCED|WROTE" | head -1)
  echo "[chunk $i] $line"
  now=$(cat "$TD/ladder_state.txt" 2>/dev/null)
  if [ "$now" != "$start" ]; then echo "=== RUNG ADVANCED: $start -> $now (stopping loop) ==="; break; fi
  if [ "$now" = DONE ]; then echo "=== LADDER COMPLETE ==="; break; fi
done
# Trailing lock: if the last game-chunk made the rung lockable (the loop only ran GRINDs and exited
# before the next iteration would LOCK), perform the LOCK now so the rung advances this invocation.
cur=$(cat "$TD/ladder_state.txt" 2>/dev/null)
if [ "$cur" = "$start" ] && [ "$cur" != DONE ] && [ -n "$cur" ]; then
  dec=$(python3 "$ROOT/tune_fit.py" "$TD/jpn${cur}_ane_L*.samples" 2>/dev/null | grep -m1 'ACTION=')
  case "$dec" in
    *ACTION=LOCK*) echo "[trailing-lock] $dec"; bash "$ROOT/ladder_step.sh" 2>&1 | grep -E "WROTE|ADVANCED" ;;
  esac
fi
echo "=== ladder_loop end: rank now $(cat "$TD/ladder_state.txt" 2>/dev/null) ==="