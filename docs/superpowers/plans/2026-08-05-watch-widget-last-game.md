# Apple Watch Last-Game Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the watch's score-only complication with a tile that shows the name and the comment of the last position in the last game.

**Architecture:** Two writers in the watch app process mirror a small `WatchWidgetSnapshot` into one App-Group `UserDefaults` key — one from the live WatchConnectivity frame, one from the newest row of the watch's CloudKit library. The widget extension decodes both and merges them per field. All decision logic is Foundation-only code in `KataGoAnalysisKit` so the iOS test bundle can cover it; the widget appex links only that light product and never touches SwiftData.

**Tech Stack:** Swift 6, SwiftUI, WidgetKit, WatchConnectivity, SwiftData (watch app only), Swift Testing, Xcode 26.5.

**Spec:** `docs/superpowers/specs/2026-08-05-watch-widget-last-game-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Platform floors:** iOS 26+, macOS 26+, visionOS 26+, watchOS 26+.
- **The widget appex contains ZERO SwiftData/CoreData.** On watchOS `SharedModelContainer.shared` takes the CloudKit-only branch with no `groupContainer`; an appex touching it would open a second, permanently empty store.
- **The widget target links `KataGoAnalysisKit` only** — never `KataGoGameStore`, `KataGoUICore`, or `GoRulesKit`.
- **No `#if os(watchOS)` in any new package code.** `KataGo AnytimeTests` runs on the iOS Simulator; platform-guarded package code is not compiled by it and is therefore silently uncovered.
- **`WidgetCenter` never appears in the package.** It lives in the watch app target and the widget target only. `KataGoGameStore` compiles for tvOS, which has no WidgetKit.
- **The widget `kind` stays `"ScoreLeadWidget"`.** Renaming orphans every existing placement and flips `WCSession.isComplicationEnabled` to false, silently disabling the phone push.
- **App-Group id:** `group.chinchangyang.KataGo-iOS.tw`. It is **watch-local** — the iPhone cannot write the watch's copy. All App-Group writers live in the watch app process.
- **English-only committed source.** This covers source and code comments, not rendered user content (imported SGF comments are routinely CJK and must pass through untouched).
- **ASCII separators in user-facing strings.** Follow `WatchLibraryRow.sizeText`'s rule ("ASCII only — not worth the encoding risk"): use `" - "`, not a typographic middot. This supersedes the middot shown in the spec's mockups.
- **Never run two `xcodebuild` invocations at once** — concurrent DerivedData locks produce spurious `TEST FAILED`.
- **A piped `xcodebuild` exit code lies.** Always grep for `BUILD SUCCEEDED` / `BUILD FAILED` / `TEST SUCCEEDED` / `TEST FAILED`.
- **Project dir for all commands:** `/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS`.
- **Test target name is `KataGo AnytimeTests`**; its source folder is `KataGo iOSTests/`.
- New files under `KataGoUICore/Sources/` are auto-discovered by SwiftPM — do **not** register them in the pbxproj. New files under `KataGo iOSTests/`, `KataGo Anytime Watch/`, and `KataGoAnytimeWatchWidget/` **must** be registered via `ruby scripts_add_swift_files.rb "<target>" <paths>`.

---

## File Structure

**New — `KataGoUICore/Sources/KataGoAnalysisKit/`** (Foundation-only, no platform guards):

| File | Responsibility |
|---|---|
| `WatchWidgetSnapshot.swift` | The record type, its content key, and the grapheme comment cap |
| `WatchWidgetRecords.swift` | The two-record envelope, the per-field merge, and stale-live eviction |
| `WatchWidgetRefreshPolicy.swift` | Write / reload / push gating and the timeline refresh interval |
| `WatchWidgetDefaults.swift` | App-Group key constants, encode/decode, legacy-key fallback and cleanup |
| `WatchWidgetTileText.swift` | Layout choice and every user-facing string the tile renders |

**New — `KataGoUICore/Sources/KataGoGameStore/`:**

| File | Responsibility |
|---|---|
| `CommentPersistence.swift` | The single place a comment pane's text becomes part of a `GameRecord` |
| `WatchWidgetLibrarySource.swift` | `@MainActor` bounded fetch turning the newest library row into a `.library` record |

**New — watch app / widget targets:**

| File | Responsibility |
|---|---|
| `KataGo Anytime Watch/WatchWidgetMirror.swift` | Owns both App-Group writes, the reload floor, and `WidgetCenter` |
| `KataGoAnytimeWatchWidget/LastGameWidget.swift` | Provider + the three family renditions (replaces `ScoreLeadWidget.swift`) |

**Modified:** `CommentView.swift`, `WatchSnapshot.swift`, `WatchSnapshotBuilder.swift`, `WatchNavigationPolicy.swift`, `WatchLibraryStore.swift`, `WatchLiveModel.swift`, `KataGoAnytimeWatchApp.swift`, `WatchRootView.swift`, `WatchLibraryPage.swift`, `WatchSessionRelay.swift`, `KataGoAnytimeWatchWidgetBundle.swift`, `KataGoAnytimeWatchWidget/Info.plist`, the pbxproj, and `CLAUDE.md`.

---

## Task 1: Comment persistence seam (slice 0)

A generated comment currently lives only in `CommentView`'s `@State` until the pane disappears, so every reader of `GameRecord.comments` — including this whole feature — sees blank or stale text for the position the user just commented on. This routes all four write sites through one tested function and adds the two missing ones.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/CommentPersistence.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/CommentView.swift:84-100,110-128`
- Test: `ios/KataGo iOS/KataGo iOSTests/CommentPersistenceTests.swift`

**Interfaces:**
- Consumes: `GameRecord` (existing `@Model`, `comments: [Int: String]?`)
- Produces: `CommentPersistence.store(_ text: String, at index: Int, in record: GameRecord)`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/CommentPersistenceTests.swift`:

```swift
//
//  CommentPersistenceTests.swift
//  KataGo AnytimeTests
//
//  The one place a comment pane's text becomes part of the record. Every
//  reader of GameRecord.comments — the watch widget included — depends on
//  this being called, so it is worth pinning on its own.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct CommentPersistenceTests {
    // `config:` has no default on GameRecord's initializer, and `comments:`
    // follows it in the declaration order — the same shape GameEntityQueryTests
    // uses.
    @Test func storesTheTextAtTheGivenIndex() {
        let record = GameRecord(config: Config(), comments: [:])
        CommentPersistence.store("A quiet opening.", at: 7, in: record)
        #expect(record.comments?[7] == "A quiet opening.")
    }

    @Test func createsTheDictionaryWhenItIsNil() {
        // An imported or CloudKit-arrived record can carry a nil dictionary;
        // storing into it must not silently drop the text.
        let record = GameRecord(config: Config(), comments: nil)
        CommentPersistence.store("First note", at: 0, in: record)
        #expect(record.comments?[0] == "First note")
    }

    @Test func overwritesAnExistingCommentAtThatIndex() {
        let record = GameRecord(config: Config(), comments: [3: "old"])
        CommentPersistence.store("new", at: 3, in: record)
        #expect(record.comments?[3] == "new")
        #expect(record.comments?.count == 1)
    }

    @Test func leavesOtherIndicesAlone() {
        let record = GameRecord(config: Config(), comments: [1: "one", 2: "two"])
        CommentPersistence.store("three", at: 3, in: record)
        #expect(record.comments?[1] == "one")
        #expect(record.comments?[2] == "two")
        #expect(record.comments?[3] == "three")
    }

    @Test func storesCjkTextUnchanged() {
        // Imported SGFs routinely carry non-Latin commentary; nothing here may
        // normalize, filter, or transcode it.
        let record = GameRecord(config: Config(), comments: [:])
        let text = "\u{5B9A}\u{77F3}\u{306E}\u{5909}\u{5316}"
        CommentPersistence.store(text, at: 0, in: record)
        #expect(record.comments?[0] == text)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/CommentPersistenceTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/CommentPersistenceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'CommentPersistence' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/CommentPersistence.swift`:

```swift
//
//  CommentPersistence.swift
//  KataGoGameStore
//
//  The single place a comment pane's text becomes part of the record.
//
//  CommentView holds its text in @State and used to flush it only when the
//  pane disappeared or the move index changed, so a freshly generated comment
//  was invisible to every other reader — the watch widget, the iOS widget,
//  Shortcuts — until the user navigated away. Routing all four write sites
//  through one function makes "when is a comment real?" a single, testable
//  question rather than four inline assignments in a view.
//

import Foundation

public enum CommentPersistence {
    /// Write `text` as the record's comment at `index`, creating the
    /// dictionary if the record arrived without one. The text is stored
    /// verbatim: it is user content, which may be in any script, and callers
    /// that care about blank comments (`WatchStoredAnalysis.at`) already trim.
    public static func store(_ text: String, at index: Int, in record: GameRecord) {
        if record.comments == nil { record.comments = [:] }
        record.comments?[index] = text
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/CommentPersistenceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Route CommentView's existing write sites through it**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/CommentView.swift`, replace the `.onChange(of: gameRecord.currentIndex)` and `.onDisappear` bodies (lines 84-100):

```swift
            .onChange(of: gameRecord.currentIndex) { oldIndex, newIndex in
                if oldIndex != newIndex {
                    CommentPersistence.store(comment, at: oldIndex, in: gameRecord)
                    comment = gameRecord.comments?[newIndex] ?? ""
                }
            }
            .onChange(of: gameRecord.comments?[gameRecord.currentIndex]) { _, newValue in
                // External writers (e.g. the Deep Report's Copy to Comment)
                // update the record directly; without this re-sync the pane's
                // stale @State would clobber their text on the next save.
                if let newValue, newValue != comment {
                    comment = newValue
                }
            }
            // Flush while the pane is still on screen. `.task(id:)` IS the
            // debounce: SwiftUI cancels the running task on every keystroke, so
            // the countdown restarts and only completes once typing stops.
            // Without this the record — and therefore the watch widget, the iOS
            // widget, and Shortcuts — would not see a comment until the pane
            // disappeared.
            .task(id: comment) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                CommentPersistence.store(comment, at: gameRecord.currentIndex, in: gameRecord)
            }
            .onDisappear {
                CommentPersistence.store(comment, at: gameRecord.currentIndex, in: gameRecord)
            }
```

- [ ] **Step 6: Persist a generated comment at generation time**

In the same file, replace the two assignments in `wandAndSparklesAction()` (lines 122-128):

```swift
        if let useLLM = gameRecord.config?.useLLM, useLLM {
            isGenerating = true
            comment = await commentator?.generateImprovedComment() ?? ""
            isGenerating = false
        } else {
            comment = commentator?.generateNaturalComment() ?? ""
        }
        // Generation finishes in one shot, so persist immediately rather than
        // waiting out the typing debounce: the whole point of the button is
        // that the text is now real.
        CommentPersistence.store(comment, at: gameRecord.currentIndex, in: gameRecord)
```

- [ ] **Step 7: Build the iOS app to verify the view still compiles**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/CommentPersistence.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/CommentView.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CommentPersistenceTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "fix(comment): persist a comment when it is generated, not when the pane closes"
```

---

## Task 2: `WatchWidgetSnapshot`, its content key, and the comment cap (slice 1)

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetSnapshot.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing (Foundation only)
- Produces:
  - `struct WatchWidgetSnapshot: Codable, Equatable, Sendable` with `gameID: String`, `name: String`, `comment: String?`, `parkedIndex: Int`, `mainlineMoveCount: Int`, `scoreLeadBlack: Double?`, `isBranch: Bool`, `capturedAt: Date`, `source: Source`
  - `enum WatchWidgetSnapshot.Source: String, Codable, Sendable { case live, library }`
  - `var contentKey: String`
  - `static func cappedComment(_ text: String?) -> String?`
  - `static let commentCharacterLimit = 256`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetSnapshotTests.swift`:

```swift
//
//  WatchWidgetSnapshotTests.swift
//  KataGo AnytimeTests
//
//  The record the watch complication renders, and the content key that
//  decides when it is worth writing at all.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetSnapshotTests {
    private func sample(comment: String? = "White cuts.",
                        parkedIndex: Int = 42,
                        score: Double? = 3.5,
                        capturedAt: Date = Date(timeIntervalSince1970: 1_000)) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: "GAME-A", name: "Ladder Fight 3",
                            comment: comment, parkedIndex: parkedIndex,
                            mainlineMoveCount: 178, scoreLeadBlack: score,
                            isBranch: false, capturedAt: capturedAt, source: .live)
    }

    // MARK: content key

    @Test func theKeyIgnoresCapturedAtAndSource() {
        // Otherwise every 2 Hz frame would look like a change and the writer
        // would encode + write to cfprefsd twice a second on watch hardware.
        var other = sample(capturedAt: Date(timeIntervalSince1970: 9_999))
        other.source = .library
        #expect(sample().contentKey == other.contentKey)
    }

    @Test func theKeyChangesWithTheComment() {
        #expect(sample().contentKey != sample(comment: "Black lives.").contentKey)
    }

    @Test func theKeyChangesWithTheParkedIndex() {
        #expect(sample().contentKey != sample(parkedIndex: 43).contentKey)
    }

    @Test func theKeyRoundsTheScoreToATenthOfAPoint() {
        // Analysis jitter must not churn the key, but a real half-point swing
        // must be visible.
        #expect(sample(score: 3.52).contentKey == sample(score: 3.54).contentKey)
        #expect(sample(score: 3.5).contentKey != sample(score: 4.0).contentKey)
    }

    @Test func theKeyTreatsPlusAndMinusZeroAsTheSameScore() {
        // A signed-zero formatter would emit "0.0" and "-0.0" and flap the key
        // every time the lead crossed even.
        #expect(sample(score: 0.02).contentKey == sample(score: -0.02).contentKey)
    }

    @Test func aMissingScoreIsNotTheSameAsZero() {
        #expect(sample(score: nil).contentKey != sample(score: 0).contentKey)
    }

    // MARK: comment cap

    @Test func aShortCommentPassesThroughUntouched() {
        #expect(WatchWidgetSnapshot.cappedComment("Short.") == "Short.")
    }

    @Test func aBlankCommentBecomesNil() {
        // An absent comment must be HIDDEN, not rendered as an empty region.
        #expect(WatchWidgetSnapshot.cappedComment("   \n ") == nil)
        #expect(WatchWidgetSnapshot.cappedComment(nil) == nil)
    }

    @Test func aLongCommentIsCappedAndEllipsized() {
        let long = String(repeating: "a", count: 400)
        let capped = WatchWidgetSnapshot.cappedComment(long)
        #expect(capped?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
        #expect(capped?.hasSuffix("\u{2026}") == true)
    }

    @Test func theCapCountsGraphemesNotBytes() {
        // Imported SGFs routinely carry CJK commentary; a byte or scalar cap
        // would truncate mid-character and could split a grapheme cluster.
        let cjk = String(repeating: "\u{56F4}\u{68CB}", count: 300)   // 600 characters
        let capped = WatchWidgetSnapshot.cappedComment(cjk)
        #expect(capped?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
    }

    @Test func aMultiScalarGraphemeIsNeverSplit() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"   // one grapheme, 5 scalars
        let text = String(repeating: family, count: 300)
        let capped = WatchWidgetSnapshot.cappedComment(text)
        #expect(capped?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
        // Dropping the trailing ellipsis must leave whole family clusters.
        let body = String(capped!.dropLast())
        #expect(body.unicodeScalars.count == WatchWidgetSnapshot.commentCharacterLimit * 5)
    }

    // MARK: codable

    @Test func itRoundTripsThroughJson() {
        let encoded = try! JSONEncoder().encode(sample())
        let decoded = try! JSONDecoder().decode(WatchWidgetSnapshot.self, from: encoded)
        #expect(decoded == sample())
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchWidgetSnapshotTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetSnapshotTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchWidgetSnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetSnapshot.swift`:

```swift
//
//  WatchWidgetSnapshot.swift
//  KataGoAnalysisKit
//
//  What the watch complication renders: one game, at one position.
//
//  Lives in the Foundation-only tier for two reasons. The watch complication
//  appex must link a product that drags in no SwiftData, CoreData, or
//  AppIntents — a wrist-sized extension has a hard memory ceiling and the iOS
//  widget already has a jetsam scar from exactly that. And the watch target
//  has no test bundle, so every rule spelled out here is only testable because
//  "KataGo AnytimeTests" (iOS Simulator) can compile it. That is also why
//  there is no `#if os(watchOS)` anywhere in this file: guarded code would not
//  be compiled by the only bundle that tests it.
//

import Foundation

public struct WatchWidgetSnapshot: Codable, Equatable, Sendable {
    /// Which mirror wrote this record. Rendered as a one-glyph distinction on
    /// the tile so a tester can tell a stalled push from a stalled reload —
    /// the freshness path's failure modes are otherwise indistinguishable.
    public enum Source: String, Codable, Sendable {
        case live
        case library
    }

    /// Bounds the wire payload, NOT the tile. Fitting text to the rect is
    /// SwiftUI's job; this exists so a Commentator paragraph cannot push the
    /// 2 Hz application context past its 16 KB test bound.
    public static let commentCharacterLimit = 256

    public var gameID: String
    public var name: String
    /// nil means "no comment at this position" and must be rendered as a
    /// different layout, never as an empty region.
    public var comment: String?
    /// Where the game is parked. NOT the end of the mainline, and NOT
    /// `WatchSnapshot.moveNumber` (stones placed, which passes do not advance).
    public var parkedIndex: Int
    public var mainlineMoveCount: Int
    public var scoreLeadBlack: Double?
    /// True while the phone is on a branch. The saved record's comments are
    /// mainline-indexed, so a branch index must not be used to look one up.
    public var isBranch: Bool
    /// Watch-observed time at which `contentKey` last changed — deliberately
    /// not the phone's `hostTimestamp` (a 2 Hz heartbeat) nor
    /// `lastModificationDate` (another device's clock, and unmoved by a
    /// comment edit). One clock governs both records, so they are comparable.
    public var capturedAt: Date
    public var source: Source

    public init(gameID: String, name: String, comment: String?,
                parkedIndex: Int, mainlineMoveCount: Int,
                scoreLeadBlack: Double?, isBranch: Bool,
                capturedAt: Date, source: Source) {
        self.gameID = gameID
        self.name = name
        self.comment = comment
        self.parkedIndex = parkedIndex
        self.mainlineMoveCount = mainlineMoveCount
        self.scoreLeadBlack = scoreLeadBlack
        self.isBranch = isBranch
        self.capturedAt = capturedAt
        self.source = source
    }

    /// Identity of what the tile would DISPLAY. Excludes `capturedAt` and
    /// `source` so an unchanged position produces an unchanged key: the
    /// writers skip the encode and the `UserDefaults` write entirely on a
    /// match, which is what keeps a 2 Hz ingest off cfprefsd.
    ///
    /// The score is rounded to a tenth as an Int rather than formatted, so
    /// analysis jitter does not churn the key and +0.0 / -0.0 cannot produce
    /// two different keys for the same lead.
    public var contentKey: String {
        let score = scoreLeadBlack.map { String(Int(($0 * 10).rounded())) } ?? ""
        return "\(gameID)|\(parkedIndex)|\(name)|\(comment ?? "")|\(score)"
    }

    /// Trim, drop-if-blank, and cap by GRAPHEME count. Never bytes or unicode
    /// scalars: imported SGFs carry CJK and emoji commentary verbatim
    /// (`GameRecord+SGF.swift` copies every `C[]` node), and a scalar cap would
    /// split a cluster. The ellipsis is appended only when truncation actually
    /// happened, so a 256-character comment is not falsely marked as clipped.
    public static func cappedComment(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > commentCharacterLimit else { return trimmed }
        return String(trimmed.prefix(commentCharacterLimit)) + "\u{2026}"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetSnapshotTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetSnapshot.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetSnapshotTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): add WatchWidgetSnapshot with a display-identity content key"
```

---

## Task 3: The two-record envelope, per-field merge, and eviction (slice 1)

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRecords.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRecordsTests.swift`

**Interfaces:**
- Consumes: `WatchWidgetSnapshot` from Task 2
- Produces:
  - `struct WatchWidgetRecords: Codable, Equatable, Sendable { var live: WatchWidgetSnapshot?; var library: WatchWidgetSnapshot? }`
  - `static let liveExpiry: TimeInterval` (24 h)
  - `func resolved(now: Date) -> WatchWidgetSnapshot?`
  - `func evictingStaleLive(libraryIDs: Set<String>, libraryIsAuthoritative: Bool) -> WatchWidgetRecords`
  - `func acceptingLive(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecords?`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRecordsTests.swift`:

```swift
//
//  WatchWidgetRecordsTests.swift
//  KataGo AnytimeTests
//
//  Which of the two mirrors the complication shows, and how they combine when
//  they describe the same game.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetRecordsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ source: WatchWidgetSnapshot.Source,
                        gameID: String = "GAME-A",
                        name: String = "Ladder Fight 3",
                        comment: String? = nil,
                        parkedIndex: Int = 10,
                        score: Double? = 1.5,
                        at offset: TimeInterval = 0) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: gameID, name: name, comment: comment,
                            parkedIndex: parkedIndex, mainlineMoveCount: 178,
                            scoreLeadBlack: score, isBranch: false,
                            capturedAt: t0.addingTimeInterval(offset), source: source)
    }

    // MARK: resolution

    @Test func nothingStoredResolvesToNothing() {
        #expect(WatchWidgetRecords().resolved(now: t0) == nil)
    }

    @Test func aLoneRecordWins() {
        let live = WatchWidgetRecords(live: record(.live), library: nil)
        #expect(live.resolved(now: t0)?.source == .live)
        let library = WatchWidgetRecords(live: nil, library: record(.library))
        #expect(library.resolved(now: t0)?.source == .library)
    }

    @Test func differentGamesResolveToTheNewer() {
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: 60))
        #expect(records.resolved(now: t0.addingTimeInterval(60))?.gameID == "GAME-B")
    }

    @Test func aLiveRecordOlderThanADayLosesToTheLibrary() {
        // A phone left idling on last Tuesday's game must not pin the tile
        // forever once the user has been playing elsewhere.
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: -3_600))
        let now = t0.addingTimeInterval(WatchWidgetRecords.liveExpiry + 1)
        #expect(records.resolved(now: now)?.gameID == "GAME-B")
    }

    @Test func aFreshLiveRecordStillBeatsAnOlderLibraryOne() {
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GAME-A", at: 0),
            library: record(.library, gameID: "GAME-B", at: -3_600))
        #expect(records.resolved(now: t0)?.gameID == "GAME-A")
    }

    // MARK: same-game merge

    @Test func theSameGameMergesRatherThanPicks() {
        // The common case: the phone is parked deep in the game while the
        // watch's CloudKit replica still sits where the comment was written.
        // Picking a record would throw that comment away.
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 158, comment: nil, at: 60),
            library: record(.library, parkedIndex: 158, comment: "White cuts.", at: 0))
        let resolved = records.resolved(now: t0.addingTimeInterval(60))
        #expect(resolved?.parkedIndex == 158)
        #expect(resolved?.comment == "White cuts.")
    }

    @Test func aCommentFromADifferentIndexIsNeverBorrowed() {
        // Labelling move 158 with move 30's comment is confidently wrong.
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 158, comment: nil, at: 60),
            library: record(.library, parkedIndex: 30, comment: "Joseki here.", at: 0))
        let resolved = records.resolved(now: t0.addingTimeInterval(60))
        #expect(resolved?.parkedIndex == 158)
        #expect(resolved?.comment == nil)
    }

    @Test func theNewerRecordsOwnCommentWins() {
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 40, comment: "Fresh.", at: 60),
            library: record(.library, parkedIndex: 40, comment: "Stale.", at: 0))
        #expect(records.resolved(now: t0.addingTimeInterval(60))?.comment == "Fresh.")
    }

    @Test func theLibraryCanBeTheNewerHalfOfAMerge() {
        let records = WatchWidgetRecords(
            live: record(.live, parkedIndex: 40, comment: nil, at: 0),
            library: record(.library, parkedIndex: 40, comment: "Written on iPad.", at: 60))
        let resolved = records.resolved(now: t0.addingTimeInterval(60))
        #expect(resolved?.source == .library)
        #expect(resolved?.comment == "Written on iPad.")
    }

    // MARK: accepting a live candidate

    @Test func anUnchangedCandidateIsRejectedSoNothingIsWritten() {
        let stored = WatchWidgetRecords(live: record(.live, at: 0), library: nil)
        var candidate = record(.live, at: 600)   // same content, later clock
        candidate.capturedAt = t0.addingTimeInterval(600)
        #expect(stored.acceptingLive(candidate) == nil)
    }

    @Test func aChangedCandidateIsAccepted() {
        let stored = WatchWidgetRecords(live: record(.live, parkedIndex: 10, at: 0), library: nil)
        let candidate = record(.live, parkedIndex: 11, at: 600)
        #expect(stored.acceptingLive(candidate)?.live?.parkedIndex == 11)
    }

    @Test func aLateOlderPayloadCannotMoveTheTileBackwards() {
        // transferCurrentComplicationUserInfo is FIFO, not latest-wins: a
        // previously-current payload stays queued and can arrive after a newer
        // one. Writing it unconditionally would jump the tile from move 88
        // back to move 71.
        let stored = WatchWidgetRecords(live: record(.live, parkedIndex: 88, at: 600), library: nil)
        let late = record(.live, parkedIndex: 71, at: 0)
        #expect(stored.acceptingLive(late) == nil)
    }

    @Test func aDifferentGameIsAcceptedEvenWithAnOlderClock() {
        // Monotonicity is per-game: switching games on the phone must not be
        // blocked by the previous game's newer timestamp.
        let stored = WatchWidgetRecords(live: record(.live, gameID: "GAME-A", at: 600), library: nil)
        let other = record(.live, gameID: "GAME-B", at: 0)
        #expect(stored.acceptingLive(other)?.live?.gameID == "GAME-B")
    }

    // MARK: eviction

    @Test func aLiveRecordForADeletedGameIsEvicted() {
        let records = WatchWidgetRecords(
            live: record(.live, gameID: "GONE"),
            library: record(.library, gameID: "GAME-B"))
        let swept = records.evictingStaleLive(libraryIDs: ["GAME-B"], libraryIsAuthoritative: true)
        #expect(swept.live == nil)
        #expect(swept.library?.gameID == "GAME-B")
    }

    @Test func anEmptyOrDegradedLibraryNeverEvicts() {
        // A degraded or still-syncing store must not mass-evict a good record.
        let records = WatchWidgetRecords(live: record(.live, gameID: "GONE"), library: nil)
        #expect(records.evictingStaleLive(libraryIDs: [], libraryIsAuthoritative: true).live != nil)
        #expect(records.evictingStaleLive(libraryIDs: ["GAME-B"],
                                          libraryIsAuthoritative: false).live != nil)
    }

    @Test func aLiveRecordStillInTheLibrarySurvives() {
        let records = WatchWidgetRecords(live: record(.live, gameID: "GAME-A"), library: nil)
        #expect(records.evictingStaleLive(libraryIDs: ["GAME-A", "GAME-B"],
                                          libraryIsAuthoritative: true).live != nil)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchWidgetRecordsTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetRecordsTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchWidgetRecords' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRecords.swift`:

