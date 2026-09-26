#!/bin/bash
#
# run_tests.sh — run the iOS test plans on a simulator of our own, unattended.
#
# Usage (from anywhere):
#   ios/KataGo\ iOS/scripts/run_tests.sh [options] [-- extra xcodebuild args]
#
#   -p, --plan NAME     Test plan: FastTestPlan (default, unit tests only) or
#                       FullTestPlan (unit + UI tests).
#   -n, --name NAME     Simulator to use, by name (default "KataGo iPhone 17").
#                       Created on first use (iPhone 17, newest iOS runtime).
#   -u, --udid UDID     Simulator to use, by UDID (overrides --name).
#   -o, --out DIR       Where the log and .xcresult go
#                       (default $TMPDIR/katago-tests/<timestamp>).
#   -r, --retries N     Reruns after an infrastructure failure (default 2).
#   -k, --keep-booted   Leave the simulator booted afterwards (default: shut
#                       it down, to give the memory back).
#
# Anything after `--` goes to xcodebuild verbatim, for example
#   run_tests.sh -p FullTestPlan -- \
#     -only-testing:"KataGo AnytimeUITests/BackendConfigSheetUITests" -test-iterations 3
#
# Exit status: 0 tests passed, 1 tests failed, 2 infrastructure failure (after
# the retries) or no verdict, 3 could not start.
#
# Why a script:
# - Never the stock "iPhone 17". Other projects on this Mac test on it too, and
#   two `xcodebuild test` runs on one simulator fail each other with
#   "Simulator device failed to launch … No such process" or "SBMainWorkspace …
#   Busy (Application failed preflight checks)" — 0 tests run. This script only
#   ever boots, shuts down or tests on its own simulator.
# - The simulator is booted and smoke-tested BEFORE xcodebuild sees it: letting
#   xcodebuild cold-boot it can race SpringBoard into the same preflight refusal.
# - xcodebuild collects a `simctl diagnose` (a sysdiagnose, up to ten minutes)
#   into the result bundle, even on a passing run, and it can hang there after
#   printing its verdict. Nothing here reads it, so it is switched off with
#   `-collect-test-diagnostics never`. Killing one instead is a last resort: it
#   crashes xcodebuild's result importer and leaves an .xcresult with no
#   Info.plist that xcresulttool cannot open.
# - xcodebuild's exit status is not trusted. The verdict is the
#   "** TEST SUCCEEDED **" / "** TEST FAILED **" line. A failed run in which
#   no test failed, with a known simulator-launch signature, is an
#   infrastructure failure to retry rather than a test failure. The usual
#   case is "Simulator device failed to launch … No such process" on the first
#   app launch after a cold boot, which hit about half the runs on this
#   project's own simulator (2026-09-26). If other test bundles did run, and
#   passed, only the bundles that never launched are rerun.
# - It refuses to start while another xcodebuild is using this project: two
#   builds sharing one DerivedData fail spuriously.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_DIR/KataGo Anytime.xcodeproj"
SCHEME="KataGo Anytime"

PLAN="FastTestPlan"
SIM_NAME="KataGo iPhone 17"
UDID=""
OUT_DIR=""
RETRIES=2
KEEP_BOOTED=0
EXTRA_ARGS=()

usage() { sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; }
say() { printf '[run_tests] %s\n' "$*" >&2; }
die() { say "$*"; exit 3; }

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--plan) PLAN="${2:?}"; shift 2 ;;
        -n|--name) SIM_NAME="${2:?}"; shift 2 ;;
        -u|--udid) UDID="${2:?}"; shift 2 ;;
        -o|--out) OUT_DIR="${2:?}"; shift 2 ;;
        -r|--retries) RETRIES="${2:?}"; shift 2 ;;
        -k|--keep-booted) KEEP_BOOTED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA_ARGS=("$@"); break ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
done

case "$RETRIES" in ''|*[!0-9]*) die "--retries takes a number, got '$RETRIES'" ;; esac

# Runs "$@" with a deadline of $1 seconds; returns 124 when the deadline hits.
# (macOS ships no `timeout`.)
with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# Every descendant PID of $1, one per line.
descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        descendants "$child"
    done
}

# --- Preconditions -----------------------------------------------------------

[ -d "$PROJECT" ] || die "Project not found: $PROJECT"

