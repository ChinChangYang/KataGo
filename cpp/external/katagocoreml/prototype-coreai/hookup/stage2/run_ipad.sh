#!/bin/zsh
# Protocol v2 (#41): one launch = one window (one arm, one position). Arms alternate per position,
# order flipping each step. Each window cools to nominal, rests 60 s, re-checks nominal, and is
# void if the thermal state leaves nominal in it; a void window is redone, up to 4 attempts.
S=${OUT:-$PWD}; D=${DEVICE:?set DEVICE to the iPad UDID}; B=chinchangyang.KataGo-iOS.tw
REPS=${REPS:-4}; k=0; fails=0
for r in $(seq 1 $REPS); do
  for p in empty g1m100 g2m150; do
    if (( k % 2 )); then order=(coreai coreml); else order=(coreml coreai); fi; k=$((k+1))
    for arm in $order; do
      # Resume: skip a window that already has a valid result.
      if grep -q "\"arm\":\"$arm\".*\"position\":\"$p\",\"rep\":$r,.*\"void\":false" $S/ipad.jsonl 2>/dev/null; then continue; fi
      for attempt in 1 2 3 4; do
        echo "window rep=$r pos=$p arm=$arm attempt=$attempt $(date +%T)" >> $S/ipad_progress.txt
        xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Library/CoreAI/bench.jsonl --destination $S/ipad.jsonl >/dev/null 2>&1
        before=$(wc -l < $S/ipad.jsonl 2>/dev/null | tr -d ' '); before=${before:-0}
        xcrun devicectl device process launch --device $D --terminate-existing -- $B -prototype.coreAI.arm $arm -prototype.coreAI.bench 1 -prototype.coreAI.rep $r -prototype.coreAI.position $p -prototype.coreAI.rest 60 -ModelRunnerView.pendingLoadModelTitle "" >> $S/ipad_console.log 2>&1
        rc=$?
        # No --console (it fails over a wireless connection): wait for the app to append its line.
        if [ $rc = 0 ]; then
          rc=9; for i in {1..160}; do
            sleep 15
            xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Library/CoreAI/bench.jsonl --destination $S/ipad.jsonl >/dev/null 2>&1
            now=$(wc -l < $S/ipad.jsonl 2>/dev/null | tr -d ' ')
            if (( ${now:-0} > before )); then rc=0; break; fi
          done
        fi
        if [ $rc != 0 ]; then
          fails=$((fails+1)); echo "launch rc=$rc fails=$fails" >> $S/ipad_progress.txt
          if (( fails >= 3 )); then echo "IPADFAILED" >> $S/ipad_progress.txt; exit 1; fi
          sleep 10; continue
        fi
        fails=0
        xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Library/CoreAI/bench.jsonl --destination $S/ipad.jsonl >/dev/null 2>&1
        last=$(tail -1 $S/ipad.jsonl); echo "$last" | cut -c1-120 >> $S/ipad_progress.txt
        echo "$last" | grep -q '"void":false' && break
      done
    done
  done
done
echo IPADDONE >> $S/ipad_progress.txt
