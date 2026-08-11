# KataGo Anytime

*KataGo Anytime* is a suite of native Apple apps that wraps the [KataGo](https://github.com/ChinChangYang/KataGo/tree/ios-dev) engine, giving you a friendly graphical interface for Go analysis and play across Apple devices. The apps talk to the embedded C++ engine over [GTP](https://github.com/ChinChangYang/KataGo/blob/ios-dev/docs/GTP_Extensions.md) and render an interactive Go board.

It runs on **iPhone and iPad, Apple Vision Pro, Mac, Apple TV, and Apple Watch** (all on OS 26+), with your game library synced between devices via iCloud. Inference is optimized for Apple silicon: the engine runs the neural network on Apple's [Neural Engine](https://machinelearning.apple.com/research/neural-engine-transformers) via CoreML, on the GPU via [MLX](https://github.com/ml-explore/mlx), or on both in parallel.

![Screenshot of the board view](docs/screenshots/GobanView.png)

## The Apps at a Glance

| Platform | Xcode scheme | What you get |
|----------|--------------|--------------|
| iOS / iPadOS 26+ | `KataGo Anytime` | Full play & analysis app (SwiftUI) |
| visionOS 26+ | `KataGo Anytime Vision` | Volumetric RealityKit app — a real-scale 3D goban played with a game controller |
| macOS 26+ | `KataGo Anytime Mac` | Native AppKit app with a three-pane window and menu-bar/hotkey workflow |
| tvOS 26+ | `KataGo Anytime TV` | Review, spectate, and play ranked games against KataGo — for the living room |
| watchOS 26+ | `KataGo Anytime Watch` | Standalone read-only game library, synced over iCloud |

Beyond the apps themselves:

- A **Saved Game widget** (iOS, iPadOS, macOS, visionOS) puts a chosen game's board and comments on your Home Screen or desktop.
- A **Last Game complication** on Apple Watch shows the name and comment at the position your last game is parked on.
- A **Safari extension** (macOS and iOS) blends KataGo analysis into Go games you find on the web — see [KataGo Anytime in Safari](#katago-anytime-in-safari).
- A **Messages extension** plays engine-free, human-vs-human correspondence Go inside a Messages thread — see [KataGo Anytime in Messages](#katago-anytime-in-messages).
- Games are persisted with **SwiftData** and synced everywhere via **CloudKit** (iCloud).

## Engine, Neural Networks, and Opening Books

### Inference Backends

All apps compile a single C++ neural-network backend (MLX) that multiplexes two inference paths: **CoreML/NE** (Apple's Neural Engine) and **MLX/GPU**.

On **iOS and visionOS** you configure the backend **per neural-network model** from the model picker's settings sheet:

- **Backend** — a three-way choice: **MLX/GPU**, **CoreML/NE** (the default, prized for power efficiency), or **GPU+ANE**, a mux that runs the GPU and the Neural Engine in parallel for higher throughput.
- **Max Board Size** — 9 / 13 / 19 / 37 (default 19). Sets the largest playable board and the neural-net buffer geometry.
- **Search threads** — a stepper from 1 to 32 (default 2 on iOS/visionOS), persisted per model.
- **Winograd Performance Tuning** — shown when the backend uses the GPU: an autotuning mode (**Fast** or **Full**) plus a one-shot **Re-tune on next load** toggle.

Platform notes:

- On the **iOS/visionOS Simulator** the backend is always pinned to **CoreML/NE**, regardless of any stored preference, because MLX GPU inference crashes in the simulator's Metal translation layer. Real devices honor your stored preference.
- On **macOS** there is no backend picker: the engine always runs a fixed mux of **1 MLX/GPU + 2 CoreML/ANE** server threads with **16 search threads**, inside a sandboxed `katago-engine` subprocess (one per window) that the app drives over GTP pipes.
- On **Apple TV** the engine runs in-process on **CoreML/NE only**.
- The CoreML model is generated **on the fly** at runtime by converting the `.bin.gz` network, then compiled and cached (up to four compiled variants per network). You never download or bundle a separate `.mlpackage`. The model picker's **Core ML Cache** footer shows what is cached and offers **Clear Cache**.

### Neural Network Models

The model picker offers the built-in 18-block `b18c384nbt` network plus eight downloadable nets:

- **Official KataGo Network** — 40-block `b40c768` (~824 MB), the strongest option.
- **FD3 Network** (~271 MB) and **Strong Large Board Net M2** (~271 MB).
- **Strong Igo Hatsuyoron 120 Net** (~174 MB), specialized for the famous tsumego.
- **Finetuned 9x9 Network** (~98 MB) and **Short Distributed Test Run Rect15 Final Net** (~87 MB).
- **Lionffen b6c64** (~2 MB) and **Lionffen b24c64** (~5 MB), tiny community nets that run very fast.

Each network row has a single status button — a download arrow, a stop icon while downloading, then a play button to launch the engine — plus a gear button for the backend settings above. On Apple TV the list is limited to networks of 100 MB or less. A separate human-style (human SL) network powers the rank and pro profiles described under [Game Settings](#settings), bundled on every platform including Apple TV.

Below those lists, a **Custom Networks** section takes any KataGo network file you already have. **Add Custom Network…** opens a file picker (`.bin.gz`, `.txt.gz`, `.bin`, `.txt`), checks there is room for it, copies it with byte-accurate progress you can cancel, and refuses anything the engine cannot load. Custom networks **stay on this device** — they are never synced — and their rows can be edited or removed with swipe-to-delete. The Mac offers the same list under **Window ▸ Manage Models…**.

### Opening Books

The model picker also links to an **Opening Books** screen with downloadable books for **6x6, 7x7, 8x8, and 9x9** boards (Japanese-like rules). When a game's board size has its book downloaded, the board's eye button gains a **book** state that overlays the book's candidate moves and evaluations.

## Using the App on iPhone and iPad

### Navigating

The app uses a [`NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview):

- A **sidebar** titled **Games** lists your saved games as thumbnails — searchable, with swipe-to-delete, and a **Select** mode for bulk deletion.
- The **detail** view shows the Go board for the selected game.

On a fresh launch (when no model has been chosen yet) the first screen is the **model picker**, followed by a loading screen while the engine initializes, and then the split view. On **iPad** a Full-Screen button hides the info pane and sidebar so the board fills the display.

### Playing and Reviewing

- **Place a move** by tapping an intersection (the engine validates legality first). To **pass**, tap the dedicated pass cell.
- **Tap a player's capsule** (the label showing "AI", a rank, or "Human" beside the captured-stone count) to toggle that side between Human and AI play.
- Below the board, a control strip has eight buttons: **Backward to End**, **Backward** (10 moves), **Backward Frame** (1 move), **Toggle Analysis** (the sparkle button cycles run → pause → clear), **Toggle Visibility** (the eye button cycles the analysis overlay: opened → book, when an opening book applies → closed), **Forward Frame**, **Forward** (10 moves), and **Forward to End**.
- Win-rate bar, ownership shading, candidate moves, and the score chart draw over and under the board according to your settings; the chart supports tap/drag navigation and an auto-play button.

**Branch mode.** When you play a move while reviewing earlier history (and not editing), the app snapshots the current line so your exploratory stones don't overwrite the saved game. While a branch is active the board is drawn with a **red border**, and the toolbar shows a **Deactivate Branch** button. Deactivating presents a two-stage confirmation: choose **Replace** or **Discard Branch**, then a second, destructive confirmation finalizes your choice — either replacing the saved game's line with the branch or discarding the branch entirely.

### The More Menu

The **More** menu (the ellipsis-circle button) in the toolbar contains:

- **New Game**.
- **Import** — from a **File** (SGF or image) or a **Photo** (see [photo import](#import-a-game-from-a-photo)).
- **Select** — enter multi-select mode in the games list.
- **This Game** — a submenu for the selected game: **Game Settings**, **Share** (export SGF), **Export GIF**, **Clone**, **Deep Report**, and **Delete**.
- **Settings** — app-wide preferences; opens **Global Settings** directly, available with or without a selected game.

Tapping **Clone** asks how much of the game to copy:

- **Whole Game** — a full copy.
- **Current Position** — a copy truncated to the move you're currently viewing; later moves are dropped, so the copy starts from that position. Handy for practicing a particular position later.

![Clone dialog](docs/screenshots/CloneDialog.png)

## Feature Highlights

### Import a Game from a Photo

Import a real-world board position from a photo (**More → Import → Photo**), a live **Camera** capture (**More → Import → Camera**, on iPhone and iPad when a back camera is available, with an on-screen guide for framing the board), an image file, or drag-and-drop:

- On-device computer vision recognizes the board and stones and shows a preview with **black/white stone counts** and a **confidence** score.
- **Tap any intersection to correct it** — taps cycle empty → black → white — and a **Reset** button undoes your edits.
- Pick who plays next with the **Next to play** selector, then import; the position becomes a regular saved game.

### Deep Analysis Report

**More → This Game → Deep Report** runs a structured probe of the current position and presents:

- Two candidates — the **best move** and an **alternative you choose** via **Pick an alternative…** — each with winrate, score lead, and visits, a principal-variation board that can toggle to an **ownership-change** view, and a follow-up if the opponent plays elsewhere (tenuki).
- A **Playing vs. Passing** comparison showing what the position is worth, with the **most contested** regions listed.
- A streamed natural-language **summary** of the findings, with **Regenerate**, **Refine** (re-runs the probe with a larger search budget), and **Copy to Comment** actions.

### GIF Export

**More → This Game → Export GIF** renders the game as an animated GIF with a live preview: playback speed (0.2–1.5 s per move), **Low (320 px)** or **High (640 px)** quality, a final-frame hold, coordinate and loop toggles, and a share sheet for the result.

### On-Device AI Commentary

The app can generate natural-language commentary for moves entirely on-device using Apple's [FoundationModels](https://developer.apple.com/documentation/foundationmodels) framework. Commentary respects the configured tone and temperature, and falls back to a deterministic, natural-language comment if generation is unavailable. Enable it via **Game Settings → Comment → Apple Intelligence**.

### Saved Game Widget

Add the **Saved Game** widget (small through extra-large) to your Home Screen or Mac desktop. It renders a crisp vector board of the game's displayed move together with that move's comment, and each widget can be configured to follow a different saved game. Tapping the widget deep-links straight to that game.

### Siri Shortcuts and Power Saving

- App Intents expose four actions to Siri and the Shortcuts app, on iOS and macOS alike: **"Get Go Game Information"** and **"Open Go Game"** (both for a game you pick), plus **"Get Latest Go Game Information"** and **"Open Latest Go Game"**.
- In human-vs-AI games, when the analysis overlay is hidden and it's the human's turn, the app **pauses continuous analysis to save power** (iOS/visionOS); revealing the overlay resumes it.

## Settings

Settings are split in two: **More → Settings** opens the app-wide **Global Settings** sheet (available with or without a selected game), while per-game configuration lives under **More → This Game → Game Settings**. Global Settings groups app-wide preferences plus an **Engine** section (running model/version and **Developer Mode**) and **Open-Source Licenses**.

### Global Settings

App-wide preferences in five groups:

- **Board** — Stone style (Fast / Classic), Move numbers (Last 3 moves / Last move / All moves / Marker), Show coordinate, Show pass, Vertical flip, and Show chart/comments.
- **Analysis** — Analysis information (Winrate / Score / All / None), Analysis style (Fast / Classic), Show ownership, Show win rate bar.
- **Sound & Haptics** — Sound effect, Haptic feedback, Show visits/s.
- **Accessibility** — a **Voice Control** help screen listing the phrases that drive the board, worded per platform ("Tap K 10" on iOS, "Click K 10" on the Mac). Every intersection and the pass tile are exposed as named targets, so Voice Control and VoiceOver can play moves through the same legality checks as a tap.
- **Game List** — Large thumbnails.

### Engine

Shows the running **Model** and engine **Version**; tapping either (and confirming) quits the engine and returns to the model picker. This section also hosts **Developer Mode**, a raw [GTP command](https://github.com/ChinChangYang/KataGo/blob/ios-dev/docs/GTP_Extensions.md) console with a scrolling message log and a text field for commands such as `list_commands`.

![GTP Console Screenshot](docs/screenshots/CommandView.png)

### Game Settings

Per-game settings in six sub-screens:

- **Name** — the game's name.
- **Rule** — a **Ruleset** picker with eleven named presets (Chinese, Chinese (OGS/KGS), Japanese, Korean, AGA, BGA, AGA Button, New Zealand, Tromp-Taylor, Stone Scoring, Ancient Territory) plus **Custom**, sitting over the individual knobs: Board width and height (default 19x19), Ko rule (Simple / Positional / Situational), Scoring rule (Area / Territory), Tax rule (None / Seki / All), Multi-stone suicide, Has-button, White handicap bonus, and Komi (default 7.5). New games default to the **Tromp-Taylor** preset. Presets are expanded by the engine's own SGF rules parser so they cannot drift, and editing any individual knob flips the picker to **Custom**. The Mac carries the same picker in its Config editor and New Game dialog.
- **Analysis** — Analysis for (Both / Black / White), Hidden analysis visit ratio, Analysis wide root noise, Max analysis moves (default 50), and Analysis interval (default 50).
- **AI** — White advantage (playout doubling advantage), plus a per-side profile picker: **AI** (the full-strength engine, with a 0–60 s "Time per move" control), human-style ranks **9d through 25k**, or **Pro 1800 through Pro 2023** profiles. Rank and pro profiles play with a fixed visit budget so that rank means strength (400 visits for 9d and pro profiles, 40 for the rest), and a side left as Human is still analyzed with the strongest network.
- **Comment** — the **Apple Intelligence** toggle, a commentary **Tone** picker (Technical, Educational, Encouraging, Enthusiastic, Poetic), and a **Temperature** stepper (0–1).
- **SGF** — view, paste, or edit the game's SGF text directly.

## KataGo Anytime on Apple Vision Pro

The Vision Pro app is a separate target (`KataGo Anytime Vision`) — not the iPhone app in a window. It opens a **volumetric window** containing a real-scale 3D goban built in RealityKit (about 0.46 x 0.50 m for a 19x19), with stones, candidate-move markers, and ownership squares placed in the scene:

- **A game controller plays the moves.** The left stick or D-pad glides a ghost stone across the board, **A** plays it, **Y** passes, **B** shows/hides the analysis overlay, **X**/**L1** step back and **R1** steps forward (hold **L1** or **R1** to repeat), and **L2**/**R2** jump to the start and end of the game. Until a controller connects the app says **Connect a controller to play**; a mapping legend appears automatically the first time one does. Pinch works on the flat ornaments — menus, the game list, settings — but not on the board itself.
- **Ornaments** ring the volume: a bottom-front bar with the player chips (pinch one to flip that side between Human and AI), a Games toggle, the analysis sparkle, a Settings gear, and the controller legend. The Games ornament lists your iCloud-synced games and carries **New Game** — 9x9 / 13x13 / 19x19 quick sizes plus a **Custom** card with width and height steppers for any rectangle.
- **Settings** (right-side card) holds Analysis information (Winrate / Score / All / None), Show ownership, a board orientation toggle between **tabletop and standing**, the neural-net picker, and **Max Board Size**; changing the last one quits and respawns the engine with a new neural-net buffer.
- The engine runs **in-process on CoreML/ANE only** — the GPU belongs to the 90 Hz compositor. A game larger than the launched Max Board Size refuses to load and points you at that setting.

The Saved Game widget and `katago-anytime://` deep links work here too.

## KataGo Anytime on the Mac

The Mac app is native AppKit with a three-pane window:

- A **library sidebar** of your games (live-refreshed as iCloud changes arrive from other devices).
- The **board** in the center.
- An **inspector** with three tabs — **Chart** (score chart stacked over the moves list), **Comments**, and **Info** — switchable with **⌘1–⌘3**.

Everything is reachable from the menu bar: File (New Game, Import, Share, Export GIF, **Re-sync from iCloud**), Game (Allow Editing ⌘E, Play Best Move, Pass, Deactivate Branch, Deep Analysis Report), Analysis (toggle/pause/clear, ownership), Navigate, and Window (**Manage Models**, **Manage Opening Books**). Move navigation is keyboard-driven: **↑ / ↓** step one move back/forward, **← / →** jump ten, and **⌥⌘← / ⌥⌘→** go to the start/end of the game. LizzieYzy-style bare-key hotkeys work whenever you're not typing: **Space** toggles analysis, **,** plays the engine's best move, and **P** passes. Hovering the score chart previews a position; clicking commits the board to it.

- **Save** ⌘S — commit the game you are editing to iCloud. While a game is
  unlocked its changes are unsaved: they live in memory and in a local
  recovery file, and never reach iCloud until you save.
- **Revert to Saved** — throw away unsaved changes and reload the saved game.

A new game (⌘N) has no library row until you save it. Switching games,
closing the window or quitting with unsaved changes asks first.

Under the hood the Mac app runs the engine in the sandboxed `katago-engine` subprocess described in [Inference Backends](#inference-backends), so an engine crash never takes the app down.

## KataGo Anytime on Apple TV

The Apple TV app reviews, spectates, **and plays ranked games against KataGo**:

- **Library** — your iCloud-synced games in a grid (with sync-aware empty states while iCloud is catching up), plus **Search** and **Settings** tabs. A permanent **Play KataGo** card opens **New Game**. Unfinished human-vs-AI games — including ones started on iPhone, iPad, or Mac — show a **Continue** badge and reopen for play; finished or symmetric (AI-vs-AI) games open the read-only review as usual.
- **New Game** — board size (9x9 / 13x13 / 19x19 quick sizes, or a custom width/height picker up to the current Max Board Size), the same eleven named ruleset presets as [Game Settings](#settings), KataGo's rank (**AI**, human-style ranks **9d through 1d** and **1k through 25k**, or **Pro 1800 through Pro 2023**), a classic handicap (0, or 2 through 9 stones — always placed for Black, with komi 0.5 and White moving first), and your color. **Start Game** creates the record and hands off straight into Play.
- **Play** — a full-bleed board with the D-pad aiming a ghost stone and **Select** playing it; the side panel has **Pass**, **Undo**, and an analysis-overlay eye toggle. With a game controller, **X**/**L1** undoes (hold to take back further moves) and **Y** passes. Two passes end the game with a result overlay, and the finished game persists like any other saved game. Games created on Apple TV sync to your other devices over iCloud, same as everywhere else.
- **Review** — step through a game read-only with a live **Top Moves** list; clicking a candidate move plays it out as a variation.
- **Self-play** — watch KataGo play itself endlessly; an idle attract mode starts a demo game on its own.
- **Settings → Diagnostics** — restart the engine, re-download the library from iCloud, run a CoreML benchmark across all four `MLComputeUnits` configurations, and toggle a live memory overlay.

The TV app runs the built-in 18-block network and the human-SL network (for ranked play) on the Neural Engine, and limits downloadable nets to 100 MB or less.

## KataGo Anytime on Apple Watch

The Watch app is a standalone reader for your game library:

- Your **saved games**, synced over iCloud, listed newest first.
- Open one and **scrub its moves with the Digital Crown**. Boards are replayed on the watch from the game's own SGF, so every position is available — not only the ones another device happened to visit.
- A **Review page** per position: win rate, score, the engine's best move, and any commentary the game already had saved. The watch runs no engine and computes nothing.
- A **Last Game complication** (inline, circular, and rectangular) for your watch face. It refreshes while the Watch app is open.

The Watch app does not connect to your iPhone and cannot change a game. Games are created on iPhone, iPad, Mac, Apple TV, or Vision Pro and reach the watch through iCloud.

## KataGo Anytime in Safari

**KataGo Anytime for Safari** is a web extension that blends KataGo analysis into Go games you find on the web. It ships as two appexes — `KataGoAnytimeSafariExt`, embedded in the Mac app, and `KataGoAnytimeSafariExtIOS`, embedded in the iOS app — and you enable it in Safari's Extensions settings.

It is **not tied to particular sites**: the content script runs on all URLs and attaches to any page that embeds a **WGo.js** kifu player. When it finds one, it injects a shadow-DOM panel with:

- **Analyze / Stop / Re-analyze**, with `n / total` progress as the sweep runs.
- A whole-game **win rate and score chart**, and a per-move tooltip (`Move N - Black 57.3% - B+4.2 - 1234 visits`).
- **Candidate moves and ownership drawn onto the site's own board**, with a Winrate / Score / All display selector.

The two platforms are not equivalent. On **macOS** the extension spawns the sandboxed `katago-engine` subprocess running the full built-in 18-block network on the Neural Engine with 8 threads. On **iOS** the engine runs **in-process inside the appex** under an 80 MB jetsam cap, so it uses the tiny bundled `b24c64` network on the Neural Engine with a single thread and a 19x19 buffer — noticeably weaker than the app itself.

> When developing the macOS extension, run the host app from `/Applications`; Safari will not load the appex from a DerivedData build location.

## KataGo Anytime in Messages

`KataGoAnytimeMessages` is an iMessage app for playing **correspondence Go against another person** inside a Messages thread. It contains **no engine and no AI** — it is human-vs-human only, and links only the bridge-free `KataGoGameStore` and `GoRulesKit` packages (a pure-Swift port of the engine's board rules and scoring).

- **Setup card** — board size 2 to 37 with 9 / 13 / 19 quick buttons, the color you take, handicap 0-9 stones, and the full rule set (ko, scoring, tax, white handicap bonus) via the same named presets and Custom option as the main app.
- **Playing** — the whole game state travels on the message bubble's URL, so each tap of a bubble restores that position. Turn alternation is enforced: the board is view-only when you sent the last message. **Confirm** stages the move and Messages' own send arrow commits it.
- **Actions** — Pass and Resign during play; **Propose score**, **Accept**, and **Resume play** once the game reaches scoring. **Open in App** copies the game into your library.

## Building from Source

### Requirements

A Mac with Xcode and the OS 26 SDKs (Apple silicon recommended). The engine and all app targets build from the one Xcode project below.

### Clone the Repository

Clone the `ios-dev` branch into a directory named `KataGo-ios-dev`:
```
git clone https://github.com/ChinChangYang/KataGo.git -b ios-dev KataGo-ios-dev
```

Transition into the directory specific to the app:
```
cd KataGo-ios-dev/ios/KataGo\ iOS
```

### Supply the Model Resources

The app loads its model files from the `Resources/` directory. These `.bin.gz` networks are gitignored and must be supplied by you before building. Place the following files in `Resources/`:

- `default_model.bin.gz` — the built-in KataGo network (an 18-block `b18c384nbt` net).
- `b18c384nbt-humanv0.bin.gz` — the human-style (human SL) network used for human-like profiles.
- `default_gtp.cfg` — the GTP configuration (already present in the repository).

You do **not** need to download or unzip a CoreML `.mlpackage`. The app converts the `.bin.gz` network into a CoreML model on the fly at runtime and caches the result.

> **Note:** Additional neural networks and the opening books are downloaded **in-app at runtime**; they do not need to be placed in `Resources/`.

### Open and Sign in Xcode

Open the project in [Xcode](https://developer.apple.com/xcode/):
```
open "KataGo Anytime.xcodeproj"
```

The project has five schemes: **KataGo Anytime** (iOS), **KataGo Anytime Mac**, **KataGo Anytime Vision**, **KataGo Anytime TV**, and **KataGo Anytime Watch**. The `KataGo Anytime` scheme supports neither macOS nor visionOS — use the platform's own scheme.

Configure code signing in Xcode under the project's "Signing & Capabilities" section. Select an appropriate code signing identity and development team, typically linked to an Apple Development certificate and a Team ID registered with the Apple Developer Program.

Refer to the screenshot below for guidance on configuring code signing in Xcode:

![Screenshot of Xcode signing](docs/screenshots/Xcode_Signing.png)

### Build Commands

You can build and run from Xcode via "Product -> Run" (or `Command + R`), or from the command line:
```
# iOS Simulator
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug

# visionOS Simulator
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug

# macOS
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug

# tvOS Simulator
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV'

# watchOS Simulator
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'
```

### Tests

Tests run on the iOS Simulator (the test target does not support the other platforms). The default **FastTestPlan** runs the unit tests; **FullTestPlan** adds the UI tests:
```
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'

# Include the UI tests
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan FullTestPlan
```

### iCloud and App Group Identifiers

Game sync uses the CloudKit container `iCloud.chinchangyang.KataGo-iOS.tw`, and the widgets share data through the App Group `group.chinchangyang.KataGo-iOS.tw`. When you build under your own team, remap these entitlements to containers and groups of your own.

### Troubleshooting: "Untrusted Developer" on Device

**Problem: Installing Apps from Outside the App Store**

* **Cause:** iOS devices are designed to prioritize security and primarily install applications from Apple's App Store. Apps compiled from source code are not automatically trusted.
* **Symptoms:** When trying to install the app, you receive an error message similar to "Untrusted Developer."

**Solution: Manually Trusting the Developer**

1. **Attempt Installation:**  Try to build and run the app as instructed in this documentation. If you receive an "Untrusted Developer" error, proceed to the next steps.

2. **Open Settings:**
   * Locate the Settings app on your iPhone or iPad.

3. **Find Device Management:**
   * Navigate to either:
     * "General" -> "Device Management"
     * "General" -> "VPN & Device Management"
     * **Note:** The exact location may vary depending on your iOS version.

4. **Locate the App Profile:**
   * Under "Device Management" look for a profile related to the app. It might be named after you.

5. **Trust the App:**
   * Tap on the app profile.
   * Choose the option to "Trust" or "Verify App."

6. **Reattempt Installation:**  The installation process should now proceed.

**Important Notes:**

* **Temporary Trust:**  Developer certificates and trusted profiles sometimes expire. You may need to repeat this process periodically.

## Architecture Notes for Developers

- **`KataGoUICore`** — a shared SwiftPM package holding most cross-platform logic. It vends four products: `KataGoUICore` (models, services, SwiftUI rendering, and the C++ bridge), `CoreMLCacheKit` (a dependency-light CoreML model cache), `KataGoGameStore` (bridge-free SwiftData models used by the widgets and the Watch app), and `GobanRecogKit` (the photo-import board recognition).
- **Engine seam** — every UI drives the engine through the `KataGoEngineIO` protocol via `GameSession`. iOS, visionOS, and tvOS run the engine **in-process**; macOS talks GTP over stdin/stdout pipes to the **`katago-engine` subprocess** (packages `KataGoEngineIPC` + `KataGoEngineHelper`).
- **Neural-net backend** — the compiled backend is [`cpp/neuralnet/mlxbackend.cpp`](https://github.com/ChinChangYang/KataGo/blob/ios-dev/cpp/neuralnet/mlxbackend.cpp) (`USE_MLX_BACKEND`), which dispatches each evaluation to CoreML/ANE or MLX/GPU per the configured device assignment. CoreML conversion, loading, and caching are handled on the Swift side.
- **Persistence** — SwiftData models synced through CloudKit; the widgets read from an App Group store.
