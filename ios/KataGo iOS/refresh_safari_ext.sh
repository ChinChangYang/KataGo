#!/bin/zsh
# Dev loop for the Safari extension: the appex can only read the containing
# app's bundle from /Applications (the appex sandbox denies DerivedData under
# $HOME — spike-verified 2026-07-23), so every iteration is: build, install
# to /Applications, unregister the DerivedData appex, restart Safari.
set -e
cd "${0:a:h}"

xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug -allowProvisioningUpdates \
  | grep -E "BUILD (SUCCEEDED|FAILED)"

SRC="DerivedData/KataGo Anytime/Build/Products/Debug/KataGoAnytimeMac.app"
DST="/Applications/KataGoAnytimeMac.app"
osascript -e 'tell application "KataGoAnytimeMac" to quit' 2>/dev/null || true
sleep 1
rm -rf "$DST"
ditto "$SRC" "$DST"
pluginkit -r "$SRC/Contents/PlugIns/KataGoAnytimeSafariExt.appex" 2>/dev/null || true
open "$DST"
osascript -e 'tell application "Safari" to quit' 2>/dev/null || true
sleep 2
open -a Safari
echo "Installed + relaunched. Registered appex:"
pluginkit -m -v -p com.apple.Safari.web-extension | grep -i katago || true
