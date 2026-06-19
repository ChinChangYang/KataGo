# KataGo Anytime — Organization-Core Refactor

- **Date:** 2026-06-19
- **Status:** Approved (design); pending implementation plan
- **Branch:** `refactor/organization-core` (off `ios-dev`)
- **Scope tier:** "Organization core" (ranks 1–7 of the architecture assessment)

## 1. Motivation

A six-way architectural assessment of the KataGo Anytime app (shared `KataGoUICore`
package, the macOS AppKit target, the iOS/visionOS SwiftUI target, the engine/transport
seam, cross-platform duplication, and project/repo topology) found a consistent shape:
**the seams are good, the centers are heavy.**

The two cleanest boundaries — the `KataGoEngineIO` transport protocol (in-process iOS vs.
subprocess macOS) and the stateless GTP parsers (`AnalysisLineParser` / `BoardTextParser`)
— are well-designed and should be preserved as the model for the rest of the app.

The weaknesses recur as four themes:

1. **God objects** concentrate unrelated responsibilities — `MainWindowController`
   (2870 LOC), `GobanState` (831), `ConfigModel` (802, a SwiftData `@Model` that also
   generates ~19 GTP commands), plus the iOS mega-views `ConfigView` (858) and
   `GameSplitView` (624).
2. **Cross-platform logic is duplicated instead of shared** —
   `CoreMLComputeHandleLoader.swift` is byte-identical in both app targets (292 LOC each,
   verified by `diff`); config→GTP sync is extracted on macOS but inlined on iOS and kept
   in parity *by hand-quoted line numbers*; 14 `GlobalSettings.*` keys are hardcoded twice.
3. **Business logic lives inside views and persistence models** — `@Model` types carry
   command generation; `GobanState` reaches down into the Bridge layer (`SgfHelper`) 10×,
   inverting the intended layer direction; views mutate `GameRecord` and fire GTP commands
   directly in `onChange`.
4. **Repo / project hygiene debt** — stale empty dirs, ~6.8 MB of committed PNGs, and
   Ruby scripts that mutate `project.pbxproj`.

This effort targets the **organization-core** subset (ranks 1–7): the de-duplication,
extraction, and reorganization changes that deliver most of the structural value at low–
medium risk, deliberately **deferring** the high-risk god-object surgery
(`MainWindowController` and `GobanState` decomposition, ranks 8–11) to a possible follow-up.

## 2. Guiding principles

- **Behavior-preserving.** Every change is a move / extract / dedupe. No feature changes,
  no GTP command-string changes, no SwiftData stored-schema changes.
- **Schema is frozen.** `Config` and `GameRecord` are SwiftData `@Model`s synced via
  CloudKit and must keep their persisted shape. We relocate **methods/computed properties
  only** — those do not affect the stored schema. No stored `@Attribute`/`@Relationship`
  is added, removed, or renamed.
- **Push shared logic down, keep platform-specific UI up.** Platform-neutral logic lands
  in `KataGoUICore`; only genuinely framework-specific UI (SwiftUI rows vs. AppKit rows)
  stays in the app targets.
- **Preserve the good seams.** `KataGoEngineIO` and the GTP parsers are not restructured.
- **The app is unreleased.** No migration or back-compat code is needed.

## 3. Constraints (verified during assessment)

- **`CoreMLComputeHandleLoader` cannot move into the SwiftPM package.** It `import`s the
  `KataGoSwift` **framework** (its `@_silgen_name("katagocoreml_*")` bridges resolve
  against the linked C++ `katagocoreml`, and it uses framework interop types
  `MetalComputeContext` / `CoreMLComputeHandle`). A SwiftPM package cannot depend on an
  Xcode framework target. → Rank 1 becomes a single-source **app-target** file, not a
  package move.
- **Build inputs must not be deleted:** `Libraries/*.a` (prebuilt CoreML static libs,
  untracked/gitignored) and `KataGoSwift/KataGoSwift.h` (a real tracked header).
- **Only the 6 root PNGs are git-tracked bloat.** `DerivedData/`, `TestResults.xcresult`,
  `__MACOSX/`, `KataGoEngineIPC/.build/`, `.DS_Store`, `.derived-data-log-*` are all
  untracked (most already gitignored).
- **Xcode Cloud free-tier push rate is limited** — keep CI-triggering pushes spaced out;
  this effort does **not** push.

## 4. Milestones

Three milestones, each ending in a full-test-plan checkpoint. After **every** step within
a milestone, build all three platforms (iOS Simulator, visionOS Simulator, macOS).

### Milestone A — De-duplication & hygiene (ranks 1, 2, 3, 7)

Low risk, mechanical. No behavioral change intended.

