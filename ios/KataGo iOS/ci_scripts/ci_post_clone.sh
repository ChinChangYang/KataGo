#!/bin/sh
wget https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/kata1-b18c384nbt-s9996604416-d4316597426.bin.gz -o default_model.bin.gz
cp -f default_model.bin.gz "${CI_PRIMARY_REPOSITORY_PATH}/ios/KataGo\ iOS/Resources/default_model.bin.gz"
wget https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz -o b18c384nbt-humanv0.bin.gz
cp -f b18c384nbt-humanv0.bin.gz "${CI_PRIMARY_REPOSITORY_PATH}/ios/KataGo\ iOS/Resources/b18c384nbt-humanv0.bin.gz"
if [ -f "${CI_PRIMARY_REPOSITORY_PATH}/ios/KataGo\ iOS/Resources/KataGoModel29x29fp16.mlpackage" ]; then
    rm -f KataGoModel29x29fp16v14s9996604416.mlpackage.zip
    wget https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/KataGoModel29x29fp16v14s9996604416.mlpackage.zip
    unzip KataGoModel29x29fp16v14s9996604416.mlpackage.zip
    mv KataGoModel29x29fp16v14s9996604416.mlpackage "${CI_PRIMARY_REPOSITORY_PATH}/ios/KataGo\ iOS/Resources/KataGoModel29x29fp16.mlpackage"
fi
if [ -f "${CI_PRIMARY_REPOSITORY_PATH}/ios/KataGo\ iOS/Resources/KataGoModel29x29fp16m1.mlpackage" ]; then
    rm -f KataGoModel29x29fp16v15m1humanv0.mlpackage.zip
    wget https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/KataGoModel29x29fp16v15m1humanv0.mlpackage.zip
    unzip KataGoModel29x29fp16v15m1humanv0.mlpackage.zip
    mv KataGoModel29x29fp16v15m1humanv0.mlpackage "${CI_PRIMARY_REPOSITORY_PATH}/ios/KataGo\ iOS/Resources/KataGoModel29x29fp16m1.mlpackage"
fi