```swift
//
//  WatchWidgetRecords.swift
//  KataGoAnalysisKit
//
//  Both mirrors, in one value, behind one App-Group key.
//
//  One key rather than two on purpose: the merge below is per-FIELD, so two
//  independently-written keys could be read across a torn cross-process
//  boundary and yield one game's parked index beside another game's comment —
//  wrong in a way no single record could ever be. Eviction also becomes one
//  atomic write instead of two.
//

import Foundation

public struct WatchWidgetRecords: Codable, Equatable, Sendable {
    /// From the phone's WatchConnectivity frame (or its complication push).
    public var live: WatchWidgetSnapshot?
    /// From the newest row of the watch's own CloudKit-synced library.
    public var library: WatchWidgetSnapshot?

    public init(live: WatchWidgetSnapshot? = nil, library: WatchWidgetSnapshot? = nil) {
        self.live = live
        self.library = library
    }

    /// How long a `.live` record stays eligible to outrank a `.library` one.
    /// Without a ceiling, a phone left idling on an old game would pin the
    /// tile indefinitely, because its heartbeat keeps a newer clock than any
    /// library edit made on another device.
    public static let liveExpiry: TimeInterval = 24 * 60 * 60

    /// What the tile should render.
    public func resolved(now: Date) -> WatchWidgetSnapshot? {
        switch (live, library) {
        case (nil, nil):
            return nil
        case (let live?, nil):
            return live
        case (nil, let library?):
            return library
        case (let live?, let library?):
            // Same game: MERGE. The two mirrors routinely park on different
            // indices (the phone at move 158, the CloudKit replica still where
            // the user typed), and picking one throws away a real comment.
            if live.gameID == library.gameID {
                return Self.merged(live: live, library: library)
            }
            if now.timeIntervalSince(live.capturedAt) >= Self.liveExpiry {
                return library
            }
            return live.capturedAt >= library.capturedAt ? live : library
        }
    }

    /// Per-field combination of two records describing the SAME game.
    /// Everything positional comes from the newer record; the older one may
    /// only contribute a comment, and only when it agrees on the index.
    static func merged(live: WatchWidgetSnapshot,
                       library: WatchWidgetSnapshot) -> WatchWidgetSnapshot {
        let liveIsNewer = live.capturedAt >= library.capturedAt
        let newer = liveIsNewer ? live : library
        let older = liveIsNewer ? library : live
        guard newer.comment == nil, newer.parkedIndex == older.parkedIndex else {
            return newer
        }
        var merged = newer
        merged.comment = older.comment
        return merged
    }

    /// The updated envelope if `candidate` is worth storing, else nil so the
    /// caller skips the encode and the `UserDefaults` write entirely.
    ///
    /// Two rules, both load-bearing. An unchanged `contentKey` means nothing
    /// the tile shows has moved, so the stored `capturedAt` must be preserved
    /// rather than refreshed — otherwise a cold replay of a days-old persisted
    /// application context would stamp itself as brand new. And for the same
    /// game the clock is MONOTONIC, which is what makes a late-delivered older
    /// complication payload harmless.
    public func acceptingLive(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecords? {
        if let stored = live {
            guard stored.contentKey != candidate.contentKey else { return nil }
            if stored.gameID == candidate.gameID, candidate.capturedAt < stored.capturedAt {
                return nil
            }
        }
        var updated = self
        updated.live = candidate
        return updated
    }

    /// The updated envelope if `candidate` is worth storing as the library
    /// record, else nil. Same content-key rule; no monotonicity guard is
    /// needed because there is exactly one library writer and it is serialized
    /// on the main actor.
    public func acceptingLibrary(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecords? {
        if let stored = library, stored.contentKey == candidate.contentKey { return nil }
        var updated = self
        updated.library = candidate
        return updated
    }

    /// Drop a `.live` record whose game no longer exists.
    ///
    /// The library mirror is the only writer that sees both worlds, so it owns
    /// this. Deleting the mirrored game from the Mac while the iPhone app is
    /// closed pushes no further frames, so without eviction the tile would
    /// keep a dead game — with a newer clock — forever, and the tap would
    /// dead-end on "Game not found".
    ///
    /// `libraryIsAuthoritative` must be false whenever the caller did not see
    /// the whole library (a degraded or in-memory store, or a fetch that hit
    /// its row cap), so a transient empty read cannot mass-evict.
    public func evictingStaleLive(libraryIDs: Set<String>,
                                  libraryIsAuthoritative: Bool) -> WatchWidgetRecords {
        guard libraryIsAuthoritative,
              let live,
              !libraryIDs.isEmpty,
              !libraryIDs.contains(live.gameID) else { return self }
        var updated = self
        updated.live = nil
        return updated
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetRecordsTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRecords.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetRecordsTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): merge the live and library widget records per field"
```

---

## Task 4: Write / reload / push gating (slice 1)

Today's gate is `guard scoreDelta >= 0.5, elapsed >= 30` (`WatchLiveModel.swift:205`). Carried forward unchanged, a name or comment change would update the record and **never render**. This re-keys every decision on the content key, with time only ever acting as a floor.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRefreshPolicy.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRefreshPolicyTests.swift`

**Interfaces:**
- Consumes: nothing (Foundation only)
- Produces:
  - `WatchWidgetRefreshPolicy.reloadFloor: TimeInterval` (30)
  - `WatchWidgetRefreshPolicy.pushInterval: TimeInterval` (300)
  - `WatchWidgetRefreshPolicy.timelineRefreshInterval: TimeInterval` (3600)
  - `static func shouldReload(previousKey: String?, nextKey: String, elapsed: TimeInterval, floor: TimeInterval = reloadFloor) -> Bool`
  - `static func shouldPush(previousKey: String?, nextKey: String, elapsed: TimeInterval, minInterval: TimeInterval = pushInterval) -> Bool`
  - `static func nextReloadDate(after date: Date) -> Date`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetRefreshPolicyTests.swift`:

```swift
//
//  WatchWidgetRefreshPolicyTests.swift
//  KataGo AnytimeTests
//
//  When a changed record is worth a timeline reload, and when a change is
//  worth spending one of the phone's ~50 daily complication transfers.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetRefreshPolicyTests {
    // MARK: reload

    @Test func anUnchangedKeyNeverReloads() {
        #expect(!WatchWidgetRefreshPolicy.shouldReload(
            previousKey: "same", nextKey: "same", elapsed: 10_000))
    }

    @Test func aChangedKeyReloadsOnceTheFloorHasPassed() {
        #expect(WatchWidgetRefreshPolicy.shouldReload(
            previousKey: "a", nextKey: "b",
            elapsed: WatchWidgetRefreshPolicy.reloadFloor))
    }

    @Test func aChangedKeyInsideTheFloorWaits() {
        #expect(!WatchWidgetRefreshPolicy.shouldReload(
            previousKey: "a", nextKey: "b", elapsed: 5))
    }

    @Test func theFirstRecordEverAlwaysReloads() {
        // No previous key means nothing has ever been rendered; making the
        // very first record wait out a floor would leave the tile on its
        // placeholder for half a minute after setup.
        #expect(WatchWidgetRefreshPolicy.shouldReload(
            previousKey: nil, nextKey: "a", elapsed: 0))
    }

    @Test func aCommentChangeAloneIsEnoughToReload() {
        // The regression this policy exists to prevent: the old gate required
        // a half-point score move, so a new comment never reached the tile.
        let before = "GAME-A|42|Ladder Fight 3||35"
        let after  = "GAME-A|42|Ladder Fight 3|White cuts.|35"
        #expect(WatchWidgetRefreshPolicy.shouldReload(
            previousKey: before, nextKey: after,
            elapsed: WatchWidgetRefreshPolicy.reloadFloor))
    }

    // MARK: push

    @Test func anUnchangedKeyNeverPushes() {
        #expect(!WatchWidgetRefreshPolicy.shouldPush(
            previousKey: "same", nextKey: "same", elapsed: 10_000))
    }

    @Test func aChangedKeyPushesOnlyOncePerInterval() {
        #expect(!WatchWidgetRefreshPolicy.shouldPush(
            previousKey: "a", nextKey: "b", elapsed: 60))
        #expect(WatchWidgetRefreshPolicy.shouldPush(
            previousKey: "a", nextKey: "b",
            elapsed: WatchWidgetRefreshPolicy.pushInterval))
    }

    @Test func theFirstPushIsNotRateLimited() {
        #expect(WatchWidgetRefreshPolicy.shouldPush(
            previousKey: nil, nextKey: "a", elapsed: 0))
    }

    @Test func thePushIntervalIsFarCoarserThanTheReloadFloor() {
        // The transfer budget is ~50/day and shared with nothing else; the
        // reload floor is local and cheap.
        #expect(WatchWidgetRefreshPolicy.pushInterval > WatchWidgetRefreshPolicy.reloadFloor)
    }

    // MARK: timeline

    @Test func theTimelineSchedulesABoundedRefresh() {
        // Never `.never`: a tile showing a three-day-old sentence with no
        // self-healing path reads as truth.
        let now = Date(timeIntervalSince1970: 0)
        #expect(WatchWidgetRefreshPolicy.nextReloadDate(after: now)
                == now.addingTimeInterval(WatchWidgetRefreshPolicy.timelineRefreshInterval))
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchWidgetRefreshPolicyTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetRefreshPolicyTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchWidgetRefreshPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRefreshPolicy.swift`:

```swift
//
//  WatchWidgetRefreshPolicy.swift
//  KataGoAnalysisKit
//
//  When a change is worth a reload, and when it is worth a transfer.
//
//  Every decision here is keyed on the DISPLAYED content, with time only ever
//  acting as a floor. The complication this replaces gated its reload on a
//  half-point score move, which was defensible for a tile that showed only a
//  score and is exactly wrong for one that shows a name and a comment: those
//  change while the score sits still.
//

