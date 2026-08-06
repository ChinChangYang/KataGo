# Default stone style → Classic

**Date:** 2026-08-06
**Status:** Approved, ready for implementation

## Feedback

> Default stone style should be classic, not fast.

## Background

`Config.stoneStyles` is `["Fast", "Classic"]` and `Config.defaultStoneStyle` is
`0`, so a fresh install draws the board with the Fast stones: flat discs with a
single drop shadow. The Classic stones — the glossy, lit stones drawn by the
`ShaderLibrary.stone` Metal shader — are one picker tap away in Global
Settings, but nobody sees them unless they go looking.

Fast became the default in `829a9dbd` ("Improve performance of stone drawing",
2024-07-11) for exactly one reason: the classic stones were expensive. That
commit's rendering built roughly three SwiftUI views per stone — a shader
circle plus two shadow circles, one of them blurred — each composited as its
own layer, so a dense 19×19 cost hundreds of offscreen shader and blur passes
per redraw.

That rationale is obsolete. The stone layer was since rewritten as a single
`Canvas` that stamps a handful of pre-rasterized symbols, which collapsed the
whole board to two or three sprite draws regardless of stone count.
`StoneRenderPerfTests` records the result: a dense 19×19 went from ~76 ms to
~0.9 ms per frame in Classic, against a hard 20 ms test bound. Classic is no
longer a performance choice, so the default should be the better-looking one.

## Approaches considered

**Reorder `stoneStyles` so Classic is index 0.** Rejected. The index — not the
name — is what gets persisted, in both the `GlobalSettings.stoneStyle`
UserDefaults key and the SwiftData `Config.stoneStyle` column. Reordering the
array silently reinterprets every value already stored on every device and in
CloudKit, turning each user's saved Fast into Classic and vice versa.

**Flip the default but pin tvOS to Fast.** Rejected. It buys nothing — the
Apple TV renders the same two sprites as everything else — and it introduces a
platform branch where there is currently a single constant.

**Flip `Config.defaultStoneStyle` to 1.** Chosen. Every consumer already reads
that one constant, so the change is confined to it.

## The change

`ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/ConfigModel.swift:321`

```swift
public static let defaultStoneStyle = 1   // was 0
```

with a comment recording why the original perf-driven default no longer
applies, so a future reader does not "restore" it.

Nothing else in production changes. These all derive from the constant and
follow automatically:

| Site | Effect |
| --- | --- |
| `Config.defaultStoneStyleText` | → `"Classic"` |
| `GobanState.stoneStyle` (compiled default) | → Classic; this is the value tvOS and the Deep Analysis Report actually use |
| `GlobalPreferenceSync` `@AppStorage` default (iOS) | absent key → Classic |
| `MacGlobalPreferenceSync.seedFromDefaults()` | absent key → Classic |
| `SettingsViewController` picker fallback (macOS) | → Classic |
| `ConfigView` picker `@State` seed | → `"Classic"` |
| `GameGifExportView.init` seed | → Classic |
| `Config()` — new SwiftData records | `stoneStyle = 1` |

The picker keeps listing Fast first. Its order is index-bound and must not
move; which entry is *selected by default* is independent of which is listed
first.

## Platform reach

Every target that draws the classic stone shader compiles `Shaders.metal` —
verified against `project.pbxproj`: `KataGo Anytime`, `KataGo Anytime Mac`,
`KataGo Anytime TV`, `KataGo Anytime Vision`, and `KataGoAnytimeMessages` (the
last through its own `classicGoban` widget-board variant, not `StoneView`). So
the shader resolves everywhere the new default can reach.

iOS and macOS expose a Stone style picker, so the change is a default only.
tvOS has no picker and never syncs `GlobalSettingsKeys`, so it takes the
compiled default directly: its board and its Deep Report slides move to
Classic. That is the intended outcome — consistency across platforms.

visionOS draws its board as RealityKit geometry, not `StoneView`, so the
setting does not reach it.

The watch, the widgets, and the Messages extension resolve their stones
through `WidgetBoardStyle` variants, which are chosen per surface and are not
driven by `Config.defaultStoneStyle`. They are unaffected.

## Migration

None, and none is needed.

`GlobalSettings.stoneStyle` is only ever written when the value actually
changes — on iOS through `GlobalPreferenceSync`'s
`.onChange(of: gobanState.stoneStyle)`, on macOS through
`MacGlobalPreferenceSync`'s observation write-back. Neither fires when the
seeding assignment writes the same value it read. So:

- A user who never opened the picker has no stored key, and picks up Classic.
- A user who deliberately chose Fast has a stored `0`, and keeps Fast.

That is the correct split: the change moves the default without overriding a
stated preference.

One path could have broken this — a per-game `Config.stoneStyle` of `0`
flowing into the global key on game load would pin every existing user to
Fast. It does not exist: `gobanState.stoneStyle` is assigned in exactly three
places (`GlobalPreferenceSync`, `MacGlobalPreferenceSync.seedFromDefaults`,
and `ConfigView`'s picker `onChange`), none of which reads a per-game
`Config`. The SwiftData `Config.stoneStyle` field is orphaned for rendering
purposes.

## SwiftData and CloudKit safety

Only a default-value literal moves; the `@Model` declaration is untouched.
Default values are not part of a Core Data entity version hash — that covers
attribute name, type, optionality, and transience — so there is no schema
change, no store incompatibility, and no CloudKit migration. This respects the
project's frozen-schema rule.

Existing `Config` rows keep whatever `stoneStyle` they were saved with. Since
that field does not drive rendering, their value is inert either way.

## Tests

Three assertions currently pin the default to Fast and must flip, in
`ios/KataGo iOS/KataGo iOSTests/ConfigModelTests.swift`:

- `testStoneStyleComputedProperties` — a fresh `Config()` must now report
  `isClassicStoneStyle == true`. Its "Default is 'Fast' (index 0)" comment
  goes with it.
- `stoneStyle` — same fresh-`Config()` expectation.
- Any comment text naming Fast as the default.

These stay green untouched because they are index-relative, not
default-relative: `testAllStoneStyles`, `testInvalidStoneStyleIndex`, and the
`config.stoneStyle == Config.defaultStoneStyle` check.

Add one explicit regression guard so a silent flip back fails a test rather
than shipping:

```swift
#expect(Config.defaultStoneStyleText == Config.classicStoneStyle)
```

`StoneRenderPerfTests.testClassicDenseBoardRenderTime` needs no change, but it
gains significance: its 20 ms bound now guards the *default* rendering path
rather than an opt-in one.

`CoreMLCacheFooterUITests` only asserts that the "Stone style" picker title
exists, never its value, so it is unaffected.

## Documentation

`ios/KataGo iOS/README.md:141` lists "Stone style (Fast / Classic)" without
naming a default, so it needs no edit. Naming the default there is optional
polish, not part of this change.

## Verification

- Build all five schemes — `KataGo Anytime`, `KataGo Anytime Mac`,
  `KataGo Anytime TV`, `KataGo Anytime Vision`, `KataGo Anytime Watch` — one
  at a time. Concurrent builds contend on the shared DerivedData lock and
  produce spurious failures.
- Judge each build by grepping for `BUILD SUCCEEDED` / `BUILD FAILED`, not by
  the exit code: a piped `xcodebuild` reports the exit status of the pipe.
- Run the iOS test suite (`KataGo AnytimeTests`) on the iOS Simulator, and
  `swift test` for the `KataGoUICore` package — SwiftPM package tests never
  run under `xcodebuild`.
- Confirm visually on the iOS Simulator that a fresh install boots with glossy
  Classic stones, and that switching the picker to Fast and back still works.
