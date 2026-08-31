# Apple product bezels

`frame_screenshots.swift` composites each raw device capture into an Apple
product bezel. **The bezel files themselves are not in this repository, and must
not be added to it** — see [Licence](#licence) below. Everything in this
directory except this README is gitignored.

## What to download

From **[Apple Design Resources](https://developer.apple.com/design/resources/)**,
under *Product Bezels*. Each is a `.dmg` (not a zip) containing Photoshop and
PNG versions. Download these five, mount each one, and copy its **PNG** files
into this directory (subdirectories are fine — the framing script searches
recursively):

| README image     | Package                    | File |
|------------------|----------------------------|------|
| `iphone-board`   | **iPhone 17**              | `Bezel-iPhone-17.dmg` |
| `ipad-board`     | **iPad Air (M4)**          | `Bezel-iPad-Air-(M4).dmg` |
| `mac-window`     | **MacBook Pro M5**         | `Bezel-MacBook-Pro-M5.dmg` |
| `tv-play`        | **Apple TV**               | `Bezel-Apple-TV.dmg` |
| `watch-board`    | **Apple Watch Series 11**  | `Bezel-Apple-Watch-Series-11-2025.dmg` |

`vision-volume` is committed **unframed**: Apple ships no Apple Vision Pro
product bezel, and a volumetric capture is a scene rather than a screen, so
there is nothing sensible to frame it in.

Orientation matters. The iPhone and iPad shots are **portrait** (the iPad shot is
the full-screen board, which reads best tall); the Mac and Apple TV shots are
**landscape**. Pick the matching bezel where a package offers both — a portrait
capture stretched to cover a landscape cut-out is cropped, not letterboxed, and
the loss is silent.

## Telling the script which file is which

`frame_screenshots.swift` matches bezel file names against a built-in list of
case-insensitive globs (`*iPhone*17*Black*Portrait*.png` and so on) and prints
everything it found when nothing matches. Apple renames these packages every
year, so when that happens, drop a `bezels.json` beside this README:

```json
{
  "iphone-board": { "patterns": ["*iPhone 17 Pro*Portrait*.png"] },
  "watch-board":  { "screenRect": [212, 188, 496, 604] }
}
```

* `patterns` — replacement globs, tried in order.
* `screenRect` — `[x, y, width, height]` in bezel pixels, top-left origin. Only
  needed if a bezel export has an **opaque** screen: the script normally finds
  the screen by flood-filling the transparent region that contains the image
  centre, and an opaque screen leaves it nothing to find. It says so explicitly
  when that happens.

`bezels.json` is gitignored along with everything else here, so keep a note of
any override you rely on.

## Licence

Apple's product bezels are covered by the
[Apple Design Resources License Agreement](https://developer.apple.com/support/downloads/terms/apple-design-resources/Apple-Design-Resources-License-20230621-English.pdf)
(2023-06-21), and the position this directory takes is:

* **§2.A** grants a licence to use the resources for mock-ups of interfaces for
  software that runs only on Apple platforms, and says that right "includes the
  right to show the Apple Design Resources in screen shots, images or other
  depictions of such Mock-Ups". The composited PNGs in `docs/screenshots/` are
  exactly that: images of this app's own interface, and this app runs only on
  Apple platforms.
* **§2.B** forbids redistribution — "you may not rent, lease, lend, trade,
  transfer, sell, sublicense or otherwise redistribute the Apple Design
  Resources in any unauthorized way, or enable others to do so" — and §2.C
  forbids extracting or repackaging the template content. Committing the bezel
  PNGs to a public repository would be exactly that, which is why they are
  gitignored and why every contributor downloads their own copy from Apple.

Also worth reading before publishing anything derived from these:
Apple's [Marketing Resources and Identity
Guidelines](https://developer.apple.com/app-store/marketing/guidelines/), which
govern how Apple product images may appear alongside an app.

Nothing here is legal advice. If you are unsure whether a particular use is
covered, read the agreement rather than trusting this summary.
