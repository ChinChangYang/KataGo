# Vector LoadingIcon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blurry 1024 px raster `LoadingIcon` asset with a vector PDF generated from the parametric app-icon generator, preserving the current "gold ring" look at all four call sites with zero Swift changes.

**Architecture:** `generate_icon.py` (the existing parametric app-icon generator) gains a `loading_svg()` composer that flattens gold background + diagonal-sector field + gradient-built stone shadows + glossy stones into one SVG, and a `--loading-dir` CLI flag that also converts it to PDF via `rsvg-convert`. The PDF replaces `icon1024.png` inside `LoadingIcon.imageset` with `preserves-vector-representation: true`. Shadows MUST be radial gradients, not `feDropShadow` — librsvg rasterizes SVG filters during PDF export, while gradients become true PDF shadings.

**Tech Stack:** Python 3 (stdlib only), `rsvg-convert` (installed at `/opt/homebrew/bin/rsvg-convert`), Xcode asset catalogs, `xcodebuild`, `xcrun assetutil`.

**Spec:** `docs/superpowers/specs/2026-06-12-vector-loading-icon-design.md`

**Working directory for all tasks:** `/Users/chinchangyang/Code/KataGo-ios-dev` (paths below are repo-relative; quote them — they contain spaces).

**Verification harness:** there is no Python test framework in this repo. The icon pipeline's regression test is `ios/KataGo iOS/IconSource/verify_icon.py probe <png>` — 10 hard pixel assertions (field colors, gold astroid, gold corner, stone luminances) that exit 1 on failure. Use it as the "test" in the TDD loop.

---

### Task 1: Add `loading_svg()` + `--loading-dir` to the icon generator

**Files:**
- Modify: `ios/KataGo iOS/IconSource/generate_icon.py`
- Test (existing harness): `ios/KataGo iOS/IconSource/verify_icon.py`

**Context:** `generate_icon.py` already provides `field_svg(R)` (the four-diagonal-sector disc), `stones_svg(R, k=1.0, baked_shadow=False)` (four glossy stones, radial gradients `kg`/`wg`), `preview_svg(R, k)` (flattened preview with a *filter-based* baked shadow — do NOT reuse its shadow for the PDF), constants `GOLD`/`CANVAS`/`C`, and `svg_header(extra_defs)`. Geometry: `R_SHIP = 420.0`, `r = R/(1+√2)`, stone centers `(C±r, C±r)`.

- [x] **Step 1: Run the "failing test" — the flag doesn't exist yet**

```bash
cd "ios/KataGo iOS/IconSource"
python3 generate_icon.py --loading-dir /tmp/katago-loading
```

Expected: FAIL — `error: unrecognized arguments: --loading-dir` (exit code 2).

- [x] **Step 2: Add imports, shadow gradient defs, and `loading_svg()`**

In `ios/KataGo iOS/IconSource/generate_icon.py`, extend the import block at the top:

```python
import argparse
import math
import os
import shutil
import subprocess
```

Add after the `STONE_DEFS` constant (which ends at line 41):

```python
SHADOW_DEFS = """
  <radialGradient id="sg" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0%" stop-color="#000" stop-opacity="0.35"/>
    <stop offset="70%" stop-color="#000" stop-opacity="0.30"/>
    <stop offset="100%" stop-color="#000" stop-opacity="0"/>
  </radialGradient>"""
```

Add this function after `preview_svg()` (after line 106):

