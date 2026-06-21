# Tappable AI/Human Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the per-color `Human`/`AI` label beside each captured-stone count a tappable tinted-capsule button that flips that side between Human (thinking time `0`) and AI (thinking time `0.5s`).

**Architecture:** The label already exists in the shared `StoneView.drawCapturedStones` with accessibility IDs `blackPlayerName`/`whitePlayerName`. We add one optional `onToggleAI` closure to `StoneView`; when present (live board) the name renders as a `Button` styled as a tinted capsule, when absent (game-list thumbnail / previews) it stays plain. `BoardView` supplies the closure, computing the new time via a new pure, unit-tested `Config.toggledMaxTime(for:)` and applying it through the existing `ConfigEngineSync.set{Black,White}MaxTime` (which writes the config **and** re-arms analysis so an enabled side-to-move plays immediately).

**Tech Stack:** SwiftUI, SwiftData (`Config` model), Swift Testing (unit), XCTest (`XCUIApplication` UI tests), xcodebuild. All code is Swift; no C++ changes.

## Global Constraints

- Platforms: iOS 26+, macOS 26+ (native AppKit, scheme `KataGo Anytime Mac`), visionOS 26+. The change must compile on all three.
- SwiftData `Config` `@Model` schema is **frozen** — no new/changed *stored* fields. New behavior goes in extensions / computed members only (`toggledMaxTime(for:)` is a method, allowed).
- App startup defaults are **unchanged**: `defaultBlackMaxTime`/`defaultWhiteMaxTime` stay `0.0` (new games start Human-vs-Human). `0.5s` is only the value applied when the toggle enables a side.
- Toggle-to-AI always sets exactly `0.5s` (no "remember custom time"). Named constant `Config.toggleAIThinkingTime = 0.5`.
- AI label text is the side's profile (default `"AI"`); human label is `Config.humanPlayerLabel` (`"Human"`).
- Do **not** push (Xcode Cloud free-tier push-rate limit). Commit locally on branch `ios-dev`.
- Use the `trash` CLI (never `rm`) if any file removal is needed.
- iOS Simulator pins the backend to CoreML/NE; engine launch is slow (UI tests use long board-ready timeouts up to 360s).

---

### Task 1: `Config.toggledMaxTime(for:)` — pure toggle-value logic

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/ConfigModel.swift` (add an extension after the existing `playerLabel(for:)` extension, ~line 197)
- Test: `ios/KataGo iOS/KataGo iOSTests/PlayerLabelTests.swift` (append a new test struct; file is already registered in the `KataGo AnytimeTests` target, so no `.xcodeproj` change)

**Interfaces:**
- Consumes: `Config.blackMaxTime` / `Config.whiteMaxTime` (computed `Float` accessors, already exist); `PlayerColor` (`.black`/`.white`/`.unknown`, `KataGoModel.swift:160`).
- Produces: `Config.toggleAIThinkingTime: Float` (== `0.5`) and `func toggledMaxTime(for color: PlayerColor) -> Float`. Consumed by Task 3.

- [ ] **Step 1: Write the failing tests**

Append to `ios/KataGo iOS/KataGo iOSTests/PlayerLabelTests.swift` (after the closing `}` of `PlayerLabelTests`):

```swift
/// `Config.toggledMaxTime(for:)` computes the per-move time a side gets when its
/// AI/Human label is tapped: human (0) → 0.5s, AI (>0) → 0. `.unknown` is a 0
/// no-op. The Config form can still set any other value; this is only the
/// quick-toggle default.
struct AIHumanToggleTests {

    @Test func humanBlackTogglesToHalfSecond() {
        let config = Config(optionalBlackMaxTime: 0)
        #expect(config.toggledMaxTime(for: .black) == 0.5)
    }

    @Test func aiBlackTogglesToZero() {
        let config = Config(optionalBlackMaxTime: 0.5)
        #expect(config.toggledMaxTime(for: .black) == 0)
    }

