# Vector App Icon (Yotsudomoe) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blurry raster app icon with a parametric vector icon delivered as a layered Icon Composer `AppIcon.icon` bundle (SVG layers) consumed by Xcode 26 for iOS and macOS, keeping the existing `solidimagestack` for visionOS.

**Architecture:** A Python generator (`generate_icon.py`) computes the icon geometry (diagonal-sector disc + four mutually tangent glossy stones, `r = R/(1+√2)`) and emits two SVG layer files into a hand-authored `AppIcon.icon` bundle plus flattened preview SVGs for verification. A verifier (`verify_icon.py`) renders the preview with `rsvg-convert`, asserts probe-pixel colors (regression test), and produces a Sobel edge overlay against the original raster icon (fidelity check). The old `AppIcon.appiconset` is deleted; the `.icon` bundle is registered in the pbxproj via the `xcodeproj` Ruby gem.

**Tech Stack:** Python 3 (stdlib only: zlib/struct/math), `rsvg-convert` (`/opt/homebrew/bin/rsvg-convert`), Ruby `xcodeproj` gem 1.27.0, `xcodebuild`, `xcrun assetutil`.

**Spec:** `docs/superpowers/specs/2026-06-12-vector-app-icon-design.md`

**Verified facts (do not re-derive):**
- Icon Composer: `/Applications/Xcode.app/Contents/Applications/Icon Composer.app` (Xcode 26.5 / 17F42).
- `icon.json` schema example (known-good, from `/Users/chinchangyang/Code/stone-path/StonePath/AppIcon.icon`): top-level `fill`, `groups` (listed **front-to-back**), `supported-platforms`; each group: `layers: [{image-name, name}]`, `shadow: {kind, opacity}`, `translucency: {enabled, value}`; assets in `Assets/` subdir. `solid` fill kind and SVG layer assets are supported (strings present in IconComposerFoundation framework: `solid`, `color-space-for-untagged-svg-colors`, `svg-contains-text`).
- `.icon` UTI: `com.apple.iconcomposer.icon`; pbxproj `lastKnownFileType` is expected to be `folder.iconcomposer.icon` (verify at build; harmless if Xcode re-types it).
- KataGo pbxproj: objectVersion 56, NO synchronized groups — file refs must be added explicitly (use the `xcodeproj` gem; app target name: `KataGo Anytime`).
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` already set for the app target (matches `AppIcon.icon` basename); leave unchanged.
- Gold `#CC994C` = `srgb:0.80000,0.60000,0.29804,1.00000`.
- Original icon for fidelity comparison: `ios/KataGo iOS/KataGo iOS/Assets.xcassets/AppIcon.appiconset/icon1024.png` (copy it before deleting the appiconset — Task 2 does this).
- Do **not** push to the remote (Xcode Cloud free-tier budget); commits only.

---

### Task 1: Icon generator script

**Files:**
- Create: `ios/KataGo iOS/IconSource/generate_icon.py`

- [x] **Step 1: Write the generator**

Create `ios/KataGo iOS/IconSource/generate_icon.py` with exactly this content:

