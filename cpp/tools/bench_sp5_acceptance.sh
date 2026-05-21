#!/usr/bin/env bash
# SP5 acceptance gate: three sub-gates.
#
# Arm A: SP4-fp16 (pre-SP5 binary) vs SP5-fp16 (this binary). Paired-t test.
#         Pass: CI_lower(SP5 - SP4) >= -2% (SP5 not worse than SP4 by >2%).
# Wall-time: cold-start tuner with cache cleared via `trash` < 120s.
# Accuracy: testgpuerror with mlxUseFP16=true vs eigen reference, exit 0.
#
# Usage:
#   bench_sp5_acceptance.sh <sp4_katago> <sp5_katago> <model.bin.gz> <eigen_ref.json>
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $(basename "$0") <sp4_katago> <sp5_katago> <model.bin.gz> <eigen_ref.json>" >&2
  exit 2
fi

SP4_BIN="$1"; SP5_BIN="$2"; MODEL="$3"; EIGEN_REF="$4"
REPS="${5:-6}"; COOL="${6:-30}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$EIGEN_REF" ]]; then
  echo "FATAL: EIGEN_REF file not found: $EIGEN_REF" >&2
  exit 2
fi

# Arm A: SP4 vs SP5 paired-t.
echo "===== Arm A: SP4-fp16 vs SP5-fp16 (paired-t) ====="
ARM_A_LOG="$(mktemp)"
BENCH_A_LABEL=SP4Fp16 BENCH_B_LABEL=SP5Fp16 \
BENCH_A_FP16=1        BENCH_B_FP16=1 \
  "$HERE/bench_mlx_honest.sh" "$SP4_BIN" "$SP5_BIN" "$MODEL" "$REPS" "$COOL" \
  | tee "$ARM_A_LOG"
CI_A="$(grep -oE 'CI_lower=[+-][0-9]+\.[0-9]+' "$ARM_A_LOG" | tail -1 | cut -d= -f2)"
if [[ -z "$CI_A" ]]; then echo "FATAL: Arm A CI_lower not parsed"; exit 2; fi

# Wall-time gate.
echo "===== Wall-time: cold-start SP5 tune < 120s ====="
trash ~/.katago/mlxwinotuning/tunemlxwino3_*.txt 2>/dev/null || true
TUNE_START=$(date +%s)
"$SP5_BIN" benchmark -model "$MODEL" -config "$HERE/../configs/gtp_example.cfg" \
  -override-config "mlxUseFP16=true" -t 1 -v 100 -n 1 > /tmp/sp5_tune.log 2>&1
TUNE_END=$(date +%s)
TUNE_SECS=$((TUNE_END - TUNE_START))
echo "  Cold-start tune wall-time: ${TUNE_SECS}s"

# Accuracy.
echo "===== Accuracy: testgpuerror (mlxUseFP16 = true) ====="
ACC_LOG="$(mktemp)"
ACC_CFG="$(mktemp).cfg"
cp "$HERE/../configs/gtp_example.cfg" "$ACC_CFG"
sed -i.bak -E 's|^[#[:space:]]*mlxUseFP16[[:space:]]*=.*|mlxUseFP16 = true|' "$ACC_CFG"
rm -f "${ACC_CFG}.bak"
set +e
"$SP5_BIN" testgpuerror -model "$MODEL" -config "$ACC_CFG" -reference-file "$EIGEN_REF" \
  2>&1 | tee "$ACC_LOG"
ACC_EXIT=${PIPESTATUS[0]}
set -e

# Gate decisions.
PASS_A="$(awk -v c="$CI_A" 'BEGIN { print (c+0 >= -2.0) ? "PASS" : "FAIL" }')"
PASS_W=$([[ "$TUNE_SECS" -lt 120 ]] && echo "PASS" || echo "FAIL")
PASS_ACC=$([[ "$ACC_EXIT" == "0" ]] && echo "PASS" || echo "FAIL")

echo "==========================================="
echo "SP5 acceptance summary"
echo "  Arm A (SP5-fp16 - SP4-fp16) CI_lower = $CI_A   [$PASS_A]"
echo "  Wall-time: ${TUNE_SECS}s  [$PASS_W]"
echo "  Accuracy: testgpuerror exit = $ACC_EXIT   [$PASS_ACC]"
echo "==========================================="

if [[ "$PASS_A" == "PASS" && "$PASS_W" == "PASS" && "$PASS_ACC" == "PASS" ]]; then
  echo "OVERALL: PASS"
  exit 0
fi
echo "OVERALL: FAIL"
exit 1
