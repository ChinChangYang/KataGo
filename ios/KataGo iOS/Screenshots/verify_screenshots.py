#!/usr/bin/env python3
"""Hard assertions on the committed README screenshots.

    python3 Screenshots/verify_screenshots.py [<README>]

Exits 1 on the FIRST failure with a message that says what to do about it.
Runs from anywhere: paths are resolved relative to this file, not the cwd.

What it pins, and why each check exists:

  * every `![...](docs/screenshots/....png)` in the README resolves to a file
    -- a broken image on the repository's front page is worse than no image;
  * every `<!-- screenshot:NAME -->` marker has a matching image, and every
    image has a matching marker -- the marker is what `update_captions.py`
    rewrites, so an orphaned one silently stops being maintained;
  * every image is a real 8-bit PNG, at most 400 KB and between 200 and 800 px
    wide -- the 2D board draws a photographic wood texture, so the size cap is
    a live constraint, not a formality;
  * the CENTRE of each framed phone/tablet/Mac shot is bright. The capture
    scripts force the simulator into light mode, but a simulator that refused
    (or a hand-taken replacement) would otherwise ship a dark screenshot that
    looks nothing like the app the README describes.

`load_png` is lifted from IconSource/verify_icon.py and extended to expand
PLTE/tRNS palettes, because `pngquant` -- which the framing script runs when an
image is over the size cap -- emits palette PNGs.

Stdlib only.
"""
import os
import re
import struct
import sys
import zlib

# Mirrors frame_screenshots.swift's constants. Keep them in step.
MAX_BYTES = 400 * 1024
MAX_WIDTH = 800
MIN_WIDTH = 200
# A light-mode board is wood and white stones; a dark-mode one is near-black.
# 0.35 sits well clear of both.
MIN_CENTRE_LUMINANCE = 0.35

# The six subjects, and whether their centre must read as light mode. tvOS and
# watchOS are excluded: the TV app has a dark full-bleed presentation and the
# watch is dark-only (there is no light appearance to force).
SUBJECTS = {
    "iphone-board": True,
    "ipad-board": True,
    "mac-window": True,
    "tv-play": False,
    "watch-board": False,
    "vision-volume": False,
}

IMAGE_REF = re.compile(r"!\[[^\]]*\]\((docs/screenshots/([A-Za-z0-9._-]+\.png))\)")
MARKER = re.compile(r"^<!-- screenshot:([a-z0-9-]+) -->$", re.MULTILINE)


def fail(message):
    print(f"FAIL  {message}", file=sys.stderr)
    sys.exit(1)


def load_png(path):
    """Decode an 8-bit PNG to (width, height, channels, bytes).

    Lifted from IconSource/verify_icon.py; the palette (colour type 3) branch
    is new, and is what makes this work on pngquant output.
    """
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path} is not a PNG")
    offset, idat, plte, trns = 8, b"", None, None
    width = height = colour_type = None
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind, chunk = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour_type = struct.unpack(">IIBB", chunk[:10])
            if depth != 8:
                fail(f"{path} is {depth}-bit; only 8-bit PNGs are supported")
            if chunk[12] != 0:
                fail(f"{path} is interlaced; write it non-interlaced")
        elif kind == b"PLTE":
            plte = chunk
        elif kind == b"tRNS":
            trns = chunk
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break

    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour_type]
    stride = width * channels
    out, previous, position = bytearray(), bytearray(stride), 0

    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)

    for _ in range(height):
        filter_type = raw[position]
        position += 1
        line = bytearray(raw[position:position + stride])
        position += stride
        if filter_type == 0:
            pass
        elif filter_type == 2:
            # The common case on photographic content, and the one worth a fast
            # path: a full 800x1700 image is 5 MB of per-byte Python otherwise.
            line = bytearray((x + y) & 255 for x, y in zip(line, previous))
        else:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = previous[x]
                c = previous[x - channels] if x >= channels else 0
                if filter_type == 1:
                    line[x] = (line[x] + a) & 255
                elif filter_type == 3:
                    line[x] = (line[x] + ((a + b) >> 1)) & 255
                elif filter_type == 4:
                    line[x] = (line[x] + paeth(a, b, c)) & 255
                else:
                    fail(f"{path} uses unknown PNG filter {filter_type}")
        out += line
        previous = line

    if colour_type == 3:
        if plte is None:
            fail(f"{path} is palette-coloured but has no PLTE chunk")
        expanded = bytearray()
        has_alpha = trns is not None
        for index in out:
            base = index * 3
            expanded += plte[base:base + 3]
            if has_alpha:
                expanded.append(trns[index] if index < len(trns) else 255)
        return width, height, (4 if has_alpha else 3), bytes(expanded)

    return width, height, channels, bytes(out)