```python
#!/usr/bin/env python3
"""Parametric generator for the KataGo Anytime app icon ("yotsudomoe").

Geometry (see docs/superpowers/specs/2026-06-12-vector-app-icon-design.md):
- 1024x1024 canvas, disc of radius R centered at C=512.
- Disc split into 4 sectors along the DIAGONALS: N white, E black, S white, W black.
- Four glossy stones of radius r = R/(1+sqrt(2)) centered at (C±r, C±r):
  TL black, TR white, BL white, BR black. Stones are mutually tangent and
  tangent to the rim; the gold background shows through a central hole of
  radius r as a four-pointed astroid.

Outputs:
  --icon-dir   : writes 1-field.svg and 2-stones.svg into <icon-dir>/Assets/
  --preview-dir: writes preview.svg (shipped geometry R=420, k=1.0) and
                 match-preview.svg (original-matching R=444, k=1.03) plus a
                 background-only gold rect is baked into both previews.

Regenerate after any geometry change:
  python3 generate_icon.py --icon-dir "../KataGo iOS/AppIcon.icon" \
                           --preview-dir /tmp/katago-icon-preview
"""
import argparse
import math
import os

GOLD = "#CC994C"
FIELD_WHITE = "#E0E0E0"
FIELD_BLACK = "#0a0a0a"
CANVAS = 1024
C = CANVAS / 2.0

STONE_DEFS = """
  <radialGradient id="kg" cx="0.38" cy="0.30" r="0.85">
    <stop offset="0%" stop-color="#fff"/><stop offset="7%" stop-color="#e6e6e6"/>
    <stop offset="20%" stop-color="#8f8f8f"/><stop offset="42%" stop-color="#383838"/>
    <stop offset="72%" stop-color="#141414"/><stop offset="100%" stop-color="#050505"/>
  </radialGradient>
  <radialGradient id="wg" cx="0.38" cy="0.30" r="0.92">
    <stop offset="0%" stop-color="#fff"/><stop offset="34%" stop-color="#fbfbfb"/>
    <stop offset="70%" stop-color="#ededed"/><stop offset="100%" stop-color="#d2d2d2"/>
  </radialGradient>"""


def svg_header(extra_defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}">\n<defs>{extra_defs}\n</defs>\n')


def field_svg(R):
    """Annular diagonal sectors (outer radius R, inner hole radius r)."""
    r = R / (1 + math.sqrt(2))
    Rq = R / math.sqrt(2)
    rq = r / math.sqrt(2)
    # outer diagonal points
    NW, NE = (C - Rq, C - Rq), (C + Rq, C - Rq)
    SE, SW = (C + Rq, C + Rq), (C - Rq, C + Rq)
    # inner diagonal points
    nw, ne = (C - rq, C - rq), (C + rq, C - rq)
    se, sw = (C + rq, C + rq), (C - rq, C + rq)

    def P(p):
        return f"{p[0]:.2f} {p[1]:.2f}"

    def sector(A, B, b, a, fill):
        # outer arc A->B clockwise, line to inner point b, inner arc b->a ccw, close
        return (f'<path d="M {P(A)} A {R:.2f} {R:.2f} 0 0 1 {P(B)} L {P(b)} '
                f'A {r:.2f} {r:.2f} 0 0 0 {P(a)} Z" fill="{fill}"/>')

    body = (sector(NW, NE, ne, nw, FIELD_WHITE)    # N sector
            + sector(NE, SE, se, ne, FIELD_BLACK)  # E sector
            + sector(SE, SW, sw, se, FIELD_WHITE)  # S sector
            + sector(SW, NW, nw, sw, FIELD_BLACK)) # W sector
    return svg_header() + body + "\n</svg>\n"


def stones_svg(R, k=1.0, baked_shadow=False):
    """Four glossy stones. k>1 oversizes stones (used only for the
    original-matching preview). baked_shadow simulates the Liquid Glass
    per-layer shadow in flat previews; the shipped layer has NO filter."""
    r = R / (1 + math.sqrt(2))
    rs = r * k
    cen = [(C - r, C - r, "kg"), (C + r, C - r, "wg"),
           (C - r, C + r, "wg"), (C + r, C + r, "kg")]
    defs = STONE_DEFS
    open_g, close_g = "<g>", "</g>"
    if baked_shadow:
        defs += ('\n  <filter id="ssh" x="-40%" y="-40%" width="180%" height="180%">'
                 '<feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="#000" '
                 'flood-opacity="0.2"/></filter>')
        open_g = '<g filter="url(#ssh)">'
    body = open_g
    for x, y, g in cen:
        body += f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{rs:.2f}" fill="url(#{g})"/>'
    body += close_g
    return svg_header(defs) + body + "\n</svg>\n"


def preview_svg(R, k=1.0):
    """Flattened composite: gold background + field + stones (baked shadow)."""
    field_body = field_svg(R).split("</defs>\n", 1)[1].rsplit("</svg>", 1)[0]
    stones = stones_svg(R, k=k, baked_shadow=True)
    stones_defs = stones.split("<defs>", 1)[1].split("</defs>", 1)[0]
    stones_body = stones.split("</defs>\n", 1)[1].rsplit("</svg>", 1)[0]
    return (svg_header(stones_defs)
            + f'<rect width="{CANVAS}" height="{CANVAS}" fill="{GOLD}"/>\n'
            + field_body + stones_body + "\n</svg>\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--icon-dir", help="AppIcon.icon bundle dir (writes Assets/*.svg)")
    ap.add_argument("--preview-dir", help="dir for preview.svg + match-preview.svg")
    args = ap.parse_args()
    R_SHIP = 420.0   # 82% margin (approved)
    R_MATCH = 444.0  # original geometry for edge-fidelity comparison
    if args.icon_dir:
        assets = os.path.join(args.icon_dir, "Assets")
        os.makedirs(assets, exist_ok=True)
        with open(os.path.join(assets, "1-field.svg"), "w") as f:
            f.write(field_svg(R_SHIP))
        with open(os.path.join(assets, "2-stones.svg"), "w") as f:
            f.write(stones_svg(R_SHIP, k=1.0, baked_shadow=False))
        print(f"wrote layers to {assets}")
    if args.preview_dir:
        os.makedirs(args.preview_dir, exist_ok=True)
        with open(os.path.join(args.preview_dir, "preview.svg"), "w") as f:
            f.write(preview_svg(R_SHIP, k=1.0))
        with open(os.path.join(args.preview_dir, "match-preview.svg"), "w") as f:
            f.write(preview_svg(R_MATCH, k=1.03))
        print(f"wrote previews to {args.preview_dir}")
    if not (args.icon_dir or args.preview_dir):
        ap.error("nothing to do: pass --icon-dir and/or --preview-dir")


if __name__ == "__main__":
    main()
```