import Foundation

public enum WatchWidgetRefreshPolicy {
    /// Minimum spacing between timeline reloads driven by the live mirror.
    /// A floor, never a trigger. A background wake bypasses it deliberately —
    /// refreshing the tile is the entire purpose of that wake.
    public static let reloadFloor: TimeInterval = 30

    /// Minimum spacing between phone complication transfers. The budget is
    /// roughly 50 a day and drops to zero the moment the tile is not on an
    /// active watch face, so this is far coarser than the local floor.
    public static let pushInterval: TimeInterval = 5 * 60

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

    public static func shouldPush(previousKey: String?,
                                  nextKey: String,
                                  elapsed: TimeInterval,
                                  minInterval: TimeInterval = pushInterval) -> Bool {
        guard let previousKey else { return true }
        guard previousKey != nextKey else { return false }
        return elapsed >= minInterval
    }

    public static func nextReloadDate(after date: Date) -> Date {
        date.addingTimeInterval(timelineRefreshInterval)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetRefreshPolicyTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetRefreshPolicy.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetRefreshPolicyTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): key widget reload and push gating on displayed content"
```

---

## Task 5: The App-Group seam (slice 1)

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetDefaults.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetDefaultsTests.swift`

**Interfaces:**
- Consumes: `WatchWidgetRecords` from Task 3
- Produces:
  - `WatchWidgetDefaults.appGroupID: String`, `.recordsKey`, `.widgetKind`, `.legacyScoreKey`, `.legacyUpdatedAtKey`, `.legacyCleanupFlagKey`
  - `static func sharedDefaults() -> UserDefaults?`
  - `static func read(from: UserDefaults?) -> WatchWidgetRecords`
  - `@discardableResult static func write(_: WatchWidgetRecords, to: UserDefaults?) -> Bool`
  - `static func legacyScoreLeadBlack(from: UserDefaults?) -> Double?`
  - `static func cleanLegacyKeysOnce(in: UserDefaults?)`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetDefaultsTests.swift`:

```swift
//
//  WatchWidgetDefaultsTests.swift
//  KataGo AnytimeTests
//
//  The watch-local IPC channel between the watch app and its complication.
//  Every test injects its own suite — never the real App Group, which the
//  simulator shares with anything else running.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetDefaultsTests {
    /// A throwaway suite, removed when the block returns.
    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "test.watchwidget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        UserDefaults().removePersistentDomain(forName: name)
    }

    private var sample: WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: "GAME-A", name: "Ladder Fight 3",
                            comment: "White cuts.", parkedIndex: 42,
                            mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                            isBranch: false,
                            capturedAt: Date(timeIntervalSince1970: 1_000),
                            source: .live)
    }

    @Test func anEmptySuiteReadsAsAnEmptyEnvelopeNotACrash() {
        withSuite { defaults in
            let records = WatchWidgetDefaults.read(from: defaults)
            #expect(records.live == nil)
            #expect(records.library == nil)
        }
    }

    @Test func aNilSuiteReadsAsAnEmptyEnvelope() {
        // `UserDefaults(suiteName:)` returns nil when the App Group is
        // unavailable; the widget must render a distinct state, not crash.
        let records = WatchWidgetDefaults.read(from: nil)
        #expect(records.live == nil)
        #expect(records.library == nil)
    }

    @Test func recordsRoundTripThroughTheSuite() {
        withSuite { defaults in
            let written = WatchWidgetRecords(live: sample, library: nil)
            #expect(WatchWidgetDefaults.write(written, to: defaults))
            #expect(WatchWidgetDefaults.read(from: defaults) == written)
        }
    }

    @Test func datesSurviveTheRoundTripToTheSecond() {
        // The encoder pins secondsSince1970 to match WatchSnapshot; a default
        // strategy change here would silently break `capturedAt` ordering.
        withSuite { defaults in
            WatchWidgetDefaults.write(WatchWidgetRecords(live: sample), to: defaults)
            let read = WatchWidgetDefaults.read(from: defaults)
            #expect(read.live?.capturedAt == sample.capturedAt)
        }
    }

    @Test func writingToANilSuiteFailsLoudlyRatherThanSilently() {
        #expect(!WatchWidgetDefaults.write(WatchWidgetRecords(live: sample), to: nil))
    }

    @Test func corruptDataReadsAsAnEmptyEnvelope() {
        withSuite { defaults in
            defaults.set(Data([0x00, 0x01]), forKey: WatchWidgetDefaults.recordsKey)
            #expect(WatchWidgetDefaults.read(from: defaults).live == nil)
        }
    }

    @Test func theLegacyScoreIsReadableForTheCutoverWindow() {
        // Immediately after the update nothing has written the new key yet,
        // and the watch app can go days unopened.
        withSuite { defaults in
            defaults.set(4.5, forKey: WatchWidgetDefaults.legacyScoreKey)
            #expect(WatchWidgetDefaults.legacyScoreLeadBlack(from: defaults) == 4.5)
        }
    }

    @Test func anAbsentLegacyScoreIsNilNotZero() {
        withSuite { defaults in
            #expect(WatchWidgetDefaults.legacyScoreLeadBlack(from: defaults) == nil)
        }
    }

    @Test func legacyKeysAreRemovedExactlyOnce() {
        withSuite { defaults in
            defaults.set(4.5, forKey: WatchWidgetDefaults.legacyScoreKey)
            defaults.set(Date(), forKey: WatchWidgetDefaults.legacyUpdatedAtKey)

            WatchWidgetDefaults.cleanLegacyKeysOnce(in: defaults)
            #expect(defaults.object(forKey: WatchWidgetDefaults.legacyScoreKey) == nil)
            #expect(defaults.object(forKey: WatchWidgetDefaults.legacyUpdatedAtKey) == nil)
            #expect(defaults.bool(forKey: WatchWidgetDefaults.legacyCleanupFlagKey))

            // A second pass must not wipe a key a later feature may have
            // legitimately reused.
            defaults.set(9.9, forKey: WatchWidgetDefaults.legacyScoreKey)
            WatchWidgetDefaults.cleanLegacyKeysOnce(in: defaults)
            #expect(defaults.double(forKey: WatchWidgetDefaults.legacyScoreKey) == 9.9)
        }
    }

    @Test func theWidgetKindIsTheLegacyIdentifier() {
        // Renaming it would orphan every placement AND flip
        // WCSession.isComplicationEnabled to false, silently killing the push.
        #expect(WatchWidgetDefaults.widgetKind == "ScoreLeadWidget")
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchWidgetDefaultsTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetDefaultsTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchWidgetDefaults' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetDefaults.swift`:

```swift
//
//  WatchWidgetDefaults.swift
//  KataGoAnalysisKit
//
//  The watch-local IPC channel between the watch app and its complication.
//
//  App Group containers are PER-DEVICE. `group.chinchangyang.KataGo-iOS.tw` is
//  entitled on both the iPhone and the watch, which reads as one shared
//  container but is not: nothing the iPhone writes there is visible to the
//  watch widget. That is why all three writers live in the watch app process
//  and the phone reaches the tile only through WatchConnectivity. It is a
//  platform constraint, not a style choice — "just have the relay write the
//  record" looks plausible and produces a permanently empty tile.
//
//  Note also that on watchOS the SwiftData store deliberately does NOT use
//  this group (see SharedModelContainer's CloudKit-only branch), so this is
//  the ONLY channel the complication has.
//

import Foundation

public enum WatchWidgetDefaults {
    public static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"
    public static let recordsKey = "watchWidget.records"

    /// The widget's `kind`, and the argument to `reloadTimelines(ofKind:)`.
    ///
    /// Deliberately still the old identifier. Renaming it would drop every
    /// placement testers have already made — they would see an empty slot, not
    /// a renamed tile — and, because `WCSession.isComplicationEnabled` tracks
    /// an ACTIVE face placement, it would also flip the phone's push gate to
    /// false with no error anywhere. Hoisted here so the app-side and
    /// widget-side constants cannot drift apart.
    public static let widgetKind = "ScoreLeadWidget"

    /// Written by the complication this one replaces. Read for one release so
    /// a watch that has not been opened since the update still shows a score,
    /// then removed once.
    public static let legacyScoreKey = "watchScoreLeadBlack"
    public static let legacyUpdatedAtKey = "watchScoreUpdatedAt"
    public static let legacyCleanupFlagKey = "didCleanLegacyComplicationKeys"

    /// nil when the App Group is unavailable — a state the widget renders
    /// differently from "no data", now that the tile claims to show a name.
    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    public static func read(from defaults: UserDefaults?) -> WatchWidgetRecords {
        guard let data = defaults?.data(forKey: recordsKey),
              let records = try? decoder.decode(WatchWidgetRecords.self, from: data)
        else { return WatchWidgetRecords() }
        return records
    }

    /// Returns false when the write could not happen (no App Group, or an
    /// encode failure), so callers do not record a reload they never earned.
    @discardableResult
    public static func write(_ records: WatchWidgetRecords, to defaults: UserDefaults?) -> Bool {
        guard let defaults, let data = try? encoder.encode(records) else { return false }
        defaults.set(data, forKey: recordsKey)
        return true
    }

    public static func legacyScoreLeadBlack(from defaults: UserDefaults?) -> Double? {
        defaults?.object(forKey: legacyScoreKey) as? Double
    }

    /// Remove the retired scalars, once. Guarded by a flag so a later feature
    /// that legitimately reuses one of those names is not wiped on every
    /// launch.
    public static func cleanLegacyKeysOnce(in defaults: UserDefaults?) {
        guard let defaults, !defaults.bool(forKey: legacyCleanupFlagKey) else { return }
        defaults.removeObject(forKey: legacyScoreKey)
        defaults.removeObject(forKey: legacyUpdatedAtKey)
        defaults.set(true, forKey: legacyCleanupFlagKey)
    }

    // `secondsSince1970` on both sides, matching WatchSnapshot's coders: the
    // default strategy would encode a Double reference-date offset, which is
    // fine in isolation but diverges from the payload this shares a process
    // with, and `capturedAt` ordering is load-bearing.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetDefaultsTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetDefaults.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetDefaultsTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): add the App-Group seam for the last-game widget records"
```

---

## Task 6: Layout choice and every string the tile renders (slice 1)

The three families are **not** three renditions of the same content. Rectangular carries name + comment; inline is system-rendered and shares its slot with the date on several faces; circular has room for neither. This puts all of that in one tested function so the widget view holds no policy.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetTileText.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetTileTextTests.swift`

**Interfaces:**
- Consumes: `WatchWidgetSnapshot` from Task 2
- Produces:
  - `enum WatchWidgetTileLayout: Equatable, Sendable { case unavailable(headline: String, detail: String?), withComment, withoutComment, reduced }`
  - `WatchWidgetTileText.inlineBudget: Int` (20), `.separator: String` (`" - "`)
  - `static func layout(for: WatchWidgetSnapshot?, storageAvailable: Bool, luminanceReduced: Bool) -> WatchWidgetTileLayout`
  - `static func scoreText(_: Double?) -> String?`
  - `static func compactScoreText(_: Double?) -> String?`
  - `static func moveText(parkedIndex: Int, mainlineMoveCount: Int, isBranch: Bool) -> String`
  - `static func inlineText(for: WatchWidgetSnapshot?) -> String`
  - `static func circularText(for: WatchWidgetSnapshot?) -> String`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetTileTextTests.swift`:

```swift
//
//  WatchWidgetTileTextTests.swift
//  KataGo AnytimeTests
//
//  Which of the rectangular layouts the tile picks, and every string it puts
//  on a watch face. The widget view itself has no test target and cannot get
//  one, so all of its policy lives here.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetTileTextTests {
    private func snapshot(name: String = "Ladder Fight 3",
                          comment: String? = nil,
                          parkedIndex: Int = 42,
                          mainlineMoveCount: Int = 178,
                          score: Double? = 3.5,
                          isBranch: Bool = false) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: "GAME-A", name: name, comment: comment,
                            parkedIndex: parkedIndex,
                            mainlineMoveCount: mainlineMoveCount,
                            scoreLeadBlack: score, isBranch: isBranch,
                            capturedAt: Date(timeIntervalSince1970: 0), source: .live)
    }

    // MARK: layout choice

    @Test func noAppGroupIsItsOwnState() {
        // Distinct from "no data": the tile now claims to show a game name, so
        // silence about a storage failure would read as an empty library.
        let layout = WatchWidgetTileText.layout(for: nil, storageAvailable: false,
                                                luminanceReduced: false)
        #expect(layout == .unavailable(headline: "Storage unavailable", detail: nil))
    }

    @Test func noRecordPointsAtTheWatchApp() {
        let layout = WatchWidgetTileText.layout(for: nil, storageAvailable: true,
                                                luminanceReduced: false)
        #expect(layout == .unavailable(headline: "No game yet",
                                       detail: "Open KataGo Anytime on your Watch"))
    }

    @Test func aCommentGetsTheCommentLayout() {
        #expect(WatchWidgetTileText.layout(for: snapshot(comment: "White cuts."),
                                           storageAvailable: true,
                                           luminanceReduced: false) == .withComment)
    }

    @Test func noCommentIsTheDefaultLayoutNotAnEmptyRegion() {
        // Comments are sparse at most indices — WatchStoredGameView already
        // prints "No analysis saved for this move" for exactly this case — so
        // the comment-less layout is the common one, and it must fill the rect
        // rather than leave a hole where a paragraph would go.
        #expect(WatchWidgetTileText.layout(for: snapshot(comment: nil),
                                           storageAvailable: true,
                                           luminanceReduced: false) == .withoutComment)
    }

    @Test func alwaysOnDropsTheCommentBody() {
        // A multi-line paragraph at reduced contrast is unreadable, and the
        // guidance for the dimmed state is to reduce content.
        #expect(WatchWidgetTileText.layout(for: snapshot(comment: "White cuts."),
                                           storageAvailable: true,
                                           luminanceReduced: true) == .reduced)
    }

    @Test func alwaysOnStillReportsAMissingAppGroup() {
        let layout = WatchWidgetTileText.layout(for: nil, storageAvailable: false,
                                                luminanceReduced: true)
        #expect(layout == .unavailable(headline: "Storage unavailable", detail: nil))
    }

    // MARK: score

    @Test func theScoreNamesItsLeader() {
        #expect(WatchWidgetTileText.scoreText(3.5) == "B+3.5")
        #expect(WatchWidgetTileText.scoreText(-3.5) == "W+3.5")
        #expect(WatchWidgetTileText.scoreText(nil) == nil)
    }

    @Test func theCircularScoreDropsTheDecimal() {
        // A signed one-decimal score does not fit above the legibility floor
        // in circular's usable inner square.
        #expect(WatchWidgetTileText.compactScoreText(21.8) == "B+22")
        #expect(WatchWidgetTileText.compactScoreText(-21.8) == "W+22")
    }

    // MARK: move line

    @Test func theMoveLineNamesTheMainlineLength() {
        #expect(WatchWidgetTileText.moveText(parkedIndex: 42, mainlineMoveCount: 178,
                                             isBranch: false) == "Move 42 of 178")
    }

    @Test func aBranchIndexNeverClaimsAMainlineLength() {
        // On a branch the index and the count describe different lines, so
        // "Move 42 of 30" is renderable unless this is suppressed.
        #expect(WatchWidgetTileText.moveText(parkedIndex: 42, mainlineMoveCount: 30,
                                             isBranch: true) == "Move 42")
    }

    @Test func anIndexPastTheCountNeverRendersAnImpossibleRatio() {
        #expect(WatchWidgetTileText.moveText(parkedIndex: 42, mainlineMoveCount: 30,
                                             isBranch: false) == "Move 42")
    }

    // MARK: inline

    @Test func inlineLeadsWithTheDurableToken() {
        // The slot is system-styled and shares space with the date on several
        // faces, so the score must survive truncation even when the name does
        // not.
        let text = WatchWidgetTileText.inlineText(for: snapshot(name: "Ladder Fight 3"))
        #expect(text.hasPrefix("B+4"))
        #expect(text.count <= WatchWidgetTileText.inlineBudget)
    }

    @Test func inlineTruncatesTheNameNotTheScore() {
        let text = WatchWidgetTileText.inlineText(
            for: snapshot(name: "A Very Long Game Name Indeed"))
        #expect(text.hasPrefix("B+4"))
        #expect(text.count <= WatchWidgetTileText.inlineBudget)
        #expect(text.hasSuffix("\u{2026}"))
    }

    @Test func inlineFallsBackToTheMoveNumberWithoutAScore() {
        let text = WatchWidgetTileText.inlineText(for: snapshot(score: nil))
        #expect(text.hasPrefix("Move 42"))
    }

    @Test func inlineSaysSomethingWithNoRecord() {
        #expect(WatchWidgetTileText.inlineText(for: nil) == "No game")
    }

    @Test func inlineUsesAnAsciiSeparator() {
        // House rule from WatchLibraryRow.sizeText: ASCII only in these small
        // strings, not a typographic middot.
        let text = WatchWidgetTileText.inlineText(for: snapshot(name: "Go"))
        #expect(text.contains(" - "))
    }

    // MARK: circular

    @Test func circularShowsTheScoreThenTheMoveNumber() {
        #expect(WatchWidgetTileText.circularText(for: snapshot(score: 21.8)) == "B+22")
        #expect(WatchWidgetTileText.circularText(for: snapshot(score: nil)) == "42")
        #expect(WatchWidgetTileText.circularText(for: nil) == "--")
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchWidgetTileTextTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetTileTextTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchWidgetTileText' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetTileText.swift`:

```swift
//
//  WatchWidgetTileText.swift
//  KataGoAnalysisKit
//
//  Which layout the rectangular tile picks, and every string the complication
//  puts on a watch face.
//
//  All of it lives here because the widget's view code has no test target and
//  cannot be given one: the only bundle that covers watch logic is
//  "KataGo AnytimeTests", which builds for the iOS Simulator against the iOS
//  host app. A rule spelled out inline in the widget would be verifiable only
//  by looking at a screenshot.
//

import Foundation

public enum WatchWidgetTileLayout: Equatable, Sendable {
    /// Nothing to show. `headline` always renders; `detail` is a second line
    /// when there is room for it.
    case unavailable(headline: String, detail: String?)
    /// Name + score row, then the comment body filling the remaining height.
    case withComment
    /// Name + score row, then the move line, then the age. The DEFAULT: most
    /// positions carry no comment.
    case withoutComment
    /// Always-On (luminance reduced): the header row and the move line only.
    case reduced
}

public enum WatchWidgetTileText {
    /// Roughly what the inline slot affords once the face's own date is
    /// alongside it. A budget, not a guarantee — the system still truncates.
    public static let inlineBudget = 20

    /// ASCII, per `WatchLibraryRow.sizeText`'s rule that a typographic
    /// character is not worth the encoding risk in a string this small.
    public static let separator = " - "

    public static func layout(for snapshot: WatchWidgetSnapshot?,
                              storageAvailable: Bool,
                              luminanceReduced: Bool) -> WatchWidgetTileLayout {
        // Storage first: it outranks Always-On because a tile that cannot read
        // its record has nothing to dim.
        guard storageAvailable else {
            return .unavailable(headline: "Storage unavailable", detail: nil)
        }
        guard let snapshot else {
            return .unavailable(headline: "No game yet",
                                detail: "Open KataGo Anytime on your Watch")
        }
        if luminanceReduced { return .reduced }
        return snapshot.comment == nil ? .withoutComment : .withComment
    }

    /// "B+3.5" / "W+3.5". Hierarchy on this tile is carried by weight and
    /// `.primary`/`.secondary` only, never hue — a tinted face renders in
    /// `.accented` mode and would flatten two colors into one.
    public static func scoreText(_ scoreLeadBlack: Double?) -> String? {
        guard let value = scoreLeadBlack else { return nil }
        return value >= 0 ? String(format: "B+%.1f", value)
                          : String(format: "W+%.1f", -value)
    }

    /// "B+22". The circular slot has no room for a decimal at a legible size.
    public static func compactScoreText(_ scoreLeadBlack: Double?) -> String? {
        guard let value = scoreLeadBlack else { return nil }
        let points = Int(abs(value).rounded())
        return value >= 0 ? "B+\(points)" : "W+\(points)"
    }

    /// The "of M" half is dropped whenever it would be a lie: on a branch the
    /// index and the mainline count describe different lines, and a parked
    /// index past the count would render an impossible ratio.
    public static func moveText(parkedIndex: Int,
                                mainlineMoveCount: Int,
                                isBranch: Bool) -> String {
        guard !isBranch, parkedIndex <= mainlineMoveCount else {
            return "Move \(parkedIndex)"
        }
        return "Move \(parkedIndex) of \(mainlineMoveCount)"
    }

    /// The inline slot is rendered by the system — its font, the face's tint,
    /// its truncation — and `.font`/`.foregroundStyle`/`.lineLimit` are
    /// silently dropped, the same styling loss this repo already recorded for
    /// watchOS navigation titles. So the WRITER truncates, and the durable
    /// token goes first.
    public static func inlineText(for snapshot: WatchWidgetSnapshot?) -> String {
        guard let snapshot else { return "No game" }
        let lead = compactScoreText(snapshot.scoreLeadBlack) ?? "Move \(snapshot.parkedIndex)"
        let remaining = inlineBudget - lead.count - separator.count
        guard remaining > 0 else { return lead }
        guard snapshot.name.count > remaining else {
            return lead + separator + snapshot.name
        }
        let clipped = String(snapshot.name.prefix(max(remaining - 1, 1)))
        return lead + separator + clipped + "\u{2026}"
    }

    /// A different readout, not a compact rendition of name + comment.
    public static func circularText(for snapshot: WatchWidgetSnapshot?) -> String {
        guard let snapshot else { return "--" }
        return compactScoreText(snapshot.scoreLeadBlack) ?? "\(snapshot.parkedIndex)"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetTileTextTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/WatchWidgetTileText.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetTileTextTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): put the complication's layout choice and copy in one tested place"
```

---

## Task 7: Link `KataGoAnalysisKit` into the watch widget target (slice 2)

The target has `dependencies = ()` and **no `packageProductDependencies` key at all**; its Frameworks phase carries only `Foundation.framework`. `scripts_add_swift_files.rb` handles source files only, so this needs its own script — modelled exactly on the existing `add_gorules_to_watch.rb`.

**Files:**
- Create: `ios/KataGo iOS/add_analysiskit_to_watch_widget.rb`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via the script)

