# tvOS Narrated Auto-Play + Controller Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Review auto-play on Apple TV becomes the same commentated broadcast as a live game — slides, typewriter, and NEW spoken narration — and a game controller starts its cursor at the last move and can step through positions while aiming.

**Architecture:** `BroadcastController` (KataGoUICore/Report) gains three seams — a `NarrationSpeaking` speaker, a `BroadcastPacing` provider, and a `replayAdvance` move source that plays the next *recorded* move instead of a licensed gen-move. `TVReviewScreen` replaces its bare timer loop with a replay-configured controller driven by a phase observer + `TVAutoPlayPolicy`. The ghost cursor's last-move anchor is the extracted visionOS `LastMoveKey` hook; step-while-aiming is a restructured `guard` in the review screen's controller handler.

**Tech Stack:** SwiftUI (tvOS 26), Swift Testing (`@Test`/`#expect`), AVFoundation (`AVSpeechSynthesizer`), the existing C++ GTP bridge (untouched).

**Spec:** `docs/superpowers/specs/2026-08-10-tvos-narrated-autoplay-controller-design.md`. One requirement in this plan is NOT in the spec text but is mandated by a constraint the spec inherits: `BroadcastController`'s header warns that BoardView's turn observer sends asymmetric human-SL `kata-set-param` bundles whose acks desync the report collector's FIFO. Synced review games are often asymmetric (Human vs 9d), so Task 6 adds a suppression flag the review screen sets during replay.

## Global Constraints

- English-only in every committed file (code, comments, docs).
- NEVER modify SwiftData `@Model` classes (`GameRecord`, `Config` are CloudKit-frozen). `GobanState` is a plain `@Observable` class — adding a `var` there is fine.
- The broadcast engine-state protocol is load-bearing and must not change: `analysisStatus` stays `.clear` while a broadcast runs, `suppressesGenMove` stays `true`, `maybePauseAnalysis` is never called around generation. Replay mode *subtracts* the gen-move; it adds no new engine traffic.
- Replay is a spectator: the CloudKit-synced `GameRecord`'s SGF and per-move dictionaries are never written from the replay path.
- tvOS focus rules: `onMoveCommand` is only a fallback (a focusable target in the pressed direction wins); `FocusState` writes are post-render requests, so mode flags stay plain state (`isAiming`); never leave zero focusable elements on screen; the `tvSelectPress` catcher is window-wide — at most one armed consumer at a time; never bind A/B/Menu/D-pad/Options/Home via GameController.
- Never run two `xcodebuild` invocations concurrently (DerivedData lock ⇒ spurious TEST FAILED). Run builds/tests sequentially, one at a time.
- Piped `xcodebuild` exit codes lie: judge by the literal `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **` line in the output.
- Unit tests live in the iOS-host target **"KataGo AnytimeTests"** (folder `KataGo iOSTests/`); the tvOS app target is unreachable from every test target, so all new logic that needs tests goes in KataGoUICore. New test *files* must be registered in the pbxproj via the `xcodeproj` Ruby gem (the project does not use synchronized folder groups). New KataGoUICore package sources need no registration.
- All paths below are relative to `/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS` unless absolute. Run all commands from that directory.
- Commit after every task. Do not push (pushes trigger Xcode Cloud → TestFlight; the user spaces them ≥ ~1 day).
- Commit-message trailer (every commit):
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01RQscogagopHKTm73HDUZ2r`

**Standard test command** (referenced as *RUN-TESTS(SuiteName)* below):

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/SuiteName" 2>&1 | tail -30
```

Expected on success: `** TEST SUCCEEDED **` in the tail. (The first run compiles the whole app — slow; later runs are incremental.)

**Standard TV build command** (referenced as *BUILD-TV*):

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 1: Broadcast pacing profiles

`TVAutoPlaySpeed` stops meaning "seconds per stone" and starts meaning "broadcast pacing profile". This task only ADDS (`BroadcastPacing`, `broadcastPacing`, `current`); the old `seconds`/`interval` are deleted in Task 7 when their last consumer (the review timer) dies.

**Files:**
- Modify: `KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift` (add `BroadcastPacing` next to `BroadcastConstants`)
- Modify: `KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlaySpeed.swift`
- Test: `KataGo iOSTests/TVAutoPlaySpeedTests.swift` (existing file — no registration needed)

**Interfaces:**
- Produces: `public struct BroadcastPacing: Equatable, Sendable { let charactersPerSecond: Double; let dwellSeconds: TimeInterval; let minimumSlideSeconds: TimeInterval; let maxSlideCount: Int; static let live: BroadcastPacing }`, `TVAutoPlaySpeed.broadcastPacing: BroadcastPacing`, `TVAutoPlaySpeed.current: TVAutoPlaySpeed` (static UserDefaults read). Tasks 4, 5, 7 consume these.

- [ ] **Step 1: Write the failing tests** — append to `TVAutoPlaySpeedTests.swift`:

```swift
    @Test("Slow replay pacing is live-broadcast parity")
    func slowPacingIsLive() {
        #expect(TVAutoPlaySpeed.slow.broadcastPacing == BroadcastPacing.live)
        #expect(BroadcastPacing.live.charactersPerSecond == BroadcastConstants.charactersPerSecond)
        #expect(BroadcastPacing.live.dwellSeconds == BroadcastConstants.dwellSeconds)
        #expect(BroadcastPacing.live.minimumSlideSeconds == BroadcastConstants.minimumSlideSeconds)
        #expect(BroadcastPacing.live.maxSlideCount == Int.max)
    }

    @Test("Normal and fast pacing tighten monotonically; fast is best-slide-only")
    func fasterProfilesTighten() {
        let slow = TVAutoPlaySpeed.slow.broadcastPacing
        let normal = TVAutoPlaySpeed.normal.broadcastPacing
        let fast = TVAutoPlaySpeed.fast.broadcastPacing
        #expect(normal.charactersPerSecond > slow.charactersPerSecond)
        #expect(fast.charactersPerSecond > normal.charactersPerSecond)
        #expect(normal.dwellSeconds < slow.dwellSeconds)
        #expect(fast.dwellSeconds < normal.dwellSeconds)
        #expect(normal.minimumSlideSeconds < slow.minimumSlideSeconds)
        #expect(fast.minimumSlideSeconds < normal.minimumSlideSeconds)
        #expect(normal.maxSlideCount == Int.max)
        #expect(fast.maxSlideCount == 1)
    }

    @Test("current reads the defaults key, falling back to the default")
    func currentReadsDefaults() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: TVAutoPlaySpeed.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: TVAutoPlaySpeed.defaultsKey) }
            else { defaults.removeObject(forKey: TVAutoPlaySpeed.defaultsKey) }
        }
        defaults.removeObject(forKey: TVAutoPlaySpeed.defaultsKey)
        #expect(TVAutoPlaySpeed.current == TVAutoPlaySpeed.defaultValue)
        defaults.set(TVAutoPlaySpeed.fast.rawValue, forKey: TVAutoPlaySpeed.defaultsKey)
        #expect(TVAutoPlaySpeed.current == .fast)
        defaults.set("garbage", forKey: TVAutoPlaySpeed.defaultsKey)
        #expect(TVAutoPlaySpeed.current == TVAutoPlaySpeed.defaultValue)
    }
```

- [ ] **Step 2: Run to verify failure** — *RUN-TESTS(TVAutoPlaySpeedTests)*. Expected: BUILD FAILED, `cannot find 'BroadcastPacing' in scope` (a compile failure IS the red step for a missing type).

- [ ] **Step 3: Implement** — in `BroadcastScript.swift`, directly below the `BroadcastConstants` enum:

```swift
/// One replay/broadcast pacing profile. The live self-play broadcast always
/// runs `.live`; the review replay maps TVAutoPlaySpeed onto tighter
/// profiles. Only the typewriter, dwell, floor, and slide count scale —
/// choreography beats, PV cadence, and the poll interval stay stock, and
/// speech is never rate-shifted (an unfinished utterance holds the slide).
public struct BroadcastPacing: Equatable, Sendable {
    public let charactersPerSecond: Double
    public let dwellSeconds: TimeInterval
    public let minimumSlideSeconds: TimeInterval
    /// Fact slides per cycle; the replay Comment slide is NOT counted.
    public let maxSlideCount: Int

    public init(charactersPerSecond: Double, dwellSeconds: TimeInterval,
                minimumSlideSeconds: TimeInterval, maxSlideCount: Int) {
        self.charactersPerSecond = charactersPerSecond
        self.dwellSeconds = dwellSeconds
        self.minimumSlideSeconds = minimumSlideSeconds
        self.maxSlideCount = maxSlideCount
    }

    public static let live = BroadcastPacing(
        charactersPerSecond: BroadcastConstants.charactersPerSecond,
        dwellSeconds: BroadcastConstants.dwellSeconds,
        minimumSlideSeconds: BroadcastConstants.minimumSlideSeconds,
        maxSlideCount: Int.max)
}
```

In `TVAutoPlaySpeed.swift`, add below `defaultValue` (leave `seconds`/`interval` alone for now — the review timer still uses them until Task 7):