    @Test func aiBlackWithCustomTimeTogglesToZero() {
        // A custom time set via the Config form still toggles back to human.
        let config = Config(optionalBlackMaxTime: 3.0)
        #expect(config.toggledMaxTime(for: .black) == 0)
    }

    @Test func humanWhiteTogglesToHalfSecond() {
        let config = Config(optionalWhiteMaxTime: 0)
        #expect(config.toggledMaxTime(for: .white) == 0.5)
    }

    @Test func aiWhiteTogglesToZero() {
        let config = Config(optionalWhiteMaxTime: 2.0)
        #expect(config.toggledMaxTime(for: .white) == 0)
    }

    @Test func eachColorTogglesIndependently() {
        // Black AI (1s), White human (0): toggling black turns it off; white turns on.
        let config = Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 0.0)
        #expect(config.toggledMaxTime(for: .black) == 0)
        #expect(config.toggledMaxTime(for: .white) == 0.5)
    }

    @Test func togglesUseTheNamedDefaultConstant() {
        let config = Config(optionalBlackMaxTime: 0)
        #expect(config.toggledMaxTime(for: .black) == Config.toggleAIThinkingTime)
    }

    @Test func unknownColorTogglesToZero() {
        let config = Config()
        #expect(config.toggledMaxTime(for: .unknown) == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (compile error)**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/AIHumanToggleTests" 2>&1 | tail -30
```
Expected: build FAILS — `value of type 'Config' has no member 'toggledMaxTime'` (and `toggleAIThinkingTime`).

- [ ] **Step 3: Implement `toggledMaxTime(for:)`**

Add to `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/ConfigModel.swift`, immediately after the `extension Config { ... playerLabel(for:) ... }` block (after line ~197):

```swift
extension Config {
    /// The per-move thinking time (seconds) a side is given when the user taps
    /// its AI/Human label to enable AI. The Config form can still set any other
    /// value; this is only the quick-toggle default.
    public static let toggleAIThinkingTime: Float = 0.5

    /// The new per-move max time for `color` when its AI/Human label is tapped:
    /// a side that is currently AI (time > 0) becomes `0` (human); a side that is
    /// currently human (`0`) becomes `toggleAIThinkingTime` (0.5s). `.unknown`
    /// returns `0` (no-op).
    public func toggledMaxTime(for color: PlayerColor) -> Float {
        switch color {
        case .black: return blackMaxTime > 0 ? 0 : Config.toggleAIThinkingTime
        case .white: return whiteMaxTime > 0 ? 0 : Config.toggleAIThinkingTime
        case .unknown: return 0
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/AIHumanToggleTests" 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`, all 8 `AIHumanToggleTests` pass.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/ConfigModel.swift" "ios/KataGo iOS/KataGo iOSTests/PlayerLabelTests.swift" && git commit -m "feat: add Config.toggledMaxTime(for:) for AI/Human label toggle"
```

---

### Task 2: `StoneView` — optional `onToggleAI` closure + tinted capsule button

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/StoneView.swift` (property + init ~lines 10-39; `body` calls ~lines 44-56; `drawCapturedStones` ~lines 65-101; add a preview)

**Interfaces:**
- Consumes: `PlayerColor`, `Config.humanPlayerLabel` (both in this module).
- Produces: `StoneView(... , onToggleAI: ((PlayerColor) -> Void)? = nil)`. Consumed by Task 3. When `onToggleAI != nil`, the name is a `Button` (XCUITest element type `buttons`, not `staticTexts`) keeping its accessibility identifier.

- [ ] **Step 1: Add the stored property and init parameter**

In `StoneView.swift`, after the `whitePlayerName` property (line 23), add:

```swift
    /// When set (live board), the per-color name renders as a tappable capsule
    /// button that calls this with the tapped color. When nil (game-list
    /// thumbnail / previews) the name is plain, non-interactive text.
    var onToggleAI: ((PlayerColor) -> Void)? = nil
```

In the `public init` (lines 25-39), add the parameter at the end of the signature (after `whitePlayerName:`) and assign it. The full init becomes:

```swift
    public init(dimensions: Dimensions,
                isClassicStoneStyle: Bool,
                verticalFlip: Bool,
                isDrawingCapturedStones: Bool = true,
                speedText: String? = nil,
                blackPlayerName: String? = nil,
                whitePlayerName: String? = nil,
                onToggleAI: ((PlayerColor) -> Void)? = nil) {
        self.dimensions = dimensions
        self.isClassicStoneStyle = isClassicStoneStyle
        self.verticalFlip = verticalFlip
        self.isDrawingCapturedStones = isDrawingCapturedStones
        self.speedText = speedText
        self.blackPlayerName = blackPlayerName
        self.whitePlayerName = whitePlayerName
        self.onToggleAI = onToggleAI
    }
```

- [ ] **Step 2: Pass each color into `drawCapturedStones` from `body`**

In `body` (lines 45-56), add a `playerColor:` argument to both calls:

```swift
            drawCapturedStones(color: .black,
                               playerColor: .black,
                               count: stones.blackStonesCaptured,
                               xOffset: 0,
                               name: blackPlayerName,
                               nameAccessibilityID: "blackPlayerName",
                               dimensions: dimensions)
            drawCapturedStones(color: .white,
                               playerColor: .white,
                               count: stones.whiteStonesCaptured,
                               xOffset: 1,
                               name: whitePlayerName,
                               nameAccessibilityID: "whitePlayerName",
                               dimensions: dimensions)
```

- [ ] **Step 3: Branch the name rendering in `drawCapturedStones`**

Replace the whole `drawCapturedStones` function (lines 65-101) with this version (adds the `playerColor` param and swaps the inline name `Text` for a `playerNameLabel(...)` helper; the `Circle` and count are unchanged):

```swift
    private func drawCapturedStones(color: Color,
                                    playerColor: PlayerColor,
                                    count: Int,
                                    xOffset: CGFloat,
                                    name: String?,
                                    nameAccessibilityID: String,
                                    dimensions: Dimensions) -> some View {
        HStack(spacing: dimensions.squareLengthDiv8) {
            if let name, !name.isEmpty {
                playerNameLabel(name: name,
                                playerColor: playerColor,
                                nameAccessibilityID: nameAccessibilityID,
                                dimensions: dimensions)
            }
            Circle()
                .foregroundStyle(color)
                .frame(width: dimensions.capturedStonesHeight, height: dimensions.capturedStonesHeight)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
            // The captured count keeps a STATIC size (fixedSize → never scaled
            // down by the adaptive name beside it).
            Text("x\(count)")
                .contentTransition(.numericText())
                .font(.system(size: dimensions.capturedStonesHeight * 0.85, design: .monospaced))
                .fixedSize()
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
        }
        .frame(width: dimensions.capturedStonesWidth, height: dimensions.capturedStonesHeight)
        .position(x: dimensions.getCapturedStoneStartX(xOffset: xOffset),
                  y: dimensions.capturedStonesStartY)
    }

    // The per-color name. With a toggle handler (live board) it is a tappable
    // tinted capsule button — accent fill when AI, neutral when Human; without
    // one (thumbnail / previews) it is the original plain, non-interactive text.
    @ViewBuilder
    private func playerNameLabel(name: String,
                                 playerColor: PlayerColor,
                                 nameAccessibilityID: String,
                                 dimensions: Dimensions) -> some View {
        if let onToggleAI {
            Button {
                onToggleAI(playerColor)
            } label: {
                capsuleNameLabel(name: name, dimensions: dimensions)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(nameAccessibilityID)
        } else {
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.2)
                .font(.system(size: dimensions.capturedStonesHeight * 0.7))
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
                .accessibilityIdentifier(nameAccessibilityID)
        }
    }

    // The capsule used for the tappable name. `isAI` (this side has an engine
    // profile rather than the "Human" label) tints it with the accent color;
    // Human uses a subtle neutral fill. Horizontal-only padding keeps the
    // capsule height within the 20pt captured-stones strip.
    private func capsuleNameLabel(name: String, dimensions: Dimensions) -> some View {
        let isAI = (name != Config.humanPlayerLabel)
        return Text(name)
            .lineLimit(1)
            .minimumScaleFactor(0.2)
            .font(.system(size: dimensions.capturedStonesHeight * 0.7))
            .foregroundStyle(isAI ? Color.white : Color.primary)
            .padding(.horizontal, dimensions.squareLengthDiv8)
            .background(
                Capsule(style: .continuous)
                    .fill(isAI ? Color.accentColor : Color.secondary.opacity(0.25))
            )
            .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
    }
```

- [ ] **Step 4: Add an interactive preview**

Append to `StoneView.swift` (end of file, after the last `#Preview`):

```swift
// Interactive capsule toggle: the names render as tappable capsules (Human =
// neutral fill, AI/profile = accent fill). Verifies the capsule fits the 20pt
// strip beside the static "x..." counts.
#Preview("Captured labels — tappable capsules") {
    let stones = Stones()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            StoneView(dimensions: Dimensions(size: geometry.size,
                                             width: 19,
                                             height: 19,
                                             showCoordinate: true),
                      isClassicStoneStyle: false,
                      verticalFlip: false,
                      blackPlayerName: "Human",
                      whitePlayerName: "AI",
                      onToggleAI: { _ in })
        }
        .environment(stones)
        .environment(GobanState())
        .onAppear {
            stones.blackStonesCaptured = 12
            stones.whiteStonesCaptured = 7
        }
    }
    .frame(width: 393, height: 640)
}
```

- [ ] **Step 5: Build the package (compile gate) and eyeball the preview**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

Then open `StoneView.swift` in Xcode and view the **"Captured labels — tappable capsules"** preview (or render it via the Xcode MCP `RenderPreview`). Confirm: the `Human` (neutral) and `AI` (accent) capsules sit on one line beside the `x12`/`x7` counts and are not vertically clipped within the strip. If clipped, change `capturedStonesHeight * 0.7` to `* 0.6` in `capsuleNameLabel` only and re-check.

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/StoneView.swift" && git commit -m "feat: render captured-stone name as a tappable AI/Human capsule"
```

---

### Task 3: `BoardView` — wire the toggle to `ConfigEngineSync`

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/BoardView.swift` (the `StoneView(...)` call ~lines 56-63; add `toggleAI(for:)` near `speedText`/`updateWinrateFromBook`, ~line 196)

**Interfaces:**
- Consumes: `StoneView(onToggleAI:)` (Task 2); `Config.toggledMaxTime(for:)` (Task 1); `ConfigEngineSync.setBlackMaxTime`/`setWhiteMaxTime(_:config:gobanState:player:messageList:)` (`ConfigEngineSync.swift:203,215`); `config` (`gameRecord.concreteConfig`), `gobanState`, `player`, `messageList` (all already in `BoardView`).
- Produces: tapping a capsule on the live board sets that side's `maxTime` (0 ⇄ 0.5) and re-arms analysis.

- [ ] **Step 1: Pass `onToggleAI` into `StoneView`**

In `BoardView.swift`, replace the `StoneView(...)` call (lines 56-63) with:

```swift
                    StoneView(
                        dimensions: dimensions,
                        isClassicStoneStyle: gobanState.isClassicStoneStyle,
                        verticalFlip: gobanState.verticalFlip,
                        speedText: speedText,
                        blackPlayerName: config.playerLabel(for: .black),
                        whitePlayerName: config.playerLabel(for: .white),
                        onToggleAI: { toggleAI(for: $0) }
                    )
```

- [ ] **Step 2: Add the `toggleAI(for:)` method**

In `BoardView.swift`, add this method right after `updateWinrateFromBook()` (after line 196):

```swift
    /// Flip a color between Human (thinking time 0) and AI (0.5s) when its
    /// captured-stone capsule is tapped. Reuses `ConfigEngineSync.set*MaxTime`,
    /// which writes the live `Config` (label updates via Observation) and re-arms
    /// analysis so an enabled side-to-move generates a move immediately.
    private func toggleAI(for color: PlayerColor) {
        switch color {
        case .black:
            ConfigEngineSync.setBlackMaxTime(config.toggledMaxTime(for: .black),
                                             config: config,
                                             gobanState: gobanState,
                                             player: player,
                                             messageList: messageList)
        case .white:
            ConfigEngineSync.setWhiteMaxTime(config.toggledMaxTime(for: .white),
                                             config: config,
                                             gobanState: gobanState,
                                             player: player,
                                             messageList: messageList)
        case .unknown:
            break
        }
    }
```

- [ ] **Step 3: Build (compile gate)**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/BoardView.swift" && git commit -m "feat: toggle a side's AI/Human by tapping its captured-stone capsule"
```

---

### Task 4: UI test — labels are now buttons + a tap-toggle case

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOSUITests/PlayerNameLabelUITests.swift` (header doc lines 5-18; `waitForLabel` element query line 168; add a new `@Test`/`func` test method)

**Interfaces:**
- Consumes: capsule buttons with identifiers `blackPlayerName`/`whitePlayerName` (Task 2) on the live board.
- Produces: regression coverage that the labels are tappable and flip the side.

- [ ] **Step 1: Update the header doc comment**

In `PlayerNameLabelUITests.swift`, replace lines 10-11:

```swift
//  The labels are SwiftUI Texts carrying the accessibility identifiers
//  "blackPlayerName" / "whitePlayerName" (see StoneView.drawCapturedStones);
```
with:

```swift
//  The labels are SwiftUI Buttons (tappable AI/Human capsules) carrying the
//  accessibility identifiers "blackPlayerName" / "whitePlayerName" (see
//  StoneView.drawCapturedStones); tapping one flips that side Human<->AI.
```

- [ ] **Step 2: Point `waitForLabel` at the button element**

In `waitForLabel` (line 168), replace:

```swift
        let element = app.staticTexts[identifier]
```
with:

```swift
        let element = app.buttons[identifier]
```

- [ ] **Step 3: Build the UI test target to confirm the existing test still compiles, then run it**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan -only-testing:"KataGo AnytimeUITests/PlayerNameLabelUITests/testPlayerNameLabelsReflectThinkingTimeConfiguration" 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` — the existing config-driven test now reads the labels as buttons.

- [ ] **Step 4: Write the tap-toggle test (the failing test for the new behavior)**

In `PlayerNameLabelUITests.swift`, add this method after `testPlayerNameLabelsReflectThinkingTimeConfiguration` (after line 72):

```swift
    /// Taps the WHITE capsule directly on the board and verifies it flips
    /// Human -> AI -> Human, with Black unaffected. White is used so the toggle
    /// never makes the side-to-move (Black, at the opening) auto-play into an
    /// uncommitted branch — keeping the board stable and the test idempotent.
    @MainActor
    func testTappingWhiteLabelTogglesAIAndHuman() throws {
        let app = XCUIApplication()
        launchToBoard(app)

        // Baseline: force both sides Human via the config steppers (robust against
        // state persisted by a previous run).
        openAIConfig(app)
        adjustStepper(app, "blackTimePerMove", decrements: 4)
        adjustStepper(app, "whiteTimePerMove", decrements: 4)
        dismissConfig(app)
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)

        // Tap WHITE's capsule -> becomes AI.
        let white = app.buttons["whitePlayerName"]
        XCTAssertTrue(white.waitForExistence(timeout: 10), "White capsule button not found")
        white.tap()
        waitForLabel(app, "whitePlayerName", equals: aiLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)  // unaffected

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WhiteToggledToAI"
        shot.lifetime = .keepAlways
        add(shot)

        // Tap again -> back to Human (restores the clean baseline for reruns).
        app.buttons["whitePlayerName"].tap()
        waitForLabel(app, "whitePlayerName", equals: humanLabel)
        waitForLabel(app, "blackPlayerName", equals: humanLabel)
    }
```

- [ ] **Step 5: Run the new test to verify it passes**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan -only-testing:"KataGo AnytimeUITests/PlayerNameLabelUITests/testTappingWhiteLabelTogglesAIAndHuman" 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`. (If it fails to find the button, the capsule's `accessibilityIdentifier` likely did not survive — confirm Task 2 Step 3 kept `.accessibilityIdentifier(nameAccessibilityID)` on the `Button`.)

- [ ] **Step 6: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && git add "ios/KataGo iOS/KataGo iOSUITests/PlayerNameLabelUITests.swift" && git commit -m "test: tap the captured-stone capsule to toggle AI/Human"
```

---

### Task 5: Cross-platform builds + computer-use verification

**Files:** none (verification only).

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: confirmation the feature compiles on all three platforms and works interactively on the iOS Simulator.

- [ ] **Step 1: Build iOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Build visionOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Build macOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Computer-use interactive check (iOS Simulator)**

Launch the app on the booted iPhone 17 Simulator (install the build from Step 1 or reuse the one the UI test installed), bring the Simulator to the front, and via computer-use:
1. Screenshot the board. Locate the **white** side's capsule above the board — it should read `Human` with a neutral fill.
2. Click that capsule. Screenshot again and confirm it now reads `AI` with an accent-colored fill, and the **black** capsule still reads `Human`. Because it is Black's turn at the opening, no stone should be auto-played.
3. Click the **black** capsule (the side to move). Confirm it flips to `AI` and the engine then plays a black stone within a couple of seconds (the 0.5s think + analysis), demonstrating the toggle enables AI move generation.
4. Click both capsules back to `Human` to leave a clean state.

Record the observed behavior (with a before/after screenshot) as the verification evidence.

- [ ] **Step 5: Final confirmation**

Confirm: all three builds succeeded, the unit tests (Task 1) and both UI tests (Task 4) passed, and the computer-use check showed the capsule flipping Human⇄AI and the side-to-move generating a move when enabled. No push (per Global Constraints).

---

## Self-Review

**Spec coverage:**
- Tappable label flips Human⇄AI → Tasks 2 (capsule button) + 3 (wire action). ✓
- 0.5s on enable, 0 on disable, always 0.5 (no remember) → Task 1 (`toggledMaxTime` + constant) + tests. ✓
- App startup unchanged (defaults stay 0.0) → Global Constraints; no task changes the default constants. ✓
- Tinted capsule affordance (accent when AI, neutral when Human) → Task 2 Step 3 (`capsuleNameLabel`, `isAI` tint). ✓
- Per-color independent → Task 1 `eachColorTogglesIndependently`; Task 4 asserts Black unaffected. ✓
- Mid-game-safe write + re-arm → Task 3 uses `ConfigEngineSync.set*MaxTime`. ✓
- Thumbnail/previews stay inert → Task 2 `onToggleAI == nil` branch keeps plain `Text`. ✓
- All three platforms → Task 5 Steps 1-3 build iOS/visionOS/macOS. ✓
- Element-type change (buttons not static texts) in existing UI test → Task 4 Steps 1-3. ✓
- New tap-toggle UI test → Task 4 Steps 4-5. ✓
- Computer-use verification → Task 5 Step 4. ✓
- No SwiftData schema change, no new Config defaults, no C++ → confirmed across all tasks. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code; the one conditional ("if clipped, change 0.7→0.6") is a concrete fallback with exact values. ✓

**Type consistency:** `onToggleAI: ((PlayerColor) -> Void)?` defined in Task 2, consumed identically in Task 3. `toggledMaxTime(for:)` / `toggleAIThinkingTime` defined in Task 1, consumed in Task 3. `ConfigEngineSync.setBlackMaxTime`/`setWhiteMaxTime` signatures match `ConfigEngineSync.swift:203,215`. Accessibility IDs `blackPlayerName`/`whitePlayerName` consistent across Tasks 2 and 4. ✓
