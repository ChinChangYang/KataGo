# Phase 1 — Native AppKit Skeleton (vertical slice) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stand up a new **native macOS AppKit app target** that launches, loads the built-in network + engine through a reusable `GameSession`, shows the Go board (reused SwiftUI `BoardView` via `NSHostingView`) inside a 3-pane `NSSplitViewController` with a native menu bar + toolbar, and supports basic move navigation — a running vertical slice on top of `KataGoUICore`.

**Architecture:** Extract the GTP message loop + engine-driven state out of `ContentView` into an `@Observable @MainActor GameSession` in `KataGoUICore` (and adopt it in the existing iOS `ContentView`, so there's one source of truth — no duplication). The new AppKit target (programmatic `NSApplication` + `AppDelegate`, no storyboard) owns a `GameSession`, hosts the SwiftUI board, and drives it via menu/toolbar. The `katago` engine + `KataGoSwift`/CoreML wiring are reused exactly as the iOS app does (the Mac target re-hosts `CoreMLComputeHandleLoader` and calls `registerCoreMLBridge()` at launch, per the Phase-0 forward note).

**Tech Stack:** Swift 6, AppKit, SwiftUI (`NSHostingView`), SwiftData (+ same CloudKit container), the `KataGoUICore` package, Xcode (`xcodebuild`), the `xcodeproj` Ruby gem.

**Out of scope (later phases):** the game **Library** sidebar contents (Phase 2 — Phase 1 uses a placeholder list), live **analysis overlay**/win-rate/ownership wiring beyond what `BoardView` shows by default (Phase 3), the **Inspector** tabs (Phase 4), **Models/Settings** windows (Phase 5), branching/book/AppIntents (Phase 6). Phase 1 proves the shell + engine + board + nav.

---

## Conventions (every task)

- Run from `cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"`, always pass `-derivedDataPath "DerivedData/KataGo Anytime"`. Run xcodebuilds **sequentially** (shared build.db lock); grep logs for `** BUILD SUCCEEDED **`/`** TEST SUCCEEDED **`/`warning:`/`error:`.
- **iOS regression gate** (the existing app must stay green): build iOS (`-destination 'platform=iOS Simulator,name=iPhone 17'`) + `xcodebuild test … -testPlan FullTestPlan` (247+ tests).
- **macOS app gate:** build the NEW scheme for `platform=macOS`, 0 warnings, cold.
- pbxproj edits via the `xcodeproj` Ruby gem (write scripts to `/tmp/*.rb`). New target name: **`KataGo Anytime Mac`** (product `KataGoAnytimeMac`), bundle id `chinchangyang.KataGo-iOS.tw.mac` (distinct from the iOS app), macOS 26 deployment, sandbox + same CloudKit container entitlement (`iCloud.chinchangyang.KataGo-iOS.tw`) so SwiftData sync matches.
- House rule: **0 build warnings**. Commit after each green task; branch `ios-dev`; do NOT push or tag.
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure (end state)

```
ios/KataGo iOS/
├── KataGoUICore/Sources/KataGoUICore/Session/
│   └── GameSession.swift              (NEW — engine-driven state + GTP loop, extracted from ContentView)
├── KataGo iOS/                        (existing iOS app — ContentView refactored to use GameSession)
└── KataGo Anytime Mac/               (NEW AppKit target)
    ├── AppDelegate.swift              NSApplicationDelegate: bridge registration, ModelContainer, main menu, open window
    ├── main.swift                     (or @main on AppDelegate) — NSApplication bootstrap
    ├── MainWindowController.swift      NSWindowController hosting the split VC + NSToolbar
    ├── MainSplitViewController.swift   NSSplitViewController: sidebar | board | inspector (sidebar/inspector = placeholders)
    ├── BoardViewController.swift       NSViewController embedding NSHostingController(rootView: MacBoardHostView)
    ├── MacBoardHostView.swift          SwiftUI: injects GameSession state into the reused BoardView
    ├── CoreMLComputeHandleLoader.swift (re-hosted copy — imports KataGoSwift; see Phase-0 note)
    ├── KataGoAnytimeMac.entitlements   sandbox + iCloud container
    └── Info.plist
```

---

## Task 1: Extract `GameSession` into `KataGoUICore` and adopt it in iOS

**Files:**
- Create: `KataGoUICore/Sources/KataGoUICore/Session/GameSession.swift`
- Modify: `KataGo iOS/KataGo iOS/ContentView.swift` (delegate to `GameSession`)

**Design:** `GameSession` is an `@Observable @MainActor` class that OWNS the engine-driven state and the GTP loop:
- Owns: `stones: Stones`, `board: BoardSize`, `player: Turn`, `analysis: Analysis`, `rootWinrate: Winrate`, `rootScore: Score`, `messageList: MessageList`, `gobanState: GobanState`, `bookLookup: BookLookup` (the objects `ContentView` currently `@State`s and that `maybeCollect*` mutate).
- Methods moved verbatim from `ContentView` (no logic change): `messaging()`, `messageTask()` (renamed to a `run()` loop with an internal `stopRequested` flag instead of reading the app's `QuitStatus`), `maybeCollectBoard/Analysis/Sgf/Play/CheckMove`, `sendInitialCommands`, and the `version`/first-response handshake (`initialize(selectedModelTitle:engineLifecycle:config:)`).
- Keeps using `KataGoHelper`/the parsers (all in-package now).
- Does NOT own app/view-only state (`navigationContext`, `thumbnailModel`, `audioModel`, `topUIState`, `quitStatus`) — those stay with the view layer and are passed in where needed.

- [ ] **Step 1: Read the green baseline** — iOS build + FullTestPlan green (record evidence). If not, STOP.

- [ ] **Step 2: Create `GameSession`** holding the 9 state objects + a `var stopRequested = false`, and move the loop/parse methods into it. The loop:
```swift
@Observable @MainActor public final class GameSession {
    public let stones = Stones()
    public let board = BoardSize()
    public let player = Turn()
    public let analysis = Analysis()
    public let rootWinrate = Winrate()
    public let rootScore = Score()
    public let messageList = MessageList()
    public let gobanState = GobanState()
    public let bookLookup = BookLookup()
    public var stopRequested = false
    private var isShowingBoard = false
    private var boardText: [String] = []
    public init() {}

    public func run() async {            // was messageTask()
        while !stopRequested { await messaging() }
    }
    public func messaging() async { /* moved verbatim; replace `quitStatus == .none` with `!stopRequested` */ }
    // maybeCollect*, sendInitialCommands, etc. — moved verbatim, made the needed members `public`/`internal`
}
```
(Pull the exact bodies of `messaging`, `maybeCollect*`, `sendInitialCommands`, `initializationTask`'s engine-handshake from `ContentView.swift` lines ~74–end; keep behavior identical. `isShowingBoard`/`boardText` become private GameSession state.)

- [ ] **Step 3: Refactor iOS `ContentView`** to own `@State private var session = GameSession()` and read its state: replace the 9 `@State` objects with `session.stones` etc.; `.environment(session.stones)` … (same objects, now via `session`); replace `messageTask()` with `await session.run()`; map `quitStatus`→`session.stopRequested` where the loop used it; call the moved `session.initialize(...)`/`session.sendInitialCommands(...)`. The body/`GameSplitView` wiring stays the same objects, just sourced from `session`. Keep `navigationContext`, `thumbnailModel`, `audioModel`, `topUIState`, `bookLookup` wiring intact (bookLookup now lives on `session`).

- [ ] **Step 4: Build iOS** → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: FullTestPlan** → `** TEST SUCCEEDED **` (the existing `KataGoModelTests`/`GobanStateBranchTests`/parser/UI suites exercise this path; they are the behavior gate).
- [ ] **Step 6: Build macOS + visionOS** (the package change must not break them) → `** BUILD SUCCEEDED **` ×2.
- [ ] **Step 7: Commit** `refactor(core): extract GameSession (GTP loop + engine state) into KataGoUICore`.

**Fallback (if Step 5 destabilizes iOS and can't be made green within reasonable effort):** report DONE_WITH_CONCERNS; keep `GameSession` in the package for the Mac app but REVERT the `ContentView` adoption (leave iOS on its own loop), and note the temporary duplication as a follow-up. Do not ship a red iOS suite.

---

## Task 2: Create the `KataGo Anytime Mac` AppKit target (launches an empty window)

**Files (create):** `KataGo Anytime Mac/{main.swift or AppDelegate.swift, KataGoAnytimeMac.entitlements, Info.plist}`; plus a re-hosted `KataGo Anytime Mac/CoreMLComputeHandleLoader.swift` (copy of the app's file — it imports `KataGoSwift`).
**Modify:** `project.pbxproj` (new native target, macOS app, links `KataGoUICore` + `katago` + `KataGoSwift` frameworks, embeds them, entitlements, a shared scheme `KataGo Anytime Mac`).

- [ ] **Step 1: Add the target via the `xcodeproj` gem** — `com.apple.product-type.application`, platform macOS 26, product name `KataGoAnytimeMac`, bundle id `chinchangyang.KataGo-iOS.tw.mac`. Add a Sources build phase, Frameworks build phase linking `KataGoUICore` (package product), `katago.framework`, `KataGoSwift.framework`, and an Embed Frameworks phase for the two frameworks. Set `SWIFT_VERSION=6.0`, `MACOSX_DEPLOYMENT_TARGET=26.0`, `GENERATE_INFOPLIST_FILE=NO` (use the explicit Info.plist), `CODE_SIGN_ENTITLEMENTS` → the new entitlements file, `ENABLE_APP_SANDBOX=YES`. Create a shared `.xcscheme` for it.

- [ ] **Step 2: `AppDelegate.swift`** — programmatic bootstrap (no storyboard):
```swift
import AppKit
import SwiftData
import KataGoUICore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?
    let modelContainer = try! ModelContainer(for: GameRecord.self)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Phase-0 forward note: re-host the CoreML bridge wiring here (the loader
        // imports KataGoSwift, which can't live in the package).
        registerCoreMLBridge()
        registerDownloadedHasher(BinFileHasher.shared.identityForDownloadedFile)
        let wc = MainWindowController(modelContainer: modelContainer)
        wc.showWindow(nil)
        self.windowController = wc
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
```
(`main.swift` not needed when using `@main` on the delegate; if the build complains about no main entry, add a `main.swift` with `NSApplication.shared` + `NSApplicationMain`.)

- [ ] **Step 3: `Info.plist` + `.entitlements`** — minimal app Info.plist (LSMinimumSystemVersion 26.0, NSPrincipalClass `NSApplication`); entitlements = `com.apple.security.app-sandbox = true`, `com.apple.developer.icloud-container-identifiers = [iCloud.chinchangyang.KataGo-iOS.tw]`, `com.apple.developer.icloud-services = [CloudKit]`, network client (for model downloads) + user-selected files read/write (SGF import/export later).

- [ ] **Step 4: Stub `MainWindowController`** (full split/toolbar comes in Task 3) — for now a plain window so the target links + launches:
```swift
final class MainWindowController: NSWindowController {
    init(modelContainer: ModelContainer) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "KataGo Anytime"
        super.init(window: w)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

- [ ] **Step 5: Build the Mac scheme** `xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug -derivedDataPath "DerivedData/KataGo Anytime"` → `** BUILD SUCCEEDED **`, 0 warnings. (Launches an empty window — fine for this task.)

- [ ] **Step 6: Commit** `feat(mac): add KataGo Anytime Mac AppKit target (empty window launches)`.

---

## Task 3: 3-pane `NSSplitViewController` + `NSToolbar` + main menu

**Files (create):** `MainSplitViewController.swift`, `BoardViewController.swift`; **modify** `MainWindowController.swift`, `AppDelegate.swift` (menu).

- [ ] **Step 1: `MainSplitViewController`** — an `NSSplitViewController` with three `NSSplitViewItem`s: `sidebar` (a placeholder `NSViewController` with an `NSTextField` "Library (Phase 2)"), `BoardViewController` (center, the only working pane this phase), and `inspector` (placeholder "Inspector (Phase 4)"). Make sidebar + inspector collapsible (`.sidebar`/`.inspector` behaviors); set sensible holding priorities so the board takes the slack.

- [ ] **Step 2: `BoardViewController`** — wraps the SwiftUI board:
```swift
final class BoardViewController: NSViewController {
    let session: GameSession
    init(session: GameSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let host = NSHostingController(rootView: MacBoardHostView(session: session))
        addChild(host)
        view = host.view
    }
}
```
(`MacBoardHostView` is created in Task 4. For Task 3, a temporary `MacBoardHostView` showing `Text("Board")` is fine so the split builds.)

- [ ] **Step 3: `MainWindowController`** — set `contentViewController = MainSplitViewController(...)`, attach an `NSToolbar` (delegate) with items: sidebar toggle, `New`, `Import`, model label (placeholder), `⏮ ◀ ▶ ⏭` nav, `Analyze` (placeholder), inspector toggle. Wire toolbar actions to first-responder selectors (implemented in Task 5; for now they can no-op/validate-disabled).

- [ ] **Step 4: Main menu** in `AppDelegate` — build `NSApp.mainMenu` programmatically: **App** (About/Settings…/Hide/Quit ⌘Q), **File** (New Game ⌘N, Import… ⌘O — actions stubbed), **Edit** (standard), **View** (Toggle Sidebar ⌃⌘S, Toggle Inspector ⌃⌘I), **Navigate** (Back ←/Forward → — stubbed), **Window**, **Help**. (Real action wiring lands in Task 5; menu items use `validateMenuItem` to disable until wired.)

- [ ] **Step 5: Build Mac scheme** → SUCCEEDED, 0 warnings. Optionally launch to confirm the 3-pane window + toolbar render (manual, if you can run it headless-launch; otherwise build is the gate).
- [ ] **Step 6: Commit** `feat(mac): 3-pane split view, toolbar, and main menu shell`.

---

## Task 4: Wire `GameSession` + built-in model + render the board

**Files (create):** `MacBoardHostView.swift`; **modify** `AppDelegate`/`MainWindowController` (own the `GameSession`, start the engine), `BoardViewController` (already takes the session).

- [ ] **Step 1: Own a `GameSession`** in `MainWindowController` (or AppDelegate) and pass it to `BoardViewController`.

- [ ] **Step 2: Start the engine + a game on launch.** Mirror the iOS `ModelRunnerView`/`ContentView.initializationTask` flow, but minimal: pick the **built-in** `NeuralNetworkModel` (bundled), call `KataGoHelper.runGtp(...)` on a background `Thread` (as iOS does via `startKataGoThread`), then `await session.initialize(...)` (version handshake + `sendInitialCommands` + load a game). For Phase 1, load the first SwiftData `GameRecord` if present, else create a new default 19×19 game (`GameRecord.createGameRecord`) inserted into `modelContainer.mainContext`. Then `Task { await session.run() }`.

- [ ] **Step 3: `MacBoardHostView`** — a SwiftUI view that injects the session's state into the reused `BoardView` (the renderer that moved to the package in Phase 0). `GobanView` stayed iOS-only, so build the minimal env wiring here:
```swift
struct MacBoardHostView: View {
    let session: GameSession
    var body: some View {
        BoardView(/* the params BoardView needs */)
            .environment(session.stones)
            .environment(session.board)
            .environment(session.player)
            .environment(session.analysis)
            .environment(session.gobanState)
            .environment(session.rootWinrate)
            .environment(session.rootScore)
            .environment(session.bookLookup)
            .environment(session.messageList)
            // + AudioModel/ThumbnailModel/NavigationContext/TopUIState as BoardView requires
    }
}
```
(Inspect `BoardView`'s `@Environment`/init requirements and provide exactly those; create lightweight Mac-side instances of any app-UI state objects `BoardView` needs, e.g. a `NavigationContext`, `AudioModel`. If `BoardView` transitively needs app-only types that aren't in the package, report it — we either host a smaller subview or move that type in a follow-up.)

- [ ] **Step 4: Build Mac scheme** → SUCCEEDED, 0 warnings.
- [ ] **Step 5: Run & verify the slice (manual or via a smoke check):** launch the Mac app; the board renders the loaded game; the engine is running (board updates from `showboard`). Capture a screenshot if possible. If a manual run isn't possible headless, the build + a unit-level check that `GameSession.initialize` drives `stones` is the gate.
- [ ] **Step 6: Commit** `feat(mac): load built-in engine via GameSession and render the board`.

---

## Task 5: Basic move navigation

**Files:** modify `MainWindowController` (toolbar actions), `AppDelegate` (menu actions), routing to `GameSession`/`GobanState`.

- [ ] **Step 1: Implement nav actions** — `goBackward`/`goForward`/`goToStart`/`goToEnd` as `@objc` methods on the window controller (first responder), calling the same `GobanState`/`messageList` navigation the iOS toolbar uses (reuse `GobanState`'s existing navigation API; inspect `StatusToolbarItems` for the exact calls). Wire both the toolbar `⏮ ◀ ▶ ⏭` items and the **Navigate** menu (←/→) to them.
- [ ] **Step 2: `validateMenuItem`/toolbar validation** — disable nav when at the ends or while the engine is mid-move (mirror iOS disabled-state logic minimally).
- [ ] **Step 3: Build Mac scheme** → SUCCEEDED, 0 warnings.
- [ ] **Step 4: Verify** nav moves the board back/forward (manual run if possible; else confirm the actions call the same GobanState API the iOS app uses).
- [ ] **Step 5: Commit** `feat(mac): wire basic move navigation (toolbar + menu)`.

---

## Task 6: Verify the slice + regression

- [ ] **Step 1: Cold build the Mac scheme** (trash `DerivedData/KataGo Anytime` first) → `** BUILD SUCCEEDED **`, **0 warnings**.
- [ ] **Step 2: iOS regression** — iOS build + `FullTestPlan` green (the Task-1 GameSession adoption must not have regressed iOS), macOS + visionOS (existing app scheme) build green.
- [ ] **Step 3: Manual slice smoke** (if runnable): Mac app launches → 3-pane window, native menu + toolbar, board renders the loaded game, ←/→ navigate moves. Note any rough edges for later phases (they're expected — sidebar/inspector are placeholders).
- [ ] **Step 4: Commit** any final fixes; tag `mac-phase1-skeleton`.

---

## Risks & Mitigations
- **Task 1 (GameSession adoption in iOS) is the riskiest** — it refactors the working iOS message loop. Mitigation: move methods verbatim (no logic change), gate on the full iOS test suite + UI tests, and the documented fallback (Mac-only GameSession) if it can't be made green.
- **`BoardView`'s env requirements** may include app-UI types not in the package (e.g. `TopUIState`); if so, host a smaller subview or move the type in a follow-up — report rather than dragging app chrome into the Mac target.
- **New target ↔ frameworks linkage** (katago/KataGoSwift/KataGoUICore) must mirror the iOS app's embed/link setup; the Mac app links them directly (as the iOS app does post-Phase-0). The `.static` `KataGoUICore` product resolves engine symbols at the Mac app link.
- **Engine on macOS** defaults to MLX/GPU + 16 threads (already in `KataGoHelper`); no simulator pinning needed (real GPU on Mac).
- **CloudKit container** must match the iOS app exactly so SwiftData sync is consistent.

## Out of Scope (restated)
Library contents, analysis overlay wiring, inspector tabs, Models/Settings windows, branching, opening book, App Intents, hover-preview, context menus — Phases 2–6.