**Interfaces:**
- Consumes: the `KataGoUICore` package reference already in the project
- Produces: `import KataGoAnalysisKit` compiles inside `KataGoAnytimeWatchWidget`

- [ ] **Step 1: Write the linking script**

Create `ios/KataGo iOS/add_analysiskit_to_watch_widget.rb`:

```ruby
#!/usr/bin/env ruby
# Links the Foundation-only KataGoAnalysisKit product into the
# "KataGoAnytimeWatchWidget" target (the last-game complication).
#
# The complication must NEVER link KataGoGameStore, KataGoUICore, or
# GoRulesKit: it is a wrist-sized appex with a hard memory ceiling, and
# KataGoGameStore alone would drag in SwiftData, CoreData, AppIntents and an
# image asset catalog. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
TARGET  = 'KataGoAnytimeWatchWidget'
PRODUCT = 'KataGoAnalysisKit'

project = Xcodeproj::Project.open(PROJECT)
target = project.targets.find { |t| t.name == TARGET } or abort("missing #{TARGET}")

pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

if target.package_product_dependencies.any? { |d| d.product_name == PRODUCT }
  puts "#{PRODUCT} already linked into #{TARGET} — nothing to do."
  exit 0
end

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = PRODUCT
target.package_product_dependencies << dep

bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
target.frameworks_build_phase.files << bf

project.save
puts "Linked #{PRODUCT} into #{TARGET}."
```

- [ ] **Step 2: Run it, and confirm it is idempotent**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby add_analysiskit_to_watch_widget.rb
ruby add_analysiskit_to_watch_widget.rb
```

Expected: `Linked KataGoAnalysisKit into KataGoAnytimeWatchWidget.` then
`KataGoAnalysisKit already linked into KataGoAnytimeWatchWidget — nothing to do.`

- [ ] **Step 3: Prove the link works by importing the module**

Temporarily add `import KataGoAnalysisKit` to the top of
`ios/KataGo iOS/KataGoAnytimeWatchWidget/ScoreLeadWidget.swift`, then build the
watch scheme (which builds the embedded widget):

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`. Keep the import — Task 8 rewrites this file and needs it.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/add_analysiskit_to_watch_widget.rb" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" \
        "ios/KataGo iOS/KataGoAnytimeWatchWidget/ScoreLeadWidget.swift"
git commit -m "build(watch): link the Foundation-only KataGoAnalysisKit into the complication"
```

---

## Task 8: Rewrite the complication as the last-game tile (slice 2)

Renames the file and the types, keeps the `kind`, and renders the three families from the App-Group record. Nothing writes that record yet — Task 10 does — so after this task the tile shows either the legacy score (cutover fallback) or "No game yet". That is the intended intermediate state.

**Files:**
- Rename: `ios/KataGo iOS/KataGoAnytimeWatchWidget/ScoreLeadWidget.swift` -> `LastGameWidget.swift` (contents fully replaced)
- Modify: `ios/KataGo iOS/KataGoAnytimeWatchWidget/KataGoAnytimeWatchWidgetBundle.swift`
- Modify: `ios/KataGo iOS/KataGoAnytimeWatchWidget/Info.plist` (`CFBundleDisplayName`)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (file path only)

**Interfaces:**
- Consumes: `WatchWidgetDefaults`, `WatchWidgetRecords`, `WatchWidgetRefreshPolicy`, `WatchWidgetTileText`, `WatchWidgetTileLayout` (Tasks 2-6)
- Produces: `struct LastGameWidget: Widget`, `struct LastGameEntry: TimelineEntry`, `struct LastGameProvider: TimelineProvider`

- [ ] **Step 1: Rename the file and retarget the project reference**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git mv KataGoAnytimeWatchWidget/ScoreLeadWidget.swift KataGoAnytimeWatchWidget/LastGameWidget.swift
sed -i '' 's/ScoreLeadWidget\.swift/LastGameWidget.swift/g' "KataGo Anytime.xcodeproj/project.pbxproj"
grep -c "LastGameWidget.swift" "KataGo Anytime.xcodeproj/project.pbxproj"
grep -c "ScoreLeadWidget.swift" "KataGo Anytime.xcodeproj/project.pbxproj" || true
```

Expected: a non-zero count for `LastGameWidget.swift` and `0` for `ScoreLeadWidget.swift`. (The bare string `ScoreLeadWidget` still appears in Swift source as the widget `kind` — that is correct and must not be renamed.)

- [ ] **Step 2: Replace the file's contents**

Overwrite `ios/KataGo iOS/KataGoAnytimeWatchWidget/LastGameWidget.swift`:

```swift
//
//  LastGameWidget.swift
//  KataGoAnytimeWatchWidget
//
//  The last game, at the position it is parked on: its name, the comment
//  written there, and the score.
//
//  This appex links KataGoAnalysisKit and NOTHING else. It must never touch
//  SwiftData: on watchOS the shared container takes the CloudKit-only branch
//  with no App Group, so an appex opening it would get a second, permanently
//  empty store — which is exactly why the watch app mirrors into UserDefaults
//  for this process to read.
//

import WidgetKit
import SwiftUI
import KataGoAnalysisKit

struct LastGameEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchWidgetSnapshot?
    /// False when the App Group is unavailable — rendered differently from
    /// "no record yet", now that the tile claims to name a game.
    let storageAvailable: Bool
    /// The retired complication's score. Read for one release: immediately
    /// after the update nothing has written the new record yet, and the watch
    /// app can go days unopened.
    let legacyScoreLeadBlack: Double?
}

struct LastGameProvider: TimelineProvider {
    private func read(at date: Date) -> LastGameEntry {
        let defaults = WatchWidgetDefaults.sharedDefaults()
        let records = WatchWidgetDefaults.read(from: defaults)
        return LastGameEntry(date: date,
                             snapshot: records.resolved(now: date),
                             storageAvailable: defaults != nil,
                             legacyScoreLeadBlack:
                                WatchWidgetDefaults.legacyScoreLeadBlack(from: defaults))
    }

    func placeholder(in context: Context) -> LastGameEntry {
        LastGameEntry(date: .now,
                      snapshot: WatchWidgetSnapshot(
                        gameID: "", name: "Ladder Fight 3",
                        comment: "White's cut is the only move that keeps the corner alive.",
                        parkedIndex: 42, mainlineMoveCount: 178,
                        scoreLeadBlack: 3.5, isBranch: false,
                        capturedAt: .now, source: .library),
                      storageAvailable: true,
                      legacyScoreLeadBlack: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LastGameEntry) -> Void) {
        // The gallery only needs a representative sample; reading the App
        // Group there would show one user's game name in a chooser.
        completion(context.isPreview ? placeholder(in: context) : read(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastGameEntry>) -> Void) {
        // Bounded, never `.never`. Every real update arrives as an explicit
        // reloadTimelines from the watch app, but a tile showing a three-day-
        // old sentence with no self-healing path reads as truth, so it also
        // re-asks on its own.
        let entry = read(at: .now)
        completion(Timeline(entries: [entry],
                            policy: .after(WatchWidgetRefreshPolicy.nextReloadDate(after: entry.date))))
    }
}

struct LastGameWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let entry: LastGameEntry

    var body: some View {
        content
            // One root for every family and every state, so the empty case is
            // laid out by the same rules as the populated one. The previous
            // tile applied this separately in each branch of an if/else around
            // a centered Text — fine for a numeral, wrong for a left-aligned
            // name above a paragraph.
            .containerBackground(.fill.tertiary, for: .widget)
            // Exactly one tap target: Link is unsupported in watchOS accessory
            // widgets. Because the URL and the rendered content come from the
            // same entry, a stale tile always opens the game it is showing.
            .widgetURL(tapURL)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            // System-rendered: font, tint and truncation are the face's, and
            // .font/.foregroundStyle/.lineLimit here would be silently
            // dropped. The writer already truncated.
            Text(inlineText)
        case .accessoryCircular:
            Text(circularText)
                .font(.system(.body, design: .rounded))
                .minimumScaleFactor(0.7)
                .widgetAccentable()
        default:
            rectangular
        }
    }

    // MARK: rectangular

    private var layout: WatchWidgetTileLayout {
        WatchWidgetTileText.layout(for: entry.snapshot,
                                   storageAvailable: entry.storageAvailable,
                                   luminanceReduced: isLuminanceReduced)
    }

    @ViewBuilder private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch layout {
            case .unavailable(let headline, let detail):
                unavailableBody(headline: headline, detail: detail)
            case .reduced:
                headerRow
                metaLine
            case .withoutComment:
                headerRow
                metaLine
            case .withComment:
                headerRow
                metaLine
                if let comment = entry.snapshot?.comment {
                    // No lineLimit on purpose: the body takes whatever height
                    // is left, so it renders two lines on a small watch and
                    // three on a large one instead of clipping a fixed stack.
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func unavailableBody(headline: String, detail: String?) -> some View {
        if let legacy = entry.legacyScoreLeadBlack,
           let score = WatchWidgetTileText.scoreText(legacy) {
            // Cutover window: no record yet, but the retired complication's
            // score is still in the App Group and beats a "no game" card.
            Text(score).font(.system(.headline, design: .monospaced))
        } else {
            Text(headline).font(.headline).lineLimit(1)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var headerRow: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 4) {
                Text(snapshot.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let score = WatchWidgetTileText.scoreText(snapshot.scoreLeadBlack) {
                    // layoutPriority so the NAME yields, not the number: a
                    // half-truncated score is unreadable, a half-truncated
                    // name is still recognisable.
                    Text(score)
                        .font(.caption2.monospacedDigit())
                        .layoutPriority(1)
                        .widgetAccentable()
                }
            }
        }
    }

    @ViewBuilder private var metaLine: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 4) {
                Text(WatchWidgetTileText.moveText(parkedIndex: snapshot.parkedIndex,
                                                  mainlineMoveCount: snapshot.mainlineMoveCount,
                                                  isBranch: snapshot.isBranch))
                Text("-")
                // Self-updating in a widget without a timeline entry, which is
                // what keeps the tile honest between reloads — and it is the
                // one signal that separates "the push never fired" from "the
                // reload was gated out" in a tester report.
                Text(snapshot.capturedAt, style: .relative)
                Spacer(minLength: 0)
                Image(systemName: snapshot.source == .live
                      ? "dot.radiowaves.left.and.right" : "icloud")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: small families

    private var inlineText: String {
        if entry.snapshot == nil, let legacy = entry.legacyScoreLeadBlack,
           let score = WatchWidgetTileText.compactScoreText(legacy) {
            return score
        }
        return WatchWidgetTileText.inlineText(for: entry.snapshot)
    }

    private var circularText: String {
        if entry.snapshot == nil, let legacy = entry.legacyScoreLeadBlack,
           let score = WatchWidgetTileText.compactScoreText(legacy) {
            return score
        }
        return WatchWidgetTileText.circularText(for: entry.snapshot)
    }

    /// Built inline rather than by linking `GameDeepLink`: that type reaches
    /// `SharedModelContainer.appGroupID` and would drag the SwiftData tier into
    /// this appex. `GameDeepLink` stays the source of truth for the scheme and
    /// host — keep these three literals in sync with it.
    private var tapURL: URL? {
        guard let gameID = entry.snapshot?.gameID, !gameID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "katago-anytime"
        components.host = "open-game"
        components.queryItems = [URLQueryItem(name: "id", value: gameID)]
        return components.url
    }
}

struct LastGameWidget: Widget {
    var body: some WidgetConfiguration {
        // The kind is deliberately the legacy identifier — see
        // WatchWidgetDefaults.widgetKind for why renaming it would orphan
        // placements and silently disable the phone's push.
        StaticConfiguration(kind: WatchWidgetDefaults.widgetKind,
                            provider: LastGameProvider()) { entry in
            LastGameWidgetView(entry: entry)
        }
        .configurationDisplayName("Last Game")
        .description("The name and comment at the position your last game is parked on.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

#Preview("Rectangular, with comment", as: .accessoryRectangular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3",
                    comment: "White's cut is the only move that keeps the corner alive.",
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                    isBranch: false, capturedAt: .now, source: .live),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Rectangular, no comment (the default)", as: .accessoryRectangular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                    isBranch: false, capturedAt: .now, source: .library),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Rectangular, empty", as: .accessoryRectangular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now, snapshot: nil, storageAvailable: true,
                  legacyScoreLeadBlack: nil)
}

#Preview("Inline", as: .accessoryInline) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 4.5,
                    isBranch: false, capturedAt: .now, source: .live),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}

#Preview("Circular", as: .accessoryCircular) {
    LastGameWidget()
} timeline: {
    LastGameEntry(date: .now,
                  snapshot: WatchWidgetSnapshot(
                    gameID: "GAME-A", name: "Ladder Fight 3", comment: nil,
                    parkedIndex: 42, mainlineMoveCount: 178, scoreLeadBlack: 21.8,
                    isBranch: false, capturedAt: .now, source: .live),
                  storageAvailable: true, legacyScoreLeadBlack: nil)
}
```

