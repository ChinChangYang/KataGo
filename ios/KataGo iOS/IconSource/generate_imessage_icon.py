#!/usr/bin/env python3
"""iMessage App Icon generator for the KataGoAnytimeMessages extension.

Messages icons are RECTANGULAR (60x45-pt family). Per the vector-only icon
policy, every raster here is rendered from the parametric SVG pipeline:
generate_icon.py's flattened preview (gold background + yotsudomoe disc) is
inlined into a wrapper SVG that letterboxes it on the gold background at each
required aspect, then rsvg-convert rasterizes the exact pixel sizes into the
extension's "iMessage App Icon.stickersiconset".

Usage:
  python3 generate_icon.py --preview-dir /tmp/katago-icon-preview
  python3 generate_imessage_icon.py --preview /tmp/katago-icon-preview/preview.svg \
      --out "../KataGoAnytimeMessages/Assets.xcassets/iMessage App Icon.stickersiconset"
"""
import argparse
import json
import os
import re
import subprocess
import tempfile

GOLD = "#CC994C"

# (filename, point size "WxH", scale, idiom, extra keys, mode)
# All entries use mode "fit" (letterbox on gold). This stickersiconset is
# the ONLY icon source for the Messages extension: with the target's
# productType set to com.apple.product-type.app-extension.messages, actool
# emits the rectangular runtime sizes as loose PNGs in the appex, injects
# MSMessagesExtensionStoreIconName + CFBundleIcons via the partial plist,
# and packs the 1024x768 ios-marketing icon into Assets.car. App Store
# validation requires all of these (build 314 was rejected with
# ITMS-90642/90649 when the target had the generic app-extension product
# type, which makes actool ignore this set). Icon Composer .icon bundles
# have no iMessage icon type — never add one named "iMessage App Icon".
# mode "fill" (stretch to the full rect) is kept for experiments but
# currently unused.
IMAGES = [
    ("icon-29@2x.png",    (29, 29),    2, "iphone",        {}, "fit"),
    ("icon-29@3x.png",    (29, 29),    3, "iphone",        {}, "fit"),
    ("icon-60x45@2x.png", (60, 45),    2, "iphone",        {}, "fit"),
    ("icon-60x45@3x.png", (60, 45),    3, "iphone",        {}, "fit"),
    ("icon-67x50@2x.png", (67, 50),    2, "ipad",          {}, "fit"),
    ("icon-74x55@2x.png", (74, 55),    2, "ipad",          {}, "fit"),
    ("icon-27x20@2x.png", (27, 20),    2, "universal",     {"platform": "ios"}, "fit"),
    ("icon-27x20@3x.png", (27, 20),    3, "universal",     {"platform": "ios"}, "fit"),
    ("icon-32x24@2x.png", (32, 24),    2, "universal",     {"platform": "ios"}, "fit"),
    ("icon-32x24@3x.png", (32, 24),    3, "universal",     {"platform": "ios"}, "fit"),
    ("icon-1024x768.png", (1024, 768), 1, "ios-marketing", {"platform": "ios"}, "fit"),
]


def inner_svg(preview_path):
    text = open(preview_path).read()
    match = re.search(r"<svg[^>]*>(.*)</svg>\s*$", text, re.S)
    if not match:
        raise SystemExit(f"could not parse {preview_path}")
    return match.group(1)


def wrapper_svg(inner, width, height, mode):
    if mode == "fill":
        # Stretch the square art to the whole rectangle (non-uniform):
        # the system's rect-to-circle squeeze then restores the circle.
        sx = width / 1024.0
        sy = height / 1024.0
        transform = f"scale({sx:.6f},{sy:.6f})"
        tx = ty = 0.0
    else:
        # Letterbox the 1024x1024 icon: fit by the SHORTER edge so the disc
        # fills the height of wide icons, centered on the gold background.
        scale = min(width, height) / 1024.0
        transform = f"scale({scale:.6f})"
        tx = (width - 1024 * scale) / 2.0
        ty = (height - 1024 * scale) / 2.0
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">\n'
        f'<rect width="{width}" height="{height}" fill="{GOLD}"/>\n'
        f'<g transform="translate({tx:.4f},{ty:.4f}) {transform}">{inner}</g>\n'
        f"</svg>\n"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", required=True, help="flattened preview.svg from generate_icon.py")
    parser.add_argument("--out", required=True, help="the .stickersiconset directory")
    args = parser.parse_args()

    inner = inner_svg(args.preview)
    os.makedirs(args.out, exist_ok=True)
    contents = {"images": [], "info": {"author": "xcode", "version": 1}}

    for filename, (pw, ph), scale, idiom, extra, mode in IMAGES:
        width, height = pw * scale, ph * scale
        svg = wrapper_svg(inner, width, height, mode)
        with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
            f.write(svg)
            svg_path = f.name
        subprocess.run(
            ["rsvg-convert", "-w", str(width), "-h", str(height),
             "-o", os.path.join(args.out, filename), svg_path],
            check=True)
        os.unlink(svg_path)
        entry = {"filename": filename, "idiom": idiom,
                 "scale": f"{scale}x", "size": f"{pw}x{ph}"}
        entry.update(extra)
        contents["images"].append(entry)

    with open(os.path.join(args.out, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {len(IMAGES)} icons + Contents.json to {args.out}")


if __name__ == "__main__":
    main()
