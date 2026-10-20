#!/bin/zsh
# Mac mux visits/s, arms alternating ABBA per repetition, idle gate before every block.
# As run for #41. Its idle gate (load average < 4) proved too loose: use the stage 1 harness's `--mode idle` instead.
HERE=${0:A:h}; S=${OUT:-$PWD}; H=${WORK:?set WORK}; REPO=$HERE/../../../../../..
M=${KATAGO_MODEL:?set KATAGO_MODEL}
# The app config aborts without a human model unless its humanSL keys go.
CFG=$S/mac_gtp.cfg; grep -v '^humanSL' "$REPO/ios/KataGo iOS/Resources/default_gtp.cfg" > $CFG
REPS=${REPS:-4}
cd $S
base="numSearchThreads=16,nnMaxBatchSize=8,numNNServerThreadsPerModel=3,mlxDeviceToUseThread0=0,logDir=$S/gtp_logs"
idle() {
  while true; do
    l=$(sysctl -n vm.loadavg | awk '{print $2}')
    busy=$(( $(pgrep -x katago | wc -l) + $(pgrep -x xcodebuild | wc -l) ))
    th=$(pmset -g therm | grep -c "level")
    if (( l < 4.0 )) && [ "$busy" = 0 ]; then echo "idle ok load=$l therm_lines=$th $(date +%T)" >> $S/mac_progress.txt; return; fi
    sleep 15
  done
  echo "idle TIMEOUT load=$l busy=$busy $(date +%T)" >> $S/mac_progress.txt
}
for r in $(seq 1 $REPS); do
  if (( r % 2 )); then order=(coreml coreai); else order=(coreai coreml); fi
  for arm in $order; do
    idle
    if [ $arm = coreai ]; then ov="$base,mlxDeviceToUseThread1=200,mlxDeviceToUseThread2=200,coreAIModelFile=$H/work/coreai"
    else ov="$base,mlxDeviceToUseThread1=100,mlxDeviceToUseThread2=100"; fi
    echo "block rep=$r arm=$arm $(date +%T)" >> $S/mac_progress.txt
    python3 -I $HERE/vps.py --katago $H/build-mlx/katago --cfg "$CFG" --model "$M" --arm $arm --rep $r --overrides "$ov" --positions $HERE/positions.json --out $S/mac.jsonl >> $S/mac_progress.txt 2>&1
  done
done
echo MACDONE >> $S/mac_progress.txt
