# Global Settings Always Available in the Dots Menu

**Date:** 2026-07-06
**Status:** Approved
**Platforms:** iOS + visionOS (the `KataGo Anytime` scheme / `KataGo iOS` app target). macOS, tvOS, and watchOS are untouched.

## Problem

Global Settings (`GlobalSettingsView`) is only reachable through the
Configurations sheet (`ConfigView` → "Global Settings" navigation link), and
the "Configurations" item in the dots (ellipsis) menu is gated on
`gameRecord != nil`. With no game selected — the game list on iPhone, or the
"Select a game" placeholder on iPad/visionOS — there is **no path to Global
Settings at all**.

## Goal

A "Global Settings" entry appears in the dots menu **unconditionally** —
whether or not a game is selected — and opens `GlobalSettingsView` directly.

## Decision (user-approved)

**Direct item, keep both.** Add an always-visible "Global Settings" menu item
that opens `GlobalSettingsView` in its own sheet. The Configurations sheet
keeps its internal "Global Settings" link. Rationale: zero disruption to the
existing Configurations flow, best discoverability. (Rejected alternatives:
de-duplicating by removing the link inside Configurations; making
Configurations itself always visible with game-only rows hidden.)

## Design

### Single change site

All dots-menu instances render the same `PlusMenuView`
(`ios/KataGo iOS/KataGo iOS/GameList/PlusMenuView.swift`):

- Game-list toolbar (`GameListToolbar`, `gameRecord` = selected game, may be nil)
- Goban toolbar (`TopToolbarView`, `gameRecord` non-nil)
- Fallback screens in `GobanView` ("Select a game", "board too large";
  `gameRecord: nil`)

One edit in `PlusMenuView` covers every surface.

### Menu structure

Restructure the bottom of the menu so the settings section is anchored by an
unconditional item:

```
New Game
Clone            (game selected only)
Import
Share            (game selected only)
Delete           (game selected only)
─────────────
Select           (game-list only)
─────────────
Global Settings  ← NEW, always visible
Configurations   (game selected only)
Developer Mode   (game selected only)
Deep Report      (game selected only)
```

- After the "Select" item: a `Divider` wrapped in `#if !os(visionOS)`
  (matching existing style), then the new always-visible
  `Button { showingGlobalSettings = true } label: { Label("Global Settings",
  systemImage: "gearshape.2") }`.
- Icon is `gearshape.2` (two gears) to distinguish it from Configurations'
  single `gearshape`.
- The existing `if gameRecord != nil` settings block (Configurations /
  Developer Mode / Deep Report) stays directly below; its now-redundant inner
  `Divider` is absorbed by the new unconditional one.

### Presentation

- New `@State private var showingGlobalSettings = false` in `PlusMenuView`.
- New `.sheet(isPresented: $showingGlobalSettings)` presenting
  `NavigationStack { GlobalSettingsView() }` — same pattern as the
  Configurations sheet: swipe-to-dismiss, no Done button.
- No `#if os(macOS)` frame modifiers (this target builds only iOS/visionOS;
  the existing macOS conditionals in this file are vestigial and are not
  extended).

### Why it is safe with no game selected

`GlobalSettingsView` touches only `GobanState` display preferences and
`ThumbnailModel` — both injected at app level and already required by
`PlusMenuView`. `GlobalPreferenceSync` (attached at `GameSplitView` level)
persists `GobanState` changes to `@AppStorage` regardless of selection. No
engine interaction, no `GameRecord` dependency, no SwiftData writes.

### Unchanged behavior

- Configurations sheet keeps its internal "Global Settings" link.
- Multi-select mode still hides the whole menu (only "Done" shows).
- macOS / tvOS / watchOS targets are not modified.

## Error handling

None required — pure UI navigation over already-available in-memory state.

## Verification

1. Build iOS Simulator and visionOS Simulator (`KataGo Anytime` scheme).
2. New UI test: with no game selected, open the dots menu, assert
   "Global Settings" exists, tap it, assert the Global Settings sheet appears
   (e.g. navigation title "Global Settings").
3. Existing UI tests pass (`KataGo AnytimeUITests`, `-testPlan FullTestPlan`).
