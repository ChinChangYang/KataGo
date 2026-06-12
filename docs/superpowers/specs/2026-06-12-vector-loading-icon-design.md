# Vector LoadingIcon — Design Spec

**Date:** 2026-06-12
**Status:** Approved
**Depends on:** `2026-06-12-vector-app-icon-design.md` (locked geometry, colors, stone shading)

## Goal

Replace the `LoadingIcon` asset — currently the old blurry 1024 px raster (`icon1024.png`) — with the refined vector app-icon design, delivered as a single universal **vector PDF** with *Preserve Vector Data*, so it renders crisp at every size and stays regenerable from the parametric generator.

## Current usage (all kept working, zero Swift changes)

| Call site | Use |
|---|---|
| `KataGo iOS/LoadingView.swift:54` | Rotating loading spinner; `clipShape(.circle)` + outer shadow |
| `KataGo iOS/ModelPickerView.swift:96` | Download-progress spinner; `clipShape(.circle)`, rotation = progress |
| `KataGo iOS/PlusMenuView.swift:61` | `SharePreview` fallback image (unclipped square) |
| `KataGo iOS/AppIntents/GameEntity.swift:128` | `DisplayRepresentation.Image(named: "LoadingIcon")` — requires a named asset-catalog image, which rules out a SwiftUI-only replacement |

## Locked decisions (user choices)

- **Composition: A — gold ring.** The image is the full app-icon square (gold `#CC994C` background, disc at `R=420` of 1024). The in-app circle clip therefore shows a gold ring around the disc, faithful to today's look. Unclipped uses (SharePreview, AppIntents) show the exact app-icon square.
- **Format: vector PDF.** One universal, single-scale PDF with `"preserves-vector-representation": true`. Rejected alternatives: 2048 px PNG (still raster, abandons the computed-icon goal); SwiftUI-drawn view (duplicates the design in code and still needs an asset for AppIntents).

## Construction

Flattened composite, geometry identical to the app icon (`R = 420`, `r = R/(1+√2)`, stone centers `(512±r, 512±r)`), layered bottom → top:

1. Full-bleed gold rect `#CC994C`.
2. The four-diagonal-sector field disc (reuses `field_svg(R)`).
3. **Four stone shadows as radial-gradient circles** — center offset `(+10, +14)` px from each stone center, radius `1.12·r`, gradient stops black 35% → 30% (at 70%) → 0% opacity. Gradients, not `feDropShadow`: librsvg rasterizes SVG *filters* during PDF export, while gradients become true PDF shadings. Prototype-verified: the exported PDF contains `/Shading` objects and **no** `/Image` XObjects (~10 KB).
4. The four glossy stones (reuses `stones_svg(R)`, no baked shadow).

## Changes

1. **`ios/KataGo iOS/IconSource/generate_icon.py`** — add `loading_svg()` composing the above, and a `--loading-dir DIR` CLI flag that writes `LoadingIcon.svg` and, when `rsvg-convert` is on PATH, converts it to `LoadingIcon.pdf` in the same directory (via `subprocess`; skip with a notice if the tool is absent).
2. **`ios/KataGo iOS/KataGo iOS/Assets.xcassets/LoadingIcon.imageset/`** — delete `icon1024.png` (use `trash`); add the generated `LoadingIcon.pdf`; rewrite `Contents.json` to a single universal image (no per-scale entries) with `"properties": {"preserves-vector-representation": true}`.
3. **No Swift changes, no pbxproj changes** — the asset name `LoadingIcon` is unchanged and imageset contents are discovered automatically.

## Verification

- Render `LoadingIcon.svg` at 1024 px with `rsvg-convert`; run `python3 verify_icon.py probe <png>` — all 10 pixel assertions must pass (field colors, astroid, gold corner, stone luminances; already passing on the design prototype).
- Inspect the PDF bytes: `/Shading` present, `/Image` absent.
- Build for iOS Simulator, macOS, and visionOS Simulator; all must succeed.
- `xcrun assetutil --info` on the compiled `Assets.car`: the `LoadingIcon` entry must carry the vector representation.

## Out of scope (YAGNI)

No dark-mode variant, no SwiftUI redraw of the spinner, no changes to rotation/clip/shadow modifiers at the call sites, no change to `AppIcon.icon` or the visionOS `AppIcon.solidimagestack`.
