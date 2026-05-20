#!/usr/bin/env bash
# Honest paired benchmark for KataGo MLX/Metal backends.
# - Interleaved A/B/A/B/..., warmup discard, cooldown between reps.
# - Output stats: per-rep deltas + paired-t 95% CI on the mean delta.
#
# Usage:
#   bench_mlx_honest.sh <bin_A> <bin_B> <model.bin.gz> [reps] [cooldown_s]
#
# Env-vars (SP3):
#   BENCH_A_LABEL    Label printed for backend A (default: "A").
#   BENCH_B_LABEL    Label printed for backend B (default: "B").
#   BENCH_A_FP16     If 1, force `*UseFP16 = true` in the config A sees.
#   BENCH_B_FP16     If 1, force `*UseFP16 = true` in the config B sees.
#   BENCH_A_FP32     If 1, force `*UseFP16 = false` in the config A sees.
#   BENCH_B_FP32     If 1, force `*UseFP16 = false` in the config B sees.
#   BENCH_CONFIG     Override default config path.
#
# The per-bin config is materialized as a temp file via sed; the original
# gtp_example.cfg is not modified.
set -euo pipefail

BIN_A="$1"; BIN_B="$2"; MODEL="$3"
REPS="${4:-6}"; COOL="${5:-30}"
A_LABEL="${BENCH_A_LABEL:-A}"; B_LABEL="${BENCH_B_LABEL:-B}"
DEFAULT_CFG="$(dirname "$0")/../configs/gtp_example.cfg"
BASE_CFG="${BENCH_CONFIG:-$DEFAULT_CFG}"

TMPDIR_BENCH="$(mktemp -d)"
OUT="$TMPDIR_BENCH/bench_raw.txt"; : > "$OUT"
CFG_A="$TMPDIR_BENCH/cfg_a.cfg"
CFG_B="$TMPDIR_BENCH/cfg_b.cfg"
echo "Raw output -> $OUT"

# Materialize per-bin configs. `sed` uncomments the relevant *UseFP16 line and
# replaces its value. Supports cudaUseFP16 / openclUseFP16 / mlxUseFP16 /
# metalUseFP16. The match is permissive (handles `# foo = auto` and
# `foo = true` alike).
#
# Note: BSD sed (macOS) does not reliably support alternation `(a|b|c)` in
# capture groups, so we apply one sed invocation per backend name.
materialize_cfg() {
  local out="$1" want16="$2" want32="$3" name val
  if [[ "$want16" == "1" && "$want32" == "1" ]]; then
    echo "ERROR: bench_mlx_honest.sh: conflicting FP16 and FP32 flags both set for $(basename "$out")" >&2
    exit 1
  fi
  cp "$BASE_CFG" "$out"
  if [[ "$want16" == "1" ]]; then val="true"
  elif [[ "$want32" == "1" ]]; then val="false"
  else return 0
  fi
  for name in cudaUseFP16 openclUseFP16 mlxUseFP16 metalUseFP16; do
    sed -i.bak -E "s|^[#[:space:]]*(${name})[[:space:]]*=.*|\\1 = ${val}|" "$out"
    rm -f "${out}.bak"
  done
}

materialize_cfg "$CFG_A" "${BENCH_A_FP16:-0}" "${BENCH_A_FP32:-0}"
materialize_cfg "$CFG_B" "${BENCH_B_FP16:-0}" "${BENCH_B_FP32:-0}"

run_one() { # $1=label $2=bin $3=cfg -> echoes visits/sec
  local label="$1" bin="$2" cfg="$3" log
  log="$("$bin" benchmark -model "$MODEL" -config "$cfg" -t 16 -half-batch-size 2>&1)"
  echo "===== $label =====" >> "$OUT"; echo "$log" >> "$OUT"
  local line; line="$(echo "$log" | grep -oE 'visits/s = [0-9]+\.[0-9]+' | tail -1)"
  echo "PARSED[$label]: $line" >> "$OUT"
  echo "$line" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

declare -a SA=() SB=()
for ((i=0;i<=REPS;i++)); do          # i=0 is warmup, discarded
  a=$(run_one "${A_LABEL} r$i" "$BIN_A" "$CFG_A"); sleep "$COOL"
  b=$(run_one "${B_LABEL} r$i" "$BIN_B" "$CFG_B"); sleep "$COOL"
  if (( i>0 )); then SA+=("$a"); SB+=("$b"); fi
  echo "rep $i: ${A_LABEL}=$a ${B_LABEL}=$b"
done

# Paired-t on per-rep delta = B - A.
python3 - "${A_LABEL}" "${B_LABEL}" "${SA[@]}" -- "${SB[@]}" <<'PY'
import sys, statistics as st, math
args = sys.argv[1:]
sep = args.index("--")
a_label = args[0]; b_label = args[1]
a = [float(x) for x in args[2:sep]]
b = [float(x) for x in args[sep+1:]]
assert len(a) == len(b), f"unequal lengths: {len(a)} vs {len(b)}"
n = len(a)
deltas = [bi - ai for ai, bi in zip(a, b)]
mean_a = st.mean(a); mean_b = st.mean(b)
d_bar  = st.mean(deltas)
s_d    = st.stdev(deltas) if n >= 2 else 0.0
se     = s_d / math.sqrt(n) if n >= 1 else 0.0
# t critical for 95% two-sided CI, n-1 dof. Table values up to n=20.
t_table = {
  1:12.706, 2:4.303, 3:3.182, 4:2.776, 5:2.571, 6:2.447, 7:2.365, 8:2.306,
  9:2.262, 10:2.228, 11:2.201, 12:2.179, 13:2.160, 14:2.145, 15:2.131,
  16:2.120, 17:2.110, 18:2.101, 19:2.093, 20:2.086,
}
t_crit = t_table.get(max(n-1, 1), None)
if t_crit is None:
    import sys as _sys
    print(f"WARNING: n-1={n-1} > 20 (paired-t table cap); falling back to normal approx 1.96 (anticonservative ~6%)", file=_sys.stderr)
    t_crit = 1.96
ci_half = t_crit * se
ci_lower = d_bar - ci_half
ci_upper = d_bar + ci_half
print("---------------------------------------------")
print(f"{a_label:<8}: mean={mean_a:.2f}")
print(f"{b_label:<8}: mean={mean_b:.2f}")
print(f"Per-rep deltas ({b_label} - {a_label}):")
for i, d in enumerate(deltas, 1):
    print(f"  rep {i}: d={d:+.3f}")
print(f"Paired N={n}, d_bar={d_bar:+.3f}, s_d={s_d:.3f}, SE={se:.3f}")
print(f"Paired 95% CI on d_bar: [{ci_lower:+.3f}, {ci_upper:+.3f}] (t_crit={t_crit:.3f})")
print(f"CI_lower={ci_lower:+.3f}")
PY

echo "(raw audit: $OUT)"
echo "(config A: $CFG_A, config B: $CFG_B)"
