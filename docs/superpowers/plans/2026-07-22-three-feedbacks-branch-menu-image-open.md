# KataGo Anytime — Three Feedback Items

## Context

Three user-feedback items on the KataGo Anytime app:

1. **Branch-mode move numbering + navigation floor.** In branch mode the board should number only the *branch* moves, starting from 1, regardless of the global move-number style (pre-existing stones stay bare). Navigation must never go earlier than the branch starting position.
2. **"Game Settings" belongs under "This Game".** Users expect "Settings" to be global-only; per-game configuration should live in the "This Game" submenu.
3. **Open images/photos with KataGo Anytime.** The app already opens SGF from Share/Files; do the same for images, routed into the existing board-photo recognition import.

## Locked decisions (grilling round)

- **Clamp UX:** silent stop at the branch-start position (inclusive — stepping back *to* the divergence is allowed; chart/move-list taps to earlier positions clamp to it). No dialogs.
- **Platform scope:** clamp + numbering apply on all platforms via shared `GobanState` — including tvOS review, where `forcesBranchOnPlay` makes every trial move a branch.
- **Numbering rule:** while a branch is active, always render 1..N on branch stones only; the engine "last 3" markers and the red last-move marker are suppressed; global `moveNumberStyle` is ignored.
- **Settings shape:** flatten. Top-level "Settings" (same label with or without a game) opens Global Settings directly; "Developer Mode" moves into Global Settings' Engine section; "Game Settings" becomes the first item of "This Game" (gearshape). The intermediate `ConfigView` hub is deleted.
- **Image open:** document-type registration only (no Share Extension), on both iOS and macOS plists; reuse the existing recognition sheet end-to-end.

All paths below are relative to `ios/KataGo iOS/`. Package = `KataGoUICore/Sources/`. Verified key facts: divergence index == `gameRecord.currentIndex` (frozen) while `isBranchActive`; `undoBranchIndex()` has no callers besides `undoIndex`; `CommandView.config` and its `player` environment are dead; `ConfigView` struct has exactly one call site (PlusMenuView:168); warm-path image open already works via `GameSplitView.importAndSelect(from:)`.

---

## Part A — Branch numbering + navigation clamp

### A1. `MoveNumbers.derive` gains `startIndex` (pure logic)
`KataGoUICore/Sources/KataGoUICore/Session/MoveNumbers.swift`
- New signature: `derive(sgf:currentIndex:startIndex: Int = 0)`; start the walk at `max(startIndex, 0)`, number = `index - max(startIndex, 0) + 1`. Pass/ko/lastPoint logic unchanged. `startIndex >= currentIndex` → empty (the floor position). Existing callers (incl. `VisionRootView:424,846` animation lastPoint) are source-compatible — do NOT pass `startIndex` there.

### A2. `GobanState`: resolved style + branch-relative numbers + cache key
`KataGoUICore/Sources/KataGoUICore/Model/GobanState.swift`
- New computed `resolvedMoveNumberStyle: MoveNumberStyle` (near `moveNumberStyleChoice` ~1085): `isBranchActive ? .allMoves : moveNumberStyleChoice`.
- `getMoveNumbers(gameRecord:)` (~785): guard on `resolvedMoveNumberStyle != .lastThreeMoves` (bypasses the short-circuit in branch mode); `startIndex = isBranchActive ? (gameRecord?.currentIndex ?? currentIndex) : 0`; pass to `derive`.
- **Widen the cache key** (line 129) to `(String, Int, Int)?` including `startIndex` — after `commitBranch`, `(sgf, currentIndex)` aliases the branch-mode key and would serve stale branch-relative numbers.

### A3. `BoardView`: one-line style swap
`KataGoUICore/Sources/KataGoUICore/Rendering/BoardView.swift:128` — pass `style: gobanState.resolvedMoveNumberStyle`. `MoveNumberView` is NOT modified (its `.lastThreeMoves`/`.lastMoveMarker` paths become unreachable in branch mode because the style resolves upstream). `ReportBoardView` (hard-coded styles, self-built MoveNumbers) stays safe by construction.