```python
def loading_svg(R):
    """Flattened LoadingIcon composite: gold background + field + vector
    stone shadows + stones. Shadows are radial-gradient circles offset
    (+10, +14) at radius 1.12*r — NOT feDropShadow, because librsvg
    rasterizes SVG filters during PDF export while gradients become true
    PDF shadings, keeping the exported PDF fully vector."""
    r = R / (1 + math.sqrt(2))
    field_body = field_svg(R).split("</defs>\n", 1)[1].rsplit("</svg>", 1)[0]
    stones = stones_svg(R)
    stones_defs = stones.split("<defs>", 1)[1].split("</defs>", 1)[0]
    stones_body = stones.split("</defs>\n", 1)[1].rsplit("</svg>", 1)[0]
    shadows = "".join(
        f'<circle cx="{C + sx * r + 10:.2f}" cy="{C + sy * r + 14:.2f}" '
        f'r="{r * 1.12:.2f}" fill="url(#sg)"/>'
        for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1)))
    return (svg_header(stones_defs + SHADOW_DEFS)
            + f'<rect width="{CANVAS}" height="{CANVAS}" fill="{GOLD}"/>\n'
            + field_body + shadows + stones_body + "\n</svg>\n")
```

- [x] **Step 3: Wire up the `--loading-dir` CLI flag**

In `main()`, add the argument after the `--preview-dir` line:

```python
    ap.add_argument("--loading-dir",
                    help="dir for LoadingIcon.svg (+ LoadingIcon.pdf if rsvg-convert is on PATH)")
```

Add this block after the `if args.preview_dir:` block (before the final `if not (...)` check):

```python
    if args.loading_dir:
        os.makedirs(args.loading_dir, exist_ok=True)
        svg_path = os.path.join(args.loading_dir, "LoadingIcon.svg")
        with open(svg_path, "w") as f:
            f.write(loading_svg(R_SHIP))
        if shutil.which("rsvg-convert"):
            pdf_path = os.path.join(args.loading_dir, "LoadingIcon.pdf")
            subprocess.run(["rsvg-convert", "-f", "pdf", svg_path, "-o", pdf_path],
                           check=True)
            print(f"wrote {svg_path} and {pdf_path}")
        else:
            print(f"wrote {svg_path}; rsvg-convert not found, skipped PDF")
```

Update the final guard to include the new flag:

```python
    if not (args.icon_dir or args.preview_dir or args.loading_dir):
        ap.error("nothing to do: pass --icon-dir, --preview-dir and/or --loading-dir")
```

Update the module docstring's `Outputs:` section (lines 12–16) to document the new flag:

```python
Outputs:
  --icon-dir   : writes 1-field.svg and 2-stones.svg into <icon-dir>/Assets/
  --preview-dir: writes preview.svg (shipped geometry R=420, k=1.0) and
                 match-preview.svg (original-matching R=444, k=1.03) plus a
                 background-only gold rect is baked into both previews.
  --loading-dir: writes LoadingIcon.svg (flattened: gold + field + vector
                 stone shadows + stones, R=420) and converts it to
                 LoadingIcon.pdf via rsvg-convert when available.
```

- [x] **Step 4: Generate and run the pixel-probe regression test**

```bash
cd "ios/KataGo iOS/IconSource"
python3 generate_icon.py --loading-dir /tmp/katago-loading
rsvg-convert -w 1024 -h 1024 /tmp/katago-loading/LoadingIcon.svg -o /tmp/katago-loading/LoadingIcon-1024.png
python3 verify_icon.py probe /tmp/katago-loading/LoadingIcon-1024.png
```

Expected: generator prints `wrote /tmp/katago-loading/LoadingIcon.svg and /tmp/katago-loading/LoadingIcon.pdf`; the probe prints 10 `PASS` lines (N/E/S/W field, astroid gold center, gold corner, TL/TR/BL/BR stones) and exits 0.

- [x] **Step 5: Verify the PDF is pure vector**

```bash
python3 - <<'EOF'
data = open('/tmp/katago-loading/LoadingIcon.pdf', 'rb').read()
assert b'/Shading' in data, 'FAIL: no vector shading objects in PDF'
assert b'/Image' not in data, 'FAIL: embedded raster image in PDF'
print(f'PASS: PDF is pure vector ({len(data)} bytes)')
EOF
```

Expected: `PASS: PDF is pure vector (...)` — roughly 10 KB.

- [x] **Step 6: Confirm existing outputs are unchanged (no regression in app-icon layers)**