```swift
    /// The persisted speed right now. For escaping closures that must read
    /// the CURRENT value each cycle (a captured @AppStorage copy would not).
    public static var current: TVAutoPlaySpeed {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let speed = TVAutoPlaySpeed(rawValue: raw) else { return defaultValue }
        return speed
    }

    /// How this speed paces the commentated replay (see BroadcastPacing).
    /// Slow IS the live broadcast; normal tightens text; fast shows only the
    /// Best Move slide at the tightest text pacing.
    public var broadcastPacing: BroadcastPacing {
        switch self {
        case .slow:
            .live
        case .normal:
            BroadcastPacing(charactersPerSecond: 45, dwellSeconds: 1.5,
                            minimumSlideSeconds: 4.0, maxSlideCount: Int.max)
        case .fast:
            BroadcastPacing(charactersPerSecond: 60, dwellSeconds: 1.0,
                            minimumSlideSeconds: 3.0, maxSlideCount: 1)
        }
    }
```

- [ ] **Step 4: Run to verify pass** — *RUN-TESTS(TVAutoPlaySpeedTests)*. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift" \
        "KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlaySpeed.swift" \
        "KataGo iOSTests/TVAutoPlaySpeedTests.swift"
git commit -m "feat(tv): add BroadcastPacing profiles behind TVAutoPlaySpeed"
```

---

### Task 2: Spoken-narration setting + speaker

**Files:**
- Create: `KataGoUICore/Sources/KataGoUICore/Util/NarrationSpeechSetting.swift`
- Create: `KataGoUICore/Sources/KataGoUICore/Services/NarrationSpeaker.swift`
- Test: `KataGo iOSTests/TVAutoPlaySpeedTests.swift` gets nothing; create `KataGo iOSTests/NarrationSpeechSettingTests.swift` (MUST be registered in the pbxproj — Step 3)

**Interfaces:**
- Produces: `NarrationSpeechSetting.defaultsKey` (= `"TVSettings.spokenNarration"`), `.defaultValue` (= `true`), `.isEnabled: Bool`; `@MainActor public protocol NarrationSpeaking: AnyObject { func speak(_ text: String); var isSpeaking: Bool { get }; func cancelAll() }`; `AVSpeechNarrationSpeaker: NarrationSpeaking`. Tasks 4, 7, 8 consume these.

- [ ] **Step 1: Write the failing test** — new file `KataGo iOSTests/NarrationSpeechSettingTests.swift`:

```swift
//
//  NarrationSpeechSettingTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGoUICore

struct NarrationSpeechSettingTests {
    @Test("Spoken narration defaults ON and reads the settings key")
    func defaultsOnAndReadsKey() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: NarrationSpeechSetting.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: NarrationSpeechSetting.defaultsKey) }
            else { defaults.removeObject(forKey: NarrationSpeechSetting.defaultsKey) }
        }
        defaults.removeObject(forKey: NarrationSpeechSetting.defaultsKey)
        #expect(NarrationSpeechSetting.isEnabled)          // absent key = default ON
        defaults.set(false, forKey: NarrationSpeechSetting.defaultsKey)
        #expect(!NarrationSpeechSetting.isEnabled)
        defaults.set(true, forKey: NarrationSpeechSetting.defaultsKey)
        #expect(NarrationSpeechSetting.isEnabled)
    }

    @Test("The defaults key follows the TVSettings prefix convention")
    func keyName() {
        #expect(NarrationSpeechSetting.defaultsKey == "TVSettings.spokenNarration")
        #expect(NarrationSpeechSetting.defaultValue == true)
    }
}
```

- [ ] **Step 2: Register the new test file in the pbxproj** (the project has no synchronized groups):

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = proj.targets.find { |t| t.name == "KataGo AnytimeTests" }
raise "target not found" unless target
ref = proj.main_group.new_reference("KataGo iOSTests/NarrationSpeechSettingTests.swift")
target.source_build_phase.add_file_reference(ref)
proj.save
puts "registered"
'
```

Expected: `registered`. (If the gem is missing: `gem install xcodeproj --user-install`. Sanity-check afterwards that an existing test file like `BinFileHasherTests.swift` sits in the same group so the reference style matches.)

- [ ] **Step 3: Run to verify failure** — *RUN-TESTS(NarrationSpeechSettingTests)*. Expected: BUILD FAILED, `cannot find 'NarrationSpeechSetting'`.

- [ ] **Step 4: Implement** — `KataGoUICore/Sources/KataGoUICore/Util/NarrationSpeechSetting.swift`:

```swift
//
//  NarrationSpeechSetting.swift
//  KataGoUICore
//
//  Whether the tvOS broadcast narration is spoken aloud. Extracted into
//  KataGoUICore (the TVAutoPlaySpeed precedent) so the default and key are
//  one source of truth for the Settings toggle's @AppStorage and the
//  broadcast's per-slide read, and unit-testable from the iOS test host.
//

import Foundation

public enum NarrationSpeechSetting {
    /// The one UserDefaults key, shared by the Settings toggle's @AppStorage
    /// and the broadcast's isSpeechEnabled closure.
    public static let defaultsKey = "TVSettings.spokenNarration"

    /// ON by default: the feedback that created this feature asked for
    /// spoken narration outright.
    public static let defaultValue = true

    public static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return defaultValue }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
```

`KataGoUICore/Sources/KataGoUICore/Services/NarrationSpeaker.swift`:

```swift
//
//  NarrationSpeaker.swift
//  KataGoUICore
//
//  Speaks broadcast narration aloud. The protocol is the test seam:
//  BroadcastController's "hold the slide until speech finishes" pacing is
//  driven by a fake; the AVSpeechSynthesizer conformer stays logic-free and
//  deliberately untested. Audio rides the session AudioModel already
//  configures (.playback, .mixWithOthers) — no session code here.
//

import AVFoundation

@MainActor
public protocol NarrationSpeaking: AnyObject {
    /// Enqueue one fact's sentence. Utterances play in submission order.
    func speak(_ text: String)
    /// True while an utterance is speaking or queued.
    var isSpeaking: Bool { get }
    /// Stop mid-word and drop the queue.
    func cancelAll()
}

@MainActor
public final class AVSpeechNarrationSpeaker: NarrationSpeaking {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        // The narration facts are English regardless of the device locale.
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func cancelAll() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
```

(`Services/` is the right directory — it already holds `AudioModel.swift`.)

- [ ] **Step 5: Run to verify pass** — *RUN-TESTS(NarrationSpeechSettingTests)*. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A "KataGoUICore/Sources/KataGoUICore" "KataGo iOSTests/NarrationSpeechSettingTests.swift" "KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(tv): add the spoken-narration setting and AVSpeech speaker seam"
```

---

### Task 3: The Comment slide kind

**Files:**
- Modify: `KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift` (`BroadcastSlideKind`, `frames(for:model:)`, `factsMayGrow`)
- Test: `KataGo iOSTests/BroadcastScriptTests.swift` (existing file)

**Interfaces:**
- Produces: `BroadcastSlideKind.comment`. A `.comment` slide has NO choreography frames (`frames` returns `[]`) and its facts never grow. Task 5's `presentStandalone` builds `BroadcastSlide(kind: .comment, title: "Comment", facts: [text])`.

- [ ] **Step 1: Write the failing test** — append to `BroadcastScriptTests.swift` (match its existing style; it is `@MainActor`):

```swift
    @Test("A comment slide has no choreography and never grows")
    func commentSlideIsStaticAndFrameless() {
        let model = DeepReportModel()
        let slide = BroadcastSlide(kind: .comment, title: "Comment",
                                   facts: ["A synced note about this move."])
        #expect(BroadcastScript.frames(for: slide, model: model).isEmpty)
        #expect(!BroadcastScript.factsMayGrow(kind: .comment, model: model))
    }
```

- [ ] **Step 2: Run to verify failure** — *RUN-TESTS(BroadcastScriptTests)*. Expected: BUILD FAILED, `type 'BroadcastSlideKind' has no member 'comment'`.

- [ ] **Step 3: Implement** — in `BroadcastScript.swift`:

Add the case:

```swift
public enum BroadcastSlideKind: Equatable, Sendable {
    case best
    case alternative
    case pass
    /// A replay-only slide carrying a synced per-move GameRecord comment.
    /// Built by BroadcastController (never by slides(from:)); it shows over
    /// the LIVE hero board — frames(for:model:) is empty and currentFrame
    /// stays nil while it types.
    case comment
}
```

In `frames(for:model:)`, add a case to the `switch slide.kind`:

```swift
        case .comment:
            // The live board IS the visual; nothing to act out.
            return []
```

In `factsMayGrow(kind:model:)`, add to the `switch kind`:

```swift
        case .comment:
            return false
```

- [ ] **Step 4: Run to verify pass** — *RUN-TESTS(BroadcastScriptTests)*. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Report/BroadcastScript.swift" "KataGo iOSTests/BroadcastScriptTests.swift"
git commit -m "feat(tv): add the frameless Comment slide kind"
```

---

### Task 4: BroadcastController speaks and paces

