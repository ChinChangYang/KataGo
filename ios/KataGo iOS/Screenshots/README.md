# README screenshots

The six images in `docs/screenshots/` are generated, not hand-taken. This
directory holds the pipeline that generates them.

```
Screenshots/
  capture_screenshots.sh    # build -> boot -> seed -> capture -> frame -> verify -> caption
  frame_screenshots.swift   # composites a capture into an Apple product bezel
  verify_screenshots.py     # hard assertions on the committed PNGs
  update_captions.py        # rewrites the README's build/date captions
  bezels/                   # Apple's bezel PNGs (gitignored — see bezels/README.md)
  raw/                      # unframed captures (gitignored)
```

## The one-liner

```bash
cd "ios/KataGo iOS"
Screenshots/capture_screenshots.sh
```

Then review `docs/screenshots/*.png` and commit them together with `README.md`.

Useful variants:

```bash
Screenshots/capture_screenshots.sh --skip-build          # reuse DerivedData
Screenshots/capture_screenshots.sh --skip-build mac tv   # only these subjects
```

A partial run only rewrites the captions of the subjects it captured, so
re-shooting one platform does not stamp today's date onto the other five.

## What gets captured

| Image                 | Platform     | Screen |
|-----------------------|--------------|--------|
| `iphone-board.png`    | iPhone 17    | The board with live analysis (the hero image) |
| `ipad-board.png`      | iPad, 13"    | The same board in full-screen board mode |
| `mac-window.png`      | macOS        | The three-pane window |
| `tv-play.png`         | Apple TV     | The Play screen |
| `watch-board.png`     | Apple Watch  | The board page |
| `vision-volume.png`   | Vision Pro   | The volume, **unframed** (Apple ships no bezel) |

All six show the **same position**: move 127 of Shusaku's 1846 Ear-Reddening
Game, the ear-reddening move itself. That is deliberate — six devices showing
one moment read as one product.

## How the seed works

Every app target takes a DEBUG-only launch argument, `--screenshot-seed`
(`ScreenshotSeed.launchArgument`, in the bridge-free `KataGoGameStore` package so
the watch — which links only that and `GoRulesKit` — can use it too). With it:

* the game is created (or found) under a fixed UUID and parked on move 127;
* iOS skips the debug model picker and auto-restores the built-in network, so
  the engine comes up without a tap, and pins the light colour scheme;
* on iPad the board toggles itself into full-screen mode;
* macOS opens the game as an unsaved **draft** and sizes the window to the
  display, because Apple's Mac bezels frame a whole display;
* Apple TV seeds a *variant* — the result tag removed and the moves truncated by
  one, with White handed to the engine — because `TVPlayability` routes the
  plain, finished game to the read-only review screen and the README wants Play;
* every platform writes a marker file once its screen is worth photographing,
  and `capture_screenshots.sh` polls for that file with a ten-minute budget
  instead of sleeping. A cold simulator spends **minutes** converting and
  compiling the Core ML model; a fixed sleep would photograph the
  "Loading engine…" line.

Without the argument all of it is inert, and outside DEBUG builds
`ScreenshotSeed.isActive` is hard-wired `false`, so a release build ignores the
argument entirely.

## Prerequisites

**1. Apple's product bezels.** Download five `.dmg` packages from
[Apple Design Resources](https://developer.apple.com/design/resources/) and copy
their PNGs into `Screenshots/bezels/`. Which packages, and why the files are not
committed: **[`bezels/README.md`](bezels/README.md)**.

**2. Screen Recording permission**, for the Mac shot only. `screencapture
-l<windowID>` without it silently photographs the desktop picture instead of the
window, so the script pre-flights the permission and refuses rather than
committing a picture of your wallpaper. Grant it to the app you run the script
*from* — Terminal, iTerm, Xcode — in **System Settings ▸ Privacy & Security ▸
Screen & System Audio Recording**, then **quit and reopen that app** (the
permission is only picked up on launch). No Accessibility permission is needed.

**3. Simulators.** `iPhone 17`, `Apple TV 4K (3rd generation)`,
`Apple Watch Series 11 (46mm)`, `Apple Vision Pro`, and a 13-inch iPad. The
script creates `iPad Air 13-inch (M4)` on the newest installed iOS runtime if no
13-inch iPad exists — the default `iPad mini (A17 Pro)` is the wrong shape for
the iPad bezel, and a mismatched aspect ratio is cropped silently.

**4. The neural networks.** The same `Resources/*.bin.gz` files the app needs to
build at all; see the main README's *Supply the Model Resources*.

**5. Optional: `pngquant`** (`brew install pngquant`). The framing script uses it
when an image lands over the 400 KB cap; without it, the image is re-rendered
100 px narrower until it fits.

**6. Sign the simulators OUT of iCloud.** The seeded game is deliberately
distinctive — name "Ear-Reddening Game", UUID
`0000A11F-…-C0DE` — but on iPhone/iPad, Apple TV's library and Vision Pro the
seed goes into the real SwiftData store, and a signed-in simulator would sync it
into your own library on every device. (macOS is safe by construction: it opens
an unsaved draft that is never inserted. Apple TV's Play variant is safe too: it
lives in `TVSampleGameStore`'s private in-memory container.)

## Constraints the pipeline enforces

`verify_screenshots.py` runs at the end of every capture and exits non-zero on
the first failure:

* every `![…](docs/screenshots/….png)` in the README resolves;
* every `<!-- screenshot:NAME -->` marker has an image and vice versa (the
  marker is what `update_captions.py` finds, so an orphan silently rots);
* every PNG is 8-bit, at most **400 KB**, and 200–800 px wide;
* the centre of the iPhone, iPad and Mac shots is bright — a dark-mode capture
  fails rather than shipping.

Run it on its own any time:

```bash
python3 Screenshots/verify_screenshots.py
```

## Troubleshooting

**"… never appeared at …/screenshot-ready".** The app never reached a
photographable state. Open the simulator and look: the usual causes are a
missing `Resources/*.bin.gz` network, or the engine failing to launch. The
script reinstalls the app before every run precisely so a crash sentinel left by
a previous run cannot cause this.

**"no bezel for &lt;subject&gt;".** The message lists every PNG in `bezels/`.
Either the package is not downloaded, or Apple renamed it — add a `patterns`
override to `bezels/bezels.json` (`bezels/README.md` has the shape).

**"the centre pixel is OPAQUE".** The bezel export has a filled screen instead
of a cut-out, so the flood fill has nothing to find. Export the bezel layer
alone from the `.psd`, or set an explicit `screenRect` override.

**A framed image looks cropped.** The capture and the bezel disagree about
aspect ratio — the capture is scaled to *cover* the screen cut-out, so the
overflow is cut off. Use the bezel that matches the device you captured.

**The Mac shot is a picture of your desktop.** Screen Recording permission. See
prerequisite 2; the pre-flight is meant to catch this before the capture, so if
you see it anyway, the terminal you granted is not the one running the script.
