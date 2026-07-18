#!/usr/bin/env python3
"""iMessage icon STACK generator for the KataGoAnytimeMessages extension.

At iOS 26 deployment, actool refuses the legacy stickersiconset runtime
sizes ("did not have any applicable content") — the extension's runtime
icon must be an Icon Composer icon stack (.icon). Messages then renders
its wide surfaces (app drawer tile ~60x45, transcript bubble badge
~27x20) by NON-UNIFORMLY squeezing the square stack, which would turn the
yotsudomoe disc into an ellipse. This script therefore copies the app's
AppIcon.icon and wraps each SVG layer in a 0.75 horizontal pre-compression
(1024*(1-0.75)/2 = 128 px recentering) so the system's ~4:3 stretch lands
back on perfect circles. The square contexts (Messages settings) show a
slightly narrow disc — the wide surfaces are the ones users see.

Regenerate after any icon geometry change:
  python3 generate_imessage_iconstack.py \
      --app-icon "../KataGo iOS/AppIcon.icon" \
      --out "../KataGoAnytimeMessages/iMessage App Icon.icon"
"""
import argparse
import os
import re
import shutil

SQUEEZE = 0.75
MARKER = "pre-squeeze"


def transform_svg(path):
    text = open(path).read()
    if MARKER in text:
        return False
    match = re.match(r"(<svg[^>]*>)(.*)(</svg>\s*)$", text, re.S)
    if not match:
        raise SystemExit(f"could not parse {path}")
    tx = 1024 * (1 - SQUEEZE) / 2
    out = (
        match.group(1)
        + f"\n<!-- {MARKER}: Messages stretches the square stack into ~60x45; "
        + f"{SQUEEZE} x-compression restores circles -->\n"
        + f'<g transform="translate({tx:g},0) scale({SQUEEZE},1)">'
        + match.group(2)
        + "</g>\n"
        + match.group(3)
    )
    open(path, "w").write(out)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-icon", required=True, help="the app's AppIcon.icon directory")
    parser.add_argument("--out", required=True, help="the extension's .icon directory to (re)create")
    args = parser.parse_args()

    if os.path.exists(args.out):
        shutil.rmtree(args.out)
    shutil.copytree(args.app_icon, args.out)
    changed = 0
    assets = os.path.join(args.out, "Assets")
    for name in sorted(os.listdir(assets)):
        if name.endswith(".svg") and transform_svg(os.path.join(assets, name)):
            changed += 1
    print(f"wrote {args.out} ({changed} SVG layers pre-squeezed by {SQUEEZE})")


if __name__ == "__main__":
    main()