- [ ] **Step 3: Update the widget bundle**

Overwrite `ios/KataGo iOS/KataGoAnytimeWatchWidget/KataGoAnytimeWatchWidgetBundle.swift`:

```swift
import WidgetKit
import SwiftUI

@main
struct KataGoAnytimeWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        LastGameWidget()
    }
}
```

- [ ] **Step 4: Update the appex display name**

In `ios/KataGo iOS/KataGoAnytimeWatchWidget/Info.plist`, change:

```xml
	<key>CFBundleDisplayName</key>
	<string>KataGo Game</string>
```

- [ ] **Step 5: Build the watch scheme**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Probe the rectangular layout on two watch sizes**

This is a required verification step, not a nicety: the published content-rect sizes for accessory families could not be confirmed from this repo, so the three-row layout above is a hypothesis until it is looked at. Open the previews in Xcode for `LastGameWidget.swift` on a **41 mm** and a **46 mm** simulator, at default text size and at AX1 and AX3, and check that:

- the comment body renders at least two lines and is not clipped at 41 mm,
- the score never truncates in the header row,
- the no-comment layout fills the rect rather than leaving a hole,
- the Always-On rendition drops the comment body.

If the three-row layout clips at 41 mm, move the age out of the meta line before reducing the comment's height. Record the observed content-rect sizes in a reference memory afterwards.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoAnytimeWatchWidget" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): show the last game's name and comment on the complication"
```

---

## Task 9: Build a `.library` record from the newest row (slice 2)

`WatchLibraryRow` carries id/name/size/sgf/lastModified only, so the mirror needs one extra bounded fetch. This splits that into a thin `@MainActor` fetch and a pure builder, so everything with a decision in it is testable.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLibrarySource.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLibrarySourceTests.swift`

**Interfaces:**
- Consumes: `WatchLibraryRow`, `WatchStoredAnalysis`, `GameRecord` (existing); `WatchWidgetSnapshot` (Task 2)
- Produces:
  - `struct WatchWidgetLibrarySource.Extras: Equatable, Sendable { var parkedIndex: Int; var comment: String?; var scoreLeadBlack: Double? }`
  - `static func extras(currentIndex: Int, comments: [Int: String]?, scoreLeads: [Int: Float]?) -> Extras`
  - `@MainActor static func extras(gameID: String, container: ModelContainer) -> Extras?`
  - `static func snapshot(row: WatchLibraryRow, moveCount: Int, extras: Extras, capturedAt: Date) -> WatchWidgetSnapshot`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLibrarySourceTests.swift`:

```swift
//
//  WatchWidgetLibrarySourceTests.swift
//  KataGo AnytimeTests
//
//  Turning the newest library row into the record the complication renders.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchWidgetLibrarySourceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func row(name: String = "Ladder Fight 3") -> WatchLibraryRow {
        WatchLibraryRow(id: "GAME-A", name: name, boardWidth: 19, boardHeight: 19,
                        sgf: "(;GM[1])", lastModified: Date(timeIntervalSince1970: 500))
    }

    // MARK: extras

    @Test func theCommentIsLookedUpAtTheParkedIndexExactly() {
        // NOT GameEntity.init's keys.max() fallback: that exists because the
        // iOS widget draws a board and faults those dictionaries anyway, and
        // it would label a comment with the wrong position.
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 42,
            comments: [30: "Joseki here.", 42: "White cuts."],
            scoreLeads: [42: 3.5])
        #expect(extras.parkedIndex == 42)
        #expect(extras.comment == "White cuts.")
        #expect(extras.scoreLeadBlack == 3.5)
    }

    @Test func anIndexWithNoCommentYieldsNil() {
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 41, comments: [42: "White cuts."], scoreLeads: nil)
        #expect(extras.comment == nil)
        #expect(extras.scoreLeadBlack == nil)
    }

    @Test func aBlankCommentIsTreatedAsAbsent() {
        // An absent readout must be HIDDEN, not rendered as an empty region —
        // the rule WatchStoredAnalysis already enforces.
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 5, comments: [5: "   "], scoreLeads: nil)
        #expect(extras.comment == nil)
    }

    @Test func aLongCommentIsCappedHereTooNotOnlyOnTheWire() {
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 0, comments: [0: String(repeating: "a", count: 400)],
            scoreLeads: nil)
        #expect(extras.comment?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
    }

    // MARK: snapshot

    @Test func theSnapshotTakesNameAndIdFromTheRow() {
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: 42, comment: "White cuts.", scoreLeadBlack: 3.5),
            capturedAt: t0)
        #expect(snapshot.gameID == "GAME-A")
        #expect(snapshot.name == "Ladder Fight 3")
        #expect(snapshot.mainlineMoveCount == 178)
        #expect(snapshot.parkedIndex == 42)
        #expect(snapshot.source == .library)
        #expect(snapshot.capturedAt == t0)
    }

    @Test func aLibraryRecordIsNeverABranch() {
        // A saved record's currentIndex is frozen at the divergence point; the
        // branch index only ever exists on the phone's live frame.
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: 42, comment: nil, scoreLeadBlack: nil),
            capturedAt: t0)
        #expect(!snapshot.isBranch)
    }

    @Test func aParkedIndexPastTheMainlineIsClampedNotRendered() {
        // A record can carry a currentIndex beyond its own sgf after an edit;
        // "Move 200 of 178" must never be constructible.
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: 200, comment: nil, scoreLeadBlack: nil),
            capturedAt: t0)
        #expect(snapshot.parkedIndex <= snapshot.mainlineMoveCount)
    }

    @Test func aNegativeParkedIndexIsClampedToZero() {
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: -3, comment: nil, scoreLeadBlack: nil),
            capturedAt: t0)
        #expect(snapshot.parkedIndex == 0)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchWidgetLibrarySourceTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetLibrarySourceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchWidgetLibrarySource' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLibrarySource.swift`:

```swift
//
//  WatchWidgetLibrarySource.swift
//  KataGoGameStore
//
//  The newest library row, as the record the complication renders.
//
//  Split deliberately: a thin @MainActor fetch that this file keeps as small
//  as possible, and pure functions holding every decision, because the watch
//  target has no test bundle and a rule buried in a SwiftData call site cannot
//  be pinned.
//

import Foundation
import SwiftData

public enum WatchWidgetLibrarySource {
    /// What a GameRecord knows that its `WatchLibraryRow` does not.
    public struct Extras: Equatable, Sendable {
        public var parkedIndex: Int
        public var comment: String?
        public var scoreLeadBlack: Double?

        public init(parkedIndex: Int, comment: String?, scoreLeadBlack: Double?) {
            self.parkedIndex = parkedIndex
            self.comment = comment
            self.scoreLeadBlack = scoreLeadBlack
        }
    }

    /// Pure derivation, so the lookup rule is testable without a store.
    /// Delegates to `WatchStoredAnalysis.at` rather than reimplementing the
    /// lookup, so this, `WatchStoredGameView`, and the phone's comment pane
    /// cannot drift apart on what "the comment at index N" means.
    public static func extras(currentIndex: Int,
                              comments: [Int: String]?,
                              scoreLeads: [Int: Float]?) -> Extras {
        let stored = WatchStoredAnalysis.at(index: currentIndex,
                                            winRates: nil,
                                            scoreLeads: scoreLeads,
                                            bestMoves: nil,
                                            comments: comments)
        return Extras(parkedIndex: currentIndex,
                      comment: WatchWidgetSnapshot.cappedComment(stored.comment),
                      scoreLeadBlack: stored.scoreLeadBlack.map(Double.init))
    }

    /// One bounded, single-record fetch.
    ///
    /// `propertiesToFetch` lists EXACTLY what is read below. Reading a
    /// property absent from that list faults the ENTIRE row — the ownership
    /// dictionaries and the HEIC thumbnail included — which for a
    /// well-analyzed game is precisely the footprint the watch avoids
    /// everywhere else. In particular `mainlineMoveCount` is NOT taken from
    /// here: it needs `sgf`, and the caller already has it memoized on the
    /// library store.
    @MainActor
    public static func extras(gameID: String, container: ModelContainer) -> Extras? {
        guard let uuid = UUID(uuidString: gameID) else { return nil }
        let target: UUID? = uuid
        var descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate { $0.uuid == target },
            sortBy: [.init(\.lastModificationDate, order: .reverse)])
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.uuid, \.currentIndex, \.comments, \.scoreLeads]
        guard let record = try? container.mainContext.fetch(descriptor).first else { return nil }
        return extras(currentIndex: record.currentIndex,
                      comments: record.comments,
                      scoreLeads: record.scoreLeads)
    }

    /// Clamped into the mainline it is about to be rendered against, so the
    /// tile can never construct "Move 200 of 178".
    public static func snapshot(row: WatchLibraryRow,
                                moveCount: Int,
                                extras: Extras,
                                capturedAt: Date) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: row.id,
                            name: row.name,
                            comment: extras.comment,
                            parkedIndex: min(max(extras.parkedIndex, 0), moveCount),
                            mainlineMoveCount: moveCount,
                            scoreLeadBlack: extras.scoreLeadBlack,
                            // A saved record's currentIndex is frozen at the
                            // divergence point; only the phone's live frame
                            // can carry a branch index.
                            isBranch: false,
                            capturedAt: capturedAt,
                            source: .library)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetLibrarySourceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLibrarySource.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetLibrarySourceTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): build the widget's library record from the newest row"
```

---

## Task 10: The mirror, and the library write path (slice 2)

`WatchLibraryStore.refresh()` must stay pure — its header calls read-only "structural, not a convention", it avoids importing CloudKit so it stays appex-safe, and `WatchLibraryStoreTests` calls it in-process, so a `UserDefaults` write inside it would scribble the real App Group on every test run. The mirror is a separate type in the watch target, invoked through a callback.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Watch/WatchWidgetMirror.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift:57-60,108-132`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift:17-52`

**Interfaces:**
- Consumes: `WatchWidgetDefaults`, `WatchWidgetRecords`, `WatchWidgetRefreshPolicy` (Tasks 3-5), `WatchWidgetLibrarySource` (Task 9), `WatchLibraryStore` (existing)
- Produces:
  - `WatchLibraryStore.onRefresh: (() -> Void)?`
  - `@MainActor final class WatchWidgetMirror` with `init(container:defaults:)`, `mirrorLibrary(rows:moveCount:libraryIsAuthoritative:now:)`, `mirrorLive(_:now:immediate:)`

- [ ] **Step 1: Add the refresh hook to the store**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift`, add the property beside `rows` (after line 57):

```swift
    /// Invoked after every `refresh()`, once `rows` is current.
    ///
    /// The store itself stays read-only and side-effect-free: it must not
    /// import WidgetKit (it compiles for tvOS, which has no WidgetKit) and it
    /// must not write UserDefaults (WatchLibraryStoreTests calls `refresh()`
    /// in-process, which would scribble the real App Group on every test run).
    /// This callback is how the complication mirror learns the library changed
    /// without either.
    @ObservationIgnored public var onRefresh: (() -> Void)?
```

and call it as the last statement of `refresh()`, after the `moveCounts` filter:

```swift
        moveCounts = moveCounts.filter { key, _ in liveKeys.contains(key) }
        onRefresh?()
    }
```

- [ ] **Step 2: Write the mirror**

Create `ios/KataGo iOS/KataGo Anytime Watch/WatchWidgetMirror.swift`:

```swift
import Foundation
import SwiftData
import WidgetKit
import KataGoGameStore

/// Owns every App-Group write the complication reads, and every timeline
/// reload it gets.
///
/// All three writers live in the watch app process because App Group
/// containers are PER-DEVICE: `group.chinchangyang.KataGo-iOS.tw` is entitled
/// on the iPhone too, but nothing the phone writes there is visible here. That
/// is a platform constraint, not a style choice.
///
/// `WidgetCenter` is confined to this type (and the widget target) on purpose:
/// KataGoGameStore compiles for tvOS, which has no WidgetKit.
@MainActor
final class WatchWidgetMirror {
    private let container: ModelContainer
    private let defaults: UserDefaults?

    /// The content key and time of the last reload actually requested, keyed
    /// on the RESOLVED record — what the tile renders — rather than on either
    /// mirror alone.
    private var lastReloadKey: String?
    private var lastReloadAt: Date?

    /// Identity of the row last mirrored, so a refresh whose newest row has
    /// not moved does no SwiftData fetch at all. CloudKit's initial sync fires
    /// a burst of refreshes.
    private var lastMirroredRow: (id: String, modified: Date)?

    init(container: ModelContainer,
         defaults: UserDefaults? = WatchWidgetDefaults.sharedDefaults()) {
        self.container = container
        self.defaults = defaults
        // Retire the previous complication's scalars, once.
        WatchWidgetDefaults.cleanLegacyKeysOnce(in: defaults)
    }

    /// Refresh the `.library` record, and evict a `.live` record whose game is
    /// gone. This is the only writer that sees both worlds, so eviction is its
    /// job: deleting the mirrored game from the Mac while the iPhone app is
    /// closed pushes no further frames, and without this the tile would keep a
    /// dead game — with a newer clock — forever.
    func mirrorLibrary(rows: [WatchLibraryRow],
                       moveCount: (WatchLibraryRow) -> Int,
                       libraryIsAuthoritative: Bool,
                       now: Date = Date()) {
        var records = WatchWidgetDefaults.read(from: defaults)
        var changed = false

        let swept = records.evictingStaleLive(libraryIDs: Set(rows.map(\.id)),
                                              libraryIsAuthoritative: libraryIsAuthoritative)
        if swept != records {
            records = swept
            changed = true
        }

        // A row with no lastModified has no honest ordering, so it is not
        // mirrored at all (the repo contains an 1846-dated sample record
        // shaped exactly like one).
        if let row = rows.first, let modified = row.lastModified {
            let unchanged = lastMirroredRow?.id == row.id && lastMirroredRow?.modified == modified
            if !unchanged {
                if let extras = WatchWidgetLibrarySource.extras(gameID: row.id,
                                                                container: container) {
                    let candidate = WatchWidgetLibrarySource.snapshot(
                        row: row, moveCount: moveCount(row), extras: extras, capturedAt: now)
                    if let updated = records.acceptingLibrary(candidate) {
                        records = updated
                        changed = true
                    }
                }
                lastMirroredRow = (row.id, modified)
            }
        }

        guard changed, WatchWidgetDefaults.write(records, to: defaults) else { return }
        reloadIfNeeded(records, now: now, immediate: false)
    }

