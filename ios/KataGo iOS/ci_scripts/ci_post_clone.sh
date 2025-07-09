#!/bin/sh
rm -f default_model.bin.gz
curl -L -o default_model.bin.gz https://github.com/ChinChangYang/KataGo/releases/download/v1.15.3-coreml1/b28c512nbt-null-s9584M.bin.gz
cp -f default_model.bin.gz ../Resources/default_model.bin.gz

curl -L -o b18c384nbt-humanv0.bin.gz https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz
cp -f b18c384nbt-humanv0.bin.gz ../Resources/b18c384nbt-humanv0.bin.gz

rm -rf ../Resources/KataGoModel19x19fp16.mlpackage
rm -f KataGoModel19x19fp16w8LiCh-s9584M.mlpackage.zip
curl -L -o KataGoModel19x19fp16w8LiCh-s9584M.mlpackage.zip https://github.com/ChinChangYang/KataGo/releases/download/v1.15.3-coreml1/KataGoModel19x19fp16w8LiCh-s9584M.mlpackage.zip
unzip KataGoModel19x19fp16w8LiCh-s9584M.mlpackage.zip
mv KataGoModel19x19fp16w8LiCh-s9584M.mlpackage ../Resources/KataGoModel19x19fp16.mlpackage

if [ ! -f ../Resources/KataGoModel19x19fp16m1.mlpackage ]; then
    rm -f KataGoModel19x19fp16m1w8LiCh.mlpackage.zip
    curl -L -o KataGoModel19x19fp16m1w8LiCh.mlpackage.zip https://github.com/ChinChangYang/KataGo/releases/download/v1.15.3-coreml1/KataGoModel19x19fp16m1w8LiCh.mlpackage.zip
    unzip KataGoModel19x19fp16m1w8LiCh.mlpackage.zip
    mv KataGoModel19x19fp16m1w8LiCh.mlpackage ../Resources/KataGoModel19x19fp16m1.mlpackage
fi