- [x] **Step 2: Run the generator (previews only) and render PNGs**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/IconSource"
python3 generate_icon.py --preview-dir /tmp/katago-icon-preview
/opt/homebrew/bin/rsvg-convert -w 1024 -h 1024 /tmp/katago-icon-preview/preview.svg -o /tmp/katago-icon-preview/preview.png
/opt/homebrew/bin/rsvg-convert -w 180 -h 180 /tmp/katago-icon-preview/preview.svg -o /tmp/katago-icon-preview/preview_180.png
/opt/homebrew/bin/rsvg-convert -w 1024 -h 1024 /tmp/katago-icon-preview/match-preview.svg -o /tmp/katago-icon-preview/match-preview.png
```

Expected: three PNGs written, no errors.

- [x] **Step 3: Visually inspect the previews**

Read `/tmp/katago-icon-preview/preview.png` and `/tmp/katago-icon-preview/preview_180.png` with the Read tool. Expected: gold background; disc with white field at 12 and 6 o'clock, black field at 3 and 9 o'clock; four glossy stones (TL+BR black, TR+BL white) merging into matching sectors; gold four-pointed astroid at center. The 180px version must still read as four stones around a gold star.

- [x] **Step 4: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/IconSource/generate_icon.py"
git commit -m "feat(icon): parametric vector icon generator (yotsudomoe geometry)"
```

---

### Task 2: Verifier script (probe assertions + edge overlay)

**Files:**
- Create: `ios/KataGo iOS/IconSource/verify_icon.py`
- Create: `ios/KataGo iOS/IconSource/original-icon1024.png` (reference copy)

- [x] **Step 1: Snapshot the original icon as the fidelity reference**

