# Watch Standalone-Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove WatchConnectivity from both the iOS app and the watchOS app, so KataGo Anytime Watch becomes a standalone, read-only game library that never controls — and never mirrors — the iPhone's live game.

**Architecture:** The watch keeps exactly one data source: its own CloudKit-synced SwiftData store, replayed to boards by `GoRulesKit.SgfReplay`. Everything that existed to carry the phone's live frame or the watch's write commands is deleted from both targets: the relay, the wire payload, the host gate, the shared cursor, the peek buffer, the live board and Top Moves pages, and the complication's second (live) record. Because "live" disappears, the "stored" vocabulary that contrasted with it is renamed to plain "game".

**Tech Stack:** Swift 6, SwiftUI, SwiftData + NSPersistentCloudKitContainer, WidgetKit (watchOS accessory families), Swift Testing, Xcode 26 SDKs, `xcodeproj` Ruby gem 1.27.0.

## Global Constraints

- **English-only in every committed byte.** No CJK in source, comments, commit messages, or docs. Existing `\u{…}`-escaped CJK inside `WatchWidgetSnapshotTests` grapheme fixtures is pre-existing test data and stays untouched.
- **Never modify SwiftData `@Model` schema.** `GameRecord` and `Config` are frozen (CloudKit). This plan touches none of them.
- **Deployment targets stay:** iOS 26+, watchOS 26+, Swift 6.
- **`xcodebuild` exit codes lie when piped.** Every build/test command below is written with `set -o pipefail` or a `grep` on the result line. Judge success by `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **`, never by `$?` alone after a pipe.
- **Never run two `xcodebuild` invocations at once.** The in-repo `DerivedData` lock produces spurious `TEST FAILED`. Run them strictly one at a time, and never delegate a build sweep to a parallel agent.
- **`KataGoUICore` package tests never run under `xcodebuild`.** They must be run separately with `swift test`.
- **All `project.pbxproj` edits go through the `xcodeproj` Ruby gem** (already installed, 1.27.0). Never hand-edit the pbxproj.
- **Do not touch `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION`.** Xcode Cloud supplies `CI_BUILD_NUMBER`.
- **`WatchWidgetDefaults.widgetKind` stays `"ScoreLeadWidget"`** and the App-Group key stays `"watchWidget.records"`. Renaming either orphans every existing complication placement.
- **The watch app target has no test bundle.** Any logic worth testing must live in `KataGoGameStore` or `KataGoAnalysisKit`, which the iOS-Simulator test target compiles. Do not "simplify" logic out of those packages into the watch target.
- **The watch app is a dependency of the iOS app target** (`Embed Watch Content`), so building the `KataGo Anytime` scheme also compiles `KataGo Anytime Watch`. No task may end with the watch app half-refactored: every build step in this plan is a real gate on both targets at once.
- **This is a deletion project.** Classic red-green TDD applies only where behavior *changes* (Task 2's `deepLinkDisposition` signature, Task 4's decode compatibility). For pure removals the cycle is inverted and stated explicitly per step: delete the test that pins the removed behavior first, watch the build fail, then delete the code.

---

## File Structure

**Deleted outright (12 source files + 10 test files)**

| File | Why |
|---|---|
| `ios/KataGo iOS/KataGo iOS/Watch/WatchSessionRelay.swift` | phone→watch push + watch→phone command receiver |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchCommandHandler.swift` | executes watch commands against the session |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchHostGate.swift` | `canScrub`/`canPlay`/`isHumanTurn` gate |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift` | builds the wire frame |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchCommand.swift` | command/reply wire types |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift` | live frame wire type |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift` | ring of recent live frames |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSharedCursor.swift` | scrub debounce/confirm state machine |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift` | live frame → complication record |
| `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift` | watch-side WCSession delegate |
| `ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift` | live board page |
| `ios/KataGo iOS/KataGo Anytime Watch/WatchMovesPage.swift` | Top Moves page |

Test files deleted: `WatchCommandTests`, `WatchCommandHandlerTests`, `WatchHostGateTests`, `WatchSnapshotTests`, `WatchSnapshotV13Tests`, `WatchSnapshotBuilderTests`, `WatchPeekBufferTests`, `WatchSharedCursorTests`, `WatchComplicationPushThrottleTests`, `WatchWidgetLiveSourceTests`.

**Renamed**

| From | To |
|---|---|
| `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift` | `WatchGameView.swift` (type `WatchStoredGameView` → `WatchGameView`) |
| `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRecords.swift` | `WatchWidgetRecord.swift` (type `WatchWidgetRecords` → `WatchWidgetRecord`) |

**Modified**

`ContentView.swift`, `KataGoAnytimeWatchApp.swift`, `WatchRootView.swift`, `WatchLibraryPage.swift`, `WatchBrowseModel.swift`, `WatchFrameBoard.swift`, `WatchAnalysisSummary.swift`, `WatchWidgetMirror.swift`, `WatchBoardFrame.swift`, `WatchBoardTitle.swift`, `WatchNavigationPolicy.swift`, `WatchWidgetSnapshot.swift`, `WatchWidgetDefaults.swift`, `WatchWidgetRefreshPolicy.swift`, `WatchWidgetLibrarySource.swift`, `LastGameWidget.swift`, `KataGo Anytime.xcodeproj/project.pbxproj`, `README.md`, `CLAUDE.md`.

**Created**

`ios/KataGo iOS/remove_files_from_xcodeproj.rb` — reusable pbxproj file-reference remover, used by Tasks 1–4.

**Explicitly NOT changed**

Entitlements (App Group, CloudKit container, and `aps-environment` are all still required); `Info.plist` (`WKCompanionAppBundleIdentifier` stays — the watch app remains dependent); `GtpCommandBuilder.continuousAnalyzeCommands` / `fastContinuousAnalyzeCommands` (the structural sticky-`maxVisits` fix is correct independently of the watch); `WatchLibraryStore`, `WatchStoredAnalysis` (its "stored" names provenance — what the record cached — not a contrast with "live", so it keeps its name), `SgfReplay`, `WatchBoardLayout`, `WatchWidgetTileText`.

**Known behavior NOT being fixed here (pre-existing, out of scope):** if the watch's library becomes completely empty, `mirrorLibrary` writes nothing and the tile keeps its last record, whose tap can dead-end on "Game not found". That is unchanged by this work — `evictingStaleLive` only ever swept the `.live` record, never the library one.

---

### Task 1: Amputate the phone side

Removes every host-side trace of the watch. The watch app still compiles untouched after this task (it only ever *read* from these types via the wire, never linked them).

**Files:**
- Create: `ios/KataGo iOS/remove_files_from_xcodeproj.rb`
- Delete: `ios/KataGo iOS/KataGo iOS/Watch/WatchSessionRelay.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchCommandHandler.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchHostGate.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchCommandHandlerTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchHostGateTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchSnapshotBuilderTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchComplicationPushThrottleTests.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/App/ContentView.swift:30`, `:65`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRefreshPolicy.swift:22-25`, `:42-49`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRefreshPolicyTests.swift:52-76`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `WatchWidgetRefreshPolicy` retaining exactly `reloadFloor: TimeInterval`, `timelineRefreshInterval: TimeInterval`, `shouldReload(previousKey:nextKey:elapsed:floor:) -> Bool`, `nextReloadDate(after:) -> Date`. `pushInterval` and `shouldPush` no longer exist. Later tasks must not reference them.

- [ ] **Step 1: Delete the tests that pin the removed host behavior**

Deletion project — the red phase is the *build* failing after the tests go, which proves the tests were the only thing holding these types up. Delete four whole files:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
trash "KataGo iOSTests/WatchCommandHandlerTests.swift" \
      "KataGo iOSTests/WatchHostGateTests.swift" \
      "KataGo iOSTests/WatchSnapshotBuilderTests.swift" \
      "KataGo iOSTests/WatchComplicationPushThrottleTests.swift"
```

- [ ] **Step 2: Remove the `shouldPush` tests**

In `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRefreshPolicyTests.swift`, delete lines 52–76 in their entirety — the `// MARK: push` comment and the four tests `anUnchangedKeyNeverPushes`, `aChangedKeyPushesOnlyOncePerInterval`, `theFirstPushIsNotRateLimited`, `thePushIntervalIsFarCoarserThanTheReloadFloor`. The file then runs straight from `aCommentChangeAloneIsEnoughToReload`'s closing `}` (line 50) to `// MARK: timeline` (line 78).

Also update the file's header comment, which currently promises the push half:

```swift
//
//  WatchWidgetRefreshPolicyTests.swift
//  KataGo AnytimeTests
//
//  When a changed record is worth a timeline reload.
//
```

- [ ] **Step 3: Create the reusable pbxproj remover**

Create `ios/KataGo iOS/remove_files_from_xcodeproj.rb`:

```ruby
#!/usr/bin/env ruby
# Removes file references — and every build-phase entry that points at them —
# from the Xcode project, by basename. Idempotent: a basename that is not in
# the project is silently skipped, so re-running after a partial failure is
# safe.
#
# Hand-editing project.pbxproj is not an option in this repo; this is the
# deletion counterpart to the add_*.rb scripts alongside it.
#
# Usage: ruby remove_files_from_xcodeproj.rb Foo.swift Bar.swift
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
abort("usage: #{$PROGRAM_NAME} <basename> [<basename>...]") if ARGV.empty?

project = Xcodeproj::Project.open(PROJECT)
removed = []
missing = []

ARGV.each do |name|
  refs = project.files.select { |f| File.basename(f.path.to_s) == name }
  if refs.empty?
    missing << name
  else
    refs.each(&:remove_from_project)
    removed << name
  end
end

project.save
puts "Removed: #{removed.join(', ')}" unless removed.empty?
puts "Not present (skipped): #{missing.join(', ')}" unless missing.empty?
```

- [ ] **Step 4: Delete the host-side sources**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
trash "KataGo iOS/Watch/WatchSessionRelay.swift" \
      "KataGoUICore/Sources/KataGoUICore/Session/WatchCommandHandler.swift" \
      "KataGoUICore/Sources/KataGoUICore/Session/WatchHostGate.swift" \
      "KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift"
