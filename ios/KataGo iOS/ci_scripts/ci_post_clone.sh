#!/bin/sh
curl -L -o default_model.bin.gz https://github.com/ChinChangYang/KataGo/releases/download/v1.15.3-coreml1/b28c512nbt-null.bin.gz
cp -f default_model.bin.gz ../Resources/default_model.bin.gz

curl -L -o b18c384nbt-humanv0.bin.gz https://github.com/ChinChangYang/KataGo/releases/download/v1.15.3-coreml1/b18c384nbt-humanv0-null.bin.gz
cp -f b18c384nbt-humanv0.bin.gz ../Resources/b18c384nbt-humanv0.bin.gz

if [ ! -f ../Resources/KataGoModel29x29fp16.mlpackage ]; then
    rm -f KataGoModel29x29fp16w8LiCh.mlpackage.zip
    curl -L -o KataGoModel29x29fp16w8LiCh.mlpackage.zip https://github.com/ChinChangYang/KataGo/releases/download/v1.15.3-coreml1/KataGoModel29x29fp16w8LiCh.mlpackage.zip
    unzip KataGoModel29x29fp16w8LiCh.mlpackage.zip
    mv KataGoModel29x29fp16w8LiCh.mlpackage ../Resources/KataGoModel29x29fp16.mlpackage
fi

if [ ! -f ../Resources/KataGoModel29x29fp16m1.mlpackage ]; then
    rm -f KataGoModel29x29fp16m1w8LiCh.mlpackage.zip
    curl -L -o KataGoModel29x29fp16m1w8LiCh.mlpackage.zip https://github.com/ChinChangYang/KataGo/releases/download/v1.15.3-coreml1/KataGoModel29x29fp16m1w8LiCh.mlpackage.zip
    unzip KataGoModel29x29fp16m1w8LiCh.mlpackage.zip
    mv KataGoModel29x29fp16m1w8LiCh.mlpackage ../Resources/KataGoModel29x29fp16m1.mlpackage
fi