- **A1 · Single-source `CoreMLComputeHandleLoader` (rank 1).**
  - First, determine whether the **macOS app process** ever calls `loadCoreMLHandle`.
    macOS runs the engine as a subprocess (`katago-engine`) with its own
    `KataGoEngineHelper/EngineCoreMLBridge.swift`, so the app-process copy may be vestigial.
  - **If vestigial on Mac:** remove the Mac target's copy; keep iOS's single copy.
  - **If live on both:** keep one physical file in a new `Shared/` group and add it to both
    app targets' Compile Sources (dual target membership). Delete the duplicate.
  - Files: `KataGo iOS/CoreMLComputeHandleLoader.swift`,
    `KataGo Anytime Mac/CoreMLComputeHandleLoader.swift`, `project.pbxproj`.

- **A2 · `GlobalSettingsKeys` single source of truth (rank 2).**
  - New `KataGoUICore/Sources/KataGoUICore/Services/GlobalSettingsKeys.swift`:
    `public enum GlobalSettingsKeys` holding the 14 `GlobalSettings.*` UserDefaults key
    strings as `static let` constants.
  - iOS `GameSplitView` (`@AppStorage`) and macOS `MacGlobalPreferenceSync` reference the
    constants instead of hardcoded literals. Pure constant extraction; no behavior change.
  - Files: new `GlobalSettingsKeys.swift`; `KataGo iOS/GameSplitView.swift`;
    `KataGo Anytime Mac/MacGlobalPreferenceSync.swift`.

- **A3 · Repo hygiene (rank 3).**
  - Move the 5 README-referenced PNGs (`GobanView.png`, `Xcode_Signing.png`,
    `CloneDialog.png`, `CommandView.png`, `ConfigView.png`) → `docs/screenshots/` and
    **update the links in `README.md`**.
  - Remove the unreferenced `GobanViewNote.png` (2.8 MB) via the `trash` CLI.
  - Remove empty/stale dirs via `trash`: `KataGo Helper/`, `KataGo Intents/`, `SgfHelper/`,
    `KataGo IntentsUI/`, and `KataGoApp/` — but only **after** confirming each is not
    referenced in `project.pbxproj`.
  - Add `__MACOSX/` and `.build/` to `.gitignore`.
  - Do **not** touch `Libraries/` or `KataGoSwift/KataGoSwift.h`.

- **A4 · iOS per-feature folders (rank 7).**
  - Replace the flat 27-file iOS target root with logical groups. Proposed taxonomy:
    - `App/` — `KataGo_iOSApp`, `ContentView`, `ModelRunnerView`, `LoadingView`
    - `Game/` — `GameSplitView`, `GobanView`, `PlayView`
    - `GameList/` — `GameListView`, `GameLinkView`, `GameListToolbar`, `PlusMenuView`,
      `NameEditorView`
    - `Config/` — `ConfigView`, `BackendConfigSheet`
    - `Models/` — `ModelPickerView`, `CoreMLCacheFooterView`
    - `Toolbars/` — `StatusToolbarItems`, `TopToolbarView`
    - `Misc/` — `InfoView`, `CommandView`, `AcknowledgmentsView`, `QuitButton`,
      `MLXTuneExperimentView`
    - `AppIntents/` — unchanged (already grouped)
  - File moves on disk + `project.pbxproj` group updates only; no code changes.
  - Done **last** in Milestone A so it captures A1's resolved file location.

**Milestone A checkpoint:** full test plan (incl. UI tests) + build all three platforms.

### Milestone B — The config linchpin (rank 4)

Medium risk. Isolated milestone because it is the highest behavioral-risk item.

- New `KataGoUICore/Sources/KataGoUICore/Session/GtpCommandBuilder.swift`: a **pure**
  `Config → [GTP command]` mapping holding the ~19 command generators currently defined on
  `ConfigModel` (e.g. `getKataAnalyzeCommand`, `getKataKomiCommand`, …). `ConfigModel`
  keeps all stored properties (schema frozen); only the command-generation methods move out.
- The macOS `ConfigEngineSync` (today in `KataGo Anytime Mac/ConfigEditingSupport.swift`,
  590 LOC) becomes a thin **shared** orchestrator in `KataGoUICore` layered over
  `GtpCommandBuilder`. Platform-specific row/form builders (SwiftUI sections on iOS, the
  AppKit `ConfigFormBuilder` on Mac) stay local.
- All three call sites converge on the shared sync: iOS `ConfigView` `onChange` handlers,
  macOS `InspectorInfoViewController`, and macOS `ConfigEditorViewController`. This removes
  the iOS↔macOS "parity by hand-quoted line numbers."
- **Behavior must match exactly:** identical command strings, identical emit timing
  (including when continuous analysis re-arms after an edit). Validate by diffing emitted
  command sequences before/after and by manual app runs.
- Files: new `GtpCommandBuilder.swift`; new/relocated shared `ConfigEngineSync`;
  `Model/ConfigModel.swift` (remove command methods); `KataGo iOS/.../ConfigView.swift`;
  `KataGo Anytime Mac/ConfigEditingSupport.swift`, `InspectorInfoViewController.swift`,
  `ConfigEditorViewController.swift`.

