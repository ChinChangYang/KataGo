#!/usr/bin/env bash
# elo_ladder_loop.sh — run several elo_ladder_step chunks per invocation (maximize compute before
# the env's ~25-45 min process-kill cap). Each step is one resumable even-game tunehuman chunk.
# Breaks early when a rung LOCKs/advances (state changes) so the agent can react to the new rung.
# Drive: `bash elo_ladder_loop.sh` in the background; relaunch on completion. Resumable via samples.
set -u
ROOT=${KATAGO_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)}
TD=$HOME/.katago_tune
CHUNK_TIMEOUT=${CHUNK_TIMEOUT:-1200}
MAX_CHUNKS=${MAX_CHUNKS:-6}
CI=30
gap_for() { case "$1" in *d) echo 100;; *k) echo 100;; *) echo "";; esac; }   # uniform 100 ELO/rung (2026-07-17)
[ -f "$TD/elo_ladder_state.txt" ] || echo 7d > "$TD/elo_ladder_state.txt"
start=$(cat "$TD/elo_ladder_state.txt" 2>/dev/null)
echo "=== elo_ladder_loop start: rank=$start, up to $MAX_CHUNKS chunks @ ${CHUNK_TIMEOUT}s ==="
for i in $(seq 1 "$MAX_CHUNKS"); do
  # DONE = the linear 7d->25k grind finished. Enter the CERTIFICATION phase: top up any UNDER-CERTIFIED
  # rung (2026-07-18 pooled-window audit) at its EXACT shipped λ until its single-cell φ=1 CI ⊂ band.
  # GPU-serialized (the linear grind is done, so nothing else runs). Loops until elo_topup reports all.
  if [ "$(cat "$TD/elo_ladder_state.txt" 2>/dev/null)" = DONE ]; then
    tu=$(TIMEOUT=$CHUNK_TIMEOUT bash "$ROOT/elo_topup.sh" 2>&1)
    echo "[topup $i] $(printf '%s' "$tu" | grep -E 'CERTIFIED|BUDGET|target=|ALL CERTIFIED' | head -1)"
    rm -rf "$HOME/Library/Caches/katago/com.apple.e5rt.e5bundlecache"/* 2>/dev/null
    if printf '%s' "$tu" | grep -q "ALL CERTIFIED"; then echo "=== ELO LADDER COMPLETE + ALL CERTIFIED ==="; break; fi
    continue
  fi
  out=$(TIMEOUT=$CHUNK_TIMEOUT bash "$ROOT/elo_ladder_step.sh" 2>&1)
  line=$(echo "$out" | grep -E "rank=|ACTION=|LOCK|ADVANCED|WROTE" | head -1)
  echo "[chunk $i] $line"
  # Prune the ANE compiled-bundle cache between chunks (no katago running here). Each chunk feeds the
  # ANE a PID-named CoreML temp, so the bundle is a cache-MISS every time and just accumulates
  # (~0.5-0.6 GB/chunk, ~10 GB/day) — it is never reused, so pruning is free and keeps disk from filling.
  rm -rf "$HOME/Library/Caches/katago/com.apple.e5rt.e5bundlecache"/* 2>/dev/null
  now=$(cat "$TD/elo_ladder_state.txt" 2>/dev/null)
  if [ "$now" = DONE ]; then echo "=== LINEAR GRIND COMPLETE — entering certification (top-up) phase ==="; continue; fi
  # Self-continue across rung advances (autonomous multi-rung grind): update the anchor and keep going,
  # rather than stopping at every lock. One invocation grinds as many rungs as it can before the
  # env's process-kill cap ends it; relaunch resumes from the current rung + samples.
  if [ "$now" != "$start" ]; then echo "=== RUNG ADVANCED: $start -> $now (continuing) ==="; start=$now; fi
done
# Trailing lock: if the last chunk's games just made the rung lockable, LOCK now so it advances
# this invocation (the loop only ran GRINDs and exited before the next iteration would LOCK).
cur=$(cat "$TD/elo_ladder_state.txt" 2>/dev/null)
if [ "$cur" = "$start" ] && [ "$cur" != DONE ] && [ -n "$cur" ]; then
  g=$(gap_for "$cur")
  dec=$(python3 "$ROOT/tune_elo.py" "$TD/elo${cur}_L*.samples" "$g" "$CI" 2>/dev/null | grep -m1 'ACTION=')
  case "$dec" in
    *ACTION=LOCK*) echo "[trailing-lock] $dec"; bash "$ROOT/elo_ladder_step.sh" 2>&1 | grep -E "WROTE|ADVANCED" ;;
  esac
fi
echo "=== elo_ladder_loop end: rank now $(cat "$TD/elo_ladder_state.txt" 2>/dev/null) ==="