The appiconset will be deleted in Task 4, so keep a reference copy next to the tools:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
cp "KataGo iOS/Assets.xcassets/AppIcon.appiconset/icon1024.png" "IconSource/original-icon1024.png"
```

- [x] **Step 2: Write the verifier**

Create `ios/KataGo iOS/IconSource/verify_icon.py` with exactly this content:

```python
#!/usr/bin/env python3
"""Verify the generated icon.

Modes:
  probe   : hard assertions on probe-pixel colors of the rendered shipped
            preview (regression test; exits 1 on failure).
  overlay : Sobel edge overlay of the match-geometry preview against the
            original raster icon; writes overlay.png (yellow=match,
            red=original-only, green=render-only) and prints the match %.
            Informational: the original is hand-drawn and asymmetric, so
            expect roughly 50-60% at +/-2px tolerance. Inspect the overlay.

Usage:
  python3 verify_icon.py probe   <preview.png>
  python3 verify_icon.py overlay <original.png> <match-preview.png> <out.png>
"""
import struct
import sys
import zlib


def load_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", f"not a PNG: {path}"
    i, idat = 8, b""
    W = H = ct = None
    while i < len(d):
        ln = struct.unpack(">I", d[i:i + 4])[0]
        typ, data = d[i + 4:i + 8], d[i + 8:i + 8 + ln]
        i += 12 + ln
        if typ == b"IHDR":
            W, H, bd, ct = struct.unpack(">IIBB", data[:10])
            assert bd == 8, "only 8-bit PNGs supported"
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            break
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    stride = W * ch
    out, prev, pos = bytearray(), bytearray(stride), 0

    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)

    for _ in range(H):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                line[x] = (line[x] + paeth(a, b, c)) & 255
        out += line
        prev = line
    return W, H, ch, bytes(out)


def write_png_rgb(path, W, H, rgb):
    def chunk(t, d):
        return (struct.pack(">I", len(d)) + t + d
                + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF))
    raw = bytearray()
    for y in range(H):
        raw.append(0)
        raw += rgb[y * W * 3:(y + 1) * W * 3]
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


def probe(path):
    W, H, ch, buf = load_png(path)
    assert (W, H) == (1024, 1024), f"expected 1024x1024, got {W}x{H}"

    def px(x, y):
        o = (y * W + x) * ch
        return buf[o], buf[o + 1], buf[o + 2]

    def lum(x, y):
        r, g, b = px(x, y)
        return (r + g + b) // 3

    def is_gold(x, y):
        r, g, b = px(x, y)
        return r > g > b and r > 180 and (r - b) > 80

    checks = [
        ("N field white", lum(512, 112) >= 200),
        ("E field black", lum(912, 512) <= 30),
        ("S field white", lum(512, 912) >= 200),
        ("W field black", lum(112, 512) <= 30),
        ("astroid gold center", is_gold(512, 512)),
        ("gold corner", is_gold(40, 40)),
        ("TL stone dark", lum(338, 338) <= 120),
        ("TR stone light", lum(686, 338) >= 225),
        ("BL stone light", lum(338, 686) >= 225),
        ("BR stone dark", lum(686, 686) <= 120),
    ]
    ok = True
    for name, passed in checks:
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed
    return ok


def lum_grid(path, S=512):
    W, H, ch, buf = load_png(path)
    g = bytearray(S * S)
    for y in range(S):
        sy = int(y * H / S)
        for x in range(S):
            sx = int(x * W / S)
            o = (sy * W + sx) * ch
            g[y * S + x] = (buf[o] + buf[o + 1] + buf[o + 2]) // 3
    return g


def sobel(g, S=512, t=60):
    e = bytearray(S * S)
    for y in range(1, S - 1):
        for x in range(1, S - 1):
            i = y * S + x
            gx = ((g[i - S + 1] + 2 * g[i + 1] + g[i + S + 1])
                  - (g[i - S - 1] + 2 * g[i - 1] + g[i + S - 1]))
            gy = ((g[i + S - 1] + 2 * g[i + S] + g[i + S + 1])
                  - (g[i - S - 1] + 2 * g[i - S] + g[i - S + 1]))
            if abs(gx) + abs(gy) > t * 4:
                e[i] = 255
    return e