Speech + pacing integration into the cycle. The controller gains four init parameters (all defaulted, so the self-play screen and all existing tests compile unchanged): `speaker`, `isSpeechEnabled`, `pacing`, and `replayAdvance` (stored now, USED in Task 5 — declaring it here avoids touching the init twice).

**Files:**
- Modify: `KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift`
- Test: create `KataGo iOSTests/BroadcastReplayTests.swift` (register in pbxproj — this file will also hold Task 5's and Task 6's tests)

**Interfaces:**
- Consumes: `NarrationSpeaking` (Task 2), `BroadcastPacing` (Task 1).
- Produces: the extended init
  `BroadcastController(messageList:gobanState:player:rootWinrate:rootScore:generateReport:sleeper:speaker:isSpeechEnabled:pacing:replayAdvance:)` with defaults `speaker: NarrationSpeaking? = nil`, `isSpeechEnabled: @escaping () -> Bool = { false }`, `pacing: @escaping () -> BroadcastPacing = { .live }`, `replayAdvance: (@MainActor () -> String?)? = nil`. Behavior: one utterance per fact enqueued as the fact starts typing; slide advance waits for typewriter AND empty speech queue AND the pacing dwell/floor; skip/pause/cancelAll cancel speech immediately; `pacing()` drives `charactersPerSecond`, `dwellSeconds`, `minimumSlideSeconds`.

- [ ] **Step 1: Create and register the test file** — `KataGo iOSTests/BroadcastReplayTests.swift` with the fixture + speech tests:

```swift
//
//  BroadcastReplayTests.swift
//  KataGo AnytimeTests
//
//  The replay move source, spoken narration, and pacing seams of the
//  broadcast cycle — all timing-free (the BroadcastControllerTests pattern:
//  scripted generator, yield-only sleeper, bounded MainActor pumps).
//

import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
final class FakeSpeaker: NarrationSpeaking {
    var spoken: [String] = []
    var cancelCount = 0
    /// true = utterances finish instantly (ordering tests);
    /// false = the queue holds until finishAll() (pacing tests).
    var autoFinishes = true
    private var queueDepth = 0

    func speak(_ text: String) {
        spoken.append(text)
        if !autoFinishes { queueDepth += 1 }
    }

    var isSpeaking: Bool { queueDepth > 0 }

    func cancelAll() {
        queueDepth = 0
        cancelCount += 1
    }

    func finishAll() { queueDepth = 0 }
}

@MainActor
struct BroadcastReplayTests {

    private static func stageFullReport(_ model: DeepReportModel) {
        model.sideToMove = .black
        model.boardWidth = 9
        model.boardHeight = 9
        model.moveNumber = 3
        model.position = PositionSummary(winrate: 0.6, scoreLead: 2.0, visits: 200)
        model.candidates = [
            CandidateReport(vertex: "E5", visits: 120, winrate: 0.6, scoreLead: 2.0,
                            winrateDelta: 0, scoreLeadDelta: 0, pv: ["E5", "C3"],
                            ownershipDelta: [:],
                            tenuki: TenukiFollowUp(vertex: "C3", winrate: 0.65,
                                                   scoreLead: 3.0, visits: 40, pv: ["C3"])),
            CandidateReport(vertex: "C3", visits: 60, winrate: 0.58, scoreLead: 1.5,
                            winrateDelta: -0.02, scoreLeadDelta: -0.5, pv: ["C3"],
                            ownershipDelta: [BoardPoint(x: 2, y: 2): -0.4],
                            tenuki: TenukiFollowUp(vertex: "E5", winrate: 0.6,
                                                   scoreLead: 2.0, visits: 30, pv: ["E5"])),
        ]
        model.passComparison = PassComparison(punishmentVertex: "E5", winrate: 0.35,
                                              scoreLead: -3.0, winrateDeltaVsBest: 0.25,
                                              scoreLeadDeltaVsBest: 5.0,
                                              ownershipDelta: [:], contestedPoints: [])
        model.stage = .complete
    }

    @MainActor
    private struct Fixture {
        let session = GameSession()
        let record: GameRecord
        let controller: BroadcastController
        let speaker = FakeSpeaker()

        init(speechEnabled: Bool = true,
             pacing: BroadcastPacing = .live,
             replayAdvance: (@MainActor () -> String?)? = nil,
             generate: @escaping @MainActor (DeepReportModel, GameRecord) async -> Void
                = { model, _ in BroadcastReplayTests.stageFullReport(model) }) {
            record = SelfPlayGame.makeRecord()
            session.board.width = 9
            session.board.height = 9
            session.player.nextColorForPlayCommand = .black
            session.gobanState.suppressesGenMove = true
            session.gobanState.analysisStatus = .clear
            controller = BroadcastController(messageList: session.messageList,
                                             gobanState: session.gobanState,
                                             player: session.player,
                                             rootWinrate: session.rootWinrate,
                                             rootScore: session.rootScore,
                                             generateReport: generate,
                                             sleeper: { _ in await Task.yield() },
                                             speaker: speaker,
                                             isSpeechEnabled: { speechEnabled },
                                             pacing: { pacing },
                                             replayAdvance: replayAdvance)
        }

        func sent(_ fragment: String) -> Bool {
            session.messageList.messages.contains { $0.text.contains(fragment) }
        }

        func pump(until condition: () -> Bool) async {
            for _ in 0..<20_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("pump timed out")
        }
    }

    // MARK: - Speech

    @Test("Enabled speech speaks every fact of every slide, in order")
    func speaksAllFactsInOrder() async {
        let f = Fixture()
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        let allFacts = BroadcastScript.slides(from: f.controller.reportModel!)
            .flatMap { $0.facts }
        #expect(!allFacts.isEmpty)
        #expect(f.speaker.spoken == allFacts)
    }

    @Test("Disabled speech speaks nothing")
    func disabledSpeaksNothing() async {
        let f = Fixture(speechEnabled: false)
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.speaker.spoken.isEmpty)
    }

    @Test("An unfinished utterance holds the slide; finishing releases it")
    func slideWaitsForSpeech() async {
        let f = Fixture()
        f.speaker.autoFinishes = false
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.slideNumber == 1 })
        // Let the typewriter and dwell run out; the speech queue still holds.
        for _ in 0..<3000 { await Task.yield() }
        #expect(f.controller.slideNumber == 1)
        f.speaker.finishAll()
        await f.pump(until: { f.controller.slideNumber >= 2 })
    }

    @Test("Skip cancels speech immediately")
    func skipCancelsSpeech() async {
        let f = Fixture()
        f.speaker.autoFinishes = false
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.slideNumber == 1 })
        f.controller.skipSlide()
        await f.pump(until: { f.speaker.cancelCount >= 1 })
        await f.pump(until: { f.controller.slideNumber >= 2 })
    }

    @Test("Pause and cancelAll cancel speech")
    func pauseAndCancelAllCancelSpeech() async {
        let f = Fixture()
        f.speaker.autoFinishes = false
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.isShowingSlides })
        await f.controller.pause(game: f.record)
        #expect(f.speaker.cancelCount >= 1)

        let g = Fixture()
        g.speaker.autoFinishes = false
        g.controller.noteTurnChanged(game: g.record)
        await g.pump(until: { g.controller.isShowingSlides })
        g.controller.cancelAll()
        #expect(g.speaker.cancelCount >= 1)
    }
}
```

Register the file:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = proj.targets.find { |t| t.name == "KataGo AnytimeTests" }
ref = proj.main_group.new_reference("KataGo iOSTests/BroadcastReplayTests.swift")
target.source_build_phase.add_file_reference(ref)
proj.save
puts "registered"
'
```

- [ ] **Step 2: Run to verify failure** — *RUN-TESTS(BroadcastReplayTests)*. Expected: BUILD FAILED, `extra arguments at positions ... in call` (the init lacks the new parameters).

- [ ] **Step 3: Implement in `BroadcastController.swift`:**

(a) Stored properties after `sleeper`:

```swift
    /// Spoken narration (nil = silent). One utterance per fact, enqueued as
    /// the fact starts typing; the end-of-slide hold waits the queue out.
    private let speaker: NarrationSpeaking?
    private let isSpeechEnabled: () -> Bool
    /// Read fresh each use so a mid-broadcast Settings change takes effect
    /// on the next slide.
    private let pacing: () -> BroadcastPacing
    /// Replay move source: non-nil switches the cycle's ending from the
    /// licensed gen-move to "play the next RECORDED move", returning the
    /// synced comment for the new position (nil = none). See Task 5.
    private let replayAdvance: (@MainActor () -> String?)?
