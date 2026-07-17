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
  --loading-dir: writes LoadingIcon.svg (flattened: gold + field + vector
                 stone shadows as constant-opacity ring stacks + stones,
                 R=420) and converts it to LoadingIcon.pdf via rsvg-convert
                 when available. The shadows must stay constant-opacity: an
                 SVG alpha gradient becomes a Luminosity /SMask in cairo's
                 PDF, and the visionOS runtime PDF rasterizer ignores those,
                 rendering each shadow as an opaque black disc.

Regenerate after any geometry change (then copy LoadingIcon.pdf into
LoadingIcon.imageset):
  python3 generate_icon.py --icon-dir "../KataGo iOS/AppIcon.icon" \
                           --preview-dir /tmp/katago-icon-preview \
                           --loading-dir /tmp/katago-loading
"""
import argparse
import math
import os
import shutil
import subprocess

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

# Cumulative-alpha profile of the stone shadow, as (radius_fraction, alpha)
# stops: black 0.35 at the center, 0.30 at 70%, fading to 0 at the rim.
# Formerly an SVG <radialGradient> with alpha stops — cairo encodes those in
# PDF as a shading masked by a Luminosity /SMask, which the visionOS runtime
# PDF rasterizer ignores (the shadow then renders as an opaque black disc).
# shadow_rings() approximates the same falloff with constant-opacity discs,
# which cairo emits as plain ExtGState /ca — no SMask.
SHADOW_STOPS = ((0.0, 0.35), (0.70, 0.30), (1.0, 0.0))


def shadow_alpha(f):
    """Piecewise-linear cumulative alpha at radius fraction f."""
    for (f0, a0), (f1, a1) in zip(SHADOW_STOPS, SHADOW_STOPS[1:]):
        if f <= f1:
            return a0 + (a1 - a0) * (f - f0) / (f1 - f0)
    return 0.0


def shadow_rings(n=12):
    """(radius_fraction, fill_opacity) pairs, outermost disc first: stacked
    constant-opacity black discs whose composited alpha 1 - prod(1 - o_i)
    matches SHADOW_STOPS at each band's midpoint. n-1 discs span the fade
    zone [0.70, 1.0]; the innermost disc covers the near-flat core (mostly
    hidden under the opaque stone anyway)."""
    step = (1.0 - SHADOW_STOPS[1][0]) / (n - 1)
    fractions = [1.0 - k * step for k in range(n)]
    rings, prev = [], 0.0
    for k, f in enumerate(fractions):
        mid = f - step / 2 if k < n - 1 else f / 2
        target = shadow_alpha(mid)
        rings.append((f, 1.0 - (1.0 - target) / (1.0 - prev)))
        prev = target
    return rings


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


def loading_svg(R):
    """Flattened LoadingIcon composite: gold background + field + vector
    stone shadows + stones. Shadows are constant-opacity ring stacks offset
    (+10, +14) at outer radius 1.12*r — NOT feDropShadow (librsvg rasterizes
    SVG filters during PDF export) and NOT an alpha radialGradient (cairo
    encodes those as a Luminosity /SMask, which the visionOS runtime PDF
    rasterizer ignores — see SHADOW_STOPS). Constant fill-opacity keeps the
    exported PDF fully vector and SMask-free."""
    r = R / (1 + math.sqrt(2))
    field_body = field_svg(R).split("</defs>\n", 1)[1].rsplit("</svg>", 1)[0]
    stones = stones_svg(R)
    stones_defs = stones.split("<defs>", 1)[1].split("</defs>", 1)[0]
    stones_body = stones.split("</defs>\n", 1)[1].rsplit("</svg>", 1)[0]
    shadows = "".join(
        f'<circle cx="{C + sx * r + 10:.2f}" cy="{C + sy * r + 14:.2f}" '
        f'r="{r * 1.12 * f:.2f}" fill="#000" fill-opacity="{o:.4f}"/>'
        for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1))
        for f, o in shadow_rings())
    return (svg_header(stones_defs)
            + f'<rect width="{CANVAS}" height="{CANVAS}" fill="{GOLD}"/>\n'
            + field_body + shadows + stones_body + "\n</svg>\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--icon-dir", help="AppIcon.icon bundle dir (writes Assets/*.svg)")
    ap.add_argument("--preview-dir", help="dir for preview.svg + match-preview.svg")
    ap.add_argument("--loading-dir",
                    help="dir for LoadingIcon.svg (+ LoadingIcon.pdf if rsvg-convert is on PATH)")
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
    if args.loading_dir:
        os.makedirs(args.loading_dir, exist_ok=True)
        svg_path = os.path.join(args.loading_dir, "LoadingIcon.svg")
        with open(svg_path, "w") as f:
            f.write(loading_svg(R_SHIP))
        if shutil.which("rsvg-convert"):
            pdf_path = os.path.join(args.loading_dir, "LoadingIcon.pdf")
            # SOURCE_DATE_EPOCH pins cairo's /CreationDate so regenerated PDFs are byte-identical
            subprocess.run(["rsvg-convert", "-f", "pdf", svg_path, "-o", pdf_path],
                           check=True,
                           env={**os.environ, "SOURCE_DATE_EPOCH": "0"})
            print(f"wrote {svg_path} and {pdf_path}")
        else:
            print(f"wrote {svg_path}; rsvg-convert not found, skipped PDF")
    if not (args.icon_dir or args.preview_dir or args.loading_dir):
        ap.error("nothing to do: pass --icon-dir, --preview-dir and/or --loading-dir")


if __name__ == "__main__":
    main()