def dilate(e, S=512, r=2):
    d = bytearray(S * S)
    for y in range(S):
        for x in range(S):
            if e[y * S + x]:
                for dy in range(-r, r + 1):
                    for dx in range(-r, r + 1):
                        yy, xx = y + dy, x + dx
                        if 0 <= yy < S and 0 <= xx < S:
                            d[yy * S + xx] = 255
    return d


def overlay(orig_path, render_path, out_path, S=512):
    eo = sobel(lum_grid(orig_path, S), S)
    er = sobel(lum_grid(render_path, S), S)
    do, dr = dilate(eo, S), dilate(er, S)
    rgb = bytearray(S * S * 3)
    m = t = 0
    for i in range(S * S):
        R, G, B = 20, 20, 20
        if (eo[i] and dr[i]) or (er[i] and do[i]):
            R, G, B = 255, 230, 40
        elif eo[i]:
            R, G, B = 255, 60, 60
        elif er[i]:
            R, G, B = 70, 255, 90
        if eo[i]:
            t += 1
            m += 1 if dr[i] else 0
        rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = R, G, B
    write_png_rgb(out_path, S, S, rgb)
    print(f"edge match vs original: {100 * m / t:.1f}%  (overlay: {out_path})")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "probe":
        sys.exit(0 if probe(sys.argv[2]) else 1)
    elif len(sys.argv) == 5 and sys.argv[1] == "overlay":
        overlay(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(__doc__)
        sys.exit(2)
```

- [x] **Step 3: Run probe assertions — expect all PASS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/IconSource"
python3 verify_icon.py probe /tmp/katago-icon-preview/preview.png && echo "PROBES OK"
```

Expected: 10 `PASS` lines and `PROBES OK`. If any FAIL, the generator geometry or colors regressed — fix `generate_icon.py`, regenerate (Task 1 Step 2), re-run.

- [x] **Step 4: Run the edge overlay against the original**

```bash
python3 verify_icon.py overlay original-icon1024.png /tmp/katago-icon-preview/match-preview.png /tmp/katago-icon-preview/overlay.png
```

Expected: prints `edge match vs original: NN.N%` with NN ≥ 50 (the original is hand-drawn/asymmetric; ~55% is normal at ±2px).

- [x] **Step 5: Visually inspect the overlay**

Read `/tmp/katago-icon-preview/overlay.png`. Expected: stone circles and disc rim largely yellow (matching); red/green pairs run parallel and close (the original's asymmetry), with no structural divergence (no extra/missing curves).

- [x] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/IconSource/verify_icon.py" "ios/KataGo iOS/IconSource/original-icon1024.png"
git commit -m "feat(icon): icon verifier (probe assertions + edge overlay vs original)"
```

---

### Task 3: Author the AppIcon.icon bundle

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/AppIcon.icon/icon.json`
- Create (generated): `ios/KataGo iOS/KataGo iOS/AppIcon.icon/Assets/1-field.svg`, `.../Assets/2-stones.svg`

- [x] **Step 1: Generate the layer SVGs into the bundle**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/IconSource"
python3 generate_icon.py --icon-dir "../KataGo iOS/AppIcon.icon"
ls "../KataGo iOS/AppIcon.icon/Assets/"
```

Expected: `1-field.svg  2-stones.svg`.

- [x] **Step 2: Write the manifest**

Create `ios/KataGo iOS/KataGo iOS/AppIcon.icon/icon.json` with exactly this content (groups are listed front-to-back: stones in front of field; the gold background is the `fill`):

```json
{
  "fill" : {
    "solid" : "srgb:0.80000,0.60000,0.29804,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "2-stones.svg",
          "name" : "stones"
        }
      ],
      "name" : "Stones",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    },
    {
      "layers" : [
        {
          "image-name" : "1-field.svg",
          "name" : "field"
        }
      ],
      "name" : "Field",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.3
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}
```

- [x] **Step 3: Validate JSON syntax**

```bash
python3 -c "import json; json.load(open('/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGo iOS/AppIcon.icon/icon.json')); print('JSON OK')"
```

Expected: `JSON OK`.

- [x] **Step 4: Smoke-open in Icon Composer (non-blocking)**

```bash
open -a "/Applications/Xcode.app/Contents/Applications/Icon Composer.app" "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGo iOS/AppIcon.icon"
```

This hands the bundle to the GUI for the user to eyeball; do not block on it. The authoritative machine check is the Task 4 build.

- [x] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add "ios/KataGo iOS/KataGo iOS/AppIcon.icon"
git commit -m "feat(icon): layered AppIcon.icon bundle (SVG field + stones, solid gold fill)"
```

---

### Task 4: Wire .icon into the Xcode project, remove appiconset, build iOS

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Ruby script)
- Delete: `ios/KataGo iOS/KataGo iOS/Assets.xcassets/AppIcon.appiconset/`
- Keep: `ios/KataGo iOS/KataGo iOS/Assets.xcassets/AppIcon.solidimagestack/` (visionOS)