### A4. Navigation floor in `GobanState`
- New `navigationFloor(gameRecord:) -> Int`: `isBranchActive ? (gameRecord?.currentIndex ?? 0) : 0`.
- New `canStepBackward(gameRecord:) -> Bool`: recorded move exists behind cursor AND cursor > floor (for out-of-funnel callers that send engine `undo` themselves).
- `undoIndex` (~672): in branch mode, decrement `branchIndex` only while `> navigationFloor(...)` (fold `undoBranchIndex()` in; it has no other callers — do not leave the parameterless 0-floor version public).
- `backwardMoves` (~721): add `currentIndex > floor` to the while guard (covers iOS back/rewind, Mac, TV `stepBy`, Vision rewind, and the descending half of `go(to:)`). Keep the trailing `sendPostExecutionCommands` even at zero moves (Vision relies on it).
- `go(to:)` (~851): `let clampedTarget = max(targetIndex, navigationFloor(...))`; early-return when equal; use `clampedTarget` in both limit computations (silently clamps LinePlotView, MovesListView, WatchCommandHandler).

### A5. Gate the two out-of-funnel callers + Mac menu mirror
Danger: at the branch floor the engine can still undo pre-branch moves, so an ungated engine `undo` desyncs the board.
- `KataGo iOS/Toolbars/StatusToolbarItems.swift` `backwardFrameAction` (~160): add `gobanState.canStepBackward(gameRecord: gameRecord)` to the condition.
- `KataGo Anytime Vision/VisionRootView.swift` `undoOneMove` (~840): add `canStepBackward` to the guard BEFORE the `expectStoneAnimation(.remove(tip))` derivation (else a clamped undo enqueues a phantom remove-intent).
- `KataGo Anytime Mac/MainWindowController.swift` `canGoBackward` (~487): add `currentIndex > navigationFloor(...)` — this property's contract is "mirrors backwardMoves' loop guard", and Mac already grays Back/First at mainline index 0; extending to the branch floor keeps it truthful.
- Benign side effect: at mainline index 0 the two gated callers stop sending a futile engine `undo` (engine refused it anyway; nothing pins it).

### A6. Tests (target "KataGo AnytimeTests", iOS Simulator)
- `KataGo iOSTests/MoveNumbersTests.swift` additions: branch-relative numbering (startIndex 2 of 5 → numbers 1..3), startIndex 0 == absolute, startIndex ≥ currentIndex → empty, pass-inside-branch keeps relative count, branch-ending-in-pass clears lastPoint, negative startIndex == 0.
- New `GobanStateBranchNumberingTests.swift`: `resolvedMoveNumberStyle` for all 4 styles active/inactive; `.lastThreeMoves` bypass in branch; empty at divergence; **cache-aliasing regression** (branch getMoveNumbers → commitBranch → getMoveNumbers must return absolute).
- New `GobanStateBranchClampTests.swift` (Fixture pattern from `GobanStateForcedBranchTests` — standalone `MessageList` makes engine commands countable): undoIndex stops at divergence / mainline still reaches 0; canStepBackward at/above floors; `backwardMoves(limit:nil)` stops at divergence with exactly N undo commands and record.currentIndex untouched; `go(to: 0)` clamps to divergence; `go(to:)` within branch still navigates.
- No existing test changes expected (13 MoveNumbersTests use the defaulted param; branch suites never navigate).

---

## Part B — Game Settings under "This Game" (iOS-only)

### B1. `KataGo iOS/Misc/CommandView.swift`
Remove dead `var config: Config` (and unused `@Environment(Turn.self)`). It only needs `MessageList` from the environment — available at every PlusMenuView host, including `gameRecord: nil` ones.

### B2. `KataGo iOS/Config/ConfigView.swift`
- `GlobalSettingsView` Engine section (~876-907): append the Developer Mode `NavigationLink { CommandView().navigationTitle("Developer Mode") } label: { Label("Developer Mode", systemImage: "doc.plaintext") }` after the Version row (unconditional — Engine section never renders empty); extend the section comment.
- Delete `struct ConfigView` (958-987). Keep `GameSettingsView` as-is (`navigationTitle("Game Settings")`). Keep `GlobalSettingsView`'s `navigationTitle("Global Settings")`. Do not rename the file.

### B3. `KataGo iOS/GameList/PlusMenuView.swift`
- Rename `showingConfig` → `showingGameSettings`.
- "This Game" submenu: insert **Game Settings** button (`gearshape`) as first item, then a `Divider()` before ShareLink.
- Collapse the settings block (141-160) to one unconditional `Button { showingGlobalSettings = true } label: { Label("Settings", systemImage: "gearshape.2") }`; rewrite the stale comment (143-147).
- Repurpose the old sheet: `showingGameSettings` → `NavigationStack { GameSettingsView(gameRecord:maxBoardLength:) }` (keep the latent `#if os(macOS)` frame guard). `showingGlobalSettings` sheet unchanged.
- Comment touch-up: `KataGo iOS/App/ContentView.swift:125` "rides the environment into ConfigView" → "GlobalSettingsView".

