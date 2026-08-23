---
name: verify
description: Build/launch/drive recipe for verifying KataGo Anytime changes end-to-end on the iOS Simulator and macOS.
---

# Verifying KataGo Anytime changes at runtime

## iOS Simulator (primary surface)

1. The unit-test build already produces the app: `ios/KataGo iOS/DerivedData/KataGo Anytime/Build/Products/Debug-iphonesimulator/KataGo Anytime.app` (bundle id `chinchangyang.KataGo-iOS.tw`). Note the space: `DerivedData/KataGo Anytime/...`, NOT `DerivedData/Build/...`.
2. Install + launch on the booted iPhone simulator:
   ```bash
   xcrun simctl install <UDID> ".../Debug-iphonesimulator/KataGo Anytime.app"
   xcrun simctl launch <UDID> chinchangyang.KataGo-iOS.tw --uitest-seed-gif-game
   ```
   `--uitest-seed-gif-game` (DEBUG-only, `UITestSeed.swift`) idempotently seeds a 6-move 19×19 game "UITest GIF Game" and makes it the newest → auto-selected at launch. `--uitest-seed-rect-game` seeds a 13×9 game.
3. Debug builds present the "Select a Model" picker **as a sheet over an already-mounted board** (the board never waits for the engine — ADR 0008): tap the checked "Built-in KataGo Network" row → its detail page → the blue ▶ button. Engine boot + CoreML load ≈ 30–60 s warm; while it runs, a "Loading engine…" line sits over the board and navigation already works. Swipe the sheet away instead and you get a live board with no engine at all and an "EngineStatus.absent" line. To wait for the engine in a script or a UI test, wait for the hidden `Board.sync` element to read `inSync` (`PortraitUITestCase.waitForBoardInSync`) — the old "wait for the Forward to End button" sentinel proves nothing now, because that button exists before the engine does.
4. Drive with computer-use on the Simulator window; `xcrun simctl io <UDID> screenshot out.png` gives pixel-exact captures.
5. Deep Report lives in the top-right ⋯ menu → "This Game ▸" → "Deep Report".

## macOS

- Product: `.../DerivedData/KataGo Anytime/Build/Products/Debug/KataGoAnytimeMac.app` (same bundle id; must be signed — default Debug is).
- Launch with `open`; a zero-window hang at startup is usually the app-group prefs VFS stall (`sample KataGoAnytimeMac` shows `isAppGroupStoreReady` + `_CFPreferences`); it self-clears in ~30–60 s — poll for the window, don't kill.
- Deep Report: Game menu → "Deep Analysis Report…". Careful: the Mac app opens the user's REAL iCloud games — avoid Copy to Comment or any mutating action.
