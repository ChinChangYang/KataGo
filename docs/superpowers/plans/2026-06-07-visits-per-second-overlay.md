# visits/s Board Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Global Settings toggle that shows a live `visits/s` search-speed readout in the board's bottom-left corner.

**Architecture:** Pure Swift, no C++/engine changes. The `kata-analyze` command is extended with `rootInfo true` so the engine emits total root visits per report. `ContentView` parses that count and feeds `(visits, timestamp)` into the `Analysis` model, which computes a per-second rate (Δvisits / Δtime, rebaselining on search resets). A new global boolean setting gates a small text overlay rendered in `BoardView`.

**Tech Stack:** SwiftUI, `@Observable`, `@AppStorage`, Swift Testing (`import Testing`, `@Test`, `#expect`).

**Conventions observed in this codebase:**
- Global settings use `@AppStorage("GlobalSettings.<key>")` in `GameSplitView`, mirrored into `GobanState`, with a `ConfigBoolItem` in `GlobalSettingsView`.
- Tests use Swift Testing inside `struct KataGoModelTests` / `struct ConfigModelTests`.
- No new Swift files (adding files requires editing `project.pbxproj`). All code goes into existing files.

**Build/test commands (run from the repo root):**
- iOS build: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
- iOS tests: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
- macOS build: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug`
- visionOS build may fail with rc=70 because the visionOS simulator runtime is not installed locally — that is a known environment limitation, not a regression.

---

## File Structure

| File | Change |
|------|--------|
| `ios/KataGo iOS/KataGo iOS/KataGoModel.swift` | Add rate state + `updateVisitsPerSecond`, `visitsPerSecondText`, `static parseRootVisits`, and reset in `clear()` on `Analysis`. |
| `ios/KataGo iOS/KataGo iOSTests/KataGoModelTests.swift` | New `@Test`s for the rate math, text formatting, and `parseRootVisits`. |
| `ios/KataGo iOS/KataGo iOS/ConfigModel.swift` | Append `rootInfo true` to the two analyze command builders. |
| `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift` | Update 4 existing exact-string assertions to include `rootInfo true`. |
| `ios/KataGo iOS/KataGo iOS/ContentView.swift` | Parse root visits in `maybeCollectAnalysis` and call `updateVisitsPerSecond`. |
| `ios/KataGo iOS/KataGo iOS/GobanState.swift` | Add `showVisitsPerSecond` property. |
| `ios/KataGo iOS/KataGo iOS/GameSplitView.swift` | Add `@AppStorage` + onAppear/onChange sync. |
| `ios/KataGo iOS/KataGo iOS/ConfigView.swift` | Add `ConfigBoolItem` to `GlobalSettingsView`. |
| `ios/KataGo iOS/KataGo iOS/BoardView.swift` | Render the corner overlay. |

---

## Task 1: visits/s rate math + root-visits parsing on `Analysis` (TDD)

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/KataGoModel.swift` (the `@Observable class Analysis`, currently lines 244-302)
- Test: `ios/KataGo iOS/KataGo iOSTests/KataGoModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these tests inside `struct KataGoModelTests` in `KataGo iOSTests/KataGoModelTests.swift` (e.g. right after the existing `testAnalysisClear` test, near line 200):

```swift
    // MARK: - Analysis visits/s Tests

    @Test func testVisitsPerSecondDefaultsToZero() async throws {
        let analysis = Analysis()
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondFirstSampleEstablishesBaseline() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0)
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondComputesRateFromDelta() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0)
        analysis.updateVisitsPerSecond(rootVisits: 300, at: 12.0)
        // (300 - 100) / (12 - 10) = 100
        #expect(analysis.visitsPerSecond == 100)
    }

    @Test func testVisitsPerSecondRebaselinesOnReset() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 500, at: 10.0)
        analysis.updateVisitsPerSecond(rootVisits: 700, at: 11.0)
        #expect(analysis.visitsPerSecond == 200)
        // New search resets visits to a smaller value -> no negative rate.
        analysis.updateVisitsPerSecond(rootVisits: 50, at: 12.0)
        #expect(analysis.visitsPerSecond == 0)
        // Next sample computes from the new baseline.
        analysis.updateVisitsPerSecond(rootVisits: 150, at: 13.0)
        #expect(analysis.visitsPerSecond == 100)
    }

    @Test func testVisitsPerSecondGuardsZeroElapsedTime() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0)
        analysis.updateVisitsPerSecond(rootVisits: 200, at: 10.0)
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondClearResets() async throws {
        let analysis = Analysis()
        analysis.updateVisitsPerSecond(rootVisits: 100, at: 10.0)
        analysis.updateVisitsPerSecond(rootVisits: 300, at: 12.0)
        #expect(analysis.visitsPerSecond == 100)
        analysis.clear()
        #expect(analysis.visitsPerSecond == 0)
        // After clear, the next sample is a fresh baseline (no rate yet).
        analysis.updateVisitsPerSecond(rootVisits: 1000, at: 20.0)
        #expect(analysis.visitsPerSecond == 0)
    }

    @Test func testVisitsPerSecondText() async throws {
        let analysis = Analysis()
        #expect(analysis.visitsPerSecondText == "0 visits/s")
        analysis.updateVisitsPerSecond(rootVisits: 0, at: 0.0)
        analysis.updateVisitsPerSecond(rootVisits: 1500, at: 1.0)
        #expect(analysis.visitsPerSecondText == "1.5k visits/s")
    }

    @Test func testParseRootVisits() async throws {
        let message = "info move A1 visits 10 winrate 0.5 rootInfo visits 12345 utility 0.1 winrate 0.5"
        #expect(Analysis.parseRootVisits(from: message) == 12345)
    }

    @Test func testParseRootVisitsReturnsNilWhenAbsent() async throws {
        let message = "info move A1 visits 10 winrate 0.5 scoreLead 1.0"
        #expect(Analysis.parseRootVisits(from: message) == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: COMPILE FAILURE — `value of type 'Analysis' has no member 'visitsPerSecond' / 'updateVisitsPerSecond' / 'visitsPerSecondText'` and `type 'Analysis' has no member 'parseRootVisits'`.

- [ ] **Step 3: Implement on `Analysis`**

In `KataGo iOS/KataGoModel.swift`, replace the `Analysis` class body region from its property declarations through `clear()`. Specifically, change the top of the class (currently lines 244-248):

```swift
@Observable
class Analysis {
    var nextColorForAnalysis = PlayerColor.white
    var info: [BoardPoint: AnalysisInfo] = [:]
    var ownershipUnits: [OwnershipUnit] = []
```

to:

```swift
@Observable
class Analysis {
    var nextColorForAnalysis = PlayerColor.white
    var info: [BoardPoint: AnalysisInfo] = [:]
    var ownershipUnits: [OwnershipUnit] = []
    var visitsPerSecond: Double = 0

    @ObservationIgnored private var lastRootVisits: Int? = nil
    @ObservationIgnored private var lastRootVisitsTime: TimeInterval? = nil
```

And replace the existing `clear()` (currently lines 298-301):

```swift
    func clear() {
        info = [:]
        ownershipUnits = []
    }
```

with:

```swift
    func clear() {
        info = [:]
        ownershipUnits = []
        visitsPerSecond = 0
        lastRootVisits = nil
        lastRootVisitsTime = nil
    }

    /// Updates `visitsPerSecond` from successive cumulative root-visit samples.
    /// `time` must be a monotonic timestamp in seconds (e.g. `ProcessInfo.processInfo.systemUptime`).
    func updateVisitsPerSecond(rootVisits: Int, at time: TimeInterval) {
        defer {
            lastRootVisits = rootVisits
            lastRootVisitsTime = time
        }
        guard let lastRootVisits, let lastRootVisitsTime else {
            // First sample after init/clear: establish a baseline, no rate yet.
            return
        }
        let deltaVisits = rootVisits - lastRootVisits
        let deltaTime = time - lastRootVisitsTime
        // A search reset makes visits drop; guard against negative/zero-time garbage.
        guard deltaVisits >= 0, deltaTime > 0 else {
            visitsPerSecond = 0
            return
        }
        visitsPerSecond = Double(deltaVisits) / deltaTime
    }

    /// SI-formatted display string, e.g. "1.2k visits/s". Reuses `convertToSIUnits`.
    var visitsPerSecondText: String {
        convertToSIUnits(Int(visitsPerSecond)) + " visits/s"
    }

    /// Parses the cumulative root visit count from a kata-analyze line, if present.
    /// `rootInfo` (capital I) is unaffected by the lowercase "info" split used elsewhere.
    static func parseRootVisits(from message: String) -> Int? {
        let pattern = /rootInfo visits (\d+)/
        if let match = message.firstMatch(of: pattern) {
            return Int(match.1)
        }
        return nil
    }
```

Note: `convertToSIUnits(_:)` is a module-internal free function defined in `AnalysisView.swift` (line 185) and is callable from here without import.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — all new `testVisitsPerSecond*` and `testParseRootVisits*` tests pass; the existing suite remains green.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/KataGoModel.swift" "ios/KataGo iOS/KataGo iOSTests/KataGoModelTests.swift"
git commit -m "feat(analysis): add visits/s rate computation to Analysis model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Request `rootInfo` and feed root visits into `Analysis`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/ConfigModel.swift:179-181` and `:191-195`
- Modify: `ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift:140`, `:148`, `:155`, `:414`
- Modify: `ios/KataGo iOS/KataGo iOS/ContentView.swift:358-386` (the `maybeCollectAnalysis` method)

- [ ] **Step 1: Update the existing command-string tests to expect `rootInfo true`**

These existing assertions pin the exact command string and must be updated first (TDD: they should fail against the unchanged source until Step 3).

In `KataGo iOSTests/ConfigModelTests.swift`, line 140, change:

```swift
        #expect(config.getKataAnalyzeCommand() == "kata-analyze interval \(Config.defaultAnalysisInterval) maxmoves \(Config.defaultMaxAnalysisMoves) ownership true ownershipStdev true")
```

to:

```swift
        #expect(config.getKataAnalyzeCommand() == "kata-analyze interval \(Config.defaultAnalysisInterval) maxmoves \(Config.defaultMaxAnalysisMoves) ownership true ownershipStdev true rootInfo true")
```

Line 148, change:

```swift
        #expect(command == "kata-analyze interval 30 maxmoves 60 ownership true ownershipStdev true")
```

to:

```swift
        #expect(command == "kata-analyze interval 30 maxmoves 60 ownership true ownershipStdev true rootInfo true")
```

Line 155, change:

```swift
        #expect(command == "kata-analyze interval 10 maxmoves 70 ownership true ownershipStdev true")
```

to:

```swift
        #expect(command == "kata-analyze interval 10 maxmoves 70 ownership true ownershipStdev true rootInfo true")
```

Line 414, change:

```swift
        let defaultCommand = "kata-analyze interval \(Config.defaultAnalysisInterval) maxmoves \(Config.defaultMaxAnalysisMoves) ownership true ownershipStdev true"
```

to:

```swift
        let defaultCommand = "kata-analyze interval \(Config.defaultAnalysisInterval) maxmoves \(Config.defaultMaxAnalysisMoves) ownership true ownershipStdev true rootInfo true"
```

- [ ] **Step 2: Run the command tests to verify they fail**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/ConfigModelTests"`
Expected: FAIL — `testKataAnalyzeCommand`, `testGetKataAnalyzeCommandWithCustomInterval`, `testGetKataFastAnalyzeCommand`, and `kataAnalyzeCommand` fail because the source still omits `rootInfo true`.

- [ ] **Step 3: Append `rootInfo true` in the command builders**

In `KataGo iOS/ConfigModel.swift`, change `getKataAnalyzeCommand(analysisInterval:)` (lines 179-181):

```swift
    func getKataAnalyzeCommand(analysisInterval: Int) -> String {
        return "kata-analyze interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true"
    }
```

to:

```swift
    func getKataAnalyzeCommand(analysisInterval: Int) -> String {
        return "kata-analyze interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true rootInfo true"
    }
```

And change `getKataGenMoveAnalyzeCommands(maxTime:)` (lines 191-195) so visits/s also works while the AI is thinking:

```swift
    func getKataGenMoveAnalyzeCommands(maxTime: Float) -> [String] {
        return [
            "kata-set-param maxTime \(max(maxTime, 0.5))",
            "kata-search_analyze_cancellable interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true"]
    }
```

to:

```swift
    func getKataGenMoveAnalyzeCommands(maxTime: Float) -> [String] {
        return [
            "kata-set-param maxTime \(max(maxTime, 0.5))",
            "kata-search_analyze_cancellable interval \(analysisInterval) maxmoves \(maxAnalysisMoves) ownership true ownershipStdev true rootInfo true"]
    }
```

- [ ] **Step 4: Run the command tests to verify they pass**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/ConfigModelTests"`
Expected: PASS.

- [ ] **Step 5: Wire root visits into `Analysis` from `ContentView.maybeCollectAnalysis`**

In `KataGo iOS/ContentView.swift`, replace the entire `maybeCollectAnalysis` method (currently lines 358-386):

```swift
    func maybeCollectAnalysis(message: String) async {
        guard gobanState.showBoardCount == 0 else { return }
        if message.starts(with: /info/) {
            let (analysisInfo, lastData) = await collectAnalysisInfo(message: message)

            let ownershipUnits = await extractOwnershipUnits(lastData: lastData, nextColorFromShowBoard: player.nextColorFromShowBoard, width: Int(board.width), height: Int(board.height))

            withAnimation {
                analysis.info = analysisInfo.reduce([:]) {
                    $0.merging($1) { (current, _) in
                        current
                    }
                }

                analysis.ownershipUnits = ownershipUnits
                analysis.nextColorForAnalysis = player.nextColorFromShowBoard

                if gobanState.eyeStatus != .book {
                    if let blackWinrate = analysis.blackWinrate {
                        rootWinrate.black = blackWinrate
                    }

                    rootScore.black = analysis.blackScore ?? 0
                }
            }

            gobanState.waitingForAnalysis = analysisInfo.isEmpty
        }
    }
```

with:

```swift
    func maybeCollectAnalysis(message: String) async {
        guard gobanState.showBoardCount == 0 else { return }
        if message.starts(with: /info/) {
            let (analysisInfo, lastData) = await collectAnalysisInfo(message: message)

            let ownershipUnits = await extractOwnershipUnits(lastData: lastData, nextColorFromShowBoard: player.nextColorFromShowBoard, width: Int(board.width), height: Int(board.height))

            let rootVisits = Analysis.parseRootVisits(from: message)
            let sampleTime = ProcessInfo.processInfo.systemUptime

            withAnimation {
                analysis.info = analysisInfo.reduce([:]) {
                    $0.merging($1) { (current, _) in
                        current
                    }
                }

                analysis.ownershipUnits = ownershipUnits
                analysis.nextColorForAnalysis = player.nextColorFromShowBoard

                if let rootVisits {
                    analysis.updateVisitsPerSecond(rootVisits: rootVisits, at: sampleTime)
                }

                if gobanState.eyeStatus != .book {
                    if let blackWinrate = analysis.blackWinrate {
                        rootWinrate.black = blackWinrate
                    }

                    rootScore.black = analysis.blackScore ?? 0
                }
            }

            gobanState.waitingForAnalysis = analysisInfo.isEmpty
        }
    }
```

Why this is safe for existing parsing: the engine emits ` rootInfo` (capital "I") *before* ` ownership`. The lowercase `"info"` separator in `collectAnalysisInfo` is case-sensitive and never matches `rootInfo`, so the split and ownership extraction behave exactly as before; root visits are read independently via the regex in `parseRootVisits`.

- [ ] **Step 6: Build iOS to verify it compiles**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/ConfigModel.swift" "ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift" "ios/KataGo iOS/KataGo iOS/ContentView.swift"
git commit -m "feat(analysis): request rootInfo and track live visits/s

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Add the "Show visits/s" global setting

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GobanState.swift:33`
- Modify: `ios/KataGo iOS/KataGo iOS/GameSplitView.swift:42`, `:94`, `:99-101`
- Modify: `ios/KataGo iOS/KataGo iOS/ConfigView.swift:756-781`

- [ ] **Step 1: Add the property to `GobanState`**

In `KataGo iOS/GobanState.swift`, change line 33:

```swift
    var hapticFeedback: Bool = false
```

to:

```swift
    var hapticFeedback: Bool = false
    var showVisitsPerSecond: Bool = false
```

- [ ] **Step 2: Add the `@AppStorage` and sync in `GameSplitView`**

In `KataGo iOS/GameSplitView.swift`, change line 42:

```swift
    @AppStorage("GlobalSettings.hapticFeedback") private var globalHapticFeedback = false
```

to:

```swift
    @AppStorage("GlobalSettings.hapticFeedback") private var globalHapticFeedback = false
    @AppStorage("GlobalSettings.showVisitsPerSecond") private var globalShowVisitsPerSecond = false
```

Change the `.onAppear` block (lines 92-95):

```swift
        .onAppear {
            gobanState.soundEffect = globalSoundEffect
            gobanState.hapticFeedback = globalHapticFeedback
        }
```

to:

```swift
        .onAppear {
            gobanState.soundEffect = globalSoundEffect
            gobanState.hapticFeedback = globalHapticFeedback
            gobanState.showVisitsPerSecond = globalShowVisitsPerSecond
        }
```

Change the haptic `.onChange` block (lines 99-101):

```swift
        .onChange(of: gobanState.hapticFeedback) { _, newValue in
            globalHapticFeedback = newValue
        }
```

to:

```swift
        .onChange(of: gobanState.hapticFeedback) { _, newValue in
            globalHapticFeedback = newValue
        }
        .onChange(of: gobanState.showVisitsPerSecond) { _, newValue in
            globalShowVisitsPerSecond = newValue
        }
```

- [ ] **Step 3: Add the toggle to `GlobalSettingsView`**

In `KataGo iOS/ConfigView.swift`, replace `GlobalSettingsView` (lines 756-781):

```swift
struct GlobalSettingsView: View {
    @State private var soundEffect: Bool = false
    @State private var hapticFeedback: Bool = false
    @Environment(GobanState.self) private var gobanState

    var body: some View {
        List {
            ConfigBoolItem(title: "Sound effect", value: $soundEffect)
                .onAppear {
                    soundEffect = gobanState.soundEffect
                }
                .onChange(of: soundEffect) {
                    gobanState.soundEffect = soundEffect
                }

            ConfigBoolItem(title: "Haptic feedback", value: $hapticFeedback)
                .onAppear {
                    hapticFeedback = gobanState.hapticFeedback
                }
                .onChange(of: hapticFeedback) {
                    gobanState.hapticFeedback = hapticFeedback
                }
        }
        .navigationTitle("Global Settings")
    }
}
```

with:

```swift
struct GlobalSettingsView: View {
    @State private var soundEffect: Bool = false
    @State private var hapticFeedback: Bool = false
    @State private var showVisitsPerSecond: Bool = false
    @Environment(GobanState.self) private var gobanState

    var body: some View {
        List {
            ConfigBoolItem(title: "Sound effect", value: $soundEffect)
                .onAppear {
                    soundEffect = gobanState.soundEffect
                }
                .onChange(of: soundEffect) {
                    gobanState.soundEffect = soundEffect
                }

            ConfigBoolItem(title: "Haptic feedback", value: $hapticFeedback)
                .onAppear {
                    hapticFeedback = gobanState.hapticFeedback
                }
                .onChange(of: hapticFeedback) {
                    gobanState.hapticFeedback = hapticFeedback
                }

            ConfigBoolItem(title: "Show visits/s", value: $showVisitsPerSecond)
                .onAppear {
                    showVisitsPerSecond = gobanState.showVisitsPerSecond
                }
                .onChange(of: showVisitsPerSecond) {
                    gobanState.showVisitsPerSecond = showVisitsPerSecond
                }
        }
        .navigationTitle("Global Settings")
    }
}
```

- [ ] **Step 4: Build iOS to verify it compiles**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/GobanState.swift" "ios/KataGo iOS/KataGo iOS/GameSplitView.swift" "ios/KataGo iOS/KataGo iOS/ConfigView.swift"
git commit -m "feat(settings): add Show visits/s global toggle

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Render the visits/s overlay in the board's bottom-left corner

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/BoardView.swift:65-69` (add to the `ZStack`) and `:178` (add a helper near `drawNextMove`)

- [ ] **Step 1: Insert the overlay into the board `ZStack`**

In `KataGo iOS/BoardView.swift`, change the end of the `ZStack` (lines 65-69):

```swift
                    if shouldShowWinrateBar {
                        WinrateBarView(dimensions: dimensions)
                            .transition(.opacity)
                    }
                }
```

to:

```swift
                    if shouldShowWinrateBar {
                        WinrateBarView(dimensions: dimensions)
                            .transition(.opacity)
                    }

                    speedOverlay(dimensions: dimensions)
                }
```

- [ ] **Step 2: Add the `speedOverlay` helper**

In `KataGo iOS/BoardView.swift`, add this method immediately before the existing `private func drawNextMove(...)` (currently at line 178):

```swift
    @ViewBuilder
    private func speedOverlay(dimensions: Dimensions) -> some View {
        if gobanState.showVisitsPerSecond,
           gobanState.analysisStatus == .run,
           analysis.visitsPerSecond > 0 {
            Text(analysis.visitsPerSecondText)
                .font(.system(size: dimensions.squareLength * 0.45, weight: .medium, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, dimensions.squareLengthDiv4)
                .padding(.vertical, dimensions.squareLengthDiv8)
                .background(.white.opacity(0.6), in: Capsule())
                .frame(width: dimensions.gobanWidth, height: dimensions.gobanHeight, alignment: .bottomLeading)
                .position(x: dimensions.gobanStartX + dimensions.gobanWidth / 2,
                          y: dimensions.gobanStartY + dimensions.gobanHeight / 2)
                .allowsHitTesting(false)
        }
    }
```

Notes:
- `analysis`, `gobanState`, and `AnalysisStatus.run` are already available in `BoardView` (env objects declared at lines 16-19).
- `.allowsHitTesting(false)` keeps the overlay from intercepting the board's `onTapGesture`.
- The `gobanWidth × gobanHeight` frame with `.bottomLeading` alignment, centered over the goban via `.position`, pins the label to the goban's bottom-left corner; font and insets scale with `squareLength` so it looks right on every board size.

- [ ] **Step 3: Build iOS to verify it compiles**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/BoardView.swift"
git commit -m "feat(board): show visits/s overlay in bottom-left corner

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Full verification across platforms

**Files:** none (verification only).

- [ ] **Step 1: Run the full iOS test suite**

Run: `xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: TEST SUCCEEDED — all suites green, including the new `Analysis` visits/s tests and the updated `ConfigModel` command tests.

- [ ] **Step 2: Build for macOS**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Build for visionOS (best effort)**

Run: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug`
Expected: BUILD SUCCEEDED if the visionOS simulator runtime is installed. If it fails with rc=70 / "missing runtime", that is the known local environment limitation — record it and move on (no code change should be needed since all changes are platform-agnostic SwiftUI).

- [ ] **Step 4: Manual smoke check (optional, if a simulator/device is handy)**

1. Open Configurations → Global Settings, toggle **Show visits/s** on.
2. Start analysis on a position; confirm a `<n> visits/s` label appears in the board's bottom-left and updates as the search runs.
3. Toggle the setting off; confirm the label disappears.
4. Pause/stop analysis; confirm the label hides (no stale number).

---

## Self-Review

**Spec coverage:**
- Toggle in Global Settings → Task 3. ✅
- Bottom-left corner overlay, hidden when inactive → Task 4 (gated on `showVisitsPerSecond`, `analysisStatus == .run`, `visitsPerSecond > 0`). ✅
- "visits/s" label / "Show visits/s" setting → Tasks 1 (`visitsPerSecondText`) & 3. ✅
- `rootInfo true` added to the analyze command → Task 2. ✅
- Robust regex parse of `rootInfo visits` → Task 1 (`parseRootVisits`) & Task 2 (wiring). ✅
- Rate = Δvisits/Δtime with rebaseline-on-reset and zero/negative-time guard, monotonic clock → Task 1. ✅
- Unit tests for normal delta, reset/rebaseline, zero-time guard, clear reset, text, parse → Task 1. ✅
- No C++/engine changes → confirmed; all tasks are Swift-only. ✅
- Build across iOS/macOS/visionOS → Task 5. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✅

**Type consistency:** `visitsPerSecond: Double`, `updateVisitsPerSecond(rootVisits: Int, at: TimeInterval)`, `visitsPerSecondText: String`, `Analysis.parseRootVisits(from: String) -> Int?`, `GobanState.showVisitsPerSecond: Bool`, `@AppStorage("GlobalSettings.showVisitsPerSecond")`, `speedOverlay(dimensions: Dimensions)` — names and signatures used identically across Tasks 1-4. ✅