### B4. UI tests (`KataGo iOSUITests/`, target "KataGo AnytimeUITests")
- `CoreMLCacheFooterUITests.swift`: (a) `testDisplayPreferencesMovedToGlobalSettings` — drop the "Global Settings" row tap after Settings; to reach Game Settings, dismiss the sheet by swiping down on the **nav bar** (list may scroll otherwise), then More ▸ This Game ▸ Game Settings; Rule/Analysis assertions unchanged. (b) `testOpenSourceLicensesScreen` — drop the row tap; assert `navigationBars["Global Settings"]` directly. (c) `waitForEngineThenQuit` — drop the globalSettings tap; update comments.
- `PlayerNameLabelUITests.swift`: `openAIConfig` — `tapRow(app, "This Game")` then `tapRow(app, "Game Settings")`; `dismissConfig` — pop only `["AI"]` then swipe-down (Game Settings is now the sheet root, no back button); update doc comments.
- `KataGo_iOSUITests.swift`: assert `navigationBars["Global Settings"]` after More ▸ Settings; rename `snap("ConfigView")` → `snap("GlobalSettingsView")`; Developer Mode is below the fold of the long list — add a swipeUp loop (≤8) before asserting; update comments.
- `GlobalSettingsMenuUITests.swift`: menu label `"Global Settings"` → `"Settings"` (no-game case); nav-bar assertion stays.
- `GifExportUITests.swift`: no code change expected (label-tapped; 7-item submenu fits) — just re-run.

### B5. Docs
`README.md` (81-96, 133-161): Game Settings listed first under This Game; "Settings — app-wide (opens Global Settings directly)"; rewrite the "## Settings" intro (keep the heading text — the `#settings` anchor at line 55 must keep resolving).

---

## Part C — Open images/photos with the app

### C1. Plist registration (both platforms)
`KataGo-iOS-Info.plist` + `KataGo Anytime Mac/Info.plist` — append to `CFBundleDocumentTypes`:
`CFBundleTypeName` "Board Photo", `CFBundleTypeRole Viewer`, `LSHandlerRank Alternate`, `LSItemContentTypes` = `public.png`, `public.jpeg`, `public.heic`, `public.heif`.
Rationale: explicit types, not `public.image` — avoids claiming GIF/TIFF/RAW/WebP/SVG the recognizer can't use; `Alternate` (never `None` — risks vanishing from Finder Open With; never default — must not steal images from Preview). No UTImportedTypeDeclarations needed (all system types). Runtime stays permissive (`imageDataIfImage` accepts anything conforming to `.image`). **macOS needs only this plist entry** — `AppDelegate.application(_:open:)` → `LibraryActions.importAndSelect` already routes images to the recognition sheet, and post-confirm selection is F14-gated by `ReadinessGate`.

### C2. Shared classifier + latch (`KataGoUICore`)
New `KataGoUICore/Sources/KataGoUICore/Model/FileOpenClassifier.swift`: `isImage(URL) -> Bool` (contentType resourceValue, fallback `UTType(filenameExtension:)`, conforms to `.image`); `imageData(at:) -> Data?` (security-scoped read); `cleanUpInboxFile(at:containerRoots:)` — deletes ONLY files under an app-container `Inbox`-suffixed parent (never an in-place Files URL; injectable roots for tests).
`DeepLinkRouter.swift`: add `public struct PendingImageImport: Equatable { imageData: Data; suggestedName: String }` and `var pendingImageImport: PendingImageImport?`. Data latch, not URL — the sandbox extension may not survive until GameSplitView mounts on cold launch.

### C3. iOS root handler (cold-launch fix)
`KataGo iOS/App/KataGo_iOSApp.swift` `.onOpenURL` (55-66): after the `gameID` branch, if not an `import-sgf` link and `FileOpenClassifier.imageData(at: url)` succeeds → latch `PendingImageImport(data, url.deletingPathExtension().lastPathComponent)` and `cleanUpInboxFile`. SGF URLs keep falling through. Root is mounted from first frame → covers picker/loading/warm phases; needs no engine, so `initializationTask` is untouched.

