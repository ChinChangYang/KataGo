#!/usr/bin/env bash
# SP3 acceptance gate: runs both paired-t arms and testgpuerror.
#
# Arm A: Metal-fp16 vs MLX-fp16   (parity: paired CI_lower on (MLX - Metal) >= 0)
# Arm B: MLX-fp32   vs MLX-fp16   (strict: paired CI_lower on (MLX_fp16 - MLX_fp32) > 0)
# Accuracy: testgpuerror with mlxUseFP16=true vs eigen reference.
#
# Usage:
#   bench_sp3_acceptance.sh <metal_katago> <mlx_katago> <model.bin.gz> <eigen_ref.json> [reps] [cooldown_s]
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $(basename "$0") <metal_katago> <mlx_katago> <model.bin.gz> <eigen_ref.json> [reps] [cooldown_s]" >&2
  exit 2
fi

METAL_BIN="$1"; MLX_BIN="$2"; MODEL="$3"; EIGEN_REF="$4"
REPS="${5:-6}"; COOL="${6:-30}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$EIGEN_REF" ]]; then
  echo "FATAL: bench_sp3_acceptance.sh: EIGEN_REF file not found: $EIGEN_REF" >&2
  echo "       Without a valid reference, testgpuerror reports all-zero errors (silent false-pass)." >&2
  echo "       Generate one with the Eigen backend: see CLAUDE.md 'GPU Error Testing' section." >&2
  exit 2
fi

# Arm A: Metal-fp16 vs MLX-fp16
echo "===== Arm A: Metal-fp16 vs MLX-fp16 ====="
ARM_A_LOG="$(mktemp)"
BENCH_A_LABEL=MetalFp16 BENCH_B_LABEL=MlxFp16 \
BENCH_A_FP16=1          BENCH_B_FP16=1 \
  "$HERE/bench_mlx_honest.sh" "$METAL_BIN" "$MLX_BIN" "$MODEL" "$REPS" "$COOL" \
  | tee "$ARM_A_LOG"
CI_A="$(grep -oE 'CI_lower=[+-][0-9]+\.[0-9]+' "$ARM_A_LOG" | tail -1 | cut -d= -f2)"
if [[ -z "$CI_A" ]]; then echo "FATAL: Arm A CI_lower not parsed"; exit 2; fi
echo

# Arm B: MLX-fp32 vs MLX-fp16
echo "===== Arm B: MLX-fp32 vs MLX-fp16 ====="
ARM_B_LOG="$(mktemp)"
BENCH_A_LABEL=MlxFp32 BENCH_B_LABEL=MlxFp16 \
BENCH_A_FP32=1        BENCH_B_FP16=1 \
  "$HERE/bench_mlx_honest.sh" "$MLX_BIN" "$MLX_BIN" "$MODEL" "$REPS" "$COOL" \
  | tee "$ARM_B_LOG"
CI_B="$(grep -oE 'CI_lower=[+-][0-9]+\.[0-9]+' "$ARM_B_LOG" | tail -1 | cut -d= -f2)"
if [[ -z "$CI_B" ]]; then echo "FATAL: Arm B CI_lower not parsed"; exit 2; fi
echo

# Accuracy: testgpuerror
echo "===== Accuracy: testgpuerror (mlxUseFP16 = true) ====="
ACC_LOG="$(mktemp)"
ACC_CFG="$(mktemp).cfg"
cp "$HERE/../configs/gtp_example.cfg" "$ACC_CFG"
sed -i.bak -E 's|^[#[:space:]]*mlxUseFP16[[:space:]]*=.*|mlxUseFP16 = true|' "$ACC_CFG"
rm -f "${ACC_CFG}.bak"
# testgpuerror exits 0 if all internal checks (99-percentile and max-percentile
# error bounds vs the Eigen reference) pass; 1 otherwise. The thresholds are
# baked into checkStats99/checkStatsMax in cpp/tests/testnnevalcanary.cpp.
set +e
"$MLX_BIN" testgpuerror -model "$MODEL" -config "$ACC_CFG" -reference-file "$EIGEN_REF" \
  2>&1 | tee "$ACC_LOG"
ACC_EXIT=${PIPESTATUS[0]}
set -e

# Gate decisions
PASS_A="$(awk -v c="$CI_A" 'BEGIN { print (c+0 >= 0) ? "PASS" : "FAIL" }')"
PASS_B="$(awk -v c="$CI_B" 'BEGIN { print (c+0 > 0) ? "PASS" : "FAIL" }')"
PASS_ACC=$([[ "$ACC_EXIT" == "0" ]] && echo "PASS" || echo "FAIL")

echo "==========================================="
echo "SP3 acceptance summary"
echo "  Arm A (MLX-fp16 - Metal-fp16) CI_lower = $CI_A   [$PASS_A]"
echo "  Arm B (MLX-fp16 - MLX-fp32)   CI_lower = $CI_B   [$PASS_B]"
echo "  Accuracy: testgpuerror exit = $ACC_EXIT   [$PASS_ACC]"
echo "  (thresholds baked into cpp/tests/testnnevalcanary.cpp checkStats99/checkStatsMax)"
echo "==========================================="

if [[ "$PASS_A" == "PASS" && "$PASS_B" == "PASS" && "$PASS_ACC" == "PASS" ]]; then
  echo "OVERALL: PASS — all three gates satisfied."
  exit 0
fi
echo "OVERALL: FAIL"
exit 1