- [x] **Step 1: Register AppIcon.icon in the pbxproj**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app = proj.targets.find { |t| t.name == "KataGo Anytime" }
raise "app target not found" unless app
# anchor on ContentView.swift to find the app source group reliably
cv = proj.files.find { |f| f.path.to_s.end_with?("ContentView.swift") }
raise "ContentView.swift ref not found" unless cv
grp = cv.parent
ref = grp.new_reference("AppIcon.icon")
ref.last_known_file_type = "folder.iconcomposer.icon"
app.resources_build_phase.add_file_reference(ref)
proj.save
puts "added AppIcon.icon to group #{grp.display_name}, target #{app.name}"
'
```

Expected: `added AppIcon.icon to group KataGo iOS, target KataGo Anytime`.

- [x] **Step 2: Delete the legacy appiconset (keep solidimagestack)**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGo iOS"
git rm -r "Assets.xcassets/AppIcon.appiconset"
```

(No pbxproj change needed — the asset catalog is referenced as a whole.)

- [x] **Step 3: Build for iOS Simulator**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

**Contingency — if actool rejects the SVG layers** (error naming `1-field.svg`/`2-stones.svg`): rasterize the layers at high resolution and point the manifest at PNGs:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGo iOS/AppIcon.icon/Assets"
/opt/homebrew/bin/rsvg-convert -w 2048 -h 2048 1-field.svg  -o 1-field.png
/opt/homebrew/bin/rsvg-convert -w 2048 -h 2048 2-stones.svg -o 2-stones.png
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path("../icon.json")
j = json.loads(p.read_text())
for g in j["groups"]:
    for l in g["layers"]:
        l["image-name"] = l["image-name"].replace(".svg", ".png")
p.write_text(json.dumps(j, indent=2))
print("icon.json now references PNGs")
EOF
git rm --cached 1-field.svg 2-stones.svg 2>/dev/null; rm -f 1-field.svg 2-stones.svg
```

The SVG source of truth remains `generate_icon.py`; rebuild and continue.

- [x] **Step 4: Verify the compiled icon is in the product**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/KataGo Anytime.app" -newer "KataGo Anytime.xcodeproj/project.pbxproj" 2>/dev/null | head -1)
[ -z "$APP" ] && APP=$(find . -path "*Debug-iphonesimulator/KataGo Anytime.app" | head -1)
xcrun assetutil --info "$APP/Assets.car" 2>/dev/null | grep -m4 -i '"Name".*AppIcon\|IconStack\|"AssetType"'
```

Expected: entries naming `AppIcon` (Icon Composer icons appear as icon/IconStack asset types). If `Assets.car` lacks any AppIcon entry, the wiring failed — re-check Step 1 output and the build log for `AppIcon.icon`.