# Another xcodebuild on this project? Select by process NAME first, so a shell
# whose command line merely mentions xcodebuild (this script's, say) never
# counts.
others="$(for p in $(pgrep -x xcodebuild); do ps -o pid=,args= -p "$p"; done \
    | grep -F "KataGo Anytime.xcodeproj")"
if [ -n "$others" ]; then
    say "Another xcodebuild is using this project; not starting a second one:"
    printf '%s\n' "$others" >&2
    exit 3
fi

if [ -z "$UDID" ]; then
    UDID="$(xcrun simctl list devices available | awk -v n="$SIM_NAME" '
        { s = $0; sub(/^ +/, "", s)
          if (index(s, n " (") == 1) { print substr(s, length(n) + 3, 36); exit } }')"
    if [ -z "$UDID" ]; then
        runtime="$(xcrun simctl list runtimes available | awk '/^iOS /{ id = $NF } END { print id }')"
        [ -n "$runtime" ] || die "No iOS simulator runtime is installed."
        say "Creating simulator \"$SIM_NAME\" (iPhone 17, $runtime)"
        UDID="$(xcrun simctl create "$SIM_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")" \
            || die "Could not create simulator \"$SIM_NAME\"."
    fi
fi
xcrun simctl list devices | grep -qF "($UDID)" || die "No simulator with UDID $UDID"

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="${TMPDIR:-/tmp}/katago-tests/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR" || die "Cannot create $OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# --- Simulator ---------------------------------------------------------------

# Boots (if needed) and waits for the simulator to finish booting, then proves
# SpringBoard will launch an app. Returns non-zero if it will not.
prepare_simulator() {
    say "Booting $UDID and waiting for it"
    if ! with_timeout 300 xcrun simctl bootstatus "$UDID" -b >/dev/null; then
        say "The simulator did not finish booting within 300 s"
        return 1
    fi
    if ! with_timeout 60 xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null; then
        say "Smoke launch of Settings failed"
        return 1
    fi
    xcrun simctl terminate "$UDID" com.apple.Preferences >/dev/null 2>&1
    return 0
}

# Retry on the same booted simulator when it still answers; restart it only
# when it does not. The launch failure this recovers from hits the first
# launch after a boot, so a restart would only invite it again.
recover_simulator() {
    prepare_simulator || reset_simulator
}

reset_simulator() {
    say "Restarting the simulator"
    with_timeout 120 xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    prepare_simulator
}

finish() {
    if [ "$KEEP_BOOTED" -eq 0 ]; then
        with_timeout 120 xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    fi
}

# --- One xcodebuild run --------------------------------------------------------

# Signatures of a run the simulator never let start.
INFRA_PATTERN='Simulator device failed to launch|failed preflight checks|RequestDenied|Unable to boot the Simulator|Failed to install or launch the test runner|never finished bootstrapping|Test runner never began executing tests|No such process'

# Runs xcodebuild once, logging to $1 and writing the result bundle to $2.
# Prints nothing; the caller reads the log.
XCODEBUILD_PID=""
run_once() {
    local log="$1" bundle="$2" pid verdict_seen=0 grace=0 d args diagnostics=()
    case " ${RUN_ARGS[*]-} " in
        *" -collect-test-diagnostics "*) ;;
        *) diagnostics=(-collect-test-diagnostics never) ;;
    esac
    (
        cd "$PROJECT_DIR" && exec xcodebuild test \
            -project "$PROJECT" -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,id=$UDID" \
            -testPlan "$PLAN" \
            -resultBundlePath "$bundle" \
            ${diagnostics[@]+"${diagnostics[@]}"} \
            ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}
    ) >"$log" 2>&1 &
    pid=$!
    XCODEBUILD_PID=$pid

    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        if [ "$verdict_seen" -eq 0 ] && grep -qE '\*\* TEST (SUCCEEDED|FAILED) \*\*' "$log"; then
            verdict_seen=1
        fi
        [ "$verdict_seen" -eq 1 ] || continue
        # The verdict is in. Give xcodebuild three minutes to finish the result
        # bundle, then stop whatever still holds it: first a `simctl diagnose`
        # (should one run despite the flag), then xcodebuild itself.
        grace=$((grace + 5))
        if [ "$grace" -eq 180 ]; then
            for d in $(descendants "$pid"); do
                args="$(ps -o args= -p "$d" 2>/dev/null)"
                case "$args" in
                    *"simctl diagnose"*)
                        say "Killing a simctl diagnose still running 3 min after the verdict (pid $d);" \
                            "the result bundle may be unreadable"
                        kill "$d" 2>/dev/null ;;
                esac
            done
        elif [ "$grace" -ge 240 ]; then
            say "xcodebuild printed its verdict but did not exit; stopping it"
            kill "$pid" 2>/dev/null
        fi
    done
    wait "$pid" 2>/dev/null
    XCODEBUILD_PID=""
    return 0
}

