#!/bin/bash
# PROTOTYPE (wayfinder #37), throwaway: run stage 1 of the Core AI gate on this Mac or on the iPad, for the record.
#
#   stage1.sh mac  <workDir> [outDir]
#   stage1.sh ipad <workDir> [outDir]      DEVICE=<udid or name> (default: the first connected iPad16,1/16,2)
#
# <workDir> is prepare.sh's. Results land in <outDir> (default <workDir>/stage1-<platform>-<timestamp>): one JSON per
# mode plus run.log, the whole console. The steps, in order:
#   info, parity, mish, residency      accuracy and residency (parity at 19x19 and 37x37, the Mish sweep, ANE asserts)
#   speed                              iPad: K=2, judged. Mac: K=1,2,4,8, a diagnostic. >= 500 samples x >= 3 reps,
#                                      blocks alternating within one process, refused unless the machine is idle
#   power                              each K=2 arm alone for 20 s (recorded only). Mac: ANE energy needs root, so
#                                      SUDO_POWER=1 runs this one step under sudo (it asks for the password)
#   loads                              each in a fresh process: coreml-first, coreml-cached x3, coreai-cold,
#                                      coreai-warm x3, then the AOT .aimodelc after a 60 s idle gap x3 and back to back x5
# Extra harness options for every measured step go in GATE_ARGS (for example GATE_ARGS="--idle-wait 900").
# Never run two of these at once, and leave the machine alone while it runs: one Neural Engine measurement at a time.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$1"; W="$(cd "$2" && pwd)"
OUT="${3:-$W/stage1-$PLATFORM-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
LOG="$OUT/run.log"
BUNDLE_ID="chinchangyang.KataGo-iOS.tw.coreaigate"
GATE_ARGS="${GATE_ARGS:-}"
IDLE_GAP="${IDLE_GAP:-60}"

say() { echo "$*" | tee -a "$LOG"; }

case "$PLATFORM" in
mac)
  BIN="$("$HERE/build.sh" mac "$W" | tail -1)"
  run() { "$BIN" --assets "$W/assets" --out "$OUT" --cache "$W/cache" "$@" $GATE_ARGS 2>&1 | tee -a "$LOG" || true; }
  ARCH="$("$BIN" --mode info --assets "$W/assets" --out "$OUT/scratch" | sed -n 's/.*Core AI architecture \([^,]*\),.*/\1/p')"
  ;;
ipad)
  DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPad16,[12]/ && / connected / {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i; exit}')}"
  [ -n "$DEVICE" ] || { echo "no connected iPad mini (A17 Pro); set DEVICE" >&2; exit 1; }
  APP="$("$HERE/build.sh" ios "$W" | tail -1)"
  xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
  run() {
    # The app runs the mode, streams its console here, writes JSON to Documents/results, and exits.
    xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing "$BUNDLE_ID" -- \
      "$@" $GATE_ARGS --exit 2>&1 | tee -a "$LOG" || true
  }
  ARCH="$(run --mode info | sed -n 's/.*Core AI architecture \([^,]*\),.*/\1/p' | tail -1)"
  ;;
*) echo "usage: stage1.sh mac|ipad <workDir> [outDir]" >&2; exit 2 ;;
esac
[ -n "$ARCH" ] || { echo "could not read the Core AI architecture" >&2; exit 1; }
say "== $PLATFORM, Core AI architecture $ARCH, results in $OUT"

# The ahead-of-time compiled function for this device, from the Mac's Metal Toolchain.
AOT="$W/assets/aot/b18_19_b1.$ARCH.aimodelc"
if [ ! -d "$AOT" ]; then
  mkdir -p "$W/assets/aot"
  P=$([ "$PLATFORM" = mac ] && echo macOS || echo iOS)
  xcrun coreai-build compile "$W/assets/coreai/b18_19_b1.aimodel" --platform "$P" --architecture "$ARCH" \
    --preferred-compute neural-engine --output "$AOT" | tee -a "$LOG"
fi
if [ "$PLATFORM" = ipad ]; then
  APP="$("$HERE/build.sh" ios "$W" "$AOT" | tail -1)"
  xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
fi

say "== accuracy and residency"
run --mode parity
run --mode mish
run --mode residency

say "== speed"
if [ "$PLATFORM" = mac ]; then run --mode speed --sweep 1,2,4,8 --k 2; else run --mode speed --k 2; fi

say "== power"
if [ "$PLATFORM" = mac ] && [ "${SUDO_POWER:-0}" = 1 ]; then
  sudo "$BIN" --mode power --assets "$W/assets" --out "$OUT/power-root" --cache "$OUT/power-root/cache" $GATE_ARGS 2>&1 | tee -a "$LOG" || true
  sudo chown -R "$(id -u):$(id -g)" "$OUT/power-root" || true
else
  run --mode power
fi

say "== loads (one process each)"
run --mode load --what coreml-first
for i in 1 2 3; do run --mode load --what coreml-cached; done
run --mode load --what coreai-cold
for i in 1 2 3; do run --mode load --what coreai-warm; done
for i in 1 2 3; do say "   idle gap ${IDLE_GAP} s"; sleep "$IDLE_GAP"; run --mode load --what coreai-aot; done
for i in 1 2 3 4 5; do run --mode load --what coreai-aot; done

if [ "$PLATFORM" = ipad ]; then
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/results --destination "$OUT/device" >/dev/null || say "could not copy Documents/results"
fi

say ""
say "== summary"
grep -hE "^(speed K=.*fastest|Parity \(|Mish sweep|Residency:|LOAD |  coreml-app|  coreai-|ERROR|WARNING|idle check .*REFUSED)" "$LOG" | tee "$OUT/summary.txt"
say "results: $OUT"