- [x] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git add -A "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" "ios/KataGo iOS/KataGo iOS/Assets.xcassets"
git commit -m "feat(icon): adopt layered AppIcon.icon; drop raster appiconset (iOS/macOS)"
```

---

### Task 5: Build macOS + visionOS, final verification

**Files:** none (verification only; fixes commit here if needed)

- [x] **Step 1: Build for macOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 2: Verify the macOS product icon**

```bash
APP=$(find . -path "*Build/Products/Debug/KataGo Anytime.app" | head -1)
ls "$APP/Contents/Resources/" | grep -i -E "icns|car"
xcrun assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null | grep -m4 -i '"Name".*AppIcon\|"AssetType"'
```

Expected: `Assets.car` present with AppIcon entries (an `AppIcon.icns` may or may not also be emitted — either is fine as long as Assets.car has the icon).

- [x] **Step 3: Build for visionOS Simulator (solidimagestack path)**

```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. The vision idiom still uses `AppIcon.solidimagestack`; if the build errors about duplicate/ambiguous `AppIcon`, exclude the `.icon` from the visionOS build by conditionalizing its membership — add to the Ruby wiring (Task 4 Step 1 file ref) a platform filter:

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
app = proj.targets.find { |t| t.name == "KataGo Anytime" }
bf = app.resources_build_phase.files.find { |f| f.file_ref&.path == "AppIcon.icon" }
raise "build file not found" unless bf
bf.platform_filters = ["ios", "macos"]
proj.save
puts "AppIcon.icon limited to ios+macos"
'
```

Then rebuild visionOS and expect success.

- [x] **Step 4: Re-run the full verification suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/IconSource"
python3 generate_icon.py --preview-dir /tmp/katago-icon-preview
/opt/homebrew/bin/rsvg-convert -w 1024 -h 1024 /tmp/katago-icon-preview/preview.svg -o /tmp/katago-icon-preview/preview.png
python3 verify_icon.py probe /tmp/katago-icon-preview/preview.png && echo ALL-OK
```

Expected: `ALL-OK`.

- [x] **Step 5: Commit any fixes made in this task**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git status --short
# if dirty:
git add -A "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "fix(icon): platform-scope AppIcon.icon for visionOS compatibility"
```

(Skip the commit if Step 3 needed no platform filter and the tree is clean.)

---

### Task 6: Human visual check on simulator (handoff)

**Files:** none

- [x] **Step 1: Install and show the Home Screen icon**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcrun simctl boot "iPhone 17" 2>/dev/null; open -a Simulator
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/KataGo Anytime.app" 2>/dev/null | head -1)
[ -z "$APP" ] && APP=$(find . -path "*Debug-iphonesimulator/KataGo Anytime.app" | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted $(defaults read "$APP/Info" CFBundleIdentifier 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
sleep 2 && xcrun simctl io booted screenshot /tmp/katago-icon-preview/home.png 2>/dev/null || true
```

Then press Home in the Simulator (Device > Home) and screenshot the icon: `xcrun simctl io booted screenshot /tmp/katago-icon-preview/home.png`; Read the screenshot to confirm the icon renders with Liquid Glass (crisp edges, system shadow between stone and field layers).

- [x] **Step 2: Report to the user**

Summarize: what shipped, where the generator lives, how to regenerate, and that dark/tinted/clear variants are system-derived (tunable later in Icon Composer by opening the committed `.icon`).

---

## Self-Review Notes

- **Spec coverage:** vector/computed ✓ (Task 1 generator, SVG layers); ≥2 layers for Icon Composer ✓ (fill + 2 groups, Task 3); crisp at any size ✓ (probe + 180px inspect, Tasks 1–2); replaces appiconset ✓ (Task 4); visionOS fallback ✓ (Task 5 Step 3); default-appearance-only ✓ (no appearance specializations in icon.json); verification approach ✓ (Tasks 2, 4, 5); risks 1–4 from spec ✓ (schema verified pre-plan; contingencies in Tasks 4–5).
- **Geometry constants** match the approved variant I: R=420, r=R/(1+√2)≈173.97, gradients/colors copied verbatim from the approved render.
- **No placeholders:** every step has complete code/commands and expected output.