### C4. `GameSplitView` drain + de-dup
- `.onOpenURL` (242-254): add `!FileOpenClassifier.isImage(url)` to the `importAndSelect(from:)` branch (root owns images now; without this a warm open presents twice).
- New `.onChange(of: deepLinkRouter.pendingImageImport, initial: true)` → `applyPendingImageImport()`: consume latch → `presentPhotoImport(imageData:name:)`. Mirrors the proven `pendingGameID` drain; `initial: true` catches latches set before mount.
- Optional dedup: `imageDataIfImage(at:)` body → `FileOpenClassifier.imageData(at:)` (fileImporter path keeps using `importAndSelect(from:)` unchanged).
- Known accepted edge: image arriving while the camera fullScreenCover is up may drop the sheet presentation (rare; defer mitigation).

### C5. `ModelPickerView` image-awareness
`.onOpenURL` (247-258): first branch — `if FileOpenClassifier.isImage(url)`: auto-select `NeuralNetworkModel.builtInModel` when none selected (mirrors the existing SGF behavior), `return`. Fixes the current UTF-8 misparse of image bytes.

### C6. Inbox cleanup consistency
Share-sheet/Mail copies land in the app's Inbox and are never deleted today (SGF path included). Call `cleanUpInboxFile` after: the root image latch (C3), successful SGF import in `GameSplitView.importAndSelect(from:)`, and `ModelPickerView`'s successful import. Guard makes in-place/Powerbox URLs untouchable.

### C7. Tests
New `KataGo iOSTests/FileOpenClassifierTests.swift` (Swift Testing): `isImage` by extension + by written-file resource key; `imageData` bytes/nil; `cleanUpInboxFile` deletes only under injected root's `Inbox/` (not outside roots, not root-level, not stray `Inbox` dirs); `PendingImageImport` equality + router latch set/clear (instance, not `.shared`).

---

## Verification

1. **Build all five schemes** (per CLAUDE.md commands): iOS, Mac, Vision, TV, Watch — Parts A/C touch shared `KataGoUICore`.
2. **Unit tests:** `xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'` (grep BUILD/TEST SUCCEEDED — piped exit codes lie).
3. **UI tests:** touched classes first via `-only-testing:`, then the full `-testPlan FullTestPlan` for parity (known flake: CameraImportUITests cover-race → rerun).
4. **Manual sim QA (verify skill):**
   - A: locked mid-game → play a stone → branch stones numbered 1..N under every global style (try "Last 3 moves": engine markers must vanish); step back to divergence → bare stones; back/rewind again → no motion; chart/move-list tap earlier → silent clamp. Mac: Back/First enablement at floor. TV review: trial move → "1", swipe-back clamps.
   - B: More ▸ This Game ▸ Game Settings (first item) → Name/Rule/…; More ▸ Settings → Global Settings directly, Developer Mode under Engine; no-game case shows "Settings" too.
   - C: Files "Open in" image warm (sheet over board) + cold (terminate → open → LoadingView → sheet after mount) + picker-phase; SGF open regression (warm/cold); widget deep link regression; photo/camera import regression; Inbox empty after share-sheet copy (`simctl get_app_container`).
5. **Device QA (deferred, note in commits):** Photos share-sheet app row (HEIC), Finder Open With on Mac (rebuild so Launch Services re-registers; stale dev builds shadow).

## Risks

- **Engine desync at branch floor** is Part A's one real hazard — closed by gating `backwardFrameAction` + Vision `undoOneMove` (A5); funnel methods only send `undo` inside guarded loops.
- **Cache aliasing after commitBranch** — closed by the 3-tuple key + regression test.
- **ReportBoardView / Vision animations** — safe only if `MoveNumberView` init and `MoveNumbers` memberwise init stay unchanged (they do).
- **Open-With pollution** — inherent to doc-type registration; mitigated by narrow type list + Alternate rank.
- **Wrong-file deletion** — Inbox guard is container-root + Inbox-parent, unit-tested.
- Cosmetic acceptance: chart/move-list selection may point pre-divergence while the board sits clamped (per silent-stop decision).

## Commit sequencing

Three independent features → separate commits per part (A can itself split: pure derive+tests → renderer → clamps, each green). Push cadence per ios-dev rules (≥~1 day spacing).