    /// Store a live candidate, if it says anything new. `immediate` bypasses
    /// the reload floor for a background wake, where refreshing the tile is
    /// the entire point of having been woken.
    func mirrorLive(_ candidate: WatchWidgetSnapshot,
                    now: Date = Date(),
                    immediate: Bool = false) {
        let records = WatchWidgetDefaults.read(from: defaults)
        guard let updated = records.acceptingLive(candidate),
              WatchWidgetDefaults.write(updated, to: defaults) else { return }
        reloadIfNeeded(updated, now: now, immediate: immediate)
    }

    private func reloadIfNeeded(_ records: WatchWidgetRecords, now: Date, immediate: Bool) {
        let key = records.resolved(now: now)?.contentKey ?? ""
        let elapsed = now.timeIntervalSince(lastReloadAt ?? .distantPast)
        guard immediate || WatchWidgetRefreshPolicy.shouldReload(previousKey: lastReloadKey,
                                                                 nextKey: key,
                                                                 elapsed: elapsed) else { return }
        lastReloadKey = key
        lastReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetDefaults.widgetKind)
    }
}
```

- [ ] **Step 3: Wire it from the root view**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`, add the state beside `latchConsumed` (after line 20):

```swift
    @State private var mirror: WatchWidgetMirror?
```

and install the hook at the top of the existing launch `.task` (before the grace loop at line 41):

```swift
        .task {
            let mirror = mirror ?? WatchWidgetMirror(container: container)
            self.mirror = mirror
            // Fires at the end of every refresh(), including the coalesced
            // remote-change path, so a CloudKit import updates the tile
            // without the user opening the library page.
            library.onRefresh = { [weak library] in
                guard let library else { return }
                mirror.mirrorLibrary(
                    rows: library.rows,
                    moveCount: { library.moveCount(for: $0) },
                    // Never evict on a partial view of the library: a
                    // degraded store, or a fetch that hit its row cap, has
                    // not proved a game is gone.
                    libraryIsAuthoritative:
                        SharedModelContainer.watchStoreMode == .cloudKit
                        && library.rows.count < WatchLibraryStore.fetchLimit)
            }

            let clock = ContinuousClock()
```

- [ ] **Step 4: Build the watch scheme**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo Anytime Watch" "KataGo Anytime Watch/WatchWidgetMirror.swift"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Verify the whole package still builds everywhere the store is linked**

`WatchLibraryStore` gained a public property and compiles for tvOS, which has no WidgetKit — so the tvOS scheme is the one that would catch an accidental import. Run these **one at a time**:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchLibraryStoreTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`, then `TEST SUCCEEDED` (the existing store tests must be unaffected — `onRefresh` is nil there).

- [ ] **Step 6: Verify on the watch simulator**

Run the watch app in the simulator with games synced. The complication (Smart Stack) should show the newest game's name, its move line, and its comment if the parked position has one. Confirm the source glyph is the cloud, not the radio waves — nothing writes the live record yet.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGo Anytime Watch/WatchWidgetMirror.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): mirror the newest library game into the complication record"
```

---

## Task 11: `WatchSnapshot` v1.3 — name, comment, branch flag (slice 3)

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift:78-90`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift:77-85`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchSnapshotV13Tests.swift`

**Interfaces:**
- Consumes: `WatchWidgetSnapshot.cappedComment` (Task 2), `GobanState.isBranchActive` (existing)
- Produces: `WatchSnapshot.gameName: String?`, `.positionComment: String?`, `.isBranch: Bool?`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchSnapshotV13Tests.swift`:

```swift
//
//  WatchSnapshotV13Tests.swift
//  KataGo AnytimeTests
//
//  The fields the complication needs, added the way v1.1 and v1.2 were: all
//  optional, because WCSession persists the last application context across
//  app updates and a watch will decode frames written by an older phone for
//  as long as the two are out of step.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchSnapshotV13Tests {
    private func frame() -> WatchSnapshot {
        WatchSnapshot(boardWidth: 19, boardHeight: 19,
                      blackStones: ["Q16"], whiteStones: ["D4"],
                      toMove: "B", moveNumber: 2, analysisRunning: true,
                      rootWinrateBlack: 0.55, rootScoreLeadBlack: 3.5,
                      candidates: [], hostTimestamp: Date(timeIntervalSince1970: 1_000))
    }

    @Test func theNewFieldsRoundTrip() {
        var snapshot = frame()
        snapshot.gameName = "Ladder Fight 3"
        snapshot.positionComment = "White cuts."
        snapshot.isBranch = true
        let decoded = try! WatchSnapshot.decode(snapshot.encodedData())
        #expect(decoded.gameName == "Ladder Fight 3")
        #expect(decoded.positionComment == "White cuts.")
        #expect(decoded.isBranch == true)
    }

    @Test func aV12PayloadStillDecodes() {
        // The exact compatibility this optionality exists for: a payload
        // written before these fields existed must decode, with nil meaning
        // "older phone" rather than "no name".
        var v12 = frame()
        v12.hostGameID = "GAME-A"
        v12.hostMoveIndex = 42
        v12.lastMoveVertex = "Q16"
        var object = try! JSONSerialization.jsonObject(
            with: v12.encodedData()) as! [String: Any]
        object.removeValue(forKey: "gameName")
        object.removeValue(forKey: "positionComment")
        object.removeValue(forKey: "isBranch")
        let data = try! JSONSerialization.data(withJSONObject: object)

        let decoded = try! WatchSnapshot.decode(data)
        #expect(decoded.gameName == nil)
        #expect(decoded.positionComment == nil)
        #expect(decoded.isBranch == nil)
        #expect(decoded.hostGameID == "GAME-A")
    }

    @Test func aWorstCaseCommentStaysInsideTheWireBound() {
        // The frame rides updateApplicationContext at 2 Hz and is pinned at
        // "~2 KB typical, hard bound 16 KB". Commentator output is a full
        // paragraph, so the cap has to hold at the point the string enters
        // the wire — not only in the App-Group record.
        var snapshot = frame()
        snapshot.gameName = String(repeating: "N", count: 200)
        snapshot.positionComment = WatchWidgetSnapshot.cappedComment(
            String(repeating: "\u{56F4}\u{68CB}", count: 500))
        snapshot.candidates = (0..<10).map { index in
            WatchSnapshot.Candidate(vertex: "Q\(index)", winrate: 0.5, scoreLead: 1,
                                    visits: 1_000,
                                    pv: ["A1", "B2", "C3", "D4", "E5", "F6"])
        }
        #expect(try! snapshot.encodedData().count < 16 * 1024)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchSnapshotV13Tests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchSnapshotV13Tests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: value of type 'WatchSnapshot' has no member 'gameName'`.

- [ ] **Step 3: Add the fields**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift`, after the `lastMoveVertex` declaration:

```swift
    // v1.3 — optional for the same reason every field after v1 is: WCSession
    // persists the last application context across app updates, and on
    // TestFlight the watch and the phone update independently, so
    // watch-1.3 + phone-1.2 is a normal multi-day state.
    /// The game's name, so the complication can name it without a lookup.
    /// The watch backfills from its own library when this is nil, which is
    /// what keeps the tile correct against an older phone.
    public var gameName: String?
    /// The comment stored at `hostMoveIndex`, already capped to the wire
    /// limit by `WatchWidgetSnapshot.cappedComment`.
    public var positionComment: String?
    /// True while the host is on a branch. `hostMoveIndex` is then a BRANCH
    /// index while `hostMoveCount` still describes the saved mainline, so a
    /// consumer must neither pair the two nor look a mainline comment up by
    /// that index.
    public var isBranch: Bool?
```

- [ ] **Step 4: Fill them in the builder**

In `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift`, inside the `if let gameRecord` block, after `snapshot.canPlay = gate.canPlay`:

```swift
            snapshot.gameName = gameRecord.name
            let onBranch = session.gobanState.isBranchActive
            snapshot.isBranch = onBranch
            // A branch index cannot address the saved record's mainline
            // comments, so send none rather than one from a different line.
            snapshot.positionComment = onBranch ? nil : WatchWidgetSnapshot.cappedComment(
                gameRecord.comments?[snapshot.hostMoveIndex ?? 0])
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchSnapshotV13Tests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 6: Run the existing snapshot and builder tests, which must be unaffected**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchSnapshotTests" \
  -only-testing:"KataGo AnytimeTests/WatchSnapshotBuilderTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchSnapshot.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Session/WatchSnapshotBuilder.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchSnapshotV13Tests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): carry the game name, position comment, and branch flag on the wire"
```

---

## Task 12: The live record replaces the legacy scalars (slice 3)

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift:16-27,101,197-209`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` (launch task)
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLiveSourceTests.swift`

**Interfaces:**
- Consumes: `WatchSnapshot` (Task 11), `WatchWidgetSnapshot` (Task 2), `WatchWidgetMirror` (Task 10)
- Produces:
  - `static func WatchWidgetLiveSource.snapshot(from: WatchSnapshot, fallbackName: String?, capturedAt: Date) -> WatchWidgetSnapshot?`
  - `WatchLiveModel.widgetMirror: WatchWidgetMirror?`, `WatchLiveModel.libraryName: ((String) -> String?)?`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLiveSourceTests.swift`:

```swift
//
//  WatchWidgetLiveSourceTests.swift
//  KataGo AnytimeTests
//
//  Which live frames are allowed to become the complication's record, and
//  what the watch fills in when the phone did not send it.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchWidgetLiveSourceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func frame(gameID: String? = "GAME-A",
                       name: String? = "Ladder Fight 3",
                       comment: String? = "White cuts.",
                       index: Int? = 42,
                       count: Int? = 178,
                       branch: Bool? = false) -> WatchSnapshot {
        var snapshot = WatchSnapshot(boardWidth: 19, boardHeight: 19,
                                     blackStones: [], whiteStones: [],
                                     toMove: "B", moveNumber: 0, analysisRunning: true,
                                     rootWinrateBlack: 0.55, rootScoreLeadBlack: 3.5,
                                     candidates: [], hostTimestamp: t0)
        snapshot.hostGameID = gameID
        snapshot.hostMoveIndex = index
        snapshot.hostMoveCount = count
        snapshot.gameName = name
        snapshot.positionComment = comment
        snapshot.isBranch = branch
        return snapshot
    }

    @Test func aNormalFrameBecomesALiveRecord() {
        let record = WatchWidgetLiveSource.snapshot(from: frame(), fallbackName: nil,
                                                    capturedAt: t0)
        #expect(record?.gameID == "GAME-A")
        #expect(record?.name == "Ladder Fight 3")
        #expect(record?.comment == "White cuts.")
        #expect(record?.parkedIndex == 42)
        #expect(record?.mainlineMoveCount == 178)
        #expect(record?.scoreLeadBlack == 3.5)
        #expect(record?.source == .live)
    }

    @Test func aFrameWithNoGameIsRefused() {
        // This is a NORMAL frame, not a malformed one: the builder fills the
        // host fields only `if let gameRecord`, and the relay passes an
        // Optional selectedGameRecord, so a phone cold launch before selection
        // lands pushes exactly this. Accepting it would put a nameless record
        // with a fresh clock ahead of the library.
        #expect(WatchWidgetLiveSource.snapshot(from: frame(gameID: nil),
                                               fallbackName: "Ladder Fight 3",
                                               capturedAt: t0) == nil)
    }

    @Test func anOlderPhoneIsRescuedByTheLibraryName() {
        // A v1.2 phone sends no gameName. Backfilling watch-side is what keeps
        // the tile correct against any phone build — WCSession replays the
        // persisted context on every cold launch, so one stale frame would
        // otherwise regenerate a blank record indefinitely.
        let record = WatchWidgetLiveSource.snapshot(from: frame(name: nil, comment: nil),
                                                    fallbackName: "From Library",
                                                    capturedAt: t0)
        #expect(record?.name == "From Library")
    }

    @Test func aFrameWithNoNameAnywhereIsRefused() {
        #expect(WatchWidgetLiveSource.snapshot(from: frame(name: nil),
                                               fallbackName: nil,
                                               capturedAt: t0) == nil)
        #expect(WatchWidgetLiveSource.snapshot(from: frame(name: "  "),
                                               fallbackName: "   ",
                                               capturedAt: t0) == nil)
    }

    @Test func aBranchFrameCarriesNoComment() {
        // hostMoveIndex is a branch index there; the record's comments are
        // mainline-indexed, so any comment would belong to another line.
        let record = WatchWidgetLiveSource.snapshot(from: frame(comment: "Mainline note.",
                                                                branch: true),
                                                    fallbackName: nil, capturedAt: t0)
        #expect(record?.comment == nil)
        #expect(record?.isBranch == true)
    }

    @Test func aPreV11FrameWithNoCursorStillReportsAPosition() {
        let record = WatchWidgetLiveSource.snapshot(from: frame(index: nil, count: nil),
                                                    fallbackName: nil, capturedAt: t0)
        #expect(record?.parkedIndex == 0)
        #expect(record?.mainlineMoveCount == 0)
    }

    @Test func theCapIsAppliedToTheCommentHereToo() {
        let record = WatchWidgetLiveSource.snapshot(
            from: frame(comment: String(repeating: "a", count: 400)),
            fallbackName: nil, capturedAt: t0)
        #expect(record?.comment?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
    }

    @Test func capturedAtIsTheWatchClockNotTheHostTimestamp() {
        // hostTimestamp is a 2 Hz heartbeat; using it would let a phone idling
        // on an old game outrank every library edit forever.
        let watchNow = t0.addingTimeInterval(9_999)
        let record = WatchWidgetLiveSource.snapshot(from: frame(), fallbackName: nil,
                                                    capturedAt: watchNow)
        #expect(record?.capturedAt == watchNow)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchWidgetLiveSourceTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetLiveSourceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchWidgetLiveSource' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift`:

```swift
//
//  WatchWidgetLiveSource.swift
//  KataGoGameStore
//
//  The phone's live frame, as the record the complication renders.
//
//  There is no comment fallback here on purpose: when both mirrors describe
//  the same game, `WatchWidgetRecords.merged` already lends the library's
//  comment to a live record that has none, and only when the two agree on the
//  index. Duplicating that here would be a second, untested copy of the rule.
//

import Foundation

public enum WatchWidgetLiveSource {
    /// nil when the frame cannot honestly name a game, in which case the
    /// caller must leave the stored record untouched.
    ///
    /// A frame with no `hostGameID` is normal, not malformed: `WatchSnapshotBuilder`
    /// fills the host fields only when it has a `GameRecord`, and the relay
    /// passes an Optional `selectedGameRecord`. Storing one would put a
    /// nameless record with a fresh clock ahead of a perfectly good library
    /// record, and no tap URL could be built from it.
    public static func snapshot(from frame: WatchSnapshot,
                                fallbackName: String?,
                                capturedAt: Date) -> WatchWidgetSnapshot? {
        guard let gameID = frame.hostGameID, !gameID.isEmpty else { return nil }

        let candidates = [frame.gameName, fallbackName]
        guard let name = candidates
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }

        let onBranch = frame.isBranch ?? false
        let parkedIndex = frame.hostMoveIndex ?? 0
        return WatchWidgetSnapshot(
            gameID: gameID,
            name: name,
            // Suppressed on a branch: the index addresses a different line
            // from the one the saved comments are keyed to.
            comment: onBranch ? nil : WatchWidgetSnapshot.cappedComment(frame.positionComment),
            parkedIndex: parkedIndex,
            mainlineMoveCount: frame.hostMoveCount ?? parkedIndex,
            scoreLeadBlack: Double(frame.rootScoreLeadBlack),
            isBranch: onBranch,
            // The WATCH's clock, deliberately: `hostTimestamp` is a 2 Hz
            // heartbeat, not an edit time.
            capturedAt: capturedAt,
            source: .live)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetLiveSourceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Replace `mirrorComplication` in the live model**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift`:

Delete `static let complicationKind` (line 18) and the two stored properties `lastComplicationReload` / `lastComplicationScore` (lines 26-27), and add:

```swift
    /// Set by WatchRootView. The model does not own the mirror: writing the
    /// record needs the SwiftData container for the library half, and the
    /// live path must never touch SwiftData.
    @ObservationIgnored var widgetMirror: WatchWidgetMirror?
    /// Resolves a game id to its library name, so a frame from a phone that
    /// predates the v1.3 wire fields still produces a named tile.
    @ObservationIgnored var libraryName: ((String) -> String?)?
```

Replace the whole `mirrorComplication(_:)` method (lines 197-209) with:

```swift
    /// Project the frame into the complication's record.
    ///
    /// The previous version wrote two App-Group scalars on EVERY ingest — up
    /// to 2 Hz — and gated only the reload, on a half-point score move. Both
    /// halves were wrong for a tile that shows a name and a comment: those
    /// change while the score sits still, and a JSON encode plus a cfprefsd
    /// transaction twice a second is not something to do on watch hardware.
    /// `WatchWidgetMirror` now gates the WRITE on the displayed content and
    /// keeps time only as a floor.
    private func mirrorWidget(_ snapshot: WatchSnapshot) {
        guard let gameID = snapshot.hostGameID,
              let candidate = WatchWidgetLiveSource.snapshot(
                from: snapshot,
                fallbackName: libraryName?(gameID),
                capturedAt: Date()) else { return }
        widgetMirror?.mirrorLive(candidate)
    }
```

and update the call site at line 101:

```swift
        mirrorWidget(snapshot)
```

- [ ] **Step 6: Inject the mirror and the name resolver**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`, inside the launch `.task` added in Task 10, after `self.mirror = mirror`:

```swift
            model.widgetMirror = mirror
            model.libraryName = { [weak library] id in library?.row(id: id)?.name }
```

- [ ] **Step 7: Build the watch scheme and confirm the legacy keys are gone**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
grep -rn "watchScoreLeadBlack\|watchScoreUpdatedAt\|complicationKind" "KataGo Anytime Watch" || echo "no legacy references remain in the watch app"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
```

Expected: `no legacy references remain in the watch app`, then `BUILD SUCCEEDED`.

- [ ] **Step 8: Verify on the paired simulator**

With the phone app open on a game, confirm the tile switches to the live source glyph (radio waves) and follows the phone's position within the 30 s floor. Close the phone app and confirm the tile keeps showing that game rather than reverting.

- [ ] **Step 9: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetLiveSourceTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): drive the complication from the live frame, gated on displayed content"
```

---

## Task 13: The phone's complication push (slice 4)

**Deviation from the spec, recorded here deliberately:** the spec said the push would carry an encoded `WatchWidgetSnapshot`. It carries the ordinary `WatchSnapshot` frame instead. A `WatchWidgetSnapshot` built on the phone would have to carry a phone-clock `capturedAt`, breaking the one-clock invariant the whole merge rests on. Sending the frame lets the watch run it through the same `WatchWidgetLiveSource` path as any other ingest, stamping its own clock — no new wire type, no second code path.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift` (add `pushKey(for:)`)
- Modify: `ios/KataGo iOS/KataGo iOS/Watch/WatchSessionRelay.swift:14-22,53-75`
- Test: append to `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLiveSourceTests.swift`

