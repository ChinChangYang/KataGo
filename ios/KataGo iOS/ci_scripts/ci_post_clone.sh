#!/bin/sh

DEFAULT_MODEL_GZ="default_model.bin.gz"
DEFAULT_MODEL_URL="https://github.com/ChinChangYang/KataGo/releases/download/v1.16.4-coreml1/kata1-b28c512nbt-adam-s11165M-d5387M-null.bin.gz"
DEFAULT_MODEL_RES="../Resources/default_model.bin.gz"

HUMAN_MODEL_GZ="b18c384nbt-humanv0.bin.gz"
HUMAN_MODEL_URL="https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz"
HUMAN_MODEL_RES="../Resources/b18c384nbt-humanv0.bin.gz"

FP16_MLPACKAGE_RES="../Resources/KataGoModel19x19fp16.mlpackage"
FP16_ZIP="KataGoModel19x19fp16-adam-s11165M.mlpackage.zip"
FP16_URL="https://github.com/ChinChangYang/KataGo/releases/download/v1.16.4-coreml1/KataGoModel19x19fp16-adam-s11165M.mlpackage.zip"
FP16_DIR="KataGoModel19x19fp16-adam-s11165M.mlpackage"

FP16M1_MLPACKAGE_RES="../Resources/KataGoModel19x19fp16m1.mlpackage"
FP16M1_ZIP="KataGoModel19x19fp16m1.mlpackage.zip"
FP16M1_URL="https://github.com/ChinChangYang/KataGo/releases/download/v1.16.4-coreml1/KataGoModel19x19fp16m1.mlpackage.zip"
FP16M1_DIR="KataGoModel19x19fp16m1.mlpackage"

rm -f "$DEFAULT_MODEL_GZ"
curl -L -o "$DEFAULT_MODEL_GZ" "$DEFAULT_MODEL_URL"
cp -f "$DEFAULT_MODEL_GZ" "$DEFAULT_MODEL_RES"

curl -L -o "$HUMAN_MODEL_GZ" "$HUMAN_MODEL_URL"
cp -f "$HUMAN_MODEL_GZ" "$HUMAN_MODEL_RES"

rm -rf "$FP16_MLPACKAGE_RES"
rm -f "$FP16_ZIP"
curl -L -o "$FP16_ZIP" "$FP16_URL"
unzip "$FP16_ZIP"
mv "$FP16_DIR" "$FP16_MLPACKAGE_RES"

if [ ! -f "$FP16M1_MLPACKAGE_RES" ]; then
    rm -f "$FP16M1_ZIP"
    curl -L -o "$FP16M1_ZIP" "$FP16M1_URL"
    unzip "$FP16M1_ZIP"
    mv "$FP16M1_DIR" "$FP16M1_MLPACKAGE_RES"
fi
