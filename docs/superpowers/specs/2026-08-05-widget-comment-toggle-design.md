# Saved Game widget — user-toggleable comment

Feature branch: `ios-dev`. Written 2026-08-05.

## Why

Tester feedback on the KataGo Anytime Widget:

> Add an option to let the user toggle comments. When the comments are off, the board should scale to fit the widget.

The widget used to decide on its own — `SavedGameWidgetLayout.plan(...)` set `showsComment = hasComment`, so a comment appeared on medium/large/extra-large whenever the displayed move had one and the user had no say. On the large family that comment block (`.callout`, up to 6 lines) cost about a third of the widget's height.

## What shipped

A third row in the Edit Widget sheet, beside the existing **Game** and **Background** pickers:

| Decision | Choice |
|---|---|
| Control | `@Parameter(title: "Show Comment", default: true) var showsComment: Bool` on `SelectGameIntent` — renders as a native switch |
| Default | **On** — today's behavior; already-placed widgets are unchanged |
| What hides | The comment **and** the extra-large "Move N" line. The game name stays on every family |
| Wide families | Board claims the full widget height; the name centres beside it |

The value flows `SelectGameIntent` → `SavedGameProvider` → `SavedGameEntry.showsComment` → `SavedGameWidgetLayout.plan(commentIsEnabled:)` → the view. The view never sees the intent, mirroring how `background` already works.

### `boardFillsHeight` keys on the SETTING, not on `showsComment`

`SavedGameWidgetLayout.Plan` gains `boardFillsHeight`, true only for medium/extraLarge and only when the switch is off. Deriving it from `!showsComment` instead would have silently relayed out **every comment-less move** for users who never touched the switch — a behavior change nobody asked for. Pinned by `commentSwitchOn_neverExpands_evenWhenTheMoveHasNoComment`.

### Why `Bool` is safe here

`SelectGameIntent`'s two other parameters were deliberately downgraded to plain `String?` because a `GameEntity?` and later an `AppEnum` parameter both resolved to **nil** in this appex (linkd rejects the widget bundle). A `Bool` is not in that class: per the SDK interface, `Swift.Bool` conforms to `AppIntents._IntentValue` **directly**, exactly as `Swift.String` does, while `AppEnum`/`AppEntity` reach it through `AppValue: PersistentlyIdentifiable` — and it is that type-identity lookup through the AppIntents registry that fails. Verified on the Simulator, not just reasoned about (below).

## Verification (2026-08-05, iPhone 17 Simulator, iOS 26.5)

- **1453 tests / 168 suites pass**, including 9 in `SavedGameWidgetLayoutTests` (5 new).
- All five schemes build: iOS, macOS, visionOS, tvOS, watchOS.
- **The parameter round-trips.** With a temporary `NSLog` in `SavedGameProvider.entry(for:)`, toggling the switch off produced `showsComment=false` **inside the widget process**, and `com.apple.appintents` logged `Prepared showsComment to Bool(<value>)` — a real value whose hash changed across the toggle, never `Bool(nil)`. The probe was removed afterwards.
- **Pre-existing configurations survive.** A widget placed before this change kept its Game and Background, and the new switch appeared defaulted ON. Adding a parameter does not reset a stored configuration; only changing a parameter's type or name does.

### Measured board size, 19×19, comment on → off

| family | device | comment ON | comment OFF | change |
|---|---|---|---|---|
| large | iPhone 17 | 220.3 pt | **302.3 pt** | **+37% side, +88% area** |
| medium | iPhone 17 | 127.7 pt | 127.7 pt | **unchanged** |
| extraLarge | iPad mini | 234.0 pt | 234.0 pt | **unchanged** |

**The wide families cannot grow, and this is not a bug.** Medium and extra-large are ~2:1, so a square board is bound by the widget's *content height*, and both were already at that ceiling — measured identical to the tenth of a point in both states, on two different devices. Hiding the comment frees horizontal space, not board size. What visibly changes there is that the comment (and, on extra-large, the "Move N" line) disappears and the name centres beside the board. `layoutPriority(1)` on the board still earns its place: it makes "full height" a guarantee rather than an artifact of how the HStack happened to split the row.

The only lever that would make medium's board physically larger is `.contentMarginsDisabled()` on the widget configuration, re-applying `\.widgetContentMargins` by hand everywhere except around the board — worth ~127.7 → 158 pt on this phone. Deliberately **not** taken here: it changes the comment-ON path too, and a full-bleed board under the Wood backplate would put coordinate labels on the widget's rounded corner.

### Per-platform pass

| surface | status |
|---|---|
| iPhone 17 — small / medium / large, comment on and off | **PASSED**, measured |
| iPad mini — extra-large, comment on and off | **PASSED**; comment and "Move 6" both drop, name centres beside the board |
| Tinted (accented) rendering, extra-large, both branches | **PASSED** — the name stays in the bright accent group, so `.widgetAccentable()` survived into `boardBesideName`; board keeps its two-tone accent treatment |
| visionOS — widget places on glass, Edit sheet shows **Show Comment** | **PASSED** |
| visionOS — comment-off layout on medium/large | **NOT RUN**: the simulator's family carousel does not advance under synthetic input. Same SwiftUI path as iOS/iPadOS |
| visionOS — simplified (distance) LOD | **NOT RUN** on device; guarded by a hard-coded `boardFillsHeight: false` early return and `distanceThreshold_isUnaffectedByTheCommentSwitch` |
| macOS — Notification Center | **NOT RUN**: a Debug build shares its bundle id with the copy in `/Applications`, which has previously wedged, and the Mac app opens the live iCloud library. Same appex binary as the three verified platforms |

### Coordinate labels

No family changes state. A 19×19 needs a board square of ≥158.5 pt (`requiredCell` 7.34 pt ÷ 0.88 × 19); medium stays at 127.7 pt in both states, and large was already over the line at 220.3 pt. Confirmed on screen: the medium board draws no labels either way, the large board draws a full intact `A`–`T` / `1`–`19` in both.

## Files

| File | Change |
|---|---|
| `KataGoAnytimeWidget/SelectGameIntent.swift` | the `showsComment` `@Parameter` |
| `KataGoAnytimeWidget/SavedGameProvider.swift` | `SavedGameEntry.showsComment` + both configuration-bearing sites |
| `KataGoAnytimeWidget/SavedGameWidgetView.swift` | `boardBesideName(...)`; medium/extraLarge branch on `boardFillsHeight` |
| `KataGoAnytimeWidget/SavedGameWidget.swift` | `.description` copy + a comment-off `#Preview` |
| `KataGoUICore/Sources/KataGoGameStore/SavedGameWidgetLayout.swift` | `commentIsEnabled` input, `boardFillsHeight` field |
| `KataGo iOSTests/SavedGameWidgetLayoutTests.swift` | 9 call sites updated, 5 tests added |

No pbxproj, Info.plist, entitlements, or localization changes.

## Known consequence

`SavedGameSnapshot.placeholder` carries *"Open KataGo Anytime to choose a game."* in its `comment` field, so an **unconfigured** widget with the switch off shows only the name *"No game selected"*. Accepted — the name still states the condition, and the default is ON.
