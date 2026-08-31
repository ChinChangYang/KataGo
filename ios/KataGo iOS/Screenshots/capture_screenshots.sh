#!/bin/bash
#
# capture_screenshots.sh — regenerate the README screenshots.
#
# Run from `ios/KataGo iOS/`:
#
#     Screenshots/capture_screenshots.sh                 # everything
#     Screenshots/capture_screenshots.sh --skip-build    # reuse DerivedData
#     Screenshots/capture_screenshots.sh iphone ipad     # only these subjects
#
# What it does, per platform: build, boot a simulator, force light mode,
# reinstall the app, launch it with `--screenshot-seed` (ScreenshotSeed.swift in
# KataGoGameStore), wait for the app to say it is worth photographing, and take
# a raw screen capture. Then it frames the raw captures in Apple's product
# bezels, verifies the results, and rewrites the README captions.
#
# WHY IT POLLS INSTEAD OF SLEEPING. A cold simulator converts and compiles the
# Core ML model on first launch, which takes MINUTES; a fixed sleep would
# photograph the "Loading engine..." line. The app touches a marker file
# (`ScreenshotSeed.touchReadinessMarker`) once its board is in sync and the
# first analysis has landed, and this script polls for that file with a
# ten-minute budget.
#
# WHY IT REINSTALLS. A persisted simulator carries the crash sentinel from
# whatever killed the last run, and a surviving sentinel makes the app come up
# in the *failed-last-launch* state with no engine at all — the poll would then
# burn its whole budget. Uninstalling first is the only reliable reset, and it
# costs nothing here: the seed is recreated on every launch and the screenshots
# use the built-in network.
#
# See Screenshots/README.md for prerequisites (Apple's bezel files, the Screen
# Recording permission the Mac capture needs, and the iCloud warning).
#
set -euo pipefail

# --------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------
PROJECT="KataGo Anytime.xcodeproj"
DERIVED_DATA="DerivedData"
SCRIPT_DIR="Screenshots"
RAW_DIR="$SCRIPT_DIR/raw"          # gitignored
BEZELS_DIR="$SCRIPT_DIR/bezels"    # gitignored except its README
OUT_DIR="docs/screenshots"         # committed
README="README.md"

# Every app target ships under the SAME bundle id; only the watch app differs
# (it is an embedded companion, so it needs its own).
BUNDLE_APP="chinchangyang.KataGo-iOS.tw"
BUNDLE_WATCH="chinchangyang.KataGo-iOS.tw.watchkitapp"

# The fixed seed UUID from ScreenshotSeed.swift. The watch and Vision open the
# game by deep link rather than by "newest game wins", so they need it here.
SEED_UUID="0000A11F-0000-0000-0000-00000000C0DE"
DEEP_LINK="katago-anytime://open-game?id=$SEED_UUID"

# Where each platform writes the readiness marker, relative to the app's DATA
# container. tvOS differs because `Documents` is not writable on real Apple TV
# hardware (it is in the Simulator, which is exactly what makes it a trap).
MARKER_DOCUMENTS="Documents/screenshot-ready"
MARKER_CACHES="Library/Caches/screenshot-ready"

MARKER_TIMEOUT=600     # 10 minutes: a cold Core ML compile is minutes, not seconds

if [ ! -d "$PROJECT" ]; then
    echo "error: run this from 'ios/KataGo iOS/' (no $PROJECT here)" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
SKIP_BUILD=0
SUBJECTS=()
for argument in "$@"; do
    case "$argument" in
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        iphone|ipad|mac|tv|watch|vision) SUBJECTS+=("$argument") ;;
        *) echo "error: unknown argument '$argument'" >&2; exit 1 ;;
    esac