```

(b) Extend the init (add the four defaulted parameters and assignments):

```swift
    public init(messageList: MessageList,
                gobanState: GobanState,
                player: Turn,
                rootWinrate: Winrate,
                rootScore: Score,
                generateReport: (@MainActor (DeepReportModel, GameRecord) async -> Void)? = nil,
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) },
                speaker: NarrationSpeaking? = nil,
                isSpeechEnabled: @escaping () -> Bool = { false },
                pacing: @escaping () -> BroadcastPacing = { .live },
                replayAdvance: (@MainActor () -> String?)? = nil) {
```

with `self.speaker = speaker`, `self.isSpeechEnabled = isSpeechEnabled`, `self.pacing = pacing`, `self.replayAdvance = replayAdvance` at the end of the body.

(c) In `present(slideIndex:model:)`:

- Right after `emitDueFactFrames()` (inside the `if factIndex < facts.count` branch), before the chunk loop:

```swift
                if isSpeechEnabled() { speaker?.speak(facts[factIndex]) }
```

- Replace the hard-coded reveal rate in the chunk loop:

```swift
                    let delay = Double(chunk.count) / pacing().charactersPerSecond
```

- Replace the skip-consumption early return (currently `if skipRequested { skipRequested = false; return }`) with:

```swift
        if skipRequested {
            skipRequested = false
            speaker?.cancelAll()
            return
        }
```

- Replace the whole dwell block (from `let dwell = max(...)` through the end of the method) with a call to the shared hold:

```swift
        await waitOutDwellAndSpeech(elapsed: elapsed)
    }
```

(d) New private method below `present`:

```swift
    /// The end-of-slide hold: the pacing dwell/floor PLUS, when narration is
    /// on, the remainder of the utterance queue (speech is never rate-
    /// shifted, so on fast pacing it becomes the slide's floor). Polled so a
    /// skip is honored AND consumed (the F4 regression) and cancellation is
    /// prompt; a consumed skip also cuts the speech off mid-word.
    private func waitOutDwellAndSpeech(elapsed: TimeInterval) async {
        let dwell = max(pacing().minimumSlideSeconds - elapsed,
                        pacing().dwellSeconds)
        var dwelled: TimeInterval = 0
        while dwelled < dwell || speaker?.isSpeaking == true {
            if Task.isCancelled { return }
            if skipRequested {
                skipRequested = false
                speaker?.cancelAll()
                return
            }
            try? await sleeper(BroadcastConstants.pollSeconds)
            dwelled += BroadcastConstants.pollSeconds
        }
    }
```

(e) In `pause(game:)`'s task body, right after the `guard !Task.isCancelled else { return }` line:

```swift
            self.speaker?.cancelAll()
```

(f) In `cancelAll()`, after `gobanState.broadcastGenMovePending = false`:

```swift
        speaker?.cancelAll()
```

- [ ] **Step 4: Run to verify pass** — *RUN-TESTS(BroadcastReplayTests)*. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Run the existing broadcast suites (regression)** — *RUN-TESTS(BroadcastControllerTests)*. Expected: `** TEST SUCCEEDED **` (the defaults keep every existing fixture silent and live-paced).

- [ ] **Step 6: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift" \
        "KataGo iOSTests/BroadcastReplayTests.swift" "KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(tv): broadcast slides speak their facts and honor pacing profiles"
```

---

### Task 5: BroadcastController replay mode

The `replayAdvance` seam goes live: a replay cycle never gen-moves, never chains internally, caps its slides per the pacing profile (cancelling the leftover generation the way pause does), presents the Comment slide over the live board, and never writes the record's dictionaries.

**Files:**
- Modify: `KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift`
- Test: `KataGo iOSTests/BroadcastReplayTests.swift`

