# Design: "Saved Game" Widget for KataGo Anytime

**Date:** 2026-06-22
**Status:** Approved (design); pending implementation plan
**Branch:** ios-dev

## 1. Overview

A **configurable** WidgetKit widget for iOS, macOS, and visionOS that displays a single
saved Go game from the KataGo Anytime library:

- the game's **name**,
- its **first position's comment** (`GameRecord.comments[0]`), and
- a **board thumbnail**.

The user chooses which game the widget shows via *Edit Widget* (an `AppIntentConfiguration`
backed by an `AppEntity`). If the user has not chosen a game, the widget falls back to the
**most recently modified** game. Tapping the widget deep-links into the app and opens that
exact game.

### Decisions locked during brainstorming

| Decision | Choice |
|---|---|
| Game selection | Configurable (`AppIntentConfiguration`), default to most-recent game when unconfigured |
| Platforms | iOS, macOS, visionOS (one shared widget extension) |
| Widget families | `systemSmall`, `systemMedium`, `systemLarge` |
| Thumbnail source | Prefer stored `GameRecord.thumbnail`; if absent, render the **last** position from stored stones; final fallback = empty board |
| Tap action | Deep-link to open that specific game |
| Data sharing | **Backyard Birds method** — App Group + shared SwiftData store (accepting model-extraction + store-migration work) |

## 2. Architecture — the module split

The widget extension must read the SwiftData store **without** linking the C++ engine
bridge or MLX (a widget has a ~30 MB memory budget). `GameRecord` currently lives in the
`KataGoUICore` target, whose target transitively links `CKataGoBridge` (and `GameRecord`'s
own SGF/import methods call the bridge via `SgfOperations`). Therefore we extract a
**light, bridge-free target** inside the existing `KataGoUICore` SwiftPM package, mirroring
the existing dependency-light `CoreMLCacheKit` product.

```
KataGoUICore package
├── KataGoGameStore  (NEW, light, bridge-free)   ← the widget links ONLY this product
│     • GameRecord + Config @Model               (moved here; stored properties identical)
│     • SharedModelContainer factory             (App Group + CloudKit + one-time migration)
│     • GameEntity + GameEntityQuery             (moved from the app target)
│     • SelectGameIntent : WidgetConfigurationIntent   (new)
│     • WidgetBoardView                          (tiny pure-SwiftUI board renderer; no Metal/engine)
├── KataGoUICore (existing, heavy)
│     → now depends on KataGoGameStore
│     → keeps GameRecord's SGF/import methods as cross-module extensions (still use the bridge)
└── CoreMLCacheKit (existing light)
```

- **App targets** (`KataGo Anytime` iOS/visionOS, `KataGo Anytime Mac`) link `KataGoUICore`
  and transitively get the models. The **widget extension** links `KataGoGameStore` +
  `WidgetKit` only (no `KataGoUICore`, no bridge, no MLX).
- SwiftPM links per target/product. Because `KataGoGameStore` has **no** dependency on
  `CKataGoBridge`, linking it into the widget does not pull in the bridge.

### Schema-identity safeguard (critical)

Moving the `@Model` classes between Swift modules must not change the SwiftData /
CloudKit schema. SwiftData entity identity and the CloudKit record type (`CD_GameRecord`)
derive from the **class name and attributes**, not the Swift module name. To stay safe:

- Keep the class names `GameRecord` and `Config` **unchanged**.
- Keep **all stored properties byte-identical** (names, types, optionality, defaults,
  relationship + delete rule).
- Only methods/computed properties move or are split into extensions.
- **Verify on-device** against the existing ~584-game CloudKit Production store before merge
  (the project has a hard rule: never break the SwiftData schema — CloudKit corruption).

## 3. Data sharing & store migration

- Add an **App Group** `group.chinchangyang.KataGo-iOS.tw` to the entitlements of the iOS
  app, the macOS app, and the widget extension. (macOS sandbox uses the
  `$(TeamIdentifierPrefix)`-prefixed group form.)
- Introduce a single **`SharedModelContainer`** factory in `KataGoGameStore` and route
  **every** container construction site through it, replacing the bare
  `ModelContainer(for: GameRecord.self)` calls:
  - `KataGo iOS/App/KataGo_iOSApp.swift:84,89`
  - `KataGo Anytime Mac/AppDelegate.swift:33`
  - `KataGo iOS/AppIntents/GetGameInfo.swift:41`
  - `KataGo iOS/AppIntents/GameEntity.swift:28,40,98`
- Configuration:
  `ModelConfiguration(schema:, groupContainer: .identifier("group.chinchangyang.KataGo-iOS.tw"), cloudKitDatabase: .private("iCloud.chinchangyang.KataGo-iOS.tw"))`.
- **One-time migration:** verified behavior — adding `groupContainer` creates a *new empty
  store* at the App-Group path; SwiftData does **not** auto-migrate the old default-location
  store. On first launch of the new build, if the App-Group store is absent but the old
  default-location store exists, copy it with
  `NSPersistentStoreCoordinator.replacePersistentStore(at:destinationOptions:withPersistentStoreFrom:sourceOptions:type:)`
  before opening the SwiftData container. CloudKit re-population is the safety net.
- **No `SchemaMigrationPlan`** is introduced (a migration plan combined with CloudKit is a
  documented source of errors). The current app uses none, so this is preserved.