done
if [ ${#SUBJECTS[@]} -eq 0 ]; then
    SUBJECTS=(iphone ipad mac tv watch vision)
fi

wanted() {
    local needle="$1" subject
    for subject in "${SUBJECTS[@]}"; do
        [ "$subject" = "$needle" ] && return 0
    done
    return 1
}

mkdir -p "$RAW_DIR" "$OUT_DIR" "$BEZELS_DIR"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
step() { printf '\n==> %s\n' "$*"; }

# ONE xcodebuild at a time, and never through a pipe: a piped xcodebuild reports
# the PIPE's exit status, so `set -e` would sail straight past a failed build.
build_scheme() {
    local scheme="$1" destination="$2"
    step "building '$scheme' for $destination"
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "$destination" \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA"
}

# The udid of an available simulator by exact device name, or empty.
sim_udid() {
    xcrun simctl list devices available -j \
        | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)["devices"]
# Newest runtime first, so a device name present on several runtimes resolves
# to the one with the current OS.
for runtime in sorted(data, reverse=True):
    for device in data[runtime]:
        if device["name"] == name:
            print(device["udid"])
            sys.exit(0)
' "$1"
}

boot_sim() {
    local udid="$1"
    # `boot` fails when the device is already booted; `bootstatus -b` boots if
    # needed and blocks until the system is up either way.
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b
    # Light mode for the committed images. watchOS is dark-only and visionOS has
    # no appearance switch, so both refuse this — deliberately ignored.
    xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
    # Apple's canonical status bar: 9:41, full battery, Wi-Fi, no carrier. Two
    # reasons beyond convention: the time is otherwise the wall clock (a
    # different value on every run, so every re-capture diffs), and the iPad's
    # status bar also prints the DATE in the simulator's own language — this
    # machine's is Chinese, and the repo's committed content is English only.
    # Unsupported on tvOS/watchOS/visionOS; ignored there.
    xcrun simctl status_bar "$udid" override --time "9:41" \
        --batteryState charged --batteryLevel 100 --wifiBars 3 \
        --cellularMode notSupported >/dev/null 2>&1 || true
}

# Poll for a file, printing a dot a second. $1 = path, $2 = what we are waiting for.
wait_for_marker() {
    local path="$1" what="$2" waited=0
    printf 'waiting for %s (up to %ss)' "$what" "$MARKER_TIMEOUT"
    while [ ! -e "$path" ]; do
        if [ "$waited" -ge "$MARKER_TIMEOUT" ]; then
            printf '\n'
            echo "error: $what never appeared at $path" >&2
            echo "       The app either never reached a photographable state or crashed." >&2
            echo "       Check the simulator, then re-run this script." >&2
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
        [ $((waited % 5)) -eq 0 ] && printf '.'
    done
    printf ' ok (%ss)\n' "$waited"
}

# Quit the Mac app with a signal, never with AppleScript: `osascript ... quit`
# sends an Apple Event, which needs the Automation consent this terminal does
# not have, so it blocks on a prompt nobody is there to answer. SIGTERM goes
# through AppKit's normal termination; the seeded game is an unsaved DRAFT the
# app was told to open, so there is nothing to save and nothing prompts.
quit_mac_app() {
    pkill -TERM -x KataGoAnytimeMac >/dev/null 2>&1 || true
    local waited=0
    while pgrep -x KataGoAnytimeMac >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
        sleep 1; waited=$((waited + 1))
    done
    pkill -KILL -x KataGoAnytimeMac >/dev/null 2>&1 || true
}

# boot + reinstall + launch + wait + screenshot, for one simulator.
#   $1 device name  $2 app path  $3 bundle id  $4 marker relative path
#   $5 output name  $6 "deeplink" to also send the open-game URL
capture_simulator() {
    local device="$1" app="$2" bundle="$3" marker_rel="$4" out_name="$5" deeplink="${6:-}"
    local udid container marker

    udid="$(sim_udid "$device")"
    if [ -z "$udid" ]; then
        echo "error: no available simulator named '$device'" >&2
        echo "       'xcrun simctl list devices available' shows what you have;" >&2
        echo "       create one with 'xcrun simctl create'." >&2
        exit 1
    fi
    if [ ! -d "$app" ]; then
        echo "error: no app at $app (build first, or drop --skip-build)" >&2
        exit 1
    fi

    step "$out_name: $device ($udid)"
    # English on the iPad: its status bar prints the DATE in the device's own
    # language (the iPhone's prints only the time), and the repo's committed
    # content is English only. Language and locale are read at boot, so the
    # device is shut down first if it is up. Only the iPad subject needs it.
    if [ "$out_name" = "ipad-board" ]; then
        # `simctl spawn` needs a BOOTED device, and the language is read at
        # boot — so: boot, write, then restart only when it actually changed.
        boot_sim "$udid"
        current_locale="$(xcrun simctl spawn "$udid" defaults read .GlobalPreferences AppleLocale 2>/dev/null || true)"
        if [ "${current_locale:-}" != "en_US" ]; then
            xcrun simctl spawn "$udid" defaults write .GlobalPreferences AppleLanguages -array en
            xcrun simctl spawn "$udid" defaults write .GlobalPreferences AppleLocale -string en_US
            xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        fi
    fi
    boot_sim "$udid"
    xcrun simctl uninstall "$udid" "$bundle" >/dev/null 2>&1 || true
    # `bootstatus -b` returns when the OS is up, which on watchOS is not yet
    # "ready to install": the first install after a boot can fail with
    # LSApplicationWorkspaceErrorDomain 115 and succeed seconds later. Retry
    # a few times before giving up.
    local attempt
    for attempt in 1 2 3 4 5 6; do
        if xcrun simctl install "$udid" "$app"; then break; fi
        if [ "$attempt" -eq 6 ]; then
            echo "error: could not install $app on $device after $attempt attempts" >&2
            exit 1
        fi
        echo "install failed (attempt $attempt); retrying in 5s"
        sleep 5
    done

    container="$(xcrun simctl get_app_container "$udid" "$bundle" data)"
    marker="$container/$marker_rel"
    rm -f "$marker"

    xcrun simctl launch "$udid" "$bundle" --screenshot-seed
    if [ "$deeplink" = "deeplink" ]; then
        # The seed is written by the app itself, so give it a moment to exist
        # before the link asks for it by id.
        sleep 5
        xcrun simctl openurl "$udid" "$DEEP_LINK"
    fi

    wait_for_marker "$marker" "$out_name to be ready"
    # One more beat so the frame that is captured is a settled one, not the one
    # mid-transition into the analysis overlay.
    sleep 3
    if ! xcrun simctl io "$udid" screenshot --type=png "$RAW_DIR/$out_name.png"; then
        # visionOS is the one platform where this is not a certainty: a volume
        # is a 3D scene rather than a screen, and simctl's capture has changed
        # shape between releases. The app is deliberately LEFT RUNNING so the
        # fallback below is still possible.
        cat >&2 <<MANUAL
error: 'xcrun simctl io screenshot' failed on $device.

       The app is still running, so take it by hand instead:
         Simulator ▸ File ▸ Save Screen  (Command-S)
       save the file as
         $RAW_DIR/$out_name.png
       and then finish the pipeline yourself:
         swift $SCRIPT_DIR/frame_screenshots.swift frame $RAW_DIR $BEZELS_DIR $OUT_DIR
         python3 $SCRIPT_DIR/verify_screenshots.py
MANUAL
        exit 1
    fi
    echo "captured $RAW_DIR/$out_name.png"
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    # Leave the simulator as we found it: the override would otherwise stick
    # for every later run of the app on that device.
    xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
PRODUCTS="$DERIVED_DATA/Build/Products"
APP_IOS="$PRODUCTS/Debug-iphonesimulator/KataGo Anytime.app"
APP_TV="$PRODUCTS/Debug-appletvsimulator/KataGo TV.app"
APP_WATCH="$PRODUCTS/Debug-watchsimulator/KataGo Anytime Watch.app"
APP_VISION="$PRODUCTS/Debug-xrsimulator/KataGo Vision.app"
APP_MAC="$PRODUCTS/Debug/KataGoAnytimeMac.app"

# The iPad bezel's aspect ratio has to match the capture, so a 13-inch iPad is
# the target; "iPad mini (A17 Pro)" (the default on a bare install) is a
# different shape and would letterbox inside the frame.
IPAD_DEVICE=""
for candidate in "iPad Air 13-inch (M4)" "iPad Pro 13-inch (M5)"; do
    if [ -n "$(sim_udid "$candidate")" ]; then IPAD_DEVICE="$candidate"; break; fi
done
if [ -z "$IPAD_DEVICE" ] && wanted ipad; then
    step "creating an iPad simulator (none of the 13-inch devices exists yet)"
    RUNTIME="$(xcrun simctl list runtimes -j \
        | python3 -c 'import json,sys; rs=[r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["name"]]; print(sorted(rs)[-1] if rs else "")')"
    if [ -z "$RUNTIME" ]; then
        echo "error: no available iOS runtime to create an iPad simulator on" >&2
        exit 1
    fi
    xcrun simctl create "iPad Air 13-inch (M4)" "iPad Air 13-inch (M4)" "$RUNTIME"
    IPAD_DEVICE="iPad Air 13-inch (M4)"
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
    if wanted iphone || wanted ipad; then
        build_scheme "KataGo Anytime" "platform=iOS Simulator,name=iPhone 17"
    fi
    if wanted tv; then
        build_scheme "KataGo Anytime TV" "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)"
    fi
    if wanted watch; then
        build_scheme "KataGo Anytime Watch" "platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)"
    fi
    if wanted vision; then
        build_scheme "KataGo Anytime Vision" "platform=visionOS Simulator,name=Apple Vision Pro"
    fi
    if wanted mac; then
        build_scheme "KataGo Anytime Mac" "platform=macOS"
    fi
fi

# --------------------------------------------------------------------------
# Capture: simulators
# --------------------------------------------------------------------------
if wanted iphone; then
    capture_simulator "iPhone 17" "$APP_IOS" "$BUNDLE_APP" \
        "$MARKER_DOCUMENTS" "iphone-board"
fi

# Same app, same seed, different device: the iPad launch toggles itself into
# full-screen board mode (GobanView's seeded onAppear).
if wanted ipad; then
    capture_simulator "$IPAD_DEVICE" "$APP_IOS" "$BUNDLE_APP" \
        "$MARKER_DOCUMENTS" "ipad-board"
fi

if wanted tv; then
    capture_simulator "Apple TV 4K (3rd generation)" "$APP_TV" "$BUNDLE_APP" \
        "$MARKER_CACHES" "tv-play"
fi

# The watch and Vision roots resolve a PENDING GAME ID rather than auto-selecting
# the newest record, so their seeds latch that id in-process (`simctl openurl`
# cannot deliver the scheme to the watch simulator: LaunchServices error 115).
if wanted watch; then
    capture_simulator "Apple Watch Series 11 (46mm)" "$APP_WATCH" "$BUNDLE_WATCH" \
        "$MARKER_DOCUMENTS" "watch-board"
fi

if wanted vision; then
    capture_simulator "Apple Vision Pro" "$APP_VISION" "$BUNDLE_APP" \
        "$MARKER_DOCUMENTS" "vision-volume"
fi

# --------------------------------------------------------------------------
# Capture: the Mac window
# --------------------------------------------------------------------------
if wanted mac; then
    step "mac-window"
    if [ ! -d "$APP_MAC" ]; then
        echo "error: no app at $APP_MAC (build first, or drop --skip-build)" >&2
        exit 1
    fi

    MAC_MARKER="$HOME/Library/Containers/$BUNDLE_APP/Data/$MARKER_DOCUMENTS"
    rm -f "$MAC_MARKER"

    # A DRAFT game, never inserted: the Mac app opens the user's REAL iCloud
    # library, and a screenshot run must not leave a record in it.
    open -n "$APP_MAC" --args --screenshot-seed
    wait_for_marker "$MAC_MARKER" "the Mac window to be ready"
    sleep 3

    # SCREEN_RECORDING= / WINDOW_ID= — see frame_screenshots.swift's `window`
    # subcommand for why this is the pre-flight.
    eval "$(swift "$SCRIPT_DIR/frame_screenshots.swift" window KataGoAnytimeMac)"
    if [ "${SCREEN_RECORDING:-denied}" != "granted" ]; then
        cat >&2 <<'PERMISSION'
error: this terminal does not hold the Screen Recording permission, so
       `screencapture -l<windowID>` would silently photograph the desktop
       picture instead of the app window.

       Grant it in System Settings > Privacy & Security > Screen & System
       Audio Recording, tick the app you are running this script FROM
       (Terminal, iTerm, Xcode, ...), QUIT and reopen that app, then re-run:

           Screenshots/capture_screenshots.sh --skip-build mac
PERMISSION
        quit_mac_app
        exit 1
    fi
    if [ -z "${WINDOW_ID:-}" ]; then
        echo "error: KataGoAnytimeMac has no on-screen window to capture" >&2
        quit_mac_app
        exit 1
    fi

    # -o drops the window shadow (the bezel supplies its own framing);
    # -x suppresses the capture sound.
    screencapture -l"$WINDOW_ID" -o -x "$RAW_DIR/mac-window.png"
    echo "captured $RAW_DIR/mac-window.png"
    quit_mac_app
fi

# --------------------------------------------------------------------------
# Frame, verify, caption
# --------------------------------------------------------------------------
step "framing"
swift "$SCRIPT_DIR/frame_screenshots.swift" frame "$RAW_DIR" "$BEZELS_DIR" "$OUT_DIR"

step "captions"
# The build number the images actually show, straight out of the app that was
# launched. Falls back to the project's own value when only some platforms ran.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP_IOS/Info.plist" 2>/dev/null || true)"
if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$APP_MAC/Contents/Info.plist" 2>/dev/null || true)"
fi
if [ -z "$BUILD_NUMBER" ]; then
    echo "error: could not read CFBundleVersion from a built app" >&2
    exit 1
fi
python3 "$SCRIPT_DIR/update_captions.py" "$README" "$BUILD_NUMBER" "$(date +%Y-%m-%d)" \
    "${SUBJECTS[@]}"

step "verifying"
python3 "$SCRIPT_DIR/verify_screenshots.py"

step "done"
echo "raw captures : $RAW_DIR/ (gitignored)"
echo "committed    : $OUT_DIR/"
echo "README       : $README"
echo
echo "Review the images, then commit $OUT_DIR/*.png together with $README."