def centre_luminance(decoded):
    """Mean relative luminance of the middle 20% x 20% of the image, 0...1.

    The middle of a framed capture is inside the screen: the bezel's own body
    and the transparency outside it are both far from the centre, so this
    measures the APP, not the frame. Takes an already-decoded image because
    `load_png` is pure Python and decoding an 800 px screenshot twice is
    seconds, not milliseconds.
    """
    width, height, channels, buffer = decoded
    x0, x1 = int(width * 0.4), int(width * 0.6)
    y0, y1 = int(height * 0.4), int(height * 0.6)
    total, count = 0.0, 0
    for y in range(y0, max(y0 + 1, y1)):
        row = y * width
        for x in range(x0, max(x0 + 1, x1)):
            offset = (row + x) * channels
            if channels <= 2:
                grey = buffer[offset]
                red = green = blue = grey
            else:
                red, green, blue = buffer[offset], buffer[offset + 1], buffer[offset + 2]
            total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
            count += 1
    return total / max(1, count)


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(here)                       # ios/KataGo iOS/
    readme_path = argv[1] if len(argv) > 1 else os.path.join(project_dir, "README.md")
    screenshots_dir = os.path.join(project_dir, "docs", "screenshots")

    if not os.path.exists(readme_path):
        fail(f"no README at {readme_path}")
    readme = open(readme_path, encoding="utf-8").read()

    referenced = {match.group(2)[:-4] for match in IMAGE_REF.finditer(readme)}
    marked = set(MARKER.findall(readme))

    if not referenced:
        fail(f"{readme_path} references no docs/screenshots/*.png at all")

    unknown = referenced - set(SUBJECTS)
    if unknown:
        fail("the README references screenshots this script does not know about: "
             f"{', '.join(sorted(unknown))}. Add them to SUBJECTS here and to "
             "frame_screenshots.swift.")

    if marked != referenced:
        missing_marker = referenced - marked
        orphan_marker = marked - referenced
        parts = []
        if missing_marker:
            parts.append("images with no <!-- screenshot:NAME --> marker: "
                         + ", ".join(sorted(missing_marker)))
        if orphan_marker:
            parts.append("markers with no image reference: "
                         + ", ".join(sorted(orphan_marker)))
        fail("; ".join(parts) + " (update_captions.py rewrites captions by marker, "
             "so the two must agree)")

    for name in sorted(referenced):
        path = os.path.join(screenshots_dir, f"{name}.png")
        if not os.path.exists(path):
            fail(f"{path} is referenced by the README but does not exist. "
                 "Run Screenshots/capture_screenshots.sh.")
        size = os.path.getsize(path)
        if size > MAX_BYTES:
            fail(f"{name}.png is {size // 1024} KB, over the "
                 f"{MAX_BYTES // 1024} KB cap")
        decoded = load_png(path)
        width, height = decoded[0], decoded[1]
        if not MIN_WIDTH <= width <= MAX_WIDTH:
            fail(f"{name}.png is {width} px wide; expected {MIN_WIDTH}...{MAX_WIDTH}")
        detail = f"{width}x{height}, {size // 1024} KB"
        if SUBJECTS[name]:
            luminance = centre_luminance(decoded)
            if luminance <= MIN_CENTRE_LUMINANCE:
                fail(f"{name}.png has a centre luminance of {luminance:.2f}, at or "
                     f"below {MIN_CENTRE_LUMINANCE} -- this looks like a DARK-MODE "
                     "capture. Force the simulator light "
                     "(`xcrun simctl ui <udid> appearance light`) and re-capture.")
            detail += f", centre luminance {luminance:.2f}"
        print(f"PASS  {name}.png  ({detail})")

    print(f"{len(referenced)} screenshot(s) verified")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