# Signs that a test itself failed (XCTest, Swift Testing, or a runner that
# aborted on a failed assertion and restarted).
FAILURE_PATTERN="^Test Case '.*' failed \\(|: error: -\\[|Test [^ ].* failed after |recorded an issue|Restarting after unexpected exit"

failure_count() {
    grep -cE "$FAILURE_PATTERN" "$1"
}

# The test bundles xcodebuild could not launch, one per line; the names are
# the test targets, which is what -only-testing takes.
stranded_bundles() {
    grep -oE 'Launching [^:]+ Finished with error' "$1" \
        | sed -E 's/^Launching (.*) Finished with error$/\1/' | sort -u
}

only_testing_given() {
    case " ${EXTRA_ARGS[*]-} " in
        *" -only-testing"*|*" -skip-testing"*) return 0 ;;
    esac
    return 1
}

# Number of tests the log shows as having run (XCTest and Swift Testing).
executed_count() {
    grep -E "^Test Case '.*' (passed|failed) \(|Test [^ ].* (passed|failed) after " "$1" \
        | grep -vc 'Test run with'
}

report() {
    local log="$1"
    grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)|Executed [0-9]+ tests?, with [0-9]+ failures?' "$log" \
        | grep -v 'Executed 0 tests' | tail -4 >&2
    grep -E "^Test Case '.*' failed \(|Test [^ ].* failed after |Restarting after unexpected exit|: error: " "$log" \
        | sort -u | head -40 >&2
}

# --- Main --------------------------------------------------------------------

trap 'finish' EXIT
# A background job ignores Ctrl-C in a script, so pass it on.
trap '[ -n "$XCODEBUILD_PID" ] && kill "$XCODEBUILD_PID" 2>/dev/null; exit 130' INT TERM

RUN_ARGS=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
earlier=""   # what earlier attempts already passed, when a retry reruns only part
attempt=0
while :; do
    attempt=$((attempt + 1))
    log="$OUT_DIR/attempt$attempt.log"
    bundle="$OUT_DIR/attempt$attempt.xcresult"

    if [ "$attempt" -eq 1 ]; then
        prepare_simulator || reset_simulator || { say "The simulator is not usable"; exit 2; }
    fi

    say "Attempt $attempt: $PLAN on $UDID ${RUN_ARGS[*]-} (log: $log)"
    run_once "$log" "$bundle"

    ran="$(executed_count "$log")"
    if grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
        report "$log"
        [ -n "$earlier" ] && say "Earlier: $earlier"
        say "TEST SUCCEEDED ($ran tests ran). Result bundle: $bundle"
        exit 0
    fi

    if [ "$(failure_count "$log")" -eq 0 ] && grep -qE "$INFRA_PATTERN" "$log"; then
        stranded="$(stranded_bundles "$log")"
        say "No test failed, but the simulator would not launch a test bundle ($ran tests ran):"
        grep -E "$INFRA_PATTERN" "$log" | sort -u | head -5 >&2
        if [ "$attempt" -gt "$RETRIES" ]; then
            say "Giving up after $attempt attempts (infrastructure)."
            exit 2
        fi
        RUN_ARGS=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
        if [ "$ran" -gt 0 ] && [ -n "$stranded" ] && ! only_testing_given; then
            # Everything else ran and passed: rerun only what never launched.
            while IFS= read -r target; do
                RUN_ARGS+=("-only-testing:$target")
            done <<< "$stranded"
            earlier="${earlier:+$earlier; }attempt $attempt: $ran tests ran, none failed, $(echo $stranded | tr '\n' ' ')never launched ($log)"
        fi
        recover_simulator || { say "The simulator is not usable"; exit 2; }
        continue
    fi

    if grep -q '\*\* TEST FAILED \*\*' "$log"; then
        report "$log"
        say "TEST FAILED ($ran tests ran). Log: $log  Result bundle: $bundle"
        exit 1
    fi

    say "xcodebuild ended without a verdict. Last lines of $log:"
    tail -20 "$log" >&2
    exit 2
done