**Interfaces:**
- Consumes: `replayAdvance` (Task 4's stored property), `BroadcastSlideKind.comment` (Task 3), `BroadcastPacing.maxSlideCount` (Task 1).
- Produces: replay behavior for Task 7 — the screen starts each cycle with `noteTurnChanged(game:)`; the cycle ends in `phase == .awaitingMove` WITHOUT chaining, having called `replayAdvance()` exactly once; a non-nil returned comment shows as a `.comment` slide with `currentFrame == nil`.

- [ ] **Step 1: Write the failing tests** — append to `BroadcastReplayTests.swift` inside the struct:

```swift
    // MARK: - Replay move source

    @MainActor
    private final class Counter {
        var advances = 0
        var comment: String?
    }

    @Test("A replay cycle advances the record once, never gen-moves, never chains")
    func replayCycleAdvancesOnceWithoutGenMove() async {
        let counter = Counter()
        let f = Fixture(replayAdvance: { counter.advances += 1; return nil })
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        for _ in 0..<500 { await Task.yield() }   // would-be chain window
        #expect(counter.advances == 1)
        #expect(!f.sent("kata-search_analyze_cancellable"))
        #expect(!f.session.gobanState.broadcastGenMovePending)
        #expect(f.controller.phase == .awaitingMove)
    }

    @Test("A synced comment shows as a frameless Comment slide, typed and spoken")
    func commentSlideShowsOverLiveBoard() async {
        let counter = Counter()
        counter.comment = "A synced note about this move."
        let f = Fixture(replayAdvance: { counter.advances += 1; return counter.comment })
        var sawComment = false
        var frameWasNilDuringComment = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentSlide?.kind == .comment {
                sawComment = true
                frameWasNilDuringComment = (f.controller.currentFrame == nil)
            }
            await Task.yield()
        }
        #expect(sawComment)
        #expect(frameWasNilDuringComment)
        #expect(f.speaker.spoken.contains("A synced note about this move."))
    }

    @Test("No comment means no Comment slide")
    func nilCommentSkipsTheSlide() async {
        let f = Fixture(replayAdvance: { nil })
        var sawComment = false
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentSlide?.kind == .comment { sawComment = true }
            await Task.yield()
        }
        #expect(!sawComment)
    }

    @Test("Fast pacing caps a replay cycle at the Best Move slide")
    func fastPacingCapsSlides() async {
        let f = Fixture(pacing: TVAutoPlaySpeed.fast.broadcastPacing,
                        replayAdvance: { nil })
        var maxSlide = 0
        f.controller.noteTurnChanged(game: f.record)
        for _ in 0..<20_000 {
            if f.controller.phase == .awaitingMove { break }
            if f.controller.currentSlide?.kind != .comment {
                maxSlide = max(maxSlide, f.controller.slideNumber)
            }
            await Task.yield()
        }
        #expect(maxSlide == 1)
        #expect(f.controller.phase == .awaitingMove)
    }

    @Test("Replay never writes the synced record's dictionaries")
    func replayNeverWritesRecordDictionaries() async {
        let f = Fixture(replayAdvance: { nil })
        let winRatesBefore = f.record.winRates
        let scoreLeadsBefore = f.record.scoreLeads
        f.controller.noteTurnChanged(game: f.record)
        await f.pump(until: { f.controller.phase == .awaitingMove })
        #expect(f.record.winRates == winRatesBefore)
        #expect(f.record.scoreLeads == scoreLeadsBefore)
        // The panel headline still gets the snapshot.
        #expect(f.session.rootWinrate.black == 0.6)
    }
```

- [ ] **Step 2: Run to verify failure** — *RUN-TESTS(BroadcastReplayTests)*. Expected: TEST FAILED — `replayCycleAdvancesOnceWithoutGenMove` fails (`advances == 0`, gen-move WAS sent) because `replayAdvance` is stored but unused.

- [ ] **Step 3: Implement in `BroadcastController.swift`:**

(a) `startCycle(game:)` — replay skips the endgame formality (it must route through the async cycle to advance + present the comment). Change the second guard to:

```swift
        guard gobanState.passCount == 0 || replayAdvance != nil else {
            // Endgame formality (grilled decision): once passing starts,
            // no report segments — answer immediately, the interstitial
            // machinery takes over after the second pass. (Live only:
            // replay routes through the full cycle so its move source and
            // comment slide run — a report on a one-pass position is fine.)
            reportModel = nil
            issueGenMove(game: game)
            phase = .awaitingMove
            return
        }
```

(b) `runCycle(game:token:)` — the slides loop gains the pacing cap. Replace the loop's head:

```swift
        var index = 0
        var cappedByPacing = false
        while !Task.isCancelled {
            let slides = BroadcastScript.slides(from: model)
            if index >= pacing().maxSlideCount {
                // Fast replay shows only the Best Move slide; the leftover
                // generation is cancelled below (probe restore() runs, the
                // same path pause takes).
                cappedByPacing = true
                break
            }
            if index >= slides.count {
                if model.stage.isSettled { break }
                try? await sleeper(BroadcastConstants.pollSeconds)
                continue
            }
```

(c) Still in `runCycle`, the early gen-move stays live-only — change its condition:

```swift
            if model.stage.isSettled && index == slides.count - 1
                && !genMoveIssued && replayAdvance == nil {
```

(d) Post-loop, replace:

```swift
        if Task.isCancelled {
            generation.cancel()
        }
        await generation.value
```

with:

```swift
        if Task.isCancelled || cappedByPacing {
            generation.cancel()
        }
        await generation.value
```

(e) Replace the tail of `runCycle` (from `if Task.isCancelled { return false }` after the token-checked blanking) with:

```swift
        if Task.isCancelled { return false }
        if let replayAdvance {
            // The recorded move IS this cycle's move. genMoveIssued marks
            // "the move is played" so a turn change landing during the
            // comment slide takes the moveLanded branch in noteTurnChanged
            // instead of starting a nested cycle; the SCREEN chains cycles
            // (policy-gated), so replay always returns false.
            genMoveIssued = true
            let comment = replayAdvance()
            if let comment {
                await presentStandalone(BroadcastSlide(kind: .comment,
                                                       title: "Comment",
                                                       facts: [comment]),
                                        token: token)
            }
            if Task.isCancelled { return false }
            phase = .awaitingMove
            return false
        }
        if !genMoveIssued {
            issueGenMove(game: game)
        }
        phase = .awaitingMove
        return moveLanded
```

(f) New private method below `present`:

```swift
    /// Types (and speaks) a slide that has NO choreography — the replay
    /// Comment slide. currentFrame stays nil, the one deliberate exception
    /// to the "frame non-nil while a slide shows" pairing: the TV screens
    /// mount the slide board only when a frame exists, so the LIVE hero
    /// board (already showing the just-played move) stays visible while the
    /// comment types over it in the panel.
    private func presentStandalone(_ slide: BroadcastSlide, token: Int) async {
        slideCount += 1
        slideNumber = slideCount
        currentSlide = slide
        currentFrame = nil
        typedText = ""
        var elapsed: TimeInterval = 0
        for fact in slide.facts {
            guard !Task.isCancelled && !skipRequested else { break }
            if isSpeechEnabled() { speaker?.speak(fact) }
            for chunk in BroadcastScript.typewriterChunks(fact) {
                guard !Task.isCancelled && !skipRequested else { break }
                typedText += chunk
                let delay = Double(chunk.count) / pacing().charactersPerSecond
                try? await sleeper(delay)
                elapsed += delay
            }
            typedText += "\n"
        }
        if skipRequested {
            skipRequested = false
            speaker?.cancelAll()
        } else if !Task.isCancelled {
            await waitOutDwellAndSpeech(elapsed: elapsed)
        }
        // Same guard as present()'s epilogue: a cancelled cycle draining
        // late must not blank a successor's live slide.
        guard !Task.isCancelled, cycleToken == token else { return }
        currentSlide = nil
        currentFrame = nil
        typedText = ""
        slideNumber = 0
    }
```

(g) `writeSnapshotStats(model:game:)` — gate the record writes (replay is a spectator of a CloudKit-synced record; the live self-play record is in-memory and keeps today's behavior):

```swift
    private func writeSnapshotStats(model: DeepReportModel, game: GameRecord) {
        guard let position = model.position else { return }
        let blackWinrate = model.sideToMove == .black ? position.winrate : 1 - position.winrate
        let blackScore = model.sideToMove == .black ? position.scoreLead : -position.scoreLead
        rootWinrate.black = blackWinrate
        rootScore.black = blackScore
        // Replay is a spectator: never write the synced record's per-move
        // dictionaries (the review no-write invariant). The headline and
        // chart playhead read the root models above.
        guard replayAdvance == nil else { return }
        game.winRates?[game.currentIndex] = blackWinrate
        withAnimation(.spring) {
            game.scoreLeads?[game.currentIndex] = blackScore
        }
    }
```

(h) Update the `currentFrame` doc comment (line ~54) to note the exception:

```swift
    /// The slide board's current choreography frame; non-nil exactly while
    /// currentSlide is non-nil — EXCEPT the replay Comment slide, which
    /// deliberately keeps it nil so the live hero board stays mounted.
    public private(set) var currentFrame: BroadcastBoardFrame?
```

- [ ] **Step 4: Run to verify pass** — *RUN-TESTS(BroadcastReplayTests)*. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Regression** — *RUN-TESTS(BroadcastControllerTests)* then *RUN-TESTS(BroadcastGenMoveTests)*. Expected: both `** TEST SUCCEEDED **` (live mode's `replayAdvance == nil` paths are byte-compatible).

- [ ] **Step 6: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Report/BroadcastController.swift" "KataGo iOSTests/BroadcastReplayTests.swift"
git commit -m "feat(tv): broadcast replay mode plays recorded moves and comment slides"
```

---

### Task 6: Silence asymmetric human-SL sends during replay

`BroadcastController`'s header: BoardView's turn observer sends asymmetric human-SL `kata-set-param` bundles regardless of `analysisStatus`; their acks landing mid-cycle desync the report collector FIFO. Synced review games are often asymmetric (Human vs 9d). Add a dedicated, default-off suppression flag — additive, so iOS/macOS/visionOS behavior is untouched.

**Files:**
- Modify: `KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift` (the flag + the guard in `maybeSendAsymmetricHumanAnalysisCommands`, line ~495)
- Test: `KataGo iOSTests/BroadcastReplayTests.swift`

**Interfaces:**
- Produces: `GobanState.suppressesHumanSLTurnCommands: Bool` (default `false`). Task 7 sets it `true` in `startAutoPlay()` and `false` in `stopAutoPlay()`.

- [ ] **Step 1: Write the failing test** — append to `BroadcastReplayTests.swift`:

```swift
    // MARK: - Asymmetric human-SL suppression

    @Test("The replay flag silences asymmetric human-SL turn commands")
    func suppressionFlagSilencesAsymmetricSends() {
        let session = GameSession()
        let record = SelfPlayGame.makeRecord()
        let config = record.concreteConfig
        config.blackMaxTime = 1.0
        config.humanSLProfile = "9d"     // black: a 9d engine profile
        config.whiteMaxTime = 0          // white: Human → effective "AI" (asymmetric)
        #expect(!config.isEqualBlackWhiteEffectiveHumanSettings)

        session.gobanState.suppressesHumanSLTurnCommands = true
        session.gobanState.maybeSendAsymmetricHumanAnalysisCommands(
            nextColorForPlayCommand: .black, config: config,
            messageList: session.messageList)
        #expect(session.messageList.messages.isEmpty)

        session.gobanState.suppressesHumanSLTurnCommands = false
        session.gobanState.maybeSendAsymmetricHumanAnalysisCommands(
            nextColorForPlayCommand: .black, config: config,
            messageList: session.messageList)
        #expect(!session.messageList.messages.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure** — *RUN-TESTS(BroadcastReplayTests)*. Expected: BUILD FAILED, `value of type 'GobanState' has no member 'suppressesHumanSLTurnCommands'`.

- [ ] **Step 3: Implement** — in `GobanState.swift`, near the other broadcast flags (search for `suppressesGenMove` and declare alongside it):

```swift
    /// While true, the per-turn asymmetric human-SL command bundles are not
    /// sent. The tvOS review REPLAY sets this for its broadcast's lifetime:
    /// a synced Human-vs-9d config is asymmetric, and the bundle's `=`/`?`
    /// acks landing between a report cycle's probes would desync the
    /// ReportCollector FIFO (see BroadcastController's header). Default
    /// false — iOS/macOS/visionOS behavior is untouched.
    public var suppressesHumanSLTurnCommands = false
```

And extend the guard in `maybeSendAsymmetricHumanAnalysisCommands`:

```swift
        if !config.isEqualBlackWhiteEffectiveHumanSettings && !isAutoPlaying
            && !suppressesHumanSLTurnCommands {
```

- [ ] **Step 4: Run to verify pass** — *RUN-TESTS(BroadcastReplayTests)*. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift" "KataGo iOSTests/BroadcastReplayTests.swift"
git commit -m "feat(tv): add a replay-scoped gate for asymmetric human-SL turn commands"
```

---

### Task 7: TVReviewScreen — the broadcast-mirror auto-play

The big rewiring. The timer loop dies; a replay-configured `BroadcastController` drives the same slide UI the self-play screen shows. `TVAutoPlaySpeed.seconds`/`interval` (now dead) are deleted. No unit test can reach this file — the deliverable is a green TV build plus the updated speed tests; behavior is device QA (Task 12 checklist).

**Files:**
- Modify: `KataGo Anytime TV/TVReviewScreen.swift`
- Modify: `KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlaySpeed.swift` (delete `seconds`/`interval`)
- Modify: `KataGo iOSTests/TVAutoPlaySpeedTests.swift` (delete the `seconds`/`interval` tests)
- Modify: `KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlayPolicy.swift` (doc comment only: `.advance` now means "run one narration cycle, which ends by stepping the move")

**Interfaces:**
- Consumes: everything from Tasks 1–6: `BroadcastController(... speaker:isSpeechEnabled:pacing:replayAdvance:)`, `AVSpeechNarrationSpeaker`, `NarrationSpeechSetting.isEnabled`, `TVAutoPlaySpeed.current.broadcastPacing`, `GobanState.suppressesHumanSLTurnCommands`, plus existing `TVBroadcastSlideBoard(frame:model:)` and `TVBroadcastSlidePanel(title:text:slideNumber:slideCount:)` from the TV target.
- Produces: nothing downstream; Task 10/11 edit this file further.

- [ ] **Step 1: Replace the auto-play state.** In `TVReviewScreen`, replace the `autoPlayTask` and `autoPlaySpeed` properties (keep `isAutoPlaying`, `isHandingOff`, `handoffTask`):

```swift
    /// Auto-Play: the recorded moves replayed as a commentated broadcast
    /// (the live self-play UX with the recorded move as the move source).
    /// Plain state, NOT `GobanState.isAutoPlaying` — that flag is the iOS
    /// wand's (see the original comment, which still applies).
    @State private var isAutoPlaying = false
    /// The replay's broadcast driver; non-nil exactly while replaying.
    @State private var replayBroadcast: BroadcastController?
    /// The user's analysis-OFF preference, restored when the replay stops
    /// (the broadcast protocol runs analysisStatus .clear — the
    /// TVSelfPlayScreen.analysisWasUserOff pattern).
    @State private var analysisWasUserOff = false
    /// Whether the recorded game already ended — a full C++ SGF parse,
    /// hoisted at replay start per this file's "never per body eval" rule.
    @State private var recordedIsFinished = false
```

- [ ] **Step 2: Rewire the hero board into a ZStack with the slide layer.** Replace the `BoardView(...)` block in `reviewContent` (through its `.onChange(of: boardFocused)`) with:

```swift
            ZStack {
                BoardView(gameRecord: game,
                          interactive: false,
                          showsCapturedStones: false,
                          showsPass: false,
                          showsWinrateBar: false,
                          highlightedPoint: highlightedPoint,
                          cursorPoint: ghost.point,
                          commentIsFocused: $commentFocused)
                    // Focusable whenever the timeline isn't — and never while
                    // replaying: the slide layer owns focus then, and a board
                    // focus would flip isAiming, which stops the replay (the
                    // self-play screen's isPaused gate, adapted).
                    .focusable(!timelineFocused && !isAutoPlaying)
                    .focused($boardFocused)
                    .onMoveCommand(perform: boardMove)
                    .tvSelectPress(isEnabled: isAiming, perform: playAtCursor)
                    .overlay {
                        Rectangle()
                            .stroke(boardFocused ? Color.tvWoodAccent : .clear,
                                    lineWidth: 4)
                    }
                    .onChange(of: boardFocused) { _, focused in
                        isAiming = focused
                        if focused {
                            // Aiming the play cursor is taking over.
                            stopAutoPlay()
                            ghost.activate(width: Int(board.width),
                                           height: Int(board.height))
                        } else {
                            ghost.reset()
                        }
                    }

                if let broadcast = replayBroadcast, broadcast.currentSlide != nil {
                    replaySlideLayer(broadcast: broadcast)
                }
            }
            // tvOS is always exactly 1920×1080 pt (see the original comment);
            // the frame moves from BoardView to the ZStack so the slide layer
            // shares it (the TVSelfPlayScreen geometry).
            .frame(width: 1080, height: 1080)
```

(The explanatory comments that were on the original `BoardView` modifiers — full-bleed geometry, the focusable-fallback rule, the select-catcher note — carry over; keep them.)

- [ ] **Step 3: Add the slide layer + panel swap.** New method in `TVReviewScreen`:

```swift
    /// The replay's slide surface over the hero slot. A choreography slide
    /// mounts the acted-out slide board (the TVSelfPlayScreen pattern); the
    /// Comment slide has no frame — the LIVE board stays visible beneath a
    /// transparent layer that only keeps a focus home and the skip controls
    /// (zero focusables would wedge the tvOS focus engine, see tooLargeView).
    @ViewBuilder
    private func replaySlideLayer(broadcast: BroadcastController) -> some View {
        Group {
            if let frame = broadcast.currentFrame, let model = broadcast.reportModel {
                TVBroadcastSlideBoard(frame: frame, model: model)
            } else {
                Color.clear
            }
        }
        .focusable(true)
        .onMoveCommand { direction in
            if direction == .right { broadcast.skipSlide() }
        }
        // Window-wide catcher invariant: while this is enabled the board's
        // own catcher is off (isAiming is false during a replay) and the
        // panel is the slide panel (no buttons).
        .tvSelectPress(isEnabled: true, perform: { broadcast.skipSlide() })
    }
```

Then swap the panel: replace the bare `panel` reference in `reviewContent`'s `HStack` with:

```swift
            Group {
                if let broadcast = replayBroadcast, let slide = broadcast.currentSlide {
                    TVBroadcastSlidePanel(title: slide.title,
                                          text: broadcast.typedText,
                                          slideNumber: broadcast.slideNumber,
                                          slideCount: broadcast.slideCount)
                } else {
                    panel
                }
            }
```

(keeping the existing `.frame(width: 500, height: 1020, alignment: .top)`, `.padding(.vertical, 30)`, `.disabled(isAiming)`, `.focusSection()` modifiers on the `Group`).

- [ ] **Step 4: Add the replay driver hooks.** On `reviewContent` (next to the existing `.onReceive` thermal observer), add:

```swift
        // The replay chain: each cycle parks in .awaitingMove; the policy
        // decides whether to run another (the old per-tick decision, now
        // per-cycle). stones.isReady re-enters a .hold once the board
        // refresh lands.
        .onChange(of: replayBroadcast?.phase) { _, newPhase in
            guard newPhase == .awaitingMove else { return }
            continueReplay()
        }
        .onChange(of: stones.isReady) { _, ready in
            guard ready, replayBroadcast?.phase == .awaitingMove else { return }
            continueReplay()
        }
```

- [ ] **Step 5: Replace the Auto-Play engine.** Replace `startAutoPlay()`, `stopAutoPlay()`, and `advanceOneMove()` (delete `advanceOneMove` entirely) with:

```swift
    /// Start the commentated replay. Already parked at the last move is not
    /// an error: nothing to replay, so report the end immediately — which
    /// finishAutoPlay turns into the live handoff for an unfinished game.
    private func startAutoPlay() {
        guard !gobanState.isBranchActive, !isAutoPlaying else { return }
        guard gobanState.getNextMove(gameRecord: game) != nil else {
            finishAutoPlay(continuesLive: !SelfPlayGame.recordedGameIsFinished(sgf: game.sgf))
            return
        }
        isAutoPlaying = true
        // Lean-back viewing with no remote input (the self-play precedent).
        UIApplication.shared.isIdleTimerDisabled = true
        // Invariant for the whole replay (game.sgf is never written here,
        // and a branch stops the loop); a full C++ parse, hoisted once.
        recordedIsFinished = SelfPlayGame.recordedGameIsFinished(sgf: game.sgf)
        // The broadcast engine-state protocol (the TVSelfPlayScreen entry,
        // adapted): remember a user OFF, then run the cycles under
        // analysisStatus .clear. suppressesGenMove is already true (review
        // is a spectator) and replay mode never gen-moves at all. The
        // asymmetric human-SL bundles are silenced for the replay's
        // lifetime — a synced Human-vs-9d config would otherwise inject
        // acks between a cycle's probes (Task 6 / the controller header).
        analysisWasUserOff = (gobanState.analysisStatus == .clear)
        gobanState.eyeStatus = .opened
        gobanState.analysisStatus = .clear
        gobanState.suppressesHumanSLTurnCommands = true
        let broadcast = BroadcastController(
            messageList: messageList,
            gobanState: gobanState,
            player: player,
            rootWinrate: rootWinrate,
            rootScore: rootScore,
            speaker: AVSpeechNarrationSpeaker(),
            isSpeechEnabled: { NarrationSpeechSetting.isEnabled },
            pacing: { TVAutoPlaySpeed.current.broadcastPacing },
            replayAdvance: { advanceReplayMove() })
        replayBroadcast = broadcast
        broadcast.noteTurnChanged(game: game)   // the first cycle
    }

    /// Every stop path funnels here (steps, picks, aiming, Play/Pause, Menu,
    /// thermal, onDisappear). Tears the broadcast down (which cancels speech)
    /// and restores the analysis state the replay protocol displaced.
    private func stopAutoPlay() {
        guard isAutoPlaying || replayBroadcast != nil else { return }
        isAutoPlaying = false
        replayBroadcast?.cancelAll()
        replayBroadcast = nil
        gobanState.suppressesHumanSLTurnCommands = false
        UIApplication.shared.isIdleTimerDisabled = false
        // cancelAll deliberately does not touch analysisStatus — the caller
        // owns restoration (its doc comment).
        if analysisWasUserOff {
            gobanState.analysisStatus = .clear
            gobanState.eyeStatus = .closed
        } else {
            gobanState.eyeStatus = .opened
            gobanState.analysisStatus = .run
            reanalyze()
        }
    }

    /// One cycle ended (phase == .awaitingMove): the per-cycle policy gate.
    private func continueReplay() {
        guard isAutoPlaying, let broadcast = replayBroadcast,
              broadcast.phase == .awaitingMove else { return }
        switch TVAutoPlayPolicy.tick(
            hasNextMove: gobanState.getNextMove(gameRecord: game) != nil,
            isBranchActive: gobanState.isBranchActive,
            stonesReady: stones.isReady,
            recordedGameIsFinished: recordedIsFinished,
            thermalState: ProcessInfo.processInfo.thermalState
        ) {
        case .advance:
            broadcast.noteTurnChanged(game: game)
        case .hold:
            break   // the stones.isReady onChange re-enters
        case .finish(let continuesLive):
            finishAutoPlay(continuesLive: continuesLive)
        case .stop:
            stopAutoPlay()
        }
    }

    /// The replay's move source: play the next recorded move and hand back
    /// the synced comment for the position it lands on (nil = none). The
    /// comment index is computed BEFORE the advance — the GTP round-trip
    /// updates indices asynchronously.
    private func advanceReplayMove() -> String? {
        let nextIndex = (gobanState.getCurrentIndex(gameRecord: game) ?? game.currentIndex) + 1
        gobanState.forwardMoves(limit: 1, gameRecord: game, board: board,
                                messageList: messageList, player: player,
                                audioModel: audioModel, stones: stones)
        let comment = game.comments?[nextIndex]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (comment?.isEmpty == false) ? comment : nil
    }
```

- [ ] **Step 6: Fix the two remaining timer references.** `finishAutoPlay` and `toggleAutoPlay` compile unchanged. Delete the now-dead `@AppStorage(TVAutoPlaySpeed.defaultsKey)` property from `TVReviewScreen` (the pacing closure reads `TVAutoPlaySpeed.current` instead). Update the file-header comment (line ~10: "replays the recorded moves on a timer" → "replays the recorded moves as a spoken, commentated broadcast — the live self-play UX with the recorded moves as the move source").

- [ ] **Step 7: Delete the dead cadence API.** In `TVAutoPlaySpeed.swift` delete the `seconds` and `interval` properties (and their doc comments); in `TVAutoPlaySpeedTests.swift` delete the tests referencing `.seconds` or `.interval` (`secondsMatchTheSpec`-style assertions and `intervalMirrorsSeconds`). In `TVAutoPlayPolicy.swift` update only the `.advance` case doc: `/// Run one narration cycle, which ends by stepping one recorded move.`

- [ ] **Step 8: Build + test.** *BUILD-TV* — Expected `** BUILD SUCCEEDED **`. Then *RUN-TESTS(TVAutoPlaySpeedTests)* — Expected `** TEST SUCCEEDED **`. Then build iOS to prove KataGoUICore still compiles for the other platforms:

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add "KataGo Anytime TV/TVReviewScreen.swift" \
        "KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlaySpeed.swift" \
        "KataGoUICore/Sources/KataGoUICore/Util/TVAutoPlayPolicy.swift" \
        "KataGo iOSTests/TVAutoPlaySpeedTests.swift"
git commit -m "feat(tv): review auto-play becomes the spoken commentated broadcast"
```

---

### Task 8: Live self-play speaks + the Settings toggle

**Files:**
- Modify: `KataGo Anytime TV/TVSelfPlayScreen.swift` (pass the speaker to its `BroadcastController`)
- Modify: `KataGo Anytime TV/TVSettingsScreen.swift` (the toggle row)

**Interfaces:**
- Consumes: `AVSpeechNarrationSpeaker`, `NarrationSpeechSetting` (Task 2), the extended `BroadcastController` init (Task 4).

- [ ] **Step 1: Self-play speaks.** In `TVSelfPlayScreen.startIfNeeded()`, replace the `BroadcastController` creation with:

```swift
        broadcast = BroadcastController(messageList: messageList,
                                        gobanState: gobanState,
                                        player: player,
                                        rootWinrate: rootWinrate,
                                        rootScore: rootScore,
                                        speaker: AVSpeechNarrationSpeaker(),
                                        isSpeechEnabled: { NarrationSpeechSetting.isEnabled })
```

(Default pacing `.live` and `replayAdvance: nil` keep the live protocol identical.)

- [ ] **Step 2: The Settings toggle.** In `TVSettingsScreen`, add the property next to `soundEffects`:

```swift
    @AppStorage(NarrationSpeechSetting.defaultsKey) private var spokenNarration
        = NarrationSpeechSetting.defaultValue
```

and in `soundSection`, after the Sound Effects toggle:

```swift
            Toggle("Spoken Narration", isOn: $spokenNarration)
            Text("Reads the broadcast commentary aloud during live games and Auto-Play.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 3: Build.** *BUILD-TV*. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "KataGo Anytime TV/TVSelfPlayScreen.swift" "KataGo Anytime TV/TVSettingsScreen.swift"
git commit -m "feat(tv): live broadcast speaks; Settings gains the Spoken Narration toggle"
```

---

### Task 9: LastMoveKey extraction (shared; visionOS switches)

**Files:**
- Create: `KataGoUICore/Sources/KataGoUICore/Vision/LastMoveKey.swift`
- Modify: `KataGo Anytime Vision/VisionRootView.swift` (delete the private struct at lines ~503–506; use the shared type; the hook body at ~424–437 switches to `newValue?.lastPoint`)
- Test: create `KataGo iOSTests/LastMoveKeyTests.swift` (register in pbxproj)

**Interfaces:**
- Produces: `public struct LastMoveKey: Equatable, Sendable { public let sgf: String; public let index: Int; public init(sgf:index:); public var lastPoint: BoardPoint? }` — `lastPoint` wraps `MoveNumbers.derive(sgf:currentIndex:).lastPoint` (nil for a pass or empty board). Task 10 consumes it on both TV screens.

- [ ] **Step 1: Write the failing test** — `KataGo iOSTests/LastMoveKeyTests.swift`:

```swift
//
//  LastMoveKeyTests.swift
//  KataGo AnytimeTests
//
//  The shared ghost-anchor derivation key (extracted from VisionRootView so
//  the tvOS screens reuse it). SGF fixtures use the engine's own coordinate
//  conventions; derive() walks the C++ parser, available in this test host.
//

import Testing
@testable import KataGoUICore

struct LastMoveKeyTests {
    // A 9x9 game: B E5, W C3. SZ first, then the moves.
    private let sgf = "(;FF[4]GM[1]SZ[9];B[ee];W[cg])"

    @Test("lastPoint is the last played move at the given index")
    func lastPointFollowsIndex() {
        let atTip = LastMoveKey(sgf: sgf, index: 2)
        #expect(atTip.lastPoint != nil)
        let afterFirst = LastMoveKey(sgf: sgf, index: 1)
        #expect(afterFirst.lastPoint != nil)
        #expect(atTip.lastPoint != afterFirst.lastPoint)
    }

    @Test("An empty board has no last point")
    func emptyBoardHasNoPoint() {
        #expect(LastMoveKey(sgf: sgf, index: 0).lastPoint == nil)
    }

    @Test("A trailing pass has no last point")
    func passHasNoPoint() {
        let withPass = "(;FF[4]GM[1]SZ[9];B[ee];W[])"
        #expect(LastMoveKey(sgf: withPass, index: 2).lastPoint == nil)
    }

    @Test("Equality is by sgf + index (the onChange trigger contract)")
    func equalitySemantics() {
        #expect(LastMoveKey(sgf: sgf, index: 1) == LastMoveKey(sgf: sgf, index: 1))
        #expect(LastMoveKey(sgf: sgf, index: 1) != LastMoveKey(sgf: sgf, index: 2))
        #expect(LastMoveKey(sgf: sgf, index: 1) != LastMoveKey(sgf: sgf + " ", index: 1))
    }
}
```

Register it (same Ruby recipe as Task 2, with `LastMoveKeyTests.swift`).

- [ ] **Step 2: Run to verify failure** — *RUN-TESTS(LastMoveKeyTests)*. Expected: BUILD FAILED, `cannot find 'LastMoveKey'`.

- [ ] **Step 3: Implement** — `KataGoUICore/Sources/KataGoUICore/Vision/LastMoveKey.swift`:

```swift
//
//  LastMoveKey.swift
//  KataGoUICore
//
//  The ghost-cursor anchor derivation key (extracted from VisionRootView so
//  the tvOS screens share it): keyed on the exact inputs of
//  MoveNumbers.derive so passes and step/jump navigation retrigger an
//  .onChange even though the stones don't change. The derive walk is an
//  O(moves) C++ SGF parse — run it once per position change (inside the
//  onChange), never per body eval or glide frame.
//

import Foundation

public struct LastMoveKey: Equatable, Sendable {
    public let sgf: String
    public let index: Int

    public init(sgf: String, index: Int) {
        self.sgf = sgf
        self.index = index
    }

    /// The board point of the last played move at this position; nil for a
    /// pass or an empty board (the caller keeps the center fallback then).
    public var lastPoint: BoardPoint? {
        MoveNumbers.derive(sgf: sgf, currentIndex: index).lastPoint
    }
}
```

- [ ] **Step 4: Run to verify pass** — *RUN-TESTS(LastMoveKeyTests)*. Expected: `** TEST SUCCEEDED **`. If a fixture expectation fails (SGF coordinate conventions), fix the FIXTURE against the parser's actual behavior — `MoveNumbers.derive` is the spec here, not the test.

- [ ] **Step 5: Switch visionOS.** In `VisionRootView.swift`: delete the `private struct LastMoveKey` (lines ~503–506, keeping the `lastMoveKey` computed property that now resolves to the shared type), and simplify the hook body:

```swift
        .onChange(of: lastMoveKey, initial: true) { _, newValue in
            let lastPoint = newValue?.lastPoint
            #if DEBUG
            NSLog("VisionAnchor index=%@ lastPoint=%@ sgfLen=%@",
                  newValue.map { String($0.index) } ?? "nil",
                  lastPoint.map { "(\($0.x),\($0.y))" } ?? "nil",
                  newValue.map { String($0.sgf.count) } ?? "nil")
            #endif
            ghost.setAnchor(lastPoint,
                            width: Int(session.board.width),
                            height: Int(session.board.height))
        }
```

- [ ] **Step 6: Build visionOS.**

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add "KataGoUICore/Sources/KataGoUICore/Vision/LastMoveKey.swift" \
        "KataGo Anytime Vision/VisionRootView.swift" \
        "KataGo iOSTests/LastMoveKeyTests.swift" "KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "refactor(vision): extract the shared LastMoveKey ghost-anchor key"
```

---

### Task 10: tvOS cursor anchors at the last move

**Files:**
- Modify: `KataGo Anytime TV/TVReviewScreen.swift`
- Modify: `KataGo Anytime TV/TVSelfPlayScreen.swift`

**Interfaces:**
- Consumes: `LastMoveKey` (Task 9), `GhostCursorModel.setAnchor(_:width:height:)` (existing, unit-tested — tvOS only lacked the caller).

- [ ] **Step 1: Review screen.** Add the computed property (near `displayIndex`):

```swift
    /// Branch-aware ghost-anchor inputs (the VisionRootView hook, shared via
    /// LastMoveKey). Reading them in body keeps the onChange armed for
    /// steps, jumps, picks, passes, and branch navigation.
    private var lastMoveKey: LastMoveKey? {
        guard let sgf = gobanState.getSgf(gameRecord: game),
              let index = gobanState.getCurrentIndex(gameRecord: game) else { return nil }
        return LastMoveKey(sgf: sgf, index: index)
    }
```

and the hook on `reviewContent` (next to the replay driver hooks):

```swift
        // Ghost anchor: reveal (and follow) the cursor at the board's last
        // move — players expect to answer near it. The O(moves) SGF walk
        // runs once per position change, never per body eval. lastPoint is
        // nil for a pass or an empty board — the center fallback stays.
        .onChange(of: lastMoveKey, initial: true) { _, newValue in
            ghost.setAnchor(newValue?.lastPoint,
                            width: Int(board.width),
                            height: Int(board.height))
        }
```

- [ ] **Step 2: Self-play screen.** Same pattern with the optional record:

```swift
    private var lastMoveKey: LastMoveKey? {
        guard let game,
              let sgf = gobanState.getSgf(gameRecord: game),
              let index = gobanState.getCurrentIndex(gameRecord: game) else { return nil }
        return LastMoveKey(sgf: sgf, index: index)
    }
```

and on `content` (next to the existing `.onChange(of: player.nextColorForPlayCommand)`):

```swift
        // Ghost anchor (the review-screen hook): the paused play cursor
        // reveals at — and follows — the last move.
        .onChange(of: lastMoveKey, initial: true) { _, newValue in
            ghost.setAnchor(newValue?.lastPoint,
                            width: Int(board.width),
                            height: Int(board.height))
        }
```

- [ ] **Step 3: Build.** *BUILD-TV*. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "KataGo Anytime TV/TVReviewScreen.swift" "KataGo Anytime TV/TVSelfPlayScreen.swift"
git commit -m "feat(tv): the play cursor reveals at the last move"
```

---

### Task 11: Step while aiming

**Files:**
- Modify: `KataGo Anytime TV/TVReviewScreen.swift` (`handleControllerEvent`)
- Modify: `KataGoUICore/Sources/KataGoUICore/Util/TVControllerEvent.swift` (header comment)
- Test: `KataGo iOSTests/TVControllerLegendTests.swift` (verify only — run it)

**Interfaces:**
- Consumes: the existing `stepBy(_:)` funnel and jump paths; the last-move anchor (Task 10) makes the visible ghost follow each step.

- [ ] **Step 1: Restructure the guard.** Replace `TVReviewScreen.handleControllerEvent` with:

```swift
    /// Focus-safe controller buttons. Navigation (L1/R1/L2/R2) now works
    /// while aiming too — the ghost follows the changing last move via the
    /// anchor hook, so stepping and aiming compose. X and Y stay inert
    /// while aiming: the board cursor owns the screen's modes, and starting
    /// Auto-Play or toggling analysis mid-aim would fight it.
    private func handleControllerEvent(_ event: TVControllerEvent) {
        switch event {
        case .buttonX:
            guard !isAiming else { return }
            toggleAutoPlay()
        case .buttonY:
            guard !isAiming else { return }
            toggleAnalysis()
        case .leftShoulder:
            stepBy(-1)
        case .rightShoulder:
            stepBy(1)
        case .leftTrigger:
            stopAutoPlay()
            guard stones.isReady else { return }
            gobanState.backwardMoves(limit: nil, gameRecord: game,
                                     messageList: messageList,
                                     player: player, stones: stones)
            reanalyze()
        case .rightTrigger:
            stopAutoPlay()
            guard stones.isReady else { return }
            gobanState.forwardMoves(limit: nil, gameRecord: game, board: board,
                                    messageList: messageList, player: player,
                                    audioModel: audioModel, stones: stones)
            reanalyze()
        }
    }
```

(`TVSelfPlayScreen.handleControllerEvent` keeps its `guard !isAiming` — its L1/R1 mean undo/skip-slide, not navigation.)

- [ ] **Step 2: Keep the legend truthful.** The row strings ("Back one move (hold to repeat)" etc.) are already accurate — they now hold in MORE states, not fewer. Update `TVControllerEvent.swift`'s header comment to record the review-screen exception:

```swift
//  On the review screen the navigation buttons (L1/R1/L2/R2) also work while
//  the play cursor is aiming — the cursor follows the last move as positions
//  change; X and Y stay aiming-suppressed there (the cursor owns the modes).
```

- [ ] **Step 3: Build + verify legend tests.** *BUILD-TV* — Expected `** BUILD SUCCEEDED **`. Then *RUN-TESTS(TVControllerLegendTests)* — Expected `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "KataGo Anytime TV/TVReviewScreen.swift" "KataGoUICore/Sources/KataGoUICore/Util/TVControllerEvent.swift"
git commit -m "feat(tv): L1/R1/L2/R2 navigate positions while the cursor is aiming"
```

---

### Task 12: Full verification sweep

**Files:** none (verification + QA checklist only).

- [ ] **Step 1: Full unit-test target** (sequentially, never parallel):

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests" 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: KataGoUICore package tests** (SwiftPM tests NEVER run under xcodebuild):

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore"
swift test 2>&1 | tail -10
```

Expected: all tests pass. (These suites — GoRulesKit, KataGoAnalysisKit, GobanRecogNative — don't touch this feature; this is a no-regression check.)

- [ ] **Step 3: All-platform builds** (sequential): *BUILD-TV*, then the iOS scheme, then Vision, then Mac:

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` for each of the four.

- [ ] **Step 4: Device/simulator QA checklist** — hand this list to the user (Apple TV device preferred; the tvOS Simulator can cover layout but not speech mixing or the fanless thermal path):

1. Review auto-play now runs slides + typewriter + spoken narration; the recorded stone appears after the slides; the score-chart playhead advances.
2. Spoken Narration OFF in Settings silences both review replay and live self-play; ON restores both.
3. Slow/Normal/Fast change the replay pacing; Fast shows only Best Move (+ Comment when present); speech is never sped up.
4. A game with iOS-written comments shows (and speaks) each comment as an extra slide over the live board.
5. Replaying to the end of an unfinished game still hands off to "Continuing live…" seamlessly.
6. Focusing the board reveals the cursor at the last move (center on an empty board / after a pass).
7. While aiming: L1/R1 step, L2/R2 jump, the ghost follows the last move; X/Y do nothing; Select still plays at the cursor; Menu still exits aiming.
8. Right-press or Select on a slide skips it (speech cuts off mid-word); stepping the timeline mid-replay stops the replay.
9. An asymmetric (Human-vs-9d) synced game replays without the broadcast ever stalling in "Analyzing…" (the FIFO-desync regression this plan's Task 6 guards).
10. Siri-Remote-only flows unchanged (D-pad aims, Play/Pause toggles replay, Menu exits).

- [ ] **Step 5: Final commit** (if the sweep produced any fixes) and report the branch state to the user. Do NOT push.

---

## Plan self-review notes

- **Spec coverage:** A1 (broadcast mirror) → Tasks 5+7; A2 (comment slide) → 3+5+7; A3 (speech) → 2+4+8; A4 (speed mapping) → 1+4+7; A5 (anchor) → 9+10; A6 (step-while-aiming) → 11; A7 (testing) → per-task tests + 12. The spec's "package tests (`swift test`)" line was corrected: the broadcast suites live in the iOS-host target "KataGo AnytimeTests", where all existing broadcast tests already run.
- **Discovered requirement:** Task 6 (asymmetric human-SL suppression) — mandated by `BroadcastController`'s engine-protocol header, surfaced during planning.
- **Type consistency:** `BroadcastPacing` / `broadcastPacing` / `current` (T1) ↔ consumed T4/5/7; `NarrationSpeaking`/`AVSpeechNarrationSpeaker`/`NarrationSpeechSetting` (T2) ↔ T4/7/8; `BroadcastSlideKind.comment` (T3) ↔ T5/7; `replayAdvance` (T4) ↔ T5/7; `suppressesHumanSLTurnCommands` (T6) ↔ T7; `LastMoveKey.lastPoint` (T9) ↔ T10.