rmdir "KataGo iOS/Watch"
```

`rmdir` (not `trash -r`) is deliberate: it fails loudly if anything unexpected is still in that folder.

- [ ] **Step 5: Deregister the deleted files from the Xcode project**

Only app-target files need this — the `KataGoUICore` package sources are discovered by SwiftPM and have no pbxproj entries.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby remove_files_from_xcodeproj.rb \
  WatchSessionRelay.swift \
  WatchCommandHandlerTests.swift \
  WatchHostGateTests.swift \
  WatchSnapshotBuilderTests.swift \
  WatchComplicationPushThrottleTests.swift
```

Expected output includes `Removed: WatchSessionRelay.swift, WatchCommandHandlerTests.swift, WatchHostGateTests.swift, WatchSnapshotBuilderTests.swift, WatchComplicationPushThrottleTests.swift`.

- [ ] **Step 6: Unwire the relay from `ContentView`**

In `ios/KataGo iOS/KataGo iOS/App/ContentView.swift`, delete line 30:

```swift
    @State private var watchRelay = WatchSessionRelay()
```

and delete line 65 from inside the first `.task`, so the block reads:

```swift
            .task {
                // Get messages from KataGo and append to the list of messages
                await session.run(
                    gameRecords: gameRecords,
                    modelContext: modelContext,
                    navigationContext: navigationContext,
                    audioModel: audioModel,
                    aiMove: $aiMove
                )
            }
```

- [ ] **Step 7: Remove `shouldPush` and `pushInterval` from the policy**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRefreshPolicy.swift`, delete lines 22–25 (the `pushInterval` declaration and its doc comment) and lines 42–49 (the `shouldPush` function). Update the file header, which currently describes both halves. The resulting file:

```swift
//
//  WatchWidgetRefreshPolicy.swift
//  KataGoAnalysisKit
//
//  When a change is worth a timeline reload.
//
//  Every decision here is keyed on the DISPLAYED content, with time only ever
//  acting as a floor. The complication this replaces gated its reload on a
//  half-point score move, which was defensible for a tile that showed only a
//  score and is exactly wrong for one that shows a name and a comment: those
//  change while the score sits still.
//
//  There is no push half any more. The phone used to spend one of its ~50
//  daily complication transfers to wake this watch app in the background; the
//  watch no longer talks to the phone at all, so the only writer left is the
//  watch's own library mirror, which runs in the foreground.
//

import Foundation

public enum WatchWidgetRefreshPolicy {
    /// Minimum spacing between timeline reloads. A floor, never a trigger.
    public static let reloadFloor: TimeInterval = 30

    /// How long a rendered entry stays valid before WidgetKit re-asks. Mirrors
    /// `WidgetReloadPolicy.refreshInterval` on the phone side.
    public static let timelineRefreshInterval: TimeInterval = 60 * 60

    /// A nil `previousKey` means nothing has ever been rendered, so the first
    /// record is never made to wait out a floor.
    public static func shouldReload(previousKey: String?,
                                    nextKey: String,
                                    elapsed: TimeInterval,
                                    floor: TimeInterval = reloadFloor) -> Bool {
        guard let previousKey else { return true }
        guard previousKey != nextKey else { return false }
        return elapsed >= floor
    }

    public static func nextReloadDate(after date: Date) -> Date {
        date.addingTimeInterval(timelineRefreshInterval)
    }
}
```

- [ ] **Step 8: Build the iOS scheme**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug \
  2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`. If it fails on an unresolved `WatchSessionRelay`, `WatchCommandHandler`, `WatchHostGate`, or `WatchSnapshotBuilder` symbol, a reference was missed — grep for it and remove that reference rather than restoring the file.

- [ ] **Step 9: Run the iOS test suite**

Never concurrently with another `xcodebuild`.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|Executed .* tests"
```

Expected: `** TEST SUCCEEDED **` with zero failures.

- [ ] **Step 10: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A
git commit -m "$(cat <<'EOF'
refactor(watch): delete the iPhone-side WatchConnectivity relay

The watch no longer sends commands to the phone or receives live frames
from it, so every host-side type that existed to serve that channel goes:
the 500 ms relay loop, the command handler, the host gate, the snapshot
builder, and the complication push throttle with its rate-limit policy.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Remove the live route, model, and pages from the watch app

**Files:**
- Delete: `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift`
- Delete: `ios/KataGo iOS/KataGo Anytime Watch/WatchBoardPage.swift`
- Delete: `ios/KataGo iOS/KataGo Anytime Watch/WatchMovesPage.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchNavigationPolicyTests.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift` (full rewrite)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` (full rewrite)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift` (full rewrite)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/KataGoAnytimeWatchApp.swift` (full rewrite)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchAnalysisSummary.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchWidgetMirror.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchDeepLinkDispositionTests.swift` (full rewrite)

**Interfaces:**
- Consumes: Task 1's `WatchWidgetRefreshPolicy` (no `shouldPush`).
- Produces:
  - `WatchDeepLinkDisposition` with cases `wait`, `game(String)`, `giveUp` — the `live` case is gone and `stored` is renamed.
  - `WatchNavigationPolicy.deepLinkDisposition(pendingGameID: String, libraryHasRow: Bool, graceExpired: Bool) -> WatchDeepLinkDisposition`.
  - `WatchRoute` with the single case `game(String)`.
  - `WatchWidgetMirror` without `mirrorLive`. `mirrorLibrary(rows:moveCount:libraryIsAuthoritative:container:now:)` keeps its signature until Task 4 — the watch app is a **dependency of the iOS target** (`Embed Watch Content`), so every step that builds the iOS scheme also compiles the watch, and no step may leave the watch mid-refactor.
  - `WatchStoredGameView` still exists under that name; Task 3 renames it.

- [ ] **Step 1: Write the failing tests for the new disposition signature**

Genuine red phase: this is a behavior change, not a deletion. Replace the whole of `ios/KataGo iOS/KataGo iOSTests/WatchDeepLinkDispositionTests.swift` with:

```swift
//
//  WatchDeepLinkDispositionTests.swift
//  KataGo AnytimeTests
//
//  Where a complication tap lands, and when it is still too early to decide.
//

import Testing
@testable import KataGoGameStore

