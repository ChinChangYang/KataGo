#!/bin/bash
# PROTOTYPE (wayfinder #36), throwaway: the whole parity run, one command.
#
#   run.sh <workDir> [stage...]      stages: setup convert inputs cpu ane residency compare (default: all)
#
# Needs a Mac on macOS 27 with Xcode 27, Homebrew protobuf + abseil, uv, and
# ios/KataGo iOS/Resources/default_model.bin.gz. Every Neural Engine arm runs alone, one after another.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
W="$1"; shift
STAGES="${*:-setup convert inputs cpu ane residency compare}"
MODEL="${KATAGO_MODEL:-$REPO/ios/KataGo iOS/Resources/default_model.bin.gz}"  # gitignored: set KATAGO_MODEL in a worktree
PY="$W/venv/bin/python -I"
export USE_OS_COREAI=1
mkdir -p "$W/models" "$W/out"

has() { [[ " $STAGES " == *" $1 "* ]]; }

if has setup; then
  [ -x "$W/venv/bin/python" ] || uv venv -q -p 3.12 "$W/venv"
  VIRTUAL_ENV="$W/venv" uv pip install -q coreai-core==1.0.0b3 numpy coremltools==9.0
  cmake -S "$HERE" -B "$W/build-cli" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
  ninja -C "$W/build-cli" mlpackage_cli >/dev/null
fi

if has convert; then
  for b in 19 37; do
    for p in FLOAT16 FLOAT32; do
      "$W/build-cli/mlpackage_cli" "$MODEL" "$W/models/b18_${b}_${p}_n1.mlpackage" $b $p 1
    done
    $PY "$HERE/mil_to_coreai.py" "$W/models/b18_${b}_FLOAT16_n1.mlpackage" "$W/models/b18_${b}_FLOAT16_n1.aimodel"
    $PY "$HERE/mil_to_coreai.py" "$W/models/b18_${b}_FLOAT32_n1.mlpackage" "$W/models/b18_${b}_FLOAT32_n1.aimodel" --peaks
    cp "$W/models/b18_${b}_FLOAT32_n1.aimodel.peaks.json" "$W/out/peaks_${b}.json"
  done
  # The app's iOS Core ML model: dynamic batch 1..3 (nnMaxBatchSize 3), evaluated at batch 1.
  "$W/build-cli/mlpackage_cli" "$MODEL" "$W/models/b18_19_FLOAT16_n3.mlpackage" 19 FLOAT16 3
fi

if has inputs; then
  for b in 19 37; do
    $PY "$HERE/parity.py" inputs $b "$W/out/inputs_${b}.npz" "$W/models/b18_${b}_FLOAT32_n1.mlpackage"
  done
fi

arm() {  # framework precision unit board
  local ext=mlpackage prec=FLOAT16
  [ "$1" = coreai ] && ext=aimodel
  [ "$2" = fp32 ] && prec=FLOAT32
  $PY "$HERE/parity.py" run "$1-$3" "$W/models/b18_${4}_${prec}_n1.$ext" "$W/out/inputs_${4}.npz" \
    "$W/out/$1-$2-$3_${4}.npz"
}

if has cpu; then
  for b in 19 37; do
    arm coreml fp32 cpu $b; arm coreai fp32 cpu $b; arm coreml fp16 cpu $b; arm coreai fp16 cpu $b
  done
fi

if has ane; then
  for b in 19 37; do arm coreml fp16 ane $b; arm coreai fp16 ane $b; done
  $PY "$HERE/parity.py" run coreml-ane "$W/models/b18_19_FLOAT16_n3.mlpackage" "$W/out/inputs_19.npz" \
    "$W/out/coreml-fp16n3-ane_19.npz"
fi

if has residency; then
  for b in 19 37; do
    $PY "$HERE/parity.py" residency coreai-ane "$W/models/b18_${b}_FLOAT16_n1.aimodel" "$W/out/residency-coreai_${b}.json"
    $PY "$HERE/parity.py" residency coreml-ane "$W/models/b18_${b}_FLOAT16_n1.mlpackage" "$W/out/residency-coreml_${b}.json"
  done
fi

if has compare; then
  for b in 19 37; do $PY "$HERE/parity.py" compare "$W/out" $b; done
fi