```bash
cd "ios/KataGo iOS/IconSource"
python3 generate_icon.py --icon-dir "../KataGo iOS/AppIcon.icon" --preview-dir /tmp/katago-icon-preview
git status --porcelain "../KataGo iOS/AppIcon.icon"
```

Expected: `wrote layers to ...` then EMPTY git status output (regenerated layers are byte-identical to the committed ones).

- [x] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/IconSource/generate_icon.py"
git commit -m "feat(icon): add flattened LoadingIcon output to icon generator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Swap LoadingIcon.imageset to the vector PDF and verify all platforms

**Files:**
- Delete: `ios/KataGo iOS/KataGo iOS/Assets.xcassets/LoadingIcon.imageset/icon1024.png` (use `trash`, NOT `rm`)
- Create: `ios/KataGo iOS/KataGo iOS/Assets.xcassets/LoadingIcon.imageset/LoadingIcon.pdf` (generated)
- Modify: `ios/KataGo iOS/KataGo iOS/Assets.xcassets/LoadingIcon.imageset/Contents.json`

**Context:** The asset keeps the name `LoadingIcon`, so the four call sites (`LoadingView.swift:54`, `ModelPickerView.swift:96`, `PlusMenuView.swift:61`, `AppIntents/GameEntity.swift:128`) need no changes, and imageset contents are not registered in `project.pbxproj` (the whole `Assets.xcassets` is one build-file entry) — so NO pbxproj edits.

- [x] **Step 1: Generate the PDF and copy it into the imageset**

```bash
cd "ios/KataGo iOS/IconSource"
python3 generate_icon.py --loading-dir /tmp/katago-loading
cp /tmp/katago-loading/LoadingIcon.pdf "../KataGo iOS/Assets.xcassets/LoadingIcon.imageset/LoadingIcon.pdf"
```

Expected: `wrote /tmp/katago-loading/LoadingIcon.svg and /tmp/katago-loading/LoadingIcon.pdf`. (Only the PDF goes into the imageset — Xcode does not accept SVG in an imageset.)

- [x] **Step 2: Remove the old raster (trash, not rm)**

```bash
trash "ios/KataGo iOS/KataGo iOS/Assets.xcassets/LoadingIcon.imageset/icon1024.png"
```

- [x] **Step 3: Rewrite Contents.json for a single-scale vector asset**

Replace the full contents of `ios/KataGo iOS/KataGo iOS/Assets.xcassets/LoadingIcon.imageset/Contents.json` with:

```json
{
  "images" : [
    {
      "filename" : "LoadingIcon.pdf",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
```

(One `universal` entry with no `scale` key = "Single Scale"; `preserves-vector-representation` = the "Preserve Vector Data" checkbox.)

- [x] **Step 4: Build for iOS Simulator**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```

Expected: `** BUILD SUCCEEDED **` (no actool warnings about LoadingIcon).

- [x] **Step 5: Verify the compiled asset carries the vector representation**

```bash
cd "ios/KataGo iOS"
CAR=$(find DerivedData -path "*Debug-iphonesimulator/KataGo Anytime.app/Assets.car" | head -1)
xcrun assetutil --info "$CAR" | grep -B2 -A10 '"Name" : "LoadingIcon"'
```

Expected: a `LoadingIcon` entry is present; with Preserve Vector Data the entry (or an adjacent one) reports a PDF/vector rendition (e.g. `"Encoding" : "..."` with `"Image Type" : "kCoreThemeOnePartScale"` plus a `Vector` rendition, exact wording varies by toolchain). FAIL if no `LoadingIcon` entry exists at all.

- [x] **Step 6: Build for macOS and visionOS Simulator**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
```

Expected: `** BUILD SUCCEEDED **` for both.

- [x] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/Assets.xcassets/LoadingIcon.imageset"
git commit -m "feat(icon): replace LoadingIcon raster with generated vector PDF

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Expected: commit shows `icon1024.png` deleted, `LoadingIcon.pdf` added, `Contents.json` modified.