**Interfaces:**
- Consumes: `WatchWidgetRefreshPolicy.shouldPush` (Task 4), `WatchWidgetLiveSource.snapshot` (Task 12)
- Produces: `static func WatchWidgetLiveSource.pushKey(for: WatchSnapshot) -> String?`

- [ ] **Step 1: Write the failing test**

Append to `ios/KataGo iOS/KataGo iOSTests/WatchWidgetLiveSourceTests.swift`, inside the struct:

```swift
    // MARK: push key

    @Test func thePushKeyIgnoresTheHeartbeat() {
        // The relay rebuilds a frame every 500 ms and candidate visits move on
        // nearly every tick; without a key that ignores them, the phone would
        // burn its ~50 daily transfers in half a minute.
        var later = frame()
        later.hostTimestamp = t0.addingTimeInterval(600)
        later.candidates = [WatchSnapshot.Candidate(vertex: "Q16", winrate: 0.5,
                                                    scoreLead: 1, visits: 99_999, pv: [])]
        #expect(WatchWidgetLiveSource.pushKey(for: frame())
                == WatchWidgetLiveSource.pushKey(for: later))
    }

    @Test func thePushKeyMovesWithTheComment() {
        #expect(WatchWidgetLiveSource.pushKey(for: frame())
                != WatchWidgetLiveSource.pushKey(for: frame(comment: "Black lives.")))
    }

    @Test func aFrameNotWorthStoringIsNotWorthPushing() {
        #expect(WatchWidgetLiveSource.pushKey(for: frame(gameID: nil)) == nil)
        #expect(WatchWidgetLiveSource.pushKey(for: frame(name: nil)) == nil)
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetLiveSourceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: type 'WatchWidgetLiveSource' has no member 'pushKey'`.

- [ ] **Step 3: Add `pushKey(for:)`**

Append to `WatchWidgetLiveSource` in `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift`:

```swift
    /// The content key this frame WOULD produce, for the phone's push gate.
    ///
    /// Reuses the record builder rather than recomputing a key, so the gate
    /// cannot drift from what the watch will actually store — and it returns
    /// nil for exactly the frames the watch would refuse, which is precisely
    /// when a transfer would be wasted. `capturedAt` is irrelevant here:
    /// `contentKey` excludes it.
    public static func pushKey(for frame: WatchSnapshot) -> String? {
        snapshot(from: frame, fallbackName: nil, capturedAt: .distantPast)?.contentKey
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchWidgetLiveSourceTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Push from the relay**

In `ios/KataGo iOS/KataGo iOS/Watch/WatchSessionRelay.swift`, add two stored properties beside `lastSent`:

```swift
    /// Content key and time of the last complication payload enqueued, so a
    /// heartbeat that changes nothing the tile shows never spends a transfer.
    private var lastPushedKey: String?
    private var lastPushedAt: Date?
```

and call the new method at the end of the successful branch in `pushIfChanged`:

```swift
        do {
            try wcSession.updateApplicationContext([WatchSnapshot.contextKey: data])
            lastSent = snapshot
            pushComplicationIfDue(snapshot, data: data,
                                  session: wcSession, now: snapshot.hostTimestamp)
        } catch {
```

then add:

```swift
    /// Wake the watch app in the background so the complication updates
    /// without the user opening it.
    ///
    /// Degrades rather than hard-gates. `isComplicationEnabled` is true only
    /// while the tile sits on an ACTIVE watch face; a Smart-Stack-only
    /// placement leaves it false and `remainingComplicationUserInfoTransfers`
    /// at zero. In that case a plain `transferUserInfo` still lands the next
    /// time the watch app runs, which is no worse than the application context
    /// already achieves — and correctness never depends on this path.
    private func pushComplicationIfDue(_ snapshot: WatchSnapshot,
                                       data: Data,
                                       session: WCSession,
                                       now: Date) {
        guard let key = WatchWidgetLiveSource.pushKey(for: snapshot) else { return }
        let elapsed = now.timeIntervalSince(lastPushedAt ?? .distantPast)
        guard WatchWidgetRefreshPolicy.shouldPush(previousKey: lastPushedKey,
                                                  nextKey: key,
                                                  elapsed: elapsed) else { return }

        // Sweep our own stale transfers first. The queue is FIFO, and the
        // header is explicit that re-tagging a new payload as current only
        // UNTAGS the previous one — it stays queued and can be delivered AFTER
        // the newer frame. The watch's monotonic clock rule makes that
        // harmless, but there is no reason to spend delivery on it.
        for transfer in session.outstandingUserInfoTransfers
        where transfer.userInfo[WatchSnapshot.contextKey] != nil {
            transfer.cancel()
        }

        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo([WatchSnapshot.contextKey: data])
        } else {
            session.transferUserInfo([WatchSnapshot.contextKey: data])
        }
        lastPushedKey = key
        lastPushedAt = now
    }
```

- [ ] **Step 6: Build the iOS scheme**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchWidgetLiveSource.swift" \
        "ios/KataGo iOS/KataGo iOS/Watch/WatchSessionRelay.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchWidgetLiveSourceTests.swift"
git commit -m "feat(watch): push a complication update from the phone on a real change"
```

---

## Task 14: Background wake on the watch (slice 4)

Four changes that cannot be separated: moving activation into `init()` is what makes the wake work, and it is also what makes the existing ingest haptic fire invisibly and the CloudKit store open on a wake.

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/KataGoAnytimeWatchApp.swift` (whole file)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift:61-78,82-87,163-185,211-237`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift` (launch route re-arm)

**Interfaces:**
- Consumes: `WatchWidgetMirror.mirrorLive(_:now:immediate:)` (Task 10), `WatchWidgetLiveSource` (Task 12)
- Produces: `WatchLiveModel.activateForLaunch()`, `.startClock()`, `.drainWatchConnectivity()`

- [ ] **Step 1: Split activation, and gate the haptics**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift`, replace `activate()` (lines 61-78) with:

```swift
    /// The launch-critical half: register the delegate, activate, and replay
    /// the persisted context. Called from `App.init()` so a BACKGROUND launch
    /// — which never evaluates the window body, and therefore never runs
    /// `.onAppear` — still has a delegate to receive the complication payload.
    func activateForLaunch() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if let data = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data {
            ingest(data, receivedAt: nil)
        }
    }

    /// The UI-only half: a 5 s tick so `isStale` re-evaluates without new
    /// frames. Started from the live view, never from `init()` — a background
    /// wake has no staleness to render and no business running a timer.
    func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        }
    }

    /// Hold the process alive until WatchConnectivity has nothing pending.
    ///
    /// Without this the app can be suspended between the delegate callback and
    /// the MainActor hop, so the wake happens and produces nothing — and
    /// `WKBackgroundTask` documents that failing to complete a background task
    /// terminates the app (0xc51bad01/02/03).
    func drainWatchConnectivity() async {
        while WCSession.default.hasContentPending, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
```

Gate the ingest haptic (lines 82-87) so an invisible delivery cannot buzz the wrist:

```swift
        let positionChanged = latest.map { $0.positionKey != snapshot.positionKey } ?? false
        // `applicationState` matters now that the delegate is registered from
        // `init()`: before that, a frame could only arrive with UI on screen.
        // A background delivery must be silent. Not observable in the
        // simulator, which reports the app as active.
        if positionChanged, receivedAt != nil, peek.isLive,
           WKApplication.shared.applicationState == .active {
            WKInterfaceDevice.current().play(.click)
        }
```

Apply the same gate to the two haptics in `handleReply` and `handleTransportFailure` by replacing each `WKInterfaceDevice.current().play(...)` call with:

```swift
            playHapticIfVisible(.success)   // or .failure
```

and add:

```swift
    /// Haptics are feedback for something the wearer just did, so they are
    /// suppressed whenever the app is not on screen.
    private func playHapticIfVisible(_ type: WKHapticType) {
        guard WKApplication.shared.applicationState == .active else { return }
        WKInterfaceDevice.current().play(type)
    }
```

- [ ] **Step 2: Receive the pushed payload**

Add to `ios/KataGo iOS/KataGo Anytime Watch/WatchLiveModel.swift`, beside the other delegate methods:

```swift
    /// The phone's complication payload. Deliberately does NOT go through
    /// `ingest`, for two reasons.
    ///
    /// `session(_:activationDidCompleteWith:)` replays the persisted context
    /// only under `guard self.latest == nil`; setting `latest` from here would
    /// permanently suppress the real mirror frame for the rest of the process,
    /// and `sharedCursorAvailable`, `canPlayNow`, the board page and the launch
    /// route all read it. And this callback fires on a background launch,
    /// where the peek buffer, the shared cursor and the haptics have no
    /// meaning.
    ///
    /// `nonisolated` and Sendable-extracting for the reason this file already
    /// documents at the sendMessage call site: WCSession invokes delegate
    /// methods on its own queue, and a plainly-declared method on a
    /// `@MainActor` type traps off-main.
    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchSnapshot.contextKey] as? Data else { return }
        Task { @MainActor in self.ingestComplicationPayload(data) }
    }

    private func ingestComplicationPayload(_ data: Data) {
        guard let frame = try? WatchSnapshot.decode(data),
              let gameID = frame.hostGameID,
              let candidate = WatchWidgetLiveSource.snapshot(
                from: frame,
                fallbackName: libraryName?(gameID),
                capturedAt: Date()) else { return }
        // `immediate`: refreshing the tile is the entire purpose of the wake,
        // so the reload floor does not apply. The mirror's monotonic rule
        // still rejects a late-delivered older payload.
        widgetMirror?.mirrorLive(candidate, immediate: true)
    }
```

- [ ] **Step 3: Rewrite the app entry point**

Overwrite `ios/KataGo iOS/KataGo Anytime Watch/KataGoAnytimeWatchApp.swift`:

```swift
import SwiftUI
import SwiftData
import KataGoGameStore

@main
struct KataGoAnytimeWatchApp: App {
    // `let`, not `@State`: `init()` calls into it, and the model has no
    // observable state the App scene itself renders.
    private let model = WatchLiveModel()
    /// Built at first UI appearance, NOT in `init()`.
    ///
    /// `SharedModelContainer.shared` takes the CloudKit-only branch on
    /// watchOS: an NSPersistentCloudKitContainer open with schema setup,
    /// mirroring, import/export scheduling and push registration. A background
    /// wake whose whole job is a UserDefaults write and a WidgetCenter reload
    /// must not pay that — the budget it spends is the one the 0xc51bad0x
    /// termination codes police.
    @State private var library: WatchLibraryStore?

    init() {
        // Registering the delegate here — rather than at `.onAppear` — is what
        // lets a background launch for a complication payload be received at
        // all: the window body is never evaluated on such a launch.
        model.activateForLaunch()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let library {
                    WatchRootView(container: SharedModelContainer.shared)
                        .environment(model)
                        .environment(library)
                } else {
                    ProgressView()
                }
            }
            .task {
                model.startClock()
                guard library == nil else { return }
                library = WatchLibraryStore(container: SharedModelContainer.shared,
                                            storeMode: SharedModelContainer.watchStoreMode)
            }
        }
        // SwiftUI completes the underlying WKWatchConnectivityRefreshBackgroundTask
        // when this action returns, so the body must not return before the
        // delegate callback has written the record and asked for the reload.
        .backgroundTask(.watchConnectivity) {
            await model.drainWatchConnectivity()
        }
    }
}
```

- [ ] **Step 4: Re-arm the launch route on the background-to-active transition**

`WatchRootView`'s launch `.task` runs once per SCENE lifetime and `routeOnLaunch()` is one-shot. If the scene is created during a background wake, the 2 s grace burns then and the live auto-push never happens when the user later raises their wrist. In `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`, add:

```swift
    @Environment(\.scenePhase) private var scenePhase
```

and, alongside the existing `.onChange(of: path)`:

```swift
        .onChange(of: scenePhase) { _, phase in
            // A scene created during a background wake has already burned its
            // one-shot launch route with no user present. Re-arm on the first
            // activation, guarded by `latchConsumed` so this can never bounce
            // the user off the library mid-session.
            guard phase == .active else { return }
            routeOnLaunch()
        }
```

- [ ] **Step 5: Build the watch scheme**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:|warning: .*Sendable" | head -20
```

Expected: `BUILD SUCCEEDED` with no Sendable warnings from the new delegate method.

- [ ] **Step 6: Run the watch navigation tests, which the route re-arm must not break**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchNavigationPolicyTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 7: On-wrist QA (this slice cannot be verified in the simulator)**

The simulator reports the app as active, so the haptic gate is invisible there, and paired-simulator WatchConnectivity QA is documented as fragile. On real hardware:

1. Place the complication on a **watch face**, not only the Smart Stack.
2. Lower your wrist so the watch app is not active. Change the position on the phone.
3. Confirm the tile's relative age resets **without** opening the watch app, and that no haptic fired.
4. Repeat with the tile only in the Smart Stack: confirm the tile updates the next time the watch app runs, and that nothing hangs or crashes.
5. Note the observed `isComplicationEnabled` and `remainingComplicationUserInfoTransfers` values for the reference memory in Task 17.

- [ ] **Step 8: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGo Anytime Watch"
git commit -m "feat(watch): update the complication from a background WatchConnectivity wake"
```

---

## Task 15: Give the watch app a real Info.plist and the URL scheme (slice 5)

The watch app is `GENERATE_INFOPLIST_FILE = YES` with four `INFOPLIST_KEY_*` overrides and no `INFOPLIST_FILE`. `CFBundleURLTypes` is an array of dictionaries and has no `INFOPLIST_KEY_` equivalent, so it cannot be declared at all today.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime Watch/Info.plist`
- Create: `ios/KataGo iOS/add_watch_info_plist.rb`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via the script)

**Interfaces:**
- Consumes: `GameDeepLink.scheme` == `"katago-anytime"` (existing)
- Produces: the watch app responds to `katago-anytime://open-game?id=<uuid>`

- [ ] **Step 1: Write the plist**

Create `ios/KataGo iOS/KataGo Anytime Watch/Info.plist`. Every one of the four generated keys is carried forward as a real key — dropping `WKApplication` or `WKCompanionAppBundleIdentifier` silently breaks pairing:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>KataGo Anytime</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>CFBundleURLName</key>
			<string>chinchangyang.KataGo-iOS.tw.watchkitapp</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>katago-anytime</string>
			</array>
		</dict>
	</array>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
	</array>
	<key>WKApplication</key>
	<true/>
	<key>WKCompanionAppBundleIdentifier</key>
	<string>chinchangyang.KataGo-iOS.tw</string>
</dict>
</plist>
```

- [ ] **Step 2: Point the target at it in BOTH configurations**

Create `ios/KataGo iOS/add_watch_info_plist.rb`:

```ruby
#!/usr/bin/env ruby
# Switches the "KataGo Anytime Watch" target from a generated Info.plist to a
# real one, so it can declare CFBundleURLTypes (an array of dictionaries, which
# has no INFOPLIST_KEY_ equivalent) for the katago-anytime scheme the
# complication's widgetURL uses.
#
# Both configurations, and the four generated keys are carried into the plist
# itself — dropping WKApplication or WKCompanionAppBundleIdentifier silently
# breaks pairing. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
TARGET  = 'KataGo Anytime Watch'
PLIST   = 'KataGo Anytime Watch/Info.plist'
GENERATED_KEYS = %w[
  INFOPLIST_KEY_CFBundleDisplayName
  INFOPLIST_KEY_UISupportedInterfaceOrientations
  INFOPLIST_KEY_WKApplication
  INFOPLIST_KEY_WKCompanionAppBundleIdentifier
].freeze

abort("missing #{PLIST} — write it before running this") \
  unless File.exist?(File.join(__dir__, PLIST))

project = Xcodeproj::Project.open(PROJECT)
target = project.targets.find { |t| t.name == TARGET } or abort("missing #{TARGET}")

target.build_configurations.each do |config|
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['INFOPLIST_FILE'] = PLIST
  GENERATED_KEYS.each { |key| config.build_settings.delete(key) }
end

