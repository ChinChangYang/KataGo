#!/usr/bin/env bash
# SP4 acceptance gate: runs SP3 vs SP4 MLX-fp16 paired-t, testgpuerror,
# and tuner wall-time bound.
#
# Arm A   (perf): SP3-MLX-fp16 vs SP4-MLX-fp16 — paired CI_lower on
#                 (SP4 - SP3) >= 0 (equivalence-or-better).
# Accuracy:       testgpuerror with mlxUseFP16=true vs eigen reference
#                 (same as SP3 — gated on exit code).
# Wall-time:      SP4 cold-start tuner completes in < 180s.
#
# Usage:
#   bench_sp4_acceptance.sh <sp3_katago> <sp4_katago> <model.bin.gz> <eigen_ref.json> [reps] [cooldown_s]
#
# Pre-conditions:
#   - <sp3_katago>: katago binary built from commit 36a88189 or earlier
#                   (SP3 — flat 2-D tuner, v1 cache files)
#   - <sp4_katago>: katago binary built from the current tip (SP4 — 6-axis
#                   hierarchical tuner, v2 cache files)
#   - Both binaries linked against MLX backend.
#   - <eigen_ref.json>: pre-generated Eigen reference for the model.

set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $(basename "$0") <sp3_katago> <sp4_katago> <model.bin.gz> <eigen_ref.json> [reps] [cooldown_s]" >&2
  exit 2
fi

SP3_BIN="$1"; SP4_BIN="$2"; MODEL="$3"; EIGEN_REF="$4"
REPS="${5:-6}"; COOL="${6:-30}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$EIGEN_REF" ]]; then
  echo "FATAL: bench_sp4_acceptance.sh: EIGEN_REF file not found: $EIGEN_REF" >&2
  echo "       Without a valid reference, testgpuerror reports all-zero errors (silent false-pass)." >&2
  echo "       Generate one with the Eigen backend: see CLAUDE.md 'GPU Error Testing' section." >&2
  exit 2
fi

# Arm A: SP3-MLX-fp16 vs SP4-MLX-fp16
echo "===== Arm A: SP3-MLX-fp16 vs SP4-MLX-fp16 ====="
ARM_A_LOG="$(mktemp)"
BENCH_A_LABEL=Sp3MlxFp16 BENCH_B_LABEL=Sp4MlxFp16 \
BENCH_A_FP16=1           BENCH_B_FP16=1 \
  "$HERE/bench_mlx_honest.sh" "$SP3_BIN" "$SP4_BIN" "$MODEL" "$REPS" "$COOL" \
  | tee "$ARM_A_LOG"
CI_A="$(grep -oE 'CI_lower=[+-][0-9]+\.[0-9]+' "$ARM_A_LOG" | tail -1 | cut -d= -f2)"
if [[ -z "$CI_A" ]]; then echo "FATAL: Arm A CI_lower not parsed"; exit 2; fi
echo

# Wall-time gate: cold-start SP4 tuner must finish in < 180s.
echo "===== Wall-time: SP4 cold-start tuner < 180s ====="
WT_LOG="$(mktemp)"
WT_CFG="$(mktemp).cfg"
cp "$HERE/../configs/gtp_example.cfg" "$WT_CFG"
sed -i.bak -E 's|^[#[:space:]]*mlxUseFP16[[:space:]]*=.*|mlxUseFP16 = true|' "$WT_CFG"
rm -f "${WT_CFG}.bak"
# Clear any existing v2 cache so the tuner does a full cold-start search.
# Tuner caches live under ~/.katago/mlxwinotuning/tunemlxwino2_*.txt
TUNE_CACHE_DIR="${HOME}/.katago/mlxwinotuning"
mkdir -p "$TUNE_CACHE_DIR"
if command -v trash >/dev/null 2>&1; then
  find "$TUNE_CACHE_DIR" -maxdepth 1 -name 'tunemlxwino2_*.txt' -print -exec trash {} \; || true
else
  find "$TUNE_CACHE_DIR" -maxdepth 1 -name 'tunemlxwino2_*.txt' -delete -print || true
fi
WT_START=$(date +%s)
set +e
"$SP4_BIN" testgpuerror -model "$MODEL" -config "$WT_CFG" -reference-file "$EIGEN_REF" \
  2>&1 | tee "$WT_LOG"
WT_EXIT=${PIPESTATUS[0]}
set -e
WT_END=$(date +%s)
WT_SECS=$((WT_END - WT_START))
echo "Wall-time: ${WT_SECS}s (bound: 180s)"
echo

# Accuracy: testgpuerror (independent of wall-time run, uses the cache from above)
echo "===== Accuracy: testgpuerror (mlxUseFP16 = true) ====="
ACC_LOG="$(mktemp)"
ACC_CFG="$(mktemp).cfg"
cp "$HERE/../configs/gtp_example.cfg" "$ACC_CFG"
sed -i.bak -E 's|^[#[:space:]]*mlxUseFP16[[:space:]]*=.*|mlxUseFP16 = true|' "$ACC_CFG"
rm -f "${ACC_CFG}.bak"
set +e
"$SP4_BIN" testgpuerror -model "$MODEL" -config "$ACC_CFG" -reference-file "$EIGEN_REF" \
  2>&1 | tee "$ACC_LOG"
ACC_EXIT=${PIPESTATUS[0]}
set -e

# Gate decisions
PASS_A="$(awk -v c="$CI_A" 'BEGIN { print (c+0 >= 0) ? "PASS" : "FAIL" }')"
PASS_WT=$([[ "$WT_SECS" -lt 180 ]] && echo "PASS" || echo "FAIL")
PASS_ACC=$([[ "$ACC_EXIT" == "0" ]] && echo "PASS" || echo "FAIL")

echo "==========================================="
echo "SP4 acceptance summary"
echo "  Arm A (SP4-MLX-fp16 - SP3-MLX-fp16) CI_lower = $CI_A   [$PASS_A]"
echo "  Wall-time (cold-start tuner) = ${WT_SECS}s              [$PASS_WT]"
echo "  Accuracy: testgpuerror exit = $ACC_EXIT                 [$PASS_ACC]"
echo "  (testgpuerror's own internal thresholds — see cpp/command/testgpuerror.cpp)"
echo "==========================================="

if [[ "$PASS_A" == "PASS" && "$PASS_WT" == "PASS" && "$PASS_ACC" == "PASS" ]]; then
  echo "OVERALL: PASS — all three SP4 gates satisfied."
  exit 0
fi
echo "OVERALL: FAIL"
exit 1
