#!/bin/zsh
# testgpuerror at 9, 13, 19 and rectangle, Core AI (200) and CoreML/NE (100), against the Eigen references.
# WORK holds build-mlx/, refs/ref_<b>.bin, work/coreai/<n>x<n>.aimodel and the hookup checkout as hookup/.
# Logs go to OUT (default: the current directory).
H=${WORK:?set WORK}; OUT=${OUT:-$PWD}
M=${KATAGO_MODEL:?set KATAGO_MODEL}
cd $H
for b in 19 9 13 rectangle; do
  for dev in 200 100; do
    extra=""; [ $dev = 200 ] && extra=",coreAIModelFile=$H/work/coreai"
    echo "start $b $dev $(date +%T) load $(sysctl -n vm.loadavg)" >> $OUT/progress.txt
    $H/build-mlx/katago testgpuerror -config hookup/cpp/configs/gtp_example.cfg -model "$M" -boardsize $b -reference-file refs/ref_$b.bin       -override-config "numNNServerThreadsPerModel=1,mlxDeviceToUseThread0=$dev,nnMaxBatchSize=8$extra" > $OUT/tge_${b}_${dev}.log 2>&1
    echo "end $b $dev rc=$? $(date +%T)" >> $OUT/progress.txt
  done
done
echo ALLDONE >> $OUT/progress.txt