## 4. The configurable widget

Reuses the existing AppIntents shape (`GameEntity` / `GameEntityQuery`), moved into
`KataGoGameStore` so both the app and the widget compile against them.

- **`SelectGameIntent: WidgetConfigurationIntent`** with one parameter
  `@Parameter var game: GameEntity?`.
- **`GameEntityQuery`** powers the picker via `suggestedEntities()` and
  `entities(matching:)`, fetching from the shared store
  (`GameRecord.fetchGameRecords`, sorted by `lastModificationDate` descending).
- **`GameEntity`** is extended to carry exactly the fields the widget renders:
  `id` (UUID), `name`, `firstComment` (`comments[0]`), `thumbnail: Data?`,
  board `width`/`height`, and the last-position stone dictionaries needed by the
  fallback renderer. (The existing `comments: [String]` stays for the Shortcuts intents.)
- **`AppIntentTimelineProvider`** resolves the chosen `GameEntity`; if `nil`, it falls back
  to `fetchGameRecords(fetchLimit: 1)` (most recent). It emits **one** entry with reload
  policy `.never`. The app drives refresh by calling
  `WidgetCenter.shared.reloadAllTimelines()` whenever a game is created, renamed,
  re-thumbnailed, or deleted.

## 5. Layouts (Small / Medium / Large)

One SwiftUI view that switches on `@Environment(\.widgetFamily)`:

- **systemSmall** — board thumbnail with the game name beneath (no comment; no room).
- **systemMedium** — thumbnail on the leading side; name + first-position comment stacked
  on the trailing side (comment `lineLimit ≈ 3`, truncating tail).
- **systemLarge** — name on top, a large thumbnail, then the first-position comment with
  more room (`lineLimit ≈ 6`).

Uses the app's existing visual style/tint and `.containerBackground` for the widget
background.

## 6. Thumbnail strategy

1. **Primary:** decode `GameRecord.thumbnail` (`Data` → `Image`). Populated lazily by the
   app's existing `createThumbnail(for:)` (`GameSplitView.swift:91`, fired when navigating
   away from a game).
2. **Fallback (per decision):** if `thumbnail` is `nil`, render the **last** position from
   the stored `blackStones[maxIndex]` / `whiteStones[maxIndex]` dictionaries via
   `WidgetBoardView` — a small pure-SwiftUI renderer (grid lines + filled circles, fast
   style only; **no Metal shaders, no engine, no GobanState environment**).
3. **Final fallback:** no stones (e.g., a brand-new empty game) → the same renderer draws a
   clean empty board of the correct size.

`WidgetBoardView` lives in `KataGoGameStore` so the widget can render without `KataGoUICore`.

## 7. Tap → open that game

- The widget view sets
  `.widgetURL(URL(string: "katago-anytime://open-game?id=\(uuid)"))`.
- Register the `katago-anytime` URL scheme via `CFBundleURLTypes` in both apps'
  Info.plist (none is registered today).
- **iOS / visionOS:** extend the existing `GameSplitView.onOpenURL` handler (`:98`,
  currently `importAndSelect(from:)`) to branch: our scheme → select the `GameRecord`
  whose `uuid` matches; otherwise the existing SGF-file import path.
- **macOS (AppKit):** handle the URL in the app delegate / `MainWindowController`, then
  select the matching game (the macOS app owns the `GameSession` and window).

## 8. Error / empty states

- **No games at all**, or the **configured game was deleted** → placeholder view
  ("Open KataGo Anytime to choose a game").
- **Missing comment** → render name + thumbnail only.
- **Missing thumbnail** → fallback renderer (§6).

## 9. Testing

- **Unit tests** (existing iOS test target):
  - `SharedModelContainer`: builds an App-Group-scoped configuration; the one-time
    `replacePersistentStore` copy preserves records.
  - `GameEntityQuery`: fetch + `lastModificationDate`-descending sort; `entities(matching:)`.
  - Timeline selection: configured entity vs. most-recent fallback.
  - `WidgetBoardView`: `ImageRenderer` snapshot for an empty board and a few stones.
- **Manual QA** (widget UI is not covered by the CI test plans — FastTestPlan is unit-only,
  and UI tests never run in CI): add the widget on each platform; pick a game; verify
  name / comment / thumbnail at each size; tap-to-open; rename a game in-app → widget
  refreshes; delete the configured game → placeholder. Tracked as a manual checklist item
  alongside the existing Mac QA list.

## 10. Risks (explicitly accepted)

| Risk | Mitigation |
|---|---|
| Moving `@Model` classes between modules changes schema identity | Class names + stored properties kept identical; on-device verification against the live CloudKit store before merge |
| Relocating the store to the App Group loses local data | One-time `replacePersistentStore` copy on first launch + CloudKit backfill |
| Widget exceeds memory budget by linking heavy code | Bridge-free `KataGoGameStore` target; pure-SwiftUI fallback renderer (no Metal/engine) |
| CloudKit + App Group migration edge cases | No `SchemaMigrationPlan`; explicit private-database CloudKit config; verify sync after migration |

## 11. Out of scope (YAGNI)

- Lock Screen / StandBy accessory families (can be added later).
- Multiple distinct widget kinds (only one "Saved Game" widget).
- Interactive widget buttons (App Intents in-widget actions beyond tap-to-open).
- Live analysis / win-rate in the widget (static saved-game info only).