struct WatchDeepLinkDispositionTests {
    @Test func aResolvableGameOpens() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: true,
            graceExpired: true) == .game("GAME-A"))
    }

    @Test func aColdLaunchWaitsRatherThanSayingGameNotFound() {
        // The exact cold-launch case: the tap arrives before the store has
        // produced a row for the game. Deciding early is what dead-ends the
        // tap on "Game not found".
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: false,
            graceExpired: false) == .wait)
    }

    @Test func onceTheGraceExpiresAMissingGameGivesUp() {
        // Giving up is not an error state: the latch clears and the user is
        // left on a fully interactive library.
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: false,
            graceExpired: true) == .giveUp)
    }

    @Test func aResolvableGameWinsBeforeTheGraceExpires() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", libraryHasRow: true,
            graceExpired: false) == .game("GAME-A"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchDeepLinkDispositionTests" \
  2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)" | head -20
```

Expected: compile errors — `extra argument 'libraryHasRow'` / `missing arguments for parameters 'hostGameID', 'hasSnapshot'`, and `type 'WatchDeepLinkDisposition' has no member 'game'`.

- [ ] **Step 3: Rewrite the navigation policy**

Replace the whole of `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift` with:

```swift
//
//  WatchNavigationPolicy.swift
//  KataGoGameStore
//
//  Where the watch lands, decided in one testable place because the watch
//  target has no test bundle.
//

import Foundation

public enum WatchNavigationPolicy {}

/// What to do with a complication tap that named a game.
public enum WatchDeepLinkDisposition: Equatable, Sendable {
    /// Too early to decide — keep the latch and re-evaluate.
    case wait
    case game(String)
    /// The game cannot be resolved and never will be; drop the latch.
    case giveUp
}

extension WatchNavigationPolicy {
    /// Precedence for a pending deep link, highest first:
    ///
    ///   1. the library can produce a row for it -> `.game`
    ///   2. it cannot, but the launch grace has not expired -> `.wait`
    ///   3. otherwise -> `.giveUp`
    ///
    /// `.wait` exists because a cold launch from a tap is the one moment when
    /// the store may not yet have imported the game the tile names. Deciding
    /// then is what dead-ends the tap on "Game not found". The grace is
    /// deliberately short (see `WatchRootView.deepLinkResolutionGrace`): during
    /// `.wait` the user is already sitting on a fully interactive library, so a
    /// long window mostly buys opportunities to yank them out of a list they
    /// have started browsing.
    public static func deepLinkDisposition(pendingGameID: String,
                                           libraryHasRow: Bool,
                                           graceExpired: Bool) -> WatchDeepLinkDisposition {
        if libraryHasRow { return .game(pendingGameID) }
        return graceExpired ? .giveUp : .wait
    }
}
```

`WatchLaunchRoute`, `launchRoute(hasSnapshot:latchConsumed:)`, and `opensLiveMirror(rowID:hostGameID:hasSnapshot:)` are all gone: with no snapshot the launch route is unconditionally the library, and with no live mirror no row can open one.

- [ ] **Step 4: Delete the now-empty navigation policy test file**

Every test in it exercised `launchRoute` or `opensLiveMirror`.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
trash "KataGo iOSTests/WatchNavigationPolicyTests.swift"
ruby remove_files_from_xcodeproj.rb WatchNavigationPolicyTests.swift
```

- [ ] **Step 5: Delete the watch's live model and its two pages**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
trash "KataGo Anytime Watch/WatchLiveModel.swift" \
      "KataGo Anytime Watch/WatchBoardPage.swift" \
      "KataGo Anytime Watch/WatchMovesPage.swift"
ruby remove_files_from_xcodeproj.rb \
  WatchLiveModel.swift WatchBoardPage.swift WatchMovesPage.swift
```

- [ ] **Step 6: Rewrite the app entry point**

The whole reason `widgetMirror` was built in `init()` was so a WatchConnectivity background launch — which never evaluates the window body — still had a writer. There are no background launches now, so both the mirror and the library are built at first UI appearance.

Replace the whole of `ios/KataGo iOS/KataGo Anytime Watch/KataGoAnytimeWatchApp.swift` with:

```swift
import SwiftUI
import SwiftData
import KataGoGameStore

@main
struct KataGoAnytimeWatchApp: App {
    /// Built at first UI appearance, NOT in `init()`.
    ///
    /// `SharedModelContainer.shared` takes the CloudKit-only branch on
    /// watchOS: an NSPersistentCloudKitContainer open with schema setup,
    /// mirroring, import/export scheduling and push registration. Deferring it
    /// keeps that cost off the launch path until something actually renders.
    @State private var library: WatchLibraryStore?
    /// Needs only `UserDefaults`, but built here alongside the library because
    /// the library refresh is now its only caller. It used to be constructed in
    /// `init()` so that a WatchConnectivity background launch — which never
    /// evaluates the window body — still had a writer to hand a frame to.
    /// There are no background launches any more.
    @State private var widgetMirror: WatchWidgetMirror?

    var body: some Scene {
        WindowGroup {
            Group {
                if let library, let widgetMirror {
                    WatchRootView(container: SharedModelContainer.shared,
                                  widgetMirror: widgetMirror)
                        .environment(library)
                } else {
                    ProgressView()
                }
            }
            .task {
                guard library == nil else { return }
                widgetMirror = WatchWidgetMirror()
                library = WatchLibraryStore(container: SharedModelContainer.shared,
                                            storeMode: SharedModelContainer.watchStoreMode)
            }
        }
    }
}
```

- [ ] **Step 7: Rewrite the root view**

Replace the whole of `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` with:

```swift
import SwiftUI
import SwiftData
import KataGoGameStore

/// Where the watch can navigate. The library is the root; a saved game is the
/// only push from it.
enum WatchRoute: Hashable {
    case game(String)
}

struct WatchRootView: View {
    @Environment(WatchLibraryStore.self) private var library
    let container: ModelContainer
    let widgetMirror: WatchWidgetMirror

    @State private var path: [WatchRoute] = []
    /// The game a complication tap named, held until it can be resolved.
    @State private var pendingDeepLinkID: String?
    /// Set once the launch grace has expired, so an unresolvable link can stop
    /// waiting rather than latch forever.
    @State private var graceExpired = false

    var body: some View {
        NavigationStack(path: $path) {
            WatchLibraryPage(path: $path)
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .game(let id):
                        if let row = library.row(byID: id) {
                            WatchStoredGameView(row: row, container: container)
                        } else {
                            ContentUnavailableView("Game not found",
                                                   systemImage: "questionmark.folder",
                                                   description: Text("It may have been deleted."))
                        }
                    }
                }
        }
        .task {
            // Fires at the end of every refresh(), including the coalesced
            // remote-change path, so a CloudKit import updates the tile
            // without the user opening the library page. This is now the ONLY
            // writer the complication has: nothing wakes this app in the
            // background any more, so the tile shows whatever was true the
            // last time the app ran.
            library.onRefresh = { [weak library] in
                guard let library else { return }
                widgetMirror.mirrorLibrary(
                    rows: library.rows,
                    moveCount: { library.moveCount(for: $0) },
                    // Never evict on a partial view of the library: a degraded
                    // store, or a fetch that hit its row cap, has not proved a
                    // game is gone. Task 4 removes this argument along with the
                    // eviction pass itself — leave it here for now so the watch
                    // target keeps compiling, which the iOS scheme requires
                    // (the watch app is an iOS target dependency).
                    libraryIsAuthoritative:
                        SharedModelContainer.watchStoreMode == .cloudKit
                        && library.rows.count < WatchLibraryStore.fetchLimit,
                    container: container)
            }
            library.refresh()
            library.startObservingRemoteChanges()

            try? await Task.sleep(for: Self.deepLinkResolutionGrace)
            graceExpired = true
            applyPendingDeepLink()
        }
        .onOpenURL { url in
            // The scheme also carries import-sgf; anything this cannot parse
            // must be ignored rather than clobber a pending link.
            guard let id = GameDeepLink.gameID(from: url)?.uuidString else { return }
            pendingDeepLinkID = id
            // Called directly, not left to .onChange: this tile points at one
            // game at a time, so tapping the SAME id twice is the normal
            // interaction and writing an equal value fires no change.
            applyPendingDeepLink()
        }
        .onChange(of: pendingDeepLinkID, initial: true) { _, _ in applyPendingDeepLink() }
    }

    /// How long a tap that names a game the store cannot yet resolve keeps
    /// waiting before giving up. `WatchLibraryStore.row(byID:)` runs its own
    /// direct descriptor fetch, independent of `refresh()` and of the 100-row
    /// cap, so a game already in the local store resolves on the first
    /// evaluation and never touches this at all — the grace only covers a
    /// CloudKit import still in flight. Kept short on purpose: while it runs
    /// the user is on a fully interactive library, and a long window mostly
    /// buys opportunities to yank them out of a list mid-browse.
    private static let deepLinkResolutionGrace: Duration = .seconds(2)

    /// The one place a pending deep link becomes navigation. Always clears the
    /// latch on a terminal disposition — a stranded latch would keep
    /// re-evaluating for the rest of the session.
    private func applyPendingDeepLink() {
        guard let pending = pendingDeepLinkID else { return }
        switch WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: pending,
            libraryHasRow: library.row(byID: pending) != nil,
            graceExpired: graceExpired) {
        case .wait:
            return
        case .game(let id):
            // ASSIGN, never append: a second tap must replace the destination
            // rather than leave a two-deep stack whose back-swipe lands on the
            // previously-tapped game instead of the library.
            path = [.game(id)]
        case .giveUp:
            break
        }
        pendingDeepLinkID = nil
    }
}
```

- [ ] **Step 8: Rewrite the library page**

Replace the whole of `ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift` with:

```swift
import SwiftUI
import CloudKit
import KataGoGameStore

/// The watch's root: every saved game, newest first.
struct WatchLibraryPage: View {
    @Environment(WatchLibraryStore.self) private var library
    @Binding var path: [WatchRoute]

    @State private var now = Date()

    var body: some View {
        List {
            if library.rows.isEmpty {
                emptyState
            } else {
                // Unsectioned on purpose. There is exactly one kind of game on
                // the watch now, so a "Games" header would label nothing — the
                // navigation title already describes the whole screen.
                ForEach(library.rows) { row in
                    Button {
                        path.append(.game(row.id))
                    } label: {
                        gameRow(row)
                    }
                }
            }
        }
        .navigationTitle("Games")
        .task {
            // Concurrent, not serialized: CKContainer.accountStatus() has no
            // timeout, so the write to `now` must not be sequenced behind
            // awaiting it — that would pin the empty state on "Syncing from
            // iCloud" for as long as that call hangs. `library.accountState` is
            // an observed property of an @Observable store, so its later
            // arrival still re-renders the empty state on its own, and
            // `LibrarySyncPolicy` checks `accountState != .unavailable` before
            // it ever looks at the grace flag, so a late `.signedOut` still
            // wins.
            async let accountState = Self.accountState()
            async let graceExpired: Void = Self.waitForLaunchGrace()
            await graceExpired
            // Re-evaluate the empty state now that the launch grace expired.
            now = Date()
            library.accountState = await accountState
        }
    }

