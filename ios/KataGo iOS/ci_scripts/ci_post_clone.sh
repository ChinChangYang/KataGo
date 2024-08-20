#!/bin/sh
curl -L -o default_model.bin.gz https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/kata1-b18c384nbt-s9996604416-d4316597426.bin.gz
cp -f default_model.bin.gz ../Resources/default_model.bin.gz

curl -L -o b18c384nbt-humanv0.bin.gz https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz
cp -f b18c384nbt-humanv0.bin.gz ../Resources/b18c384nbt-humanv0.bin.gz

if [ ! -f ../Resources/KataGoModel29x29fp16.mlpackage ]; then
    rm -f KataGoModel29x29fp16v14s9996604416.mlpackage.zip
    curl -L -o KataGoModel29x29fp16v14s9996604416.mlpackage.zip https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/KataGoModel29x29fp16v14s9996604416.mlpackage.zip
    unzip KataGoModel29x29fp16v14s9996604416.mlpackage.zip
    mv KataGoModel29x29fp16v14s9996604416.mlpackage ../Resources/KataGoModel29x29fp16.mlpackage
fi

if [ ! -f ../Resources/KataGoModel29x29fp16m1.mlpackage ]; then
    rm -f KataGoModel29x29fp16v15m1humanv0.mlpackage.zip
    curl -L -o KataGoModel29x29fp16v15m1humanv0.mlpackage.zip https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/KataGoModel29x29fp16v15m1humanv0.mlpackage.zip
    unzip KataGoModel29x29fp16v15m1humanv0.mlpackage.zip
    mv KataGoModel29x29fp16v15m1humanv0.mlpackage ../Resources/KataGoModel29x29fp16m1.mlpackage
fi
