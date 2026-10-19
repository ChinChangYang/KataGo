#!/bin/bash
# PROTOTYPE (wayfinder #37), throwaway: build the stage 1 harness.
#
#   build.sh mac <workDir>                      -> <workDir>/bin/coreai-gate
#   build.sh ios <workDir> [aimodelc]           -> <workDir>/ios/CoreAIGate.app, signed for development
#
# Plain swiftc, no Xcode project. The iPad app is signed with the team's wildcard development profile
# ("iOS Team Provisioning Profile: *"), so building it registers nothing with the developer account. Its bundle holds
# the assets the iPad runs: the iOS app's Core ML model, the batch-1 parity models, the Core AI batch-1/batch-2/37x37
# functions, the Mish sweep, the parity data, and the optional AOT .aimodelc (stage1.sh compiles it for the iPad's
# architecture).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$1"; W="$(cd "$2" && pwd)"
BUNDLE_ID="chinchangyang.KataGo-iOS.tw.coreaigate"
SWIFT_FLAGS=(-O -swift-version 5 -parse-as-library -module-name CoreAIGate
  -Xfrontend -disable-autolink-framework -Xfrontend CoreAIRuntime
  -Xfrontend -disable-autolink-framework -Xfrontend CoreAIDelegates
  -Xfrontend -disable-autolink-framework -Xfrontend CoreAICompiler
  -framework CoreAI -framework CoreML -framework Metal)

case "$TARGET" in
mac)
  SPI="$("$HERE/spi/make_spi.sh" "$W/spi" macosx)"
  mkdir -p "$W/bin"
  xcrun --sdk macosx swiftc "${SWIFT_FLAGS[@]}" -target arm64-apple-macos27.0 -I "$SPI" \
    "$HERE"/Sources/*.swift "$HERE/mac/main.swift" -o "$W/bin/coreai-gate"
  codesign --force --sign - "$W/bin/coreai-gate"
  echo "$W/bin/coreai-gate"
  ;;
ios)
  SPI="$("$HERE/spi/make_spi.sh" "$W/spi" iphoneos)"
  APP="$W/ios/CoreAIGate.app"
  rm -rf "$APP"; mkdir -p "$APP/assets/coreml" "$APP/assets/coreai" "$APP/assets/aot"
  xcrun --sdk iphoneos swiftc "${SWIFT_FLAGS[@]}" -target arm64-apple-ios27.0 -I "$SPI" -framework UIKit -framework SwiftUI \
    "$HERE"/Sources/*.swift "$HERE/ios/App.swift" -o "$APP/CoreAIGate"
  A="$W/assets"
  for m in b18_19_n3 b18_19_n1 b18_37_n1; do cp -R "$A/coreml/$m.mlpackage" "$APP/assets/coreml/"; done
  for m in b18_19_b1 b18_19_b2 b18_37_b1; do cp -R "$A/coreai/$m.aimodel" "$APP/assets/coreai/"; done
  cp -R "$A/mish" "$A/parity_19" "$A/parity_37" "$APP/assets/"
  if [ $# -ge 3 ]; then cp -R "$3" "$APP/assets/aot/"; fi
  cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>CoreAIGate</string>
  <key>CFBundleName</key><string>CoreAIGate</string>
  <key>CFBundleDisplayName</key><string>Core AI Gate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>27.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UILaunchScreen</key><dict/>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
  <key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>DTSDKName</key><string>iphoneos$(xcrun --sdk iphoneos --show-sdk-version)</string>
</dict></plist>
PLIST
  # The newest unexpired wildcard development profile.
  plist() { security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
  PROFILE=""; BEST=0; NOW="$(date +%s)"
  for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
    [ "$(plist "$f" Name)" = "iOS Team Provisioning Profile: *" ] || continue
    EXP="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(plist "$f" ExpirationDate)" +%s 2>/dev/null || echo 0)"
    if [ "$EXP" -gt "$BEST" ] && [ "$EXP" -gt "$NOW" ]; then BEST=$EXP; PROFILE="$f"; fi
  done
  [ -n "$PROFILE" ] || { echo "no wildcard development profile found" >&2; exit 1; }
  cp "$PROFILE" "$APP/embedded.mobileprovision"
  TEAM="$(plist "$PROFILE" TeamIdentifier.0)"
  cat > "$W/ios/entitlements.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
ENT
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
  codesign --force --sign "$IDENTITY" --entitlements "$W/ios/entitlements.plist" --timestamp=none --generate-entitlement-der "$APP"
  du -sh "$APP" | cut -f1
  echo "$APP"
  ;;
*) echo "usage: build.sh mac|ios <workDir> [aimodelc]" >&2; exit 2 ;;
esac
