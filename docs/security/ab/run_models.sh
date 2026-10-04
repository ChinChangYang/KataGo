#!/bin/bash
# A/B harness for hostile model files.
# usage: run_models.sh <katago-binary> <label> <dir-with-crafted-models>
# Starts the GTP engine on each model, then reports exit code, peak RSS and the first error line.
# Needs GNU time (/usr/bin/time). Run from the repo root.
BIN=$1; L=$2; D=$3; CFG=cpp/configs/gtp_example.cfg
LOGS=$(mktemp -d)
for m in g170-ok m1_bomb m2_huge_conv m2_overflow_conv m3_global_channels; do
  f=$D/$m.bin.gz; [ $m = g170-ok ] && f=cpp/tests/models/g170-b6c96-s175395328-d26788732.bin.gz
  out=$( { printf 'genmove b\nquit\n' | /usr/bin/time -f "RSS_KB=%M" timeout 300 $BIN gtp -model $f -config $CFG \
           -override-config "numSearchThreads=1,maxVisits=8,logDir=$LOGS" ; echo "EXIT=$?"; } 2>&1 )
  echo "[$L] $m: $(echo "$out" | grep -o 'EXIT=[0-9]*' | tail -1) $(echo "$out" | grep -o 'RSS_KB=[0-9]*') :: $(echo "$out" | grep -E 'what\(\)|FATAL|AddressSanitizer|^= ' | head -1 | sed 's#.*\.bin\.gz: ##' | cut -c1-140)"
done
