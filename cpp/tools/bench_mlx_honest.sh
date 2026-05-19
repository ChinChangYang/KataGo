#!/usr/bin/env bash
# Honest paired benchmark: Metal backend vs MLX-fp32 (Winograd).
# Interleaved A/B/A/B, warmup discard, cooldown, mean/stdev/95% CI.
# Usage: bench_mlx_honest.sh <metal_katago> <mlx_katago> <model.bin.gz> [reps] [cooldown_s]
set -euo pipefail
METAL_BIN="$1"; MLX_BIN="$2"; MODEL="$3"
REPS="${4:-6}"; COOL="${5:-30}"
CFG="$(dirname "$0")/../configs/gtp_example.cfg"
OUT="$(mktemp -d)/bench_raw.txt"; : > "$OUT"
echo "Raw output -> $OUT"

run_one() { # $1=label $2=bin -> echoes visits/sec
  local label="$1" bin="$2" log
  log="$("$bin" benchmark -model "$MODEL" -config "$CFG" -t 16 -half-batch-size 2>&1)"
  echo "===== $label =====" >> "$OUT"; echo "$log" >> "$OUT"
  # Pinned -t 16 => exactly one result row; print the parsed line for audit.
  local line; line="$(echo "$log" | grep -oE 'visits/s = [0-9]+\.[0-9]+' | tail -1)"
  echo "PARSED[$label]: $line" >> "$OUT"
  echo "$line" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

declare -a M=() X=()
for ((i=0;i<=REPS;i++)); do          # i=0 is warmup, discarded
  m=$(run_one "METAL r$i" "$METAL_BIN"); sleep "$COOL"
  x=$(run_one "MLX   r$i" "$MLX_BIN");   sleep "$COOL"
  if (( i>0 )); then M+=("$m"); X+=("$x"); fi
  echo "rep $i: metal=$m mlx=$x"
done

stats() { # args: samples -> "mean stdev ci95"
  python3 - "$@" <<'PY'
import sys,statistics as st
v=[float(a) for a in sys.argv[1:]]
m=st.mean(v); sd=st.pstdev(v) if len(v)>1 else 0.0
ci=1.96*sd/(len(v)**0.5) if v else 0.0
print(f"{m:.2f} {sd:.2f} {ci:.2f}")
PY
}
read MM MSD MCI <<<"$(stats "${M[@]}")"
read XM XSD XCI <<<"$(stats "${X[@]}")"
DELTA=$(python3 -c "print(f'{($XM-$MM):.2f}')")
echo "---------------------------------------------"
echo "Metal : mean=$MM stdev=$MSD 95%CI=±$MCI"
echo "MLX   : mean=$XM stdev=$XSD 95%CI=±$XCI"
echo "Delta (MLX-Metal): $DELTA  (raw audit: $OUT)"
python3 -c "import sys; sys.exit(0 if ($XM-$XCI)>=($MM-$MCI) else 1)" \
  && echo "GATE PASS: MLX-fp32 >= Metal (CI-aware)" \
  || echo "GATE FAIL: MLX-fp32 slower than Metal"
