#!/bin/bash
# PROTOTYPE (wayfinder #37), throwaway: build every model and data file stage 1 of the Core AI gate needs.
#
#   prepare.sh <workDir>
#
# Writes <workDir>/assets/:
#   coreml/b18_19_n3.mlpackage   the iOS app's Core ML model: 19x19, FP16, dynamic batch 1..3 (nnMaxBatchSize 3)
#   coreml/b18_19_n8.mlpackage   the macOS app's: dynamic batch 1..8 (nnMaxBatchSize 8)
#   coreml/b18_{19,37}_n1.mlpackage   batch 1, the parity comparison (as in #36)
#   coreai/b18_19_b{1,2,4,8}.aimodel  static batch functions translated from MILBuilder's MIL (#36's converter)
#   coreai/b18_37_b1.aimodel
#   mish/                        the FP16 Mish sweep models (build_mish.py)
#   parity_{19,37}/              #36's positions and the FP32 reference outputs (Core ML FP32 on the CPU)
# All Core ML models use the app's options: FP16 compute, FP32 I/O, mask on, optimize_identity_mask off.
# Needs what ../run.sh needs: macOS 27, Xcode 27, Homebrew protobuf + abseil, uv.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROTO="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$PROTO/../../../.." && pwd)"
W="$(mkdir -p "$1" && cd "$1" && pwd)"
MODEL="${KATAGO_MODEL:-$REPO/ios/KataGo iOS/Resources/default_model.bin.gz}"  # gitignored: set KATAGO_MODEL in a worktree
PY="$W/venv/bin/python -I"
CLI="$W/build-cli/mlpackage_cli"
M="$W/models"; A="$W/assets"
mkdir -p "$M" "$A/coreml" "$A/coreai" "$A/mish"

"$PROTO/run.sh" "$W" setup

ml() {  # name board precision maxBatch [minBatch]
  [ -d "$M/$1.mlpackage" ] || "$CLI" "$MODEL" "$M/$1.mlpackage" "$2" "$3" "$4" 0 "${5:-1}" >/dev/null
}
ai() {  # mlpackage aimodel
  [ -d "$A/coreai/$2.aimodel" ] || $PY "$PROTO/mil_to_coreai.py" "$M/$1.mlpackage" "$A/coreai/$2.aimodel" | cut -c1-160
}

for b in 19 37; do
  ml "b18_${b}_FLOAT32_n1" $b FLOAT32 1
  ml "b18_${b}_n1" $b FLOAT16 1
done
ml b18_19_n3 19 FLOAT16 3
ml b18_19_n8 19 FLOAT16 8
for k in 2 4 8; do ml "b18_19_s$k" 19 FLOAT16 $k $k; done
for n in b18_19_n1 b18_37_n1 b18_19_n3 b18_19_n8; do
  rm -rf "$A/coreml/$n.mlpackage"; cp -R "$M/$n.mlpackage" "$A/coreml/"
done
ai b18_19_n1 b18_19_b1
ai b18_37_n1 b18_37_b1
for k in 2 4 8; do ai "b18_19_s$k" "b18_19_b$k"; done

[ -d "$A/mish/mishtorch_ai.aimodel" ] || $PY "$HERE/build_mish.py" "$A/mish" "$PROTO/mil_to_coreai.py"

for b in 19 37; do
  [ -f "$M/inputs_$b.npz" ] || $PY "$PROTO/parity.py" inputs $b "$M/inputs_$b.npz" "$M/b18_${b}_FLOAT32_n1.mlpackage" | tail -c 300
  [ -f "$M/ref_$b.npz" ] || $PY "$PROTO/parity.py" run coreml-cpu "$M/b18_${b}_FLOAT32_n1.mlpackage" "$M/inputs_$b.npz" "$M/ref_$b.npz"
  $PY "$HERE/export_assets.py" "$M/inputs_$b.npz" "$M/ref_$b.npz" "$A/parity_$b"
done
du -sh "$A"/*