    private func gameRow(_ row: WatchLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name).lineLimit(1)
            Text("\(row.sizeText) - \(library.moveCount(for: row)) moves")
                .font(.caption2).foregroundStyle(.secondary)
            if let date = row.lastModified {
                Text(date, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch library.emptyState(now: now) {
        case .syncing:
            HStack {
                ProgressView()
                Text("Syncing from iCloud").font(.caption)
            }
        case .signedOut:
            Label("Sign in to iCloud on iPhone to see your games",
                  systemImage: "icloud.slash")
                .font(.caption)
        case .unavailable:
            Label("iCloud is unavailable. Games will appear once it reconnects.",
                  systemImage: "exclamationmark.icloud")
                .font(.caption)
        case .empty:
            // Still "from your iPhone": the phone is where games are created
            // and iCloud is still the pipe. It is just no longer a live one.
            Label("No games yet. Games sync from your iPhone.",
                  systemImage: "circle.grid.cross")
                .font(.caption)
        }
    }

    /// The launch-grace timer, split out so it can run concurrently with
    /// `accountState()` in one `.task` (see there for why).
    private static func waitForLaunchGrace() async {
        try? await Task.sleep(for: .seconds(WatchLibraryStore.launchGrace))
    }

    /// The account signal the empty-state policy needs. Kept in the view so
    /// KataGoGameStore never has to import CloudKit.
    private static func accountState() async -> ICloudAccountState {
        do {
            switch try await CKContainer(identifier: SharedModelContainer.cloudKitContainerID)
                .accountStatus() {
            case .available: return .available
            case .noAccount, .restricted: return .unavailable
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }
}
```

- [ ] **Step 9: Drop `staleSince` from the analysis summary**

Its only caller was the deleted Top Moves page. In `ios/KataGo iOS/KataGo Anytime Watch/WatchAnalysisSummary.swift`, replace the whole file with:

```swift
import SwiftUI
import KataGoGameStore

/// The analysis readouts that used to be drawn on the board.
///
/// The body is a set of sibling rows rather than a container, so a caller can
/// drop it straight into its own `List` and keep one flat list of rows.
///
/// Rows are omitted rather than zeroed when a value is absent — the watch
/// never invents a number.
struct WatchAnalysisSummary: View {
    let winrateBlack: Float?
    let scoreLeadBlack: Float?

    var body: some View {
        if let winrateBlack, winrateBlack.isFinite {
            LabeledContent("Black",
                           value: WatchBoardFrame.winratePercentText(winrateBlack))
        }
        if let scoreLeadBlack, scoreLeadBlack.isFinite {
            LabeledContent("Score", value: WatchBoardFrame.scoreText(scoreLeadBlack))
        }
    }
}
```

- [ ] **Step 10: Delete the live mirror from `WatchWidgetMirror`**

Scoped deliberately: `mirrorLive` and its `immediate` bypass go now, because their callers just went. The `mirrorLibrary` signature and `WatchWidgetRecords` stay until Task 4 — the watch app is an iOS target dependency, so leaving the watch mid-refactor would break Step 11's build.

In `ios/KataGo iOS/KataGo Anytime Watch/WatchWidgetMirror.swift`, replace the type doc comment (lines 6–27) with:

```swift
/// Owns every App-Group write the complication reads, and every timeline
/// reload it gets.
///
/// The mirror lives in the watch app process because App Group containers are
/// PER-DEVICE: `group.chinchangyang.KataGo-iOS.tw` is entitled on the iPhone
/// too, but nothing the iPhone writes there is visible here. That was already
/// a platform constraint rather than a style choice; now that the phone has no
/// WatchConnectivity channel either, this process is the only writer there can
/// possibly be.
///
/// `WidgetCenter` is confined to this type (and the widget target) on purpose:
/// KataGoGameStore compiles for tvOS, which has no WidgetKit.
///
/// Deliberately holds no `ModelContainer` — `mirrorLibrary` takes one as a
/// parameter from its caller instead.
```

Delete `mirrorLive` entirely (lines 103–113), and drop the `immediate` bypass from `reloadIfNeeded` (lines 115–124), whose only user was that method:

```swift
    private func reloadIfNeeded(_ records: WatchWidgetRecords, now: Date) {
        let key = records.resolved(now: now)?.contentKey ?? ""
        let elapsed = now.timeIntervalSince(lastReloadAt ?? .distantPast)
        guard WatchWidgetRefreshPolicy.shouldReload(previousKey: lastReloadKey,
                                                    nextKey: key,
                                                    elapsed: elapsed) else { return }
        lastReloadKey = key
        lastReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetDefaults.widgetKind)
    }
```

`mirrorLibrary`'s single call to it becomes `reloadIfNeeded(records, now: now)` — delete the `immediate: false` argument on line 100.

- [ ] **Step 11: Build and test the iOS scheme**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)|Executed .* tests"
```

Expected: `** TEST SUCCEEDED **`, zero failures. The four rewritten `WatchDeepLinkDispositionTests` now pass (green phase for Step 1).

- [ ] **Step 12: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A
git commit -m "$(cat <<'EOF'
refactor(watch): drop the live route, live model, and its two pages

The watch app has one destination now: a saved game. WatchRoute loses
.live, the deep-link policy loses its live branch and its snapshot
inputs, the launch route (always the library) disappears entirely, and
the library page becomes one unsectioned list titled Games.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Prune the shared wire and frame types

**Files:**
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchCommand.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSharedCursor.swift`
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchCommandTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchSnapshotTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchSnapshotV13Tests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchPeekBufferTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchSharedCursorTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLiveSourceTests.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift` (full rewrite)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardTitle.swift` (full rewrite)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift:36`, `:48`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchBrowseModel.swift:73-89`
- Rename: `ios/KataGo iOS/KataGo Anytime Watch/WatchStoredGameView.swift` → `WatchGameView.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` (call site of the renamed view)
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift` (full rewrite)
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchBoardTitleTests.swift` (full rewrite)

**Interfaces:**
- Consumes: Task 2's `WatchRoute.game(String)`.
- Produces:
  - `WatchBoardFrame` with a memberwise `init(title:boardWidth:boardHeight:blackStones:whiteStones:lastMoveVertex:moveIndex:moveCount:winrateBlack:scoreLeadBlack:bestMove:comment:)` and no `Source`, `source`, `candidates`, `candidateVertices`, or static factories. `bestMoveMark(showBestMove:)`, `bestMoveVertex(showBestMove:)`, `scoreText(_:)`, `winratePercentText(_:)` are unchanged.
  - `WatchBoardTitle.game(name:index:count:showsCounter:) -> String` — the only member. `live(...)` is gone.
  - `WatchGameView(row:container:)` — renamed from `WatchStoredGameView`.

- [ ] **Step 1: Delete the tests for the removed wire types**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
trash "KataGo iOSTests/WatchCommandTests.swift" \
      "KataGo iOSTests/WatchSnapshotTests.swift" \
      "KataGo iOSTests/WatchSnapshotV13Tests.swift" \
      "KataGo iOSTests/WatchPeekBufferTests.swift" \
      "KataGo iOSTests/WatchSharedCursorTests.swift" \
      "KataGo iOSTests/WatchWidgetLiveSourceTests.swift"
ruby remove_files_from_xcodeproj.rb \
  WatchCommandTests.swift WatchSnapshotTests.swift WatchSnapshotV13Tests.swift \
  WatchPeekBufferTests.swift WatchSharedCursorTests.swift WatchWidgetLiveSourceTests.swift
```

- [ ] **Step 2: Rewrite `WatchBoardFrameTests` against the single-source frame**

Replace the whole of `ios/KataGo iOS/KataGo iOSTests/WatchBoardFrameTests.swift` with:

```swift
//
//  WatchBoardFrameTests.swift
//  KataGo AnytimeTests
//
//  The one frame the watch renders: a position it replayed itself from its
//  own copy of a saved game.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchBoardFrameTests {
    private func frame(title: String? = "Study",
                       width: Int = 19, height: Int = 19,
                       moveIndex: Int = 3, moveCount: Int = 40,
                       winrateBlack: Float? = 0.5, scoreLeadBlack: Float? = 0,
                       bestMove: String? = nil,
                       comment: String? = nil) -> WatchBoardFrame {
        WatchBoardFrame(title: title, boardWidth: width, boardHeight: height,
                        blackStones: [], whiteStones: [], lastMoveVertex: nil,
                        moveIndex: moveIndex, moveCount: moveCount,
                        winrateBlack: winrateBlack, scoreLeadBlack: scoreLeadBlack,
                        bestMove: bestMove, comment: comment)
    }

    @Test func aFrameCarriesTheCachedReviewData() {
        let frame = WatchBoardFrame(title: "Kobayashi",
                                    boardWidth: 13, boardHeight: 13,
                                    blackStones: ["D4"], whiteStones: [],
                                    lastMoveVertex: "D4",
                                    moveIndex: 1, moveCount: 40,
                                    winrateBlack: 0.61, scoreLeadBlack: -2.5,
                                    bestMove: "K10", comment: "Solid opening.")
        #expect(frame.title == "Kobayashi")
        #expect(frame.boardWidth == 13)
        #expect(frame.blackStones == ["D4"])
        #expect(frame.lastMoveVertex == "D4")
        #expect(frame.moveIndex == 1)
        #expect(frame.moveCount == 40)
        #expect(frame.winrateBlack == 0.61)
        #expect(frame.scoreLeadBlack == -2.5)
        #expect(frame.bestMove == "K10")
        #expect(frame.comment == "Solid opening.")
    }

    @Test func aFrameOmitsNumbersTheRecordNeverCached() {
        // Hidden, never zeroed — the watch must not invent a number.
        let frame = frame(winrateBlack: nil, scoreLeadBlack: nil)
        #expect(frame.winrateBlack == nil)
        #expect(frame.scoreLeadBlack == nil)
    }

    @Test func bestMoveMarkIsNoneWhenTheToggleIsOff() {
        #expect(frame(bestMove: "K10").bestMoveMark(showBestMove: false) == .none)
        #expect(frame(bestMove: "K10").bestMoveVertex(showBestMove: false) == nil)
    }

    /// Analysis coverage is whatever the phone happened to look at, so most
    /// indices cache nothing.
    @Test func bestMoveMarkIsNoneWhenTheRecordCachedNothing() {
        #expect(frame(bestMove: nil).bestMoveMark(showBestMove: true) == .none)
    }

    @Test func bestMoveMarkIsDrawableForARealVertex() {
        let f = frame(bestMove: "K10")
        #expect(f.bestMoveMark(showBestMove: true) == .drawable("K10"))
        #expect(f.bestMoveVertex(showBestMove: true) == "K10")
    }

    /// The case the Review page has to spell out in words. `Coordinate.move`
    /// really does return the literal "pass", and near the end of a scored
    /// game passing IS the engine's best move — so a well-reviewed record has
    /// cached passes at exactly the indices a user scrubs to last. The board
    /// cannot draw one, so it must not be reported as drawable.
    @Test func bestMoveMarkIsUnrenderableForAPass() {
        let f = frame(bestMove: "pass")
        #expect(f.bestMoveMark(showBestMove: true) == .unrenderable("pass"))
        #expect(f.bestMoveVertex(showBestMove: true) == nil)
    }

    /// Anything the board's own parser rejects is unrenderable, not silently
    /// dropped: 'I' is skipped in GTP columns, and a vertex can outrun a
    /// smaller board if a record was ever written against a different size.
    @Test(arguments: ["I5", "T19", "", "Z99", "AA1"])
    func bestMoveMarkIsUnrenderableForAnythingTheBoardCannotParse(vertex: String) {
        // 9x9: the rightmost column is 'J' and the top row is 9.
        let f = frame(width: 9, height: 9, bestMove: vertex)
        #expect(f.bestMoveMark(showBestMove: true) == .unrenderable(vertex))
        #expect(f.bestMoveVertex(showBestMove: true) == nil)
    }

    @Test func scoreTextReadsFromWhicheverSideLeads() {
        #expect(WatchBoardFrame.scoreText(3.5) == "B+3.5")
        #expect(WatchBoardFrame.scoreText(-3.5) == "W+3.5")
        #expect(WatchBoardFrame.scoreText(0) == "B+0.0")
    }

    /// Every input here is exactly representable in Float, so the rounding
    /// boundaries are deterministic rather than dependent on binary
    /// approximation of the literal.
    @Test func winratePercentRoundsHalvesAwayFromZero() {
        #expect(WatchBoardFrame.winratePercentText(0) == "0%")
        #expect(WatchBoardFrame.winratePercentText(0.375) == "38%")
        #expect(WatchBoardFrame.winratePercentText(0.5) == "50%")
        #expect(WatchBoardFrame.winratePercentText(0.625) == "63%")
        #expect(WatchBoardFrame.winratePercentText(1) == "100%")
    }

    /// A win rate a hair under 1 must read 100%, not 99% — the watch reports
    /// what the record cached, and truncation would understate a won game.
    @Test func winratePercentRoundsRatherThanTruncates() {
        #expect(WatchBoardFrame.winratePercentText(0.999) == "100%")
    }
}
```

- [ ] **Step 3: Rewrite `WatchBoardTitleTests`**

Replace the whole of `ios/KataGo iOS/KataGo iOSTests/WatchBoardTitleTests.swift` with:

```swift
import Testing
@testable import KataGoGameStore

struct WatchBoardTitleTests {
    @Test func itShowsTheCounterOnlyWhileScrubbing() {
        #expect(WatchBoardTitle.game(name: "Sanren-sei", index: 3, count: 50,
                                     showsCounter: true) == "3/50")
        #expect(WatchBoardTitle.game(name: "Sanren-sei", index: 3, count: 50,
                                     showsCounter: false) == "Sanren-sei")
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchBoardTitleTests" \
  2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)" | head -20
```

Expected: compile error — `type 'WatchBoardTitle' has no member 'game'`.

- [ ] **Step 5: Rewrite `WatchBoardFrame`**

Replace the whole of `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardFrame.swift` with:

```swift
//
//  WatchBoardFrame.swift
//  KataGoGameStore
//
//  What the watch draws: one position it replayed itself from its own copy of
//  a saved game.
//
//  This used to carry a `Source` discriminator because a frame could also
//  arrive mirrored from the iPhone over WatchConnectivity. That channel is
//  gone, and with it the candidate list — nothing analyzes on the watch, so a
//  frame's analysis fields are only ever whatever the record already cached.
//
//  Lives here rather than in the watch target because the watch has no test
//  bundle — this is the same reason the visionOS logic lives in the package.
//

import Foundation

public struct WatchBoardFrame: Equatable, Sendable {
    public var title: String?
    public var boardWidth: Int
    public var boardHeight: Int
    public var blackStones: [String]
    public var whiteStones: [String]
    public var lastMoveVertex: String?
    public var moveIndex: Int?
    public var moveCount: Int?
    /// Black's win rate, 0...1. Nil where nothing has been analyzed — hidden,
    /// never zeroed, so the watch does not invent a number.
    public var winrateBlack: Float?
    /// Black's score lead in points. Nil where nothing has been analyzed.
    public var scoreLeadBlack: Float?
    /// The engine's best move at this index, as the record cached it.
    public var bestMove: String?
    /// The commentary the record cached at this index.
    public var comment: String?

    public init(title: String?, boardWidth: Int, boardHeight: Int,
                blackStones: [String], whiteStones: [String],
                lastMoveVertex: String?,
                moveIndex: Int?, moveCount: Int?,
                winrateBlack: Float?, scoreLeadBlack: Float?,
                bestMove: String?, comment: String?) {
        self.title = title
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.blackStones = blackStones
        self.whiteStones = whiteStones
        self.lastMoveVertex = lastMoveVertex
        self.moveIndex = moveIndex
        self.moveCount = moveCount
        self.winrateBlack = winrateBlack
        self.scoreLeadBlack = scoreLeadBlack
        self.bestMove = bestMove
        self.comment = comment
    }

    /// What the Review toggle can actually do with this frame's cached best
    /// move.
    public enum BestMoveMark: Equatable, Sendable {
        /// Nothing to show: the toggle is off, or the record cached no best
        /// move at this index (coverage is whatever the phone happened to
        /// analyze, so most indices land here).
        case none
        /// A vertex the board can draw.
        case drawable(String)
        /// A vertex the board CANNOT draw, carried so the caller can say so in
        /// words instead of showing an unchanged board.
        ///
        /// This is not hypothetical: `Coordinate.move` returns the literal
        /// string `"pass"`, `GobanState.maybeUpdateAnalysisData` stores
        /// whatever `getBestMove` returned, and near the end of a scored game
        /// passing IS the engine's best move — so any well-reviewed game has
        /// cached passes at exactly the indices a user scrubs to last.
        case unrenderable(String)
    }

    /// Classifies the cached best move for the Review page's toggle.
    ///
    /// Renderability is decided with `parseVertex` — the same function the
    /// board itself parses with — so the classification and the drawing can
    /// never disagree about what "drawable" means.
    public func bestMoveMark(showBestMove: Bool) -> BestMoveMark {
        guard showBestMove, let bestMove else { return .none }
        guard parseVertex(bestMove, width: boardWidth, height: boardHeight) != nil else {
            return .unrenderable(bestMove)
        }
        return .drawable(bestMove)
    }

    /// The vertex to hand `WidgetBoardView`, or nil.
    public func bestMoveVertex(showBestMove: Bool) -> String? {
        guard case .drawable(let vertex) = bestMoveMark(showBestMove: showBestMove) else {
            return nil
        }
        return vertex
    }

    /// "B+3.2" / "W+3.2" from Black's signed score lead.
    public static func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }

    /// "62%" from Black's win rate.
    ///
    /// Black-perspective to agree with the gutter bar beside the board, which
    /// fills from the bottom for Black, and with that bar's accessibility
    /// label — the number and the picture must never disagree about whose win
    /// rate is being shown.
    public static func winratePercentText(_ winrateBlack: Float) -> String {
        "\(Int((winrateBlack * 100).rounded()))%"
    }
}
```

- [ ] **Step 6: Rewrite `WatchBoardTitle`**

Replace the whole of `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchBoardTitle.swift` with:

```swift
//
//  WatchBoardTitle.swift
//  KataGoGameStore
//
//  What the board page's navigation title says.
//
//  The watch board fills its whole page, so the title is the only chrome left
//  that can report status without covering stones. That is why the rule lives
//  here, in one testable place, rather than inline in a view: the watch target
//  has no test bundle, so a rule spelled out there cannot be tested at all.
//

import Foundation

public enum WatchBoardTitle {
    /// A game's title: the scrub counter while the Crown is moving, the game's
    /// name once it settles. Showing the counter permanently would mean a
    /// game's name was never on screen.
    public static func game(name: String, index: Int, count: Int,
                            showsCounter: Bool) -> String {
        showsCounter ? "\(index)/\(count)" : name
    }
}
```

- [ ] **Step 7: Delete the remaining wire types**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
trash "KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift" \
      "KataGoUICore/Sources/KataGoGameStore/WatchCommand.swift" \
      "KataGoUICore/Sources/KataGoGameStore/WatchPeekBuffer.swift" \
      "KataGoUICore/Sources/KataGoGameStore/WatchSharedCursor.swift" \
      "KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift"
```

No pbxproj step: these are SwiftPM package sources.

- [ ] **Step 8: Drop `candidateVertices` from `WatchFrameBoard`**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchFrameBoard.swift`, delete line 48:

```swift
                        candidateVertices: frame.candidateVertices,
```

`WidgetBoardView`'s `candidateVertices:` parameter defaults to `[]`, so removing the argument is sufficient — do not change `WidgetBoardView`.

Then replace the `showBestMove` doc comment and declaration (lines 32–36), whose justification referenced the deleted live path:

```swift
    /// Whether to blend the record's cached best move onto the board. The
    /// Review page's toggle drives it; it defaults to false so a caller that
    /// has no toggle gets a plain board.
    var showBestMove: Bool = false
```

Finally, update the type doc comment's second sentence (line 5–6), which claims two worlds:

```swift
/// Draws a WatchBoardFrame: the board at the largest size the page allows,
/// with a vertical winrate bar beside it in reserved margin.
```

- [ ] **Step 9: Point `WatchBrowseModel` at the memberwise initializer**

`WatchBoardFrame.stored(...)` was the only producer left and Step 5 deleted it, so this is the call site that must move to the plain `init`. In `ios/KataGo iOS/KataGo Anytime Watch/WatchBrowseModel.swift`, replace the `frame` property (lines 73–89) with:

```swift
    var frame: WatchBoardFrame? {
        guard var replay = self.replay else { return nil }
        let position = replay.position(at: index)
        self.replay = replay   // keep the memoized checkpoints
        let analysis = storedAnalysis()
        return WatchBoardFrame(
            title: row.name,
            boardWidth: replay.width, boardHeight: replay.height,
            blackStones: position.blackVertices,
            whiteStones: position.whiteVertices,
            lastMoveVertex: position.lastMoveVertex,
            moveIndex: index, moveCount: replay.moveCount,
            winrateBlack: analysis.winrateBlack,
            scoreLeadBlack: analysis.scoreLeadBlack,
            bestMove: analysis.bestMove,
            comment: analysis.comment)
    }
```

The argument list is otherwise identical — the factory took exactly these labels — so nothing about what the model produces changes.

- [ ] **Step 10: Rename `WatchStoredGameView` to `WatchGameView`**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git mv "KataGo Anytime Watch/WatchStoredGameView.swift" "KataGo Anytime Watch/WatchGameView.swift"
```

Then point the project at the new path:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open(File.join(Dir.pwd, "KataGo Anytime.xcodeproj"))
ref = project.files.find { |f| File.basename(f.path.to_s) == "WatchStoredGameView.swift" }
abort("WatchStoredGameView.swift not found in project") unless ref
ref.path = ref.path.to_s.sub("WatchStoredGameView.swift", "WatchGameView.swift")
project.save
puts "Renamed reference to #{ref.path}"
'
```

In `WatchGameView.swift`, make four edits.

Lines 5–7, the doc comment and the type name — the "same two-page shape as the live mirror" clause names something that no longer exists:

```swift
/// A saved game the watch replays itself: a board page plus a review page.
struct WatchGameView: View {
```

Lines 56–59, the title helper:

```swift
        .navigationTitle(WatchBoardTitle.game(name: model?.row.name ?? row.name,
                                              index: model?.index ?? 0,
                                              count: model?.moveCount ?? 0,
                                              showsCounter: showsCounter))
```

Lines 68–70, the comment inside `boardPage` that justifies the `VStack` by parity with the deleted `WatchBoardPage`:

```swift
        // The VStack is kept as the modifier host: `.focusable()` is what wins
        // the Crown away from the enclosing TabView's vertical paging, and it
        // must not move.
```

Line 34, the `@AppStorage` doc comment's reference to `WatchRootView`'s destination closure, is still accurate and stays as-is.

In `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`, update the destination:

```swift
                        if let row = library.row(byID: id) {
                            WatchGameView(row: row, container: container)
                        } else {
```

- [ ] **Step 11: Build and test the iOS scheme**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)|Executed .* tests"
```

Expected: `** TEST SUCCEEDED **`, zero failures.

- [ ] **Step 12: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A
git commit -m "$(cat <<'EOF'
refactor(watch): delete the wire types and collapse the board frame

WatchSnapshot, WatchCommand, WatchPeekBuffer, WatchSharedCursor and
WatchWidgetLiveSource have no callers left. WatchBoardFrame loses its
Source discriminator and its candidate list — nothing analyzes on the
watch — and WatchBoardTitle keeps only the game title. WatchStoredGameView
becomes WatchGameView now that no other kind of game view exists.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Collapse the complication to a single record

**Files:**
- Rename: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRecords.swift` → `WatchWidgetRecord.swift` (full rewrite)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetSnapshot.swift:22-26`, `:51`, `:56`, `:65`, `:68-72`, `:101-113`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetDefaults.swift:5-18`, `:50-64`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLibrarySource.swift:88`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchWidgetMirror.swift` (the `mirrorLibrary` signature and body)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` (the `onRefresh` call site)
- Modify: `ios/KataGo iOS/KataGoAnytimeWatchWidget/LastGameWidget.swift:34-35`, `:44-49`, `:207-228`, `:271-327`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRecordsTests.swift` → `WatchWidgetRecordTests.swift` (full rewrite)
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetDefaultsTests.swift:23-30`, `:32-75`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetSnapshotTests.swift:21-35`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLibrarySourceTests.swift:68`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetTileTextTests.swift:25`

**Interfaces:**
- Consumes: Task 2's `WatchWidgetMirror` (no `mirrorLive`, `reloadIfNeeded` without `immediate`).
- Produces:
  - `WatchWidgetRecord` with `var library: WatchWidgetSnapshot?`, `init(library: WatchWidgetSnapshot? = nil)`, and `accepting(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecord?`. `WatchWidgetRecords`, `resolved(now:)`, `merged(live:library:)`, `acceptingLive`, `acceptingLibrary`, `evictingStaleLive`, and `liveExpiry` are all gone.
  - `WatchWidgetMirror.mirrorLibrary(rows:moveCount:container:now:)` — `libraryIsAuthoritative` is gone with the eviction pass it guarded.
  - `WatchWidgetSnapshot` without `Source` or `source`; its memberwise init is `init(gameID:name:comment:parkedIndex:mainlineMoveCount:scoreLeadBlack:isBranch:capturedAt:)`.
  - `WatchWidgetDefaults.read(from:) -> WatchWidgetRecord` and `write(_:to:) -> Bool` taking a `WatchWidgetRecord`.

- [ ] **Step 1: Write the failing tests for the collapsed record**

Genuine red phase: the decode-compatibility behavior is new. Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRecordTests.swift`:

```swift
//
//  WatchWidgetRecordTests.swift
//  KataGo AnytimeTests
//
//  The one record the complication renders, and when it is worth writing.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetRecordTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(gameID: String = "GAME-A",
                          name: String = "Ladder Fight 3",
                          parkedIndex: Int = 10,
                          comment: String? = nil,
                          score: Double? = 1.5,
                          at offset: TimeInterval = 0) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: gameID, name: name, comment: comment,
                            parkedIndex: parkedIndex, mainlineMoveCount: 178,
                            scoreLeadBlack: score, isBranch: false,
                            capturedAt: t0.addingTimeInterval(offset))
    }

    @Test func anEmptyRecordHoldsNothing() {
        #expect(WatchWidgetRecord().library == nil)
    }

    @Test func anUnchangedCandidateIsRejectedSoNothingIsWritten() {
        // A CloudKit refresh burst must not rewrite an identical record once
        // per notification.
        let stored = WatchWidgetRecord(library: snapshot(at: 0))
        #expect(stored.accepting(snapshot(at: 600)) == nil)
    }

    @Test func aChangedCandidateIsAccepted() {
        let stored = WatchWidgetRecord(library: snapshot(comment: nil, at: 0))
        let updated = stored.accepting(snapshot(comment: "New note.", at: 600))
        #expect(updated?.library?.comment == "New note.")
    }

    @Test func theFirstRecordIsAlwaysAccepted() {
        #expect(WatchWidgetRecord().accepting(snapshot())?.library != nil)
    }

    @Test func thereIsNoMonotonicGuard() {
        // There is exactly one writer, serialized on the main actor, so an
        // out-of-order write cannot occur — and an older-clocked but DIFFERENT
        // record must still land, because a game edited on another device can
        // legitimately carry an earlier timestamp.
        let stored = WatchWidgetRecord(library: snapshot(at: 600))
        #expect(stored.accepting(snapshot(gameID: "GAME-B", at: 0))?.library?.gameID == "GAME-B")
    }

    /// The App-Group blob written by the previous two-mirror build must still
    /// yield its library half. `JSONDecoder` ignores the now-unknown "live"
    /// key, so this costs nothing at the process boundary — but it is the only
    /// thing standing between an update and a blank tile, so it is pinned.
    @Test func aTwoMirrorBlobStillDecodesItsLibraryHalf() throws {
        let legacy = """
        {"live":{"gameID":"OLD","name":"Old","parkedIndex":1,\
        "mainlineMoveCount":2,"isBranch":false,"capturedAt":0,"source":"live"},\
        "library":{"gameID":"GAME-A","name":"Ladder Fight 3","parkedIndex":10,\
        "mainlineMoveCount":178,"scoreLeadBlack":1.5,"isBranch":false,\
        "capturedAt":1000000,"source":"library"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(WatchWidgetRecord.self,
                                        from: Data(legacy.utf8))
        #expect(record.library?.gameID == "GAME-A")
        #expect(record.library?.parkedIndex == 10)
    }
}
```

Then delete the old test file and register the new one:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
trash "KataGo iOSTests/WatchWidgetRecordsTests.swift"
ruby remove_files_from_xcodeproj.rb WatchWidgetRecordsTests.swift
ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open(File.join(Dir.pwd, "KataGo Anytime.xcodeproj"))
target = project.targets.find { |t| t.name == "KataGo AnytimeTests" } or abort("no test target")
group = project.main_group.find_subpath("KataGo iOSTests", true)
ref = group.new_reference("KataGo iOSTests/WatchWidgetRecordTests.swift")
target.source_build_phase.add_file_reference(ref)
project.save
puts "Added WatchWidgetRecordTests.swift"
'
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetRecordTests" \
  2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)" | head -20
```

Expected: `cannot find 'WatchWidgetRecord' in scope`, and `missing argument for parameter 'source'`.

- [ ] **Step 3: Create the collapsed record type**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git mv "KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRecords.swift" \
       "KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRecord.swift"
```

Replace its whole contents with:

```swift
//
//  WatchWidgetRecord.swift
//  KataGoAnalysisKit
//
//  What the complication renders, behind one App-Group key.
//
//  This used to hold two mirrors — one fed by the phone's WatchConnectivity
//  frames, one by the watch's own CloudKit library — with a resolution rule, a
//  per-field merge, a 24-hour expiry ceiling and an eviction pass. The phone
//  channel is gone, so all of that machinery served a contrast that no longer
//  exists and has been deleted with it.
//

import Foundation

public struct WatchWidgetRecord: Codable, Equatable, Sendable {
    /// From the newest row of the watch's own CloudKit-synced library.
    ///
    /// The property name is also the JSON key, and it is deliberately
    /// unchanged: an App-Group blob written by the previous two-mirror build
    /// decodes cleanly here because `JSONDecoder` ignores the now-unknown
    /// "live" key. Renaming this property (without `CodingKeys`) would blank
    /// every tile until the watch app next ran. Pinned by
    /// `WatchWidgetRecordTests.aTwoMirrorBlobStillDecodesItsLibraryHalf`.
    public var library: WatchWidgetSnapshot?

    public init(library: WatchWidgetSnapshot? = nil) {
        self.library = library
    }

    /// The updated record if `candidate` is worth storing, else nil so the
    /// caller skips the encode and the `UserDefaults` write entirely.
    ///
    /// An unchanged `contentKey` means nothing the tile shows has moved, so
    /// the stored `capturedAt` is preserved rather than refreshed. There is no
    /// monotonicity guard: exactly one writer exists and it is serialized on
    /// the main actor, and a game edited on another device can legitimately
    /// arrive with an earlier timestamp.
    public func accepting(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecord? {
        if let library, library.contentKey == candidate.contentKey { return nil }
        return WatchWidgetRecord(library: candidate)
    }
}
```

- [ ] **Step 4: Drop `Source` from `WatchWidgetSnapshot`**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetSnapshot.swift`:

Delete lines 20–26 (the `Source` enum and its doc comment), line 51 (`public var source: Source`), the `source` parameter on line 56, and the assignment on line 65. The initializer becomes:

```swift
    public init(gameID: String, name: String, comment: String?,
                parkedIndex: Int, mainlineMoveCount: Int,
                scoreLeadBlack: Double?, isBranch: Bool,
                capturedAt: Date) {
        self.gameID = gameID
        self.name = name
        self.comment = comment
        self.parkedIndex = parkedIndex
        self.mainlineMoveCount = mainlineMoveCount
        self.scoreLeadBlack = scoreLeadBlack
        self.isBranch = isBranch
        self.capturedAt = capturedAt
    }
```

Update `capturedAt`'s doc comment (lines 45–50), which references two records:

```swift
    /// Watch-observed time at which `contentKey` last changed — deliberately
    /// not `lastModificationDate`, which is another device's clock and does
    /// not move when only a comment changes.
    public var capturedAt: Date
```

And the first paragraph of `contentKey`'s doc comment (lines 68–72):

```swift
    /// Identity of what the tile would DISPLAY. Excludes `capturedAt` so an
    /// unchanged position produces an unchanged key: the writer skips the
    /// encode and the `UserDefaults` write entirely on a match.
```

Everything from "The score is rounded to a tenth" onward stays verbatim, except delete the sentence "so this does NOT stop the key from changing on most frames while analysis is live —" and its surrounding clause; that paragraph becomes:

```swift
    /// The score is rounded to a tenth as an Int rather than formatted.
    /// Rounding collapses sub-tenth differences the tile would not render
    /// anyway, and makes +0.0 / -0.0 produce the same key instead of two
    /// different ones for the same lead.
```

The `contentKey` body itself is unchanged.

- [ ] **Step 5: Update `WatchWidgetDefaults` to the new type**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetDefaults.swift`, replace the file header (lines 5–18) with:

```swift
//  The watch-local IPC channel between the watch app and its complication.
//
//  App Group containers are PER-DEVICE. `group.chinchangyang.KataGo-iOS.tw` is
//  entitled on both the iPhone and the watch, which reads as one shared
//  container but is not: nothing the iPhone writes there is visible to the
//  watch widget. The watch app is therefore the only possible writer — which,
//  now that the phone has no WatchConnectivity channel to the watch either, is
//  also the only writer there is.
//
//  Note also that on watchOS the SwiftData store deliberately does NOT use
//  this group (see SharedModelContainer's CloudKit-only branch), so this is
//  the ONLY channel the complication has.
```

Then change the two accessors' types (lines 50–64):

```swift
    public static func read(from defaults: UserDefaults?) -> WatchWidgetRecord {
        guard let data = defaults?.data(forKey: recordsKey),
              let record = try? decoder.decode(WatchWidgetRecord.self, from: data)
        else { return WatchWidgetRecord() }
        return record
    }

    /// Returns false when the write could not happen (no App Group, or an
    /// encode failure), so callers do not record a reload they never earned.
    @discardableResult
    public static func write(_ record: WatchWidgetRecord, to defaults: UserDefaults?) -> Bool {
        guard let defaults, let data = try? encoder.encode(record) else { return false }
        defaults.set(data, forKey: recordsKey)
        return true
    }
```

Update `widgetKind`'s doc comment (lines 27–35) — its second reason no longer applies:

```swift
    /// The widget's `kind`, and the argument to `reloadTimelines(ofKind:)`.
    ///
    /// Deliberately still the old identifier. Renaming it would drop every
    /// placement testers have already made — they would see an empty slot, not
    /// a renamed tile. Hoisted here so the app-side and widget-side constants
    /// cannot drift apart.
```

Finally, the coder comment at lines 80–83 references `WatchSnapshot`, which no longer exists:

```swift
    // `secondsSince1970` on both sides. `capturedAt` ordering is load-bearing,
    // and the default strategy would encode a Double reference-date offset —
    // fine in isolation, but this is a cross-process boundary and an explicit
    // strategy is what keeps both sides pinned to the same one.
```

- [ ] **Step 6: Drop the `source:` argument from the library source**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLibrarySource.swift`, delete the `source: .library` argument on line 88 (and the trailing comma on the line above it).

- [ ] **Step 7: Simplify `WatchWidgetMirror` and its one caller**

`evictingStaleLive` swept a `.live` record whose game had been deleted; there is no `.live` record any more, so the pass and the `libraryIsAuthoritative` flag that guarded it both go. In `ios/KataGo iOS/KataGo Anytime Watch/WatchWidgetMirror.swift`, replace `mirrorLibrary` in full with:

```swift
    /// Refresh the stored record from the newest row of the library.
    ///
    /// The extras fetch below runs on every call that has a newest row —
    /// there is deliberately no memo keyed on `(id, lastModified)` to skip it
    /// when the row "hasn't moved". Such a memo was tried and removed: a
    /// `GameRecord`'s `lastModificationDate` does NOT advance when only its
    /// comment changes (`CommentPersistence.store` and Deep Report's
    /// copy-to-comment both mutate `comments` without touching it — see the
    /// note on `WatchWidgetSnapshot.capturedAt`), so an id/lastModified memo
    /// would silently swallow every comment-only edit until the watch app
    /// next relaunched — defeating this feature's headline behavior. Re-doing
    /// the fetch every time is safe and cheap instead: it is one row with
    /// four properties (`fetchLimit = 1`, narrow `propertiesToFetch`), the
    /// resulting write is already content-gated by `WatchWidgetRecord.accepting`
    /// (an unchanged `contentKey` produces no `UserDefaults` write and no
    /// timeline reload), and the burst this would otherwise guard against —
    /// CloudKit's initial-sync storm — is already damped upstream by
    /// `WatchLibraryStore`'s `CoalescedTrigger`.
    func mirrorLibrary(rows: [WatchLibraryRow],
                       moveCount: (WatchLibraryRow) -> Int,
                       container: ModelContainer,
                       now: Date = Date()) {
        // A row with no lastModified has no honest ordering, so it is not
        // mirrored at all (the repo contains an 1846-dated sample record
        // shaped exactly like one).
        guard let row = rows.first, row.lastModified != nil,
              let extras = WatchWidgetLibrarySource.extras(gameID: row.id,
                                                           container: container) else { return }
        let candidate = WatchWidgetLibrarySource.snapshot(
            row: row, moveCount: moveCount(row), extras: extras, capturedAt: now)
        let stored = WatchWidgetDefaults.read(from: defaults)
        guard let updated = stored.accepting(candidate),
              WatchWidgetDefaults.write(updated, to: defaults) else { return }
        reloadIfNeeded(updated, now: now)
    }
```

and retype `reloadIfNeeded`:

```swift
    private func reloadIfNeeded(_ record: WatchWidgetRecord, now: Date) {
        let key = record.library?.contentKey ?? ""
        let elapsed = now.timeIntervalSince(lastReloadAt ?? .distantPast)
        guard WatchWidgetRefreshPolicy.shouldReload(previousKey: lastReloadKey,
                                                    nextKey: key,
                                                    elapsed: elapsed) else { return }
        lastReloadKey = key
        lastReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetDefaults.widgetKind)
    }
```

Then drop the now-removed argument at the call site in `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`, so the `onRefresh` block reads:

```swift
            library.onRefresh = { [weak library] in
                guard let library else { return }
                widgetMirror.mirrorLibrary(
                    rows: library.rows,
                    moveCount: { library.moveCount(for: $0) },
                    container: container)
            }
```

- [ ] **Step 8: Update the widget**

In `ios/KataGo iOS/KataGoAnytimeWatchWidget/LastGameWidget.swift`:

Replace `LastGameProvider.read` (lines 32–40):

```swift
    private func read(at date: Date) -> LastGameEntry {
        let defaults = WatchWidgetDefaults.sharedDefaults()
        return LastGameEntry(date: date,
                             snapshot: WatchWidgetDefaults.read(from: defaults).library,
                             storageAvailable: defaults != nil,
                             legacyScoreLeadBlack:
                                WatchWidgetDefaults.legacyScoreLeadBlack(from: defaults))
    }
```

Replace `metaLine` (lines 207–228). The glyph distinguished a live record from a library one; there is only one kind now, so an always-`icloud` icon would carry zero information:

```swift
    @ViewBuilder private var metaLine: some View {
        if let snapshot = entry.snapshot {
            // No relative-date Text here, deliberately. One reserved width
            // for the widest value it could EVER show — not the value it
            // is showing — and it squeezed this row's only real content
            // down to a bare "Move…" at every size, 46mm included. The
            // move number is the position identity the tile exists to
            // name, so the age is what leaves. Cost, recorded honestly:
            // the tile no longer self-reports staleness between reloads.
            Text(WatchWidgetTileText.moveText(parkedIndex: snapshot.parkedIndex,
                                              mainlineMoveCount: snapshot.mainlineMoveCount,
                                              isBranch: snapshot.isBranch))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
```

Then delete every `source:` argument from the five `WatchWidgetSnapshot(...)` literals: line 49 (`placeholder`) and lines 285, 296, 314, 325 (the previews). In each, the preceding argument becomes the last one — e.g. line 48–49 becomes:

```swift
                        scoreLeadBlack: 3.5, isBranch: false,
                        capturedAt: .now),
```

- [ ] **Step 9: Update the four remaining widget test files**

`WatchWidgetSnapshotTests.swift` — delete `source: .live` from the `sample` helper (line 24) and rewrite the first test (lines 29–35), whose subject was partly the `source` field:

```swift
    @Test func theKeyIgnoresCapturedAt() {
        // Otherwise a re-read of an unchanged record would look like a change
        // and the writer would encode + write to cfprefsd for nothing.
        let other = sample(capturedAt: Date(timeIntervalSince1970: 9_999))
        #expect(sample().contentKey == other.contentKey)
    }
```

`WatchWidgetDefaultsTests.swift` — delete `source: .live` from `sample` (line 29) and rewrite lines 32–75:

```swift
    @Test func anEmptySuiteReadsAsAnEmptyRecordNotACrash() {
        withSuite { defaults in
            #expect(WatchWidgetDefaults.read(from: defaults).library == nil)
        }
    }

    @Test func aNilSuiteReadsAsAnEmptyRecord() {
        // `UserDefaults(suiteName:)` returns nil when the App Group is
        // unavailable; the widget must render a distinct state, not crash.
        #expect(WatchWidgetDefaults.read(from: nil).library == nil)
    }

    @Test func theRecordRoundTripsThroughTheSuite() {
        withSuite { defaults in
            let written = WatchWidgetRecord(library: sample)
            #expect(WatchWidgetDefaults.write(written, to: defaults))
            #expect(WatchWidgetDefaults.read(from: defaults) == written)
        }
    }

    @Test func datesSurviveTheRoundTripToTheSecond() {
        // The encoder pins secondsSince1970; a default strategy change here
        // would silently break `capturedAt` ordering.
        withSuite { defaults in
            WatchWidgetDefaults.write(WatchWidgetRecord(library: sample), to: defaults)
            #expect(WatchWidgetDefaults.read(from: defaults).library?.capturedAt
                    == sample.capturedAt)
        }
    }

    @Test func writingToANilSuiteFailsLoudlyRatherThanSilently() {
        #expect(!WatchWidgetDefaults.write(WatchWidgetRecord(library: sample), to: nil))
    }

    @Test func corruptDataReadsAsAnEmptyRecord() {
        withSuite { defaults in
            defaults.set(Data([0x00, 0x01]), forKey: WatchWidgetDefaults.recordsKey)
            #expect(WatchWidgetDefaults.read(from: defaults).library == nil)
        }
    }
```

Also rewrite the last test's comment (lines 110–113), which cites the deleted push gate:

```swift
    @Test func theWidgetKindIsTheLegacyIdentifier() {
        // Renaming it would orphan every placement testers have already made.
        #expect(WatchWidgetDefaults.widgetKind == "ScoreLeadWidget")
    }
```

`WatchWidgetLibrarySourceTests.swift` — delete line 68 (`#expect(snapshot.source == .library)`).

`WatchWidgetTileTextTests.swift` — delete `source: .live` from line 25.

- [ ] **Step 10: Run the full iOS test suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)|Executed .* tests"
```

Expected: `** TEST SUCCEEDED **`, zero failures, including the new `WatchWidgetRecordTests` (green phase for Step 1).

- [ ] **Step 11: Build the watch scheme on its own**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **` with **zero warnings** — the watch target has historically been warning-free and must stay that way.

- [ ] **Step 12: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A
git commit -m "$(cat <<'EOF'
refactor(watch): collapse the complication to a single record

WatchWidgetRecords held two mirrors with a resolution rule, a per-field
merge, a 24-hour expiry and an eviction pass; only one mirror can exist
now. The envelope shape and the watchWidget.records key are unchanged, so
a blob written by the two-mirror build still decodes its library half —
pinned by a test, because the alternative is a blank tile after update.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Documentation and the full verification sweep

**Files:**
- Modify: `ios/KataGo iOS/README.md:17`, `:22`, `:194-200`
- Modify: `CLAUDE.md` (the watchOS paragraph in Build Commands; the Platform Support line)

**Interfaces:**
- Consumes: the finished state of Tasks 1–4.
- Produces: nothing code-facing.

- [ ] **Step 1: Update the README scheme table**

In `ios/KataGo iOS/README.md`, line 17, replace the watchOS row's description:

```markdown
| watchOS 26+ | `KataGo Anytime Watch` | Standalone read-only game library, synced over iCloud |
```

- [ ] **Step 2: Update the README feature bullet**

Line 22 currently promises a live score. Replace it with:

```markdown
- A **Last Game complication** on Apple Watch shows the name and comment at the position your last game is parked on.
```

- [ ] **Step 3: Rewrite the README's Apple Watch section**

Replace lines 194–200 with:

```markdown
## KataGo Anytime on Apple Watch

The Watch app is a standalone reader for your game library:

- Your **saved games**, synced over iCloud, listed newest first.
- Open one and **scrub its moves with the Digital Crown**. Boards are replayed on the watch from the game's own SGF, so every position is available — not only the ones another device happened to visit.
- A **Review page** per position: win rate, score, the engine's best move, and any commentary the game already had saved. The watch runs no engine and computes nothing.
- A **Last Game complication** (inline, circular, and rectangular) for your watch face. It refreshes while the Watch app is open.

The Watch app does not connect to your iPhone and cannot change a game. Games are created on iPhone, iPad, Mac, Apple TV, or Vision Pro and reach the watch through iCloud.
```

- [ ] **Step 4: Update `CLAUDE.md`**

In the Build Commands section, replace the sentence beginning "There are **five app targets/schemes**…" through "…second, permanently empty store." with a version that no longer claims a companion role. The watchOS clauses become:

```markdown
`KataGo Anytime Watch` (watchOS, a **standalone read-only game library** — it does not use WatchConnectivity and never talks to the iPhone). The watch links `KataGoGameStore` **and** `GoRulesKit` (both bridge-free) and opens `SharedModelContainer.shared` through the CloudKit-only ladder it shares with tvOS — a plain non-App-Group store over the private CloudKit database that degrades to local-only, then in-memory, and never crashes. Board positions on the watch come from replaying `GameRecord.sgf` via `SgfHeaderScan` + `GoRulesKit.SgfReplay`, never from the per-move `blackStones`/`whiteStones` dictionaries, which only cover indices the phone visited. The watch also embeds the **`KataGoAnytimeWatchWidget`** complication (`kind: "ScoreLeadWidget"` — a legacy identifier kept deliberately: renaming it orphans every existing placement; see `WatchWidgetDefaults.widgetKind`). That appex links **only** `KataGoAnalysisKit` (Foundation-only, zero package dependencies) and reads the App-Group key `watchWidget.records`; it must never link `KataGoGameStore` or touch SwiftData, because on watchOS `SharedModelContainer.shared` takes the CloudKit-only branch with no `groupContainer`, so an appex opening it would get a second, permanently empty store. **App Group containers are per-device**: `group.chinchangyang.KataGo-iOS.tw` is entitled on both the iPhone and the watch, but nothing the phone writes there is visible to the watch widget — the App Group is a watch-LOCAL channel between the watch app and its complication, and the watch app is its only writer. Because nothing wakes the watch app in the background any more, the complication refreshes only while that app runs.
```

Then update the Platform Support line:

```markdown
- watchOS 26+ (standalone read-only game library, synced over iCloud; no connection to the iPhone)
```

- [ ] **Step 5: Build all five schemes, strictly one at a time**

The `DerivedData` lock makes concurrent invocations produce spurious failures. Run this as a single sequential script — do not parallelize it, and do not delegate it to a subagent.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
for spec in \
  "KataGo Anytime|platform=iOS Simulator,name=iPhone 17" \
  "KataGo Anytime Mac|platform=macOS" \
  "KataGo Anytime Vision|platform=visionOS Simulator,name=Apple Vision Pro" \
  "KataGo Anytime TV|platform=tvOS Simulator,name=Apple TV" \
  "KataGo Anytime Watch|platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)"
do
  scheme="${spec%%|*}"; dest="${spec##*|}"
  echo "=== $scheme ==="
  xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "$scheme" \
    -destination "$dest" -configuration Debug 2>&1 \
    | grep -E "BUILD (SUCCEEDED|FAILED)|error:" | head -20
done
```

Expected: five `** BUILD SUCCEEDED **` lines, no `error:` lines.

- [ ] **Step 6: Run the iOS test suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
set -o pipefail
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|Executed .* tests|failed"
```

Expected: `** TEST SUCCEEDED **`, zero failures.

- [ ] **Step 7: Run the package tests**

These never run under `xcodebuild` — the Xcode test action does not include the SwiftPM test targets, so skipping this leaves `KataGoUICore`'s own suite unverified.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore"
set -o pipefail
swift test 2>&1 | tail -30
```

Expected: all tests pass. If any test references a deleted type (`WatchSnapshot`, `WatchCommand`, `WatchPeekBuffer`, `WatchSharedCursor`, `WatchWidgetLiveSource`, `WatchWidgetRecords`), delete that test — it pinned removed behavior.

- [ ] **Step 8: Confirm no dangling references remain**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
grep -rn --include="*.swift" \
  "WatchSnapshot\b\|WatchCommand\|WatchPeekBuffer\|WatchSharedCursor\|WatchHostGate\|WatchSessionRelay\|WatchLiveModel\|WatchWidgetLiveSource\|WatchWidgetRecords\|WatchStoredGameView\|mirrorLive\|shouldPush\|opensLiveMirror\|launchRoute" \
  . | grep -v "^./DerivedData"
```

Expected: **no output.** Any hit outside `DerivedData` is a leftover reference — usually inside a doc comment that outlived its subject. Fix it rather than ignoring it; a comment describing a deleted system is exactly what sends the next reader hunting.

```bash
grep -rn "WatchConnectivity" --include="*.swift" . | grep -v "^./DerivedData"
```

Expected: **no output.**

- [ ] **Step 9: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A
git commit -m "$(cat <<'EOF'
docs: the Watch app is a standalone library, not a companion

README and CLAUDE.md both described a live mirror with remote control and
a score-lead complication. None of that is true any more: the watch reads
its own iCloud-synced library, replays boards from SGF, and refreshes its
Last Game tile only while it is running.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## On-Wrist QA (after the plan, before pushing to TestFlight)

The watch target has **no test bundle**, so nothing above covers the watch app's own code. These are the checks automation cannot make:

1. **Launch.** The app opens straight to a list titled "Games", newest first — never to a board, never to an empty top section where the live row used to be.
2. **Open and scrub.** Tapping a game replays it; the Crown moves through moves; the title flips between the counter and the game's name.
3. **Complication after update.** The existing tile placement survives (its `kind` is unchanged) and still renders the last game's name and comment — this is what the decode-compatibility test predicts, verified for real.
4. **Complication tap.** Tapping the tile cold-launches the app and lands on the named game, not on "Game not found".
5. **Complication lag.** Confirm the accepted cost: play moves on the phone, leave the watch app closed, and observe that the tile does not change until the watch app is opened.
6. **Phone with the watch nearby.** Play a game on the iPhone and confirm nothing on the watch reacts, and that the phone shows no rejection or connectivity UI.

## Rollout

Ship both sides together in one build. During the multi-day window where a tester's watch app has not yet updated, an old watch build renders a frozen live row titled `Offline` and its commands fail with a red banner; a new watch build simply ignores an old phone's pushes. Both are cosmetic and self-heal on the next watch update. Do not add a compatibility shim — this is TestFlight with disposable tester data and a standing policy of skipping back-compat.
