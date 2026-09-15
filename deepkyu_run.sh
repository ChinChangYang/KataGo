#!/usr/bin/env bash
# One bounded chunk of the deep-kyu even-game campaign.
#
# The environment SIGKILLs long-lived processes at ~25-45 min, so every run is a short chunk;
# SGF files are the state, so a kill costs at most the games in flight (one per game thread).
# Both Apple caches leak ~0.5 GB per chunk and are regenerable, so they are pruned after each run.
#
# Env: CFG (match cfg) SGF (sgf out dir) [RUN] [KATAGO] [HUMAN] [LOG] [CHUNK secs]
set -u
RUN=${RUN:-$HOME/.katago_tune/deepkyu}
KATAGO=${KATAGO:-$RUN/katago}
HUMAN=${HUMAN:-/Users/chinchangyang/Code/KataGo-MLX/cpp/models/b18c384nbt-humanv0.bin.gz}
CHUNK=${CHUNK:-1200}
: "${CFG:?set CFG=<match cfg>}"
: "${SGF:?set SGF=<sgf output dir>}"
LOG=${LOG:-$RUN/logs/$(basename "${SGF}").log}

mkdir -p "$SGF" "$(dirname "$LOG")"
before=$(find "$SGF" -name '*.sgf*' -exec cat {} + 2>/dev/null | grep -c 'PB\[' || true)
t0=$(date +%s)
timeout -k 30 "$CHUNK" "$KATAGO" match \
  -config "$CFG" -human-model "$HUMAN" -sgf-output-dir "$SGF" -log-file "$LOG" \
  >>"${LOG}.stdout" 2>&1
rc=$?
t1=$(date +%s)
after=$(find "$SGF" -name '*.sgf*' -exec cat {} + 2>/dev/null | grep -c 'PB\[' || true)

# Regenerable Apple caches: prune so a multi-day campaign cannot fill the disk (only 43 GiB free).
rm -rf "$HOME/Library/Caches/katago/com.apple.e5rt.e5bundlecache/"* 2>/dev/null
# DEAD-PID ONLY. The old form deleted every model_<pid>_*.mlmodelc including the cache of a
# katago that is STILL RUNNING. This script runs between chunks of its own match, but any
# concurrent katago -- a throughput probe, a benchmark -- would have its CoreML backend yanked
# out from under it mid-game. Matches scratchpad/clean_mlmodelc.sh, which was always dead-PID-only.
for d in "${TMPDIR:-/tmp}"/model_*_*.mlmodelc; do
  [ -d "$d" ] || continue
  pid=$(basename "$d" | sed -n 's/^model_\([0-9][0-9]*\)_.*/\1/p')
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null && continue     # owner alive -> leave it alone
  rm -rf "$d" 2>/dev/null
done

secs=$((t1 - t0))
games=$((after - before))
rate=0
[ "$secs" -gt 0 ] && rate=$(( games * 3600 / secs ))
echo "chunk rc=$rc secs=${secs} games=${games} rate=${rate}/h total=${after} free=$(df -h /System/Volumes/Data | awk 'NR==2{print $4}')"