project.save
puts "#{TARGET} now uses #{PLIST} in #{target.build_configurations.map(&:name).join(' and ')}."
```

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby add_watch_info_plist.rb
```

Expected: `KataGo Anytime Watch now uses KataGo Anytime Watch/Info.plist in Debug and Release.`

- [ ] **Step 3: Build, then inspect the Info.plist inside the built app**

Do not assume Xcode merges generated keys into a supplied plist — read the result:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
APP=$(find DerivedData -name "KataGo Anytime Watch.app" -path "*watchsimulator*" | head -1)
/usr/libexec/PlistBuddy -c "Print :WKApplication" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :WKCompanionAppBundleIdentifier" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$APP/Info.plist"
```

Expected: `BUILD SUCCEEDED`, then `true`, `chinchangyang.KataGo-iOS.tw`, `katago-anytime`.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGo Anytime Watch/Info.plist" \
        "ios/KataGo iOS/add_watch_info_plist.rb" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "build(watch): register the katago-anytime URL scheme on the watch app"
```

---

## Task 16: Tap the tile, open that game (slice 5)

Two coupled failures to fix, not one. `routeOnLaunch()` guards only on `path.isEmpty` and would push `.live` over the tap; and `.stored(id)` resolves through a linear scan of `rows`, which is filled only by `WatchLibraryPage.task` — behind a pushed destination, and capped at 100 rows.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift` (add `row(byID:)`)
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`
- Modify: `ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift:41-43`
- Test: `ios/KataGo iOS/KataGo iOSTests/WatchDeepLinkDispositionTests.swift`

**Interfaces:**
- Consumes: `WatchNavigationPolicy.opensLiveMirror` (existing), `GameDeepLink.gameID(from:)` (existing)
- Produces:
  - `enum WatchDeepLinkDisposition: Equatable, Sendable { case wait, live, stored(String), giveUp }`
  - `static func WatchNavigationPolicy.deepLinkDisposition(pendingGameID:hostGameID:hasSnapshot:libraryHasRow:graceExpired:) -> WatchDeepLinkDisposition`
  - `WatchLibraryStore.row(byID:) -> WatchLibraryRow?`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/WatchDeepLinkDispositionTests.swift`:

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
    @Test func tappingTheGameThePhoneIsPlayingOpensTheMirror() {
        // There is never a stale second view of the game the phone is on —
        // the same rule the library rows already follow.
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-A", hasSnapshot: true,
            libraryHasRow: true, graceExpired: true) == .live)
    }

    @Test func tappingAnotherGameOpensTheReplay() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-B", hasSnapshot: true,
            libraryHasRow: true, graceExpired: true) == .stored("GAME-A"))
    }

    @Test func aColdLaunchWaitsRatherThanSayingGameNotFound() {
        // The exact cold-launch case: the tap arrives before the library has
        // loaded and before WCSession has replayed its context, so neither
        // branch can be decided yet. Deciding early is what dead-ends the tap.
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: nil, hasSnapshot: false,
            libraryHasRow: false, graceExpired: false) == .wait)
    }

    @Test func onceTheGraceExpiresAMissingGameGivesUp() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: nil, hasSnapshot: false,
            libraryHasRow: false, graceExpired: true) == .giveUp)
    }

    @Test func theLiveMirrorWinsEvenBeforeTheLibraryLoads() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-A", hasSnapshot: true,
            libraryHasRow: false, graceExpired: false) == .live)
    }

    @Test func aStoredRowWinsBeforeTheGraceExpires() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: nil, hasSnapshot: false,
            libraryHasRow: true, graceExpired: false) == .stored("GAME-A"))
    }

    @Test func aHostGameIdWithoutASnapshotIsNotTheLiveGame() {
        #expect(WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: "GAME-A", hostGameID: "GAME-A", hasSnapshot: false,
            libraryHasRow: true, graceExpired: true) == .stored("GAME-A"))
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/WatchDeepLinkDispositionTests.swift"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchDeepLinkDispositionTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `BUILD FAILED` with `error: cannot find 'WatchDeepLinkDisposition' in scope`.

- [ ] **Step 3: Add the policy**

Append to `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift`:

```swift
/// What to do with a complication tap that named a game.
public enum WatchDeepLinkDisposition: Equatable, Sendable {
    /// Too early to decide — keep the latch and re-evaluate.
    case wait
    case live
    case stored(String)
    /// The game cannot be resolved and never will be; drop the latch.
    case giveUp
}

extension WatchNavigationPolicy {
    /// Precedence for a pending deep link, highest first:
    ///
    ///   1. the phone is playing this exact game -> `.live`
    ///   2. the library can produce a row for it -> `.stored`
    ///   3. neither, but the launch grace has not expired -> `.wait`
    ///   4. otherwise -> `.giveUp`
    ///
    /// `.wait` exists because a cold launch from a tap is the one moment when
    /// BOTH inputs are still missing: the library has not fetched, and
    /// WCSession has not replayed its persisted context. Deciding then is what
    /// dead-ends the tap on "Game not found".
    public static func deepLinkDisposition(pendingGameID: String,
                                           hostGameID: String?,
                                           hasSnapshot: Bool,
                                           libraryHasRow: Bool,
                                           graceExpired: Bool) -> WatchDeepLinkDisposition {
        if opensLiveMirror(rowID: pendingGameID, hostGameID: hostGameID,
                           hasSnapshot: hasSnapshot) {
            return .live
        }
        if libraryHasRow { return .stored(pendingGameID) }
        return graceExpired ? .giveUp : .wait
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/WatchDeepLinkDispositionTests" 2>&1 \
  | grep -E "BUILD FAILED|TEST FAILED|TEST SUCCEEDED|error:" | head -20
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Resolve a game by id without depending on `refresh()`**

Append to `WatchLibraryStore` in `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift`:

```swift
    /// One game by id, independent of `refresh()` ordering and of the
    /// newest-100 window.
    ///
    /// `row(id:)` scans `rows`, which is populated only after a refresh and is
    /// capped at `fetchLimit` — fine for a list the user is looking at, and
    /// wrong for a complication tap that cold-launches the app or names an
    /// older game. Bounded exactly like `WatchBrowseModel.record(for:)`:
    /// `propertiesToFetch` lists precisely the fields a `WatchLibraryRow`
    /// carries, `sgf` included, because the stored-game view replays from it.
    public func row(byID id: String) -> WatchLibraryRow? {
        if let cached = row(id: id) { return cached }
        guard let uuid = UUID(uuidString: id) else { return nil }
        let target: UUID? = uuid
        var descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate { $0.uuid == target },
            sortBy: [.init(\.lastModificationDate, order: .reverse)])
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [
            \.uuid, \.name, \.width, \.height, \.sgf, \.lastModificationDate
        ]
        guard let record = try? container.mainContext.fetch(descriptor).first,
              let recordUUID = record.uuid else { return nil }
        return WatchLibraryRow(id: recordUUID.uuidString,
                               name: record.name,
                               boardWidth: record.width ?? 19,
                               boardHeight: record.height ?? 19,
                               sgf: record.sgf,
                               lastModified: record.lastModificationDate)
    }
```

- [ ] **Step 6: Hoist the refresh out of the library page**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift`, delete these two lines from its `.task` (lines 42-43):

```swift
            library.refresh()
            library.startObservingRemoteChanges()
```

The root view now owns them, so a deep link that never reaches the library page still has rows.

- [ ] **Step 7: Wire the latch in the root view**

In `ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift`:

Add the state:

```swift
    /// The game a complication tap named, held until it can be resolved.
    @State private var pendingDeepLinkID: String?
    /// Set once the launch grace has expired, so an unresolvable link can stop
    /// waiting rather than latch forever.
    @State private var graceExpired = false
```

Take over the refresh, inside the launch `.task` added in Task 10 (after the `onRefresh` hook is installed):

```swift
            library.refresh()
            library.startObservingRemoteChanges()
```

Add the URL entry point and the three re-evaluation points alongside the existing modifiers:

```swift
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
        .onChange(of: model.latest?.hostGameID) { _, _ in applyPendingDeepLink() }
```

Add the resolver, and make `routeOnLaunch` yield to it:

```swift
    /// The one place a pending deep link becomes navigation. Always clears the
    /// latch on a terminal disposition — a stranded latch would suppress
    /// `routeOnLaunch` for the rest of the session.
    private func applyPendingDeepLink() {
        guard let pending = pendingDeepLinkID else { return }
        switch WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: pending,
            hostGameID: model.latest?.hostGameID,
            hasSnapshot: model.latest != nil,
            libraryHasRow: library.row(byID: pending) != nil,
            graceExpired: graceExpired) {
        case .wait:
            return
        case .live:
            // ASSIGN, never append: the app is often already at [.live], and
            // appending would leave a two-deep stack whose back-swipe lands on
            // the mirror instead of the library.
            path = [.live]
        case .stored(let id):
            path = [.stored(id)]
        case .giveUp:
            break
        }
        pendingDeepLinkID = nil
    }

    private func routeOnLaunch() {
        // A tap names a specific game; the launch heuristic must never
        // overwrite it.
        guard pendingDeepLinkID == nil, path.isEmpty else { return }
        let route = WatchNavigationPolicy.launchRoute(hasSnapshot: model.latest != nil,
                                                      latchConsumed: latchConsumed)
        if route == .liveGame { path = [.live] }
    }
```

Finally, set `graceExpired` and re-evaluate at the end of the launch task's grace loop, immediately before `routeOnLaunch()`:

```swift
            graceExpired = true
            applyPendingDeepLink()
            routeOnLaunch()
```

- [ ] **Step 8: Build and exercise the route**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`. Then, with the watch app installed on the simulator and a known game uuid:

```bash
xcrun simctl openurl booted "katago-anytime://open-game?id=<UUID>"
```

Expected: the watch app opens that game's board. Repeat with the app already open on the live mirror (must replace the stack, not stack up), and with a uuid that does not exist (must land on the library, not hang).

- [ ] **Step 9: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchNavigationPolicy.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/WatchLibraryStore.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchRootView.swift" \
        "ios/KataGo iOS/KataGo Anytime Watch/WatchLibraryPage.swift" \
        "ios/KataGo iOS/KataGo iOSTests/WatchDeepLinkDispositionTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(watch): open the tapped game from the complication"
```

---

## Task 17: Documentation, memory, and the full verification sweep

**Files:**
- Modify: `CLAUDE.md` (the watchOS paragraph and the Platform Support list)
- Create: `/Users/chinchangyang/.claude/projects/-Users-chinchangyang-Code-KataGo-ios-dev/memory/project_watch_last_game_widget.md`
- Modify: `/Users/chinchangyang/.claude/projects/-Users-chinchangyang-Code-KataGo-ios-dev/memory/MEMORY.md`

- [ ] **Step 1: Update `CLAUDE.md`**

The watchOS paragraph in the **Building for All Platforms** section describes what the watch links but never mentions the widget target, and will be wrong after this change. In the sentence beginning "The watch links `KataGoGameStore` **and** `GoRulesKit`...", append:

```markdown
The watch also embeds the **`KataGoAnytimeWatchWidget`** complication (`kind: "ScoreLeadWidget"` — a legacy identifier kept so existing placements and the phone's complication push survive; see `WatchWidgetDefaults.widgetKind`). That appex links **only** `KataGoAnalysisKit` (Foundation-only) and reads the App-Group key `watchWidget.records`; it must never link `KataGoGameStore` or touch SwiftData, because on watchOS `SharedModelContainer.shared` takes the CloudKit-only branch with no `groupContainer` and an appex opening it would get a second, permanently empty store. The App Group is a watch-LOCAL channel between the watch app and its complication — containers are per-device, so nothing the iPhone writes there is visible on the watch.
```

- [ ] **Step 2: Write the memory topic file**

Create `project_watch_last_game_widget.md` in the memory directory:

```markdown
---
name: project_watch_last_game_widget
description: Watch complication shows the last game's name + comment; merge rule, App-Group channel, and the traps that shaped it
metadata:
  type: project
---

The watch complication (`kind: "ScoreLeadWidget"`, deliberately not renamed) shows the
name and the comment at the position the last game is parked on. Spec:
`docs/superpowers/specs/2026-08-05-watch-widget-last-game-design.md`.

Non-obvious constraints, all of which cost real debugging to find:

- **The App Group is watch-LOCAL.** Containers are per-device, so the iPhone cannot write
  the record the watch widget reads. All writers live in the watch app process; the phone
  reaches the tile only over WatchConnectivity.
- **The merge key is watch-observed content, not a timestamp.** `lastModificationDate` is
  another device's clock AND does not move when a comment is edited; `hostTimestamp` is a
  2 Hz heartbeat. Both produce a tile pinned to the wrong game.
- **Same game in both mirrors merges per field**, because the phone's parked index and the
  CloudKit replica's routinely differ and the comment lives on only one of them.
- **`kind` renames are destructive twice over**: they orphan placements AND flip
  `WCSession.isComplicationEnabled` to false, silently killing the push.
- **The phone push is an accelerator, never a dependency.** `isComplicationEnabled` is false
  for Smart-Stack-only placements, so the budget is 0 and the transfer degrades to a queued
  `transferUserInfo`.
- Observed `isComplicationEnabled` / `remainingComplicationUserInfoTransfers` behaviour on
  device: <fill in from Task 14 step 7>.
- Measured `accessoryRectangular` content rect at 41 mm and 46 mm: <fill in from Task 8
  step 6>.

**Why:** every one of these looks like an implementation detail and is actually a
correctness rule.
**How to apply:** before changing the widget's data path, re-read the merge rule in
`WatchWidgetRecords`; before renaming anything, check `WatchWidgetDefaults.widgetKind`.

Related: [[project_watchos_companion]], [[project_watch_standalone_library]],
[[project_saved_game_widget]], [[reference_watch_board_page_geometry]].
```

Then add one line to `MEMORY.md` under `## watchOS`:

```markdown
- [Watch last-game widget](project_watch_last_game_widget.md) — name + comment tile; ⚠️ App Group is watch-LOCAL, merge key is watch-observed content
```

- [ ] **Step 3: Note the retired keys in the two specs that document them**

`project_watchos_companion.md` and `project_watch_standalone_library.md` both document
`watchScoreLeadBlack` / `watchScoreUpdatedAt` as live. Add to each: those keys are retired
as of this change and removed once by `WatchWidgetDefaults.cleanLegacyKeysOnce`; the
complication now reads `watchWidget.records`.

- [ ] **Step 4: Full verification sweep — ONE AT A TIME**

The iOS app target depends on and embeds the watch app, which embeds the widget, so a
watch-widget compile error breaks the iOS build and every Xcode Cloud archive. Never run
two of these concurrently (DerivedData lock contention produces spurious `TEST FAILED`),
and never delegate this sweep to a subagent.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"

xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED" | tail -1

xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED" | tail -1

xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 \
  | grep -E "TEST SUCCEEDED|TEST FAILED|failed" | tail -5

xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED" | tail -1

xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED" | tail -1

xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED" | tail -1

cd KataGoUICore && swift test 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED` six times, `TEST SUCCEEDED` once, and a passing `swift test`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add CLAUDE.md
git commit -m "docs: describe the watch complication's link graph and App-Group channel"
```

---

## Self-Review

Run against the spec after the plan was written.

**Spec coverage.** Every section maps to a task: content key and cap (T2), envelope and
per-field merge and eviction (T3), reload/push gating (T4), App-Group seam and legacy
cutover (T5), layout choice and copy (T6), widget link (T7), the three renditions plus AOD,
render modes, degraded states and `widgetURL` (T8), the bounded library fetch (T9), the
mirror and its refresh hook (T10), wire v1.3 (T11), the live writer with its refusals,
backfill and branch suppression (T12), the phone push with FIFO sweep and degradation
(T13), background wake with the activation split, haptic gate, lazy store and route re-arm
(T14), the watch `Info.plist` and URL scheme (T15), the deep-link disposition with
`row(byID:)` and the refresh hoist (T16), and docs plus the sweep (T17). The
`CommentView` flush the spec calls for is T1.

**One deviation, recorded in T13.** The spec said the complication push would carry an
encoded `WatchWidgetSnapshot`; it carries the ordinary `WatchSnapshot` frame instead,
because a record built on the phone would have to carry a phone-clock `capturedAt` and
break the one-clock invariant the merge depends on.

**Two things the spec left open, resolved here.** The `libraryIsAuthoritative` guard is
`storeMode == .cloudKit && rows.count < fetchLimit` — the spec mentioned only the store
mode, but a fetch that hit its row cap has not proved a game is gone either. And the
separator in tile copy is ASCII `" - "`, per `WatchLibraryRow.sizeText`'s existing rule,
superseding the typographic middot in the spec's mockups.

**Type consistency.** Every signature produced in one task is used with the same
argument labels in every later task; the `WatchWidgetSnapshot` memberwise initializer,
`WatchWidgetRecords.acceptingLive` / `acceptingLibrary` / `evictingStaleLive` /
`resolved(now:)`, the two `WatchWidgetRefreshPolicy` predicates, and the
`WatchWidgetMirror.mirrorLive(_:now:immediate:)` call sites in T12 and T14 were checked
against each other by hand.

**Known unresolved.** The rectangular layout's exact fit is a hypothesis until T8 step 6
probes it on a 41 mm and a 46 mm simulator; the step says what to change first if it
clips. The background-wake and push behaviour cannot be verified in a simulator at all —
T14 step 7 is on-wrist QA, and the two numbers it records feed the memory file in T17.