**Milestone B checkpoint:** full test plan (incl. UI tests) + build all three platforms +
**manual iOS and macOS app runs** confirming config edits behave identically.

### Milestone C — Layer & ownership cleanup (ranks 5, 6)

Medium risk, internal to `KataGoUICore`.

- **C1 · `SgfOperations` (rank 5).** New `KataGoUICore/Sources/KataGoUICore/Session/
  SgfOperations.swift` wrapping the SGF parsing the Model layer currently does via the
  Bridge `SgfHelper` (10 call sites across `GobanState` and `GameRecord`). Model calls
  `SgfOperations` instead of `SgfHelper`, restoring `Bridge → Session → Model` direction
  and removing the Bridge import from the Model layer.
  - Files: `Model/GobanState.swift`, `Model/GameRecord.swift`, new `Session/SgfOperations.swift`.
- **C2 · Single engine owner (rank 6).** `GameSession` becomes the sole `KataGoEngineIO`
  owner. `MessageList.appendAndSend` routes through a session-provided engine reference
  instead of holding its own default `InProcessKataGoEngine`, removing the dual-ownership
  desync risk (today both `GameSession.engine` and `MessageList.engine` default
  independently and are reconciled only by `GameSession.useEngine`).
  - Files: `Session/GameSession.swift`, `Model/KataGoModel.swift` (MessageList), and the
    macOS injection site in `MainWindowController` / iOS `ContentView` wiring.

**Milestone C checkpoint:** full test plan (incl. UI tests) + build all three platforms.

## 5. Verification strategy

- **Per step (every rank):** build iOS Simulator (`KataGo Anytime`), visionOS Simulator
  (`KataGo Anytime`), and macOS (`KataGo Anytime Mac`) — Debug.
- **Per milestone (A, B, C):** run the **full test plan** (`-testPlan FullTestPlan`,
  including the sim-pinned UI tests) on iOS Simulator.
- **Milestone B additionally:** manual iOS + macOS runs verifying config-edit behavior is
  unchanged (command emission and analysis re-arm).

Build commands per `CLAUDE.md`:
```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime"     -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime"     -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug
```

## 6. Delivery strategy

- All work on branch `refactor/organization-core` (off `ios-dev`).
- **One commit per rank** (7 commits) plus this design-doc commit.
- **No pushes** during the effort (respecting the Xcode Cloud rate limit). The user pushes
  when ready.
- `project.pbxproj` edits use the `xcodeproj` Ruby gem (the established project pattern),
  followed immediately by a three-platform build.
- File deletions use the `trash` CLI (project convention).

## 7. Risks & mitigations

| # | Risk | Mitigation |
|---|------|-----------|
| 1 | Rank 4 behavior drift (command order/timing) | Isolated milestone; diff emitted command sequences before/after; manual iOS + macOS runs at the checkpoint. |
| 2 | `project.pbxproj` churn from A1/A4 file moves corrupts the project | Use the `xcodeproj` gem; build all three platforms immediately after each pbxproj change; commit per rank for easy revert. |
| 3 | Rank 1 wrong assumption about Mac usage of the loader | Resolve with an explicit usage check (A1) before deleting or sharing anything. |
| 4 | Removing `KataGoApp/` breaks the project | Confirm no `project.pbxproj` reference before removal. |
| 5 | Moving methods off a frozen `@Model` accidentally touches stored schema | Only command-generation methods/computed vars move; stored `@Attribute`/`@Relationship` left untouched; verified by building + running on a synced container. |

## 8. Open items to resolve during implementation

- **A1:** Is the macOS app-target `CoreMLComputeHandleLoader` actually invoked, or vestigial
  given the subprocess engine? (Decides delete vs. dual-membership.)
- **A3:** Is `KataGoApp/` referenced anywhere in `project.pbxproj`? (Decides safe removal.)
- **B:** Exact list of the ~19 `ConfigModel` command generators and their current emit
  call-sites/timing, to guarantee an exact behavioral match.

## 9. Out of scope (deferred)

- Rank 8: de-mega-ing `ConfigView` / `GameSplitView` into coordinators/subviews.
- Rank 9: extracting `EngineLifecycleManager` + `ObserverCoordinator` from
  `MainWindowController`.
- Rank 10: splitting `GobanState` into focused collaborators.
- Rank 11: checking in a stabilized `pbxproj` and adding a header-path build assertion.
- Any change to the C++ engine (`cpp/`).

## 10. Success criteria

- The byte-identical `CoreMLComputeHandleLoader` duplication is eliminated.
- `GlobalSettings` keys and config→GTP sync each have exactly one definition shared across
  platforms.
- `ConfigModel` no longer generates GTP commands; the Model layer no longer imports the
  Bridge `SgfHelper`.
- `GameSession` is the single engine owner.
- The iOS target is organized into per-feature folders; the repo is free of the stale dirs
  and the unreferenced PNG.
- All three platforms build and the full test plan passes at each milestone; no behavioral
  regressions observed in the manual runs.
