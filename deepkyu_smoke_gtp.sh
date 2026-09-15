#!/usr/bin/env bash
# Phase-4 verification: every shipped deep-kyu config must load and play a legal move through GTP.
# Also proves the 21k-25k profiles still resolve (they need this fork's SGFMetadata::getProfile).
set -u
RUN=${RUN:-$HOME/.katago_tune/deepkyu}
KATAGO=${KATAGO:-$RUN/katago}
MODEL=${MODEL:-/Users/chinchangyang/Code/KataGo-MLX/cpp/models/kata1-b28c512nbt-s8326494464-d4628051565.bin.gz}
HUMAN=${HUMAN:-/Users/chinchangyang/Code/KataGo-MLX/cpp/models/b18c384nbt-humanv0.bin.gz}
CFGDIR=${CFGDIR:-$(dirname "$0")/cpp/configs}
fail=0
# 14k is included because patch_anchor() adds mlxUseFP16/nnRandomize to it -- it ships changed too.
for r in 14k 15k 16k 17k 18k 19k 20k 21k 22k 23k 24k 25k; do
  out=$(printf 'boardsize 19\nkomi 6.5\nplay b Q16\ngenmove w\nquit\n' | \
        timeout 120 "$KATAGO" gtp -config "$CFGDIR/gtp_human$r.cfg" -model "$MODEL" -human-model "$HUMAN" 2>/dev/null)
  mv=$(echo "$out" | grep -E "^= [A-T][0-9]+|^= pass" | tail -1)
  if [ -z "$mv" ]; then echo "FAIL $r"; fail=1; else echo "ok   $r -> ${mv#= }"; fi
done
exit $fail
